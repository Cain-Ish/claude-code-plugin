#!/bin/bash
# flow-guard.sh — PreToolUse hook (HarnessAudit sar_flow channel).
#
# Asks before a tool call that combines an OUTBOUND egress channel with a
# CREDENTIAL-shaped payload in the tool input. Closes the third L1 boundary
# (alongside tool-scope and resource-scope). The most realistic exfil mode
# in an LLM-driven workflow is the agent helpfully pasting a session secret
# into an http request — the paper calls this a "flow boundary" violation.
#
# In scope:
#   - Bash: command must contain a network tool AND a credential pattern.
#   - WebFetch / WebSearch: any credential pattern anywhere in tool_input.
#
# Out of scope (other guards / non-egress):
#   - Edit / Write / Read — local file ops, handled by resource-scope.
#   - Task — subagent dispatch is a separate channel (future work).
#
# Patterns detected (conservative; false-negative leaning):
#   JWT, AWS Access Key, GitHub PAT (legacy + fine-grained), Anthropic
#   key, OpenAI key, Slack token, PEM private key block, Bearer + long
#   base64 (≥40 chars) bundle. All anchored with surrounding context to
#   avoid tripping on test fixtures of random base64.
#
# Verdict: ask. Reason carries which pattern matched (no secret value).
# Logged to audit-log.jsonl. Kill switch: SB_FLOW_GUARD=off.
# Always exits 0.
set -u

[ "${SB_FLOW_GUARD:-on}" = "off" ] && exit 0

# >>> sb-guard-fastpath (B7) — pasted byte-identical into every deny/ask PreToolUse guard;
# tests/test-guard-wiring.sh fails on drift. A PreToolUse hook that answers after its timeout is
# CANCELLED and the tool RUNS (CLI 2.1.283 probe, 2026-09-28; ~217 guard runs failed open in four
# heavy sessions). So each guard decides its dangerous cases here first, with bash builtins only:
# no lib.sh, no jq, no process at all (one `date` on bash < 4.2 for an audit timestamp). The fast
# path asks/denies only when certain and never allows: whatever it cannot decide falls through
# to the guard's full logic. Helper locals carry a per-helper prefix so no caller's VAR name can be
# shadowed by them (printf -v writes through dynamic scope). Assignments that substitute with a
# quoted replacement stay unquoted: bash <= 4.2 did not quote-remove it inside "${…}".
# Every helper is linear in the payload, since a 512 KB Write reaches the full logic too:
# ${X#*KEY}, ${X%%KEY*} and ${X%"\n"} rescan the string once per position (O(n^2): 20-220 s per
# guard at 512 KB on MSYS, far past the 5 s timeout), so text is cut by word splitting
# (_fp_split) and tested with `case` globs and fixed-string substitutions.
_fp_bs='\' _fp_q='"' _fp_us=$'\037' _fp_nl=$'\n' _fp_cr=$'\r' _fp_tab=$'\t'
_fp_re='^[[:space:]]*:[[:space:]]*$'
_fp_rebs='(\\+)$'   # =~-bounded: matched only against _fp_str's tail slice of <= 65 characters
_fp_uc=ABCDEFGHIJKLMNOPQRSTUVWXYZ _fp_lc=abcdefghijklmnopqrstuvwxyz
# _fp_str walks one bash iteration per escaped quote and per escape (~110-120 us each on MSYS): a
# value with more than _fp_emax of either is left to jq (one spawn, ~0.1 s for any size). DA #1
# (0.54.1): 100k \" in a 300 KB command took 10.8 s per guard, past the 5 s timeout — a fail-open.
# Measured at the cap on a loaded MSYS box: 2000 added ~0.4 s to a persona-tool-guard call (it
# decodes on the fast path, then again in the full logic) and ~0.8 s to a flow-guard WebFetch with
# url and prompt both at the cap; 1000 adds ~0.17 s / ~0.38 s, about what the jq fallback costs.
_fp_emax=1000
# bash < 4.3 (macOS /bin/bash is 3.2) steps the builtin payload reader aside altogether: _fp_at,
# and so _fp_str, return 2 and jq decides — main's behaviour there. That bash runs even a
# one-match ${v//pat/rep} in O(candidates x length^2) (4.3 added the fixed-length match jump) and
# mangles bytes the reader leans on (its CTLESC/CTLNUL quoting: an empty field of a joined slice
# came back as \177 on the macOS lane, 0.54.1 F8); a jq spawn is cheap on a native fork, and the
# spawn tax this fast path exists for is an MSYS one.
_fp_ob=0
{ [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; } && _fp_ob=1
# The payload: up to 16 KiB by builtin read (bash reads a pipe a byte at a time, ~1 us/byte on
# MSYS, so a typical Edit/Bash payload costs 1-5 ms and no process); the rest by one `cat` in
# _fp_raw_all, only for a bigger payload.
_FP_RAW="" _FP_EOF=0 _FP="" _FP_I=0
_FP_A=()
IFS= read -r -d '' -n 16384 _FP_RAW || _FP_EOF=1

# _fp_raw_all: RAW = the whole payload for the full logic (trailing newlines stripped, as the old
# RAW=$(cat) did); _fp_str reads the whole payload from then on.
_fp_raw_all() {
  if [ "$_FP_EOF" = 1 ]; then RAW="$_FP_RAW"; else RAW="$_FP_RAW$(cat)"; fi
  _fp_trimnl RAW "$RAW"
  _FP_RAW="$RAW" _FP_EOF=1
}

# _fp_split SEP TEXT: _FP_A = TEXT cut at every SEP (one character) by word splitting — linear in
# every bash — with globbing off meanwhile. A trailing SEP adds no empty last field; with SEP a
# newline (IFS white space) empty lines vanish as well.
_fp_split() {
  local IFS="$1" _sp_o="$-"
  set -f
  _FP_A=($2)
  case "$_sp_o" in *f*) ;; *) set +f ;; esac
}

# _fp_feed TEXT CMD…: run CMD with TEXT and a newline on stdin. `CMD <<< "$TEXT"` only for a short
# TEXT (8192 characters, at most 32 KiB): bash >= 5.1 writes a here-string into a pipe before it
# starts the reader, and on MSYS one of 65,536..~65,650 bytes never fits — the guard hangs past its
# timeout and the tool runs. A longer TEXT goes through a process substitution, whose writer runs
# alongside the reader.
_fp_feed() {
  local _fd_t="$1"; shift
  if [ "${#_fd_t}" -le 8192 ]; then "$@" <<< "$_fd_t"; else "$@" < <(printf '%s\n' "$_fd_t"); fi
}

# _fp_at KEY: find the string value of the ONE "KEY": "…" pair in the payload. _FP_A = the payload
# from KEY on, cut at every '"' (the last field ends in a \037 sentinel, so a value that runs to the
# end of what was read never looks closed); _FP_I = the field the value starts in. 0 = found;
# 1 = absent (the whole payload was seen); 2 = undecidable — KEY occurs twice (nested or
# duplicated: jq decides which one counts), the value is not a string, the payload holds a \037,
# or KEY may be spelled with a \u escape, or bash is older than 4.3 (_fp_ob, see above). JSON
# escapes every quote inside a string, so a "KEY" followed by ':' is always a real key, never text
# inside a value.
_fp_at() {
  local _fa_f _fa_i=0
  [ "$_fp_ob" = 1 ] && return 2
  case "$_FP_RAW" in
    *"$_fp_q$1$_fp_q"*) ;;
    *) [ "$_FP_EOF" = 1 ] || return 2
       case "$_FP_RAW" in *"$_fp_bs"u*) _fp_uesc "$_FP_RAW" && return 2 ;; esac
       return 1 ;;
  esac
  case "$_FP_RAW" in *"$_fp_us"*) return 2 ;; esac
  if [ "${#_FP_RAW}" -le 16384 ]; then
    _fp_split "$_fp_q" "$_FP_RAW$_fp_us"
    _FP_I=-1
    for _fa_f in ${_FP_A[@]+"${_FP_A[@]}"}; do
      if [ "$_fa_f" = "$1" ]; then [ "$_FP_I" = -1 ] || return 2; _FP_I=$_fa_i; fi
      _fa_i=$((_fa_i + 1))
    done
    [ "$_FP_I" -ge 1 ] || return 2
  else
    _fp_split "$_fp_us" "${_FP_RAW//"$_fp_q$1$_fp_q"/"$_fp_us"}"
    [ "${#_FP_A[@]}" = 2 ] || return 2
    _fp_split "$_fp_q" "${_FP_A[1]}$_fp_us"
    _FP_I=-1
  fi
  [[ ${_FP_A[$((_FP_I + 1))]-x} =~ $_fp_re ]] || return 2
  _FP_I=$((_FP_I + 2))
  [ "$_FP_I" -lt "${#_FP_A[@]}" ] || return 2
  return 0
}

# _fp_join VAR FROM TO: VAR = fields FROM..TO of _FP_A joined by the '"' _fp_split cut out. The
# slice is copied out first, then joined whole under the local IFS: bash 3.2 (macOS) turns each
# EMPTY element of a "${a[*]:from:len}" slice into its internal \177 (CTLNUL) byte — a decoded
# `q \"` came back `q "` + \177 on the macOS lane (F8) — and joins with spaces instead when the
# copy is made after `local IFS`. The _fp_ob gate keeps bash < 4.3 out of here now; the join stays
# byte-safe there all the same.
_fp_join() {
  _FP_J=("${_FP_A[@]:$2:$(($3 - $2 + 1))}")
  local IFS="$_fp_q"
  printf -v "$1" '%s' ${_FP_J[*]+"${_FP_J[*]}"}
}

# _fp_str KEY: _FP = the decoded string value of the ONE "KEY": "…" pair in the payload.
# 0 = found; 1 = absent; 2 = undecidable (_fp_at's cases, a value that runs past the 16 KiB read,
# an escape left to jq: \u \b \f, or more than _fp_emax escaped quotes or escapes). The value ends
# at the first '"' not escaped: a field that ends in an odd run of backslashes ended at an escaped
# quote.
_fp_str() {
  local _fs_v _fs_f _fs_t _fs_s _fs_n
  _FP=""
  _fp_at "$1" || return $?
  _fs_s=$_FP_I _fs_n=$(( ${#_FP_A[@]} - 1 ))
  while :; do
    [ "$_FP_I" -lt "$_fs_n" ] || return 2
    _fs_f="${_FP_A[$_FP_I]}"
    case "$_fs_f" in *"$_fp_bs") ;; *) break ;; esac
    [ $((_FP_I - _fs_s)) -lt "$_fp_emax" ] || return 2
    _fs_t="$_fs_f"; [ "${#_fs_t}" -le 65 ] || _fs_t="${_fs_t:${#_fs_t}-65}"
    [[ $_fs_t =~ $_fp_rebs ]] && [ "${#BASH_REMATCH[1]}" -le 64 ] || return 2
    [ $(( ${#BASH_REMATCH[1]} % 2 )) = 1 ] || break
    _FP_I=$((_FP_I + 1))
  done
  _fp_join _fs_v "$_fs_s" "$_FP_I"
  # Nothing escaped: the value is its own decoding.
  case "$_fs_v" in *"$_fp_bs"*) ;; *) _FP="$_fs_v"; return 0 ;; esac
  # Decode by cutting at every backslash: each field after the first starts with the escaped
  # character, except the field after an escaped backslash ("\\" leaves an empty field), which is
  # plain text. A ${v//"\"n/…} pass per escape costs O(matches x length) instead — every bash in a
  # multibyte string (117 s for a 512 KB heredoc holding one 'é'), and bash < 4.3 even in ASCII.
  local -a _fs_o=()
  local _fs_p=1
  _fp_split "$_fp_bs" "$_fs_v"
  [ "${#_FP_A[@]}" -le $((_fp_emax + 1)) ] || return 2
  for _fs_f in ${_FP_A[@]+"${_FP_A[@]}"}; do
    if [ "$_fs_p" = 1 ]; then _fs_o+=("$_fs_f"); _fs_p=0; continue; fi
    if [ -z "$_fs_f" ]; then _fs_o+=("$_fp_bs"); _fs_p=1; continue; fi
    _fs_t="${_fs_f:0:1}"
    case "$_fs_t" in
      n) _fs_t="$_fp_nl" ;;
      t) _fs_t="$_fp_tab" ;;
      r) _fs_t="$_fp_cr" ;;
      "$_fp_q"|/) ;;
      *) return 2 ;;
    esac
    _fs_o+=("$_fs_t${_fs_f:1}")
  done
  printf -v _FP '%s' ${_fs_o[@]+"${_fs_o[@]}"}
  return 0
}

# _fp_uesc TEXT: true when TEXT holds a \u escape — a 'u' right after an escaping backslash, not
# after an escaped one ("\\u" is a backslash and a 'u'). Linear, as _fp_str's decode.
_fp_uesc() {
  local _fu_f _fu_p=1
  _fp_split "$_fp_bs" "$1"
  for _fu_f in ${_FP_A[@]+"${_FP_A[@]}"}; do
    if [ "$_fu_p" = 1 ]; then _fu_p=0; continue; fi
    if [ -z "$_fu_f" ]; then _fu_p=1; continue; fi
    case "$_fu_f" in u*) return 0 ;; esac
  done
  return 1
}

# _fp_nocr VAR TEXT: TEXT without its CRs, cut at each CR and rejoined — a ${v//$'\r'/} pass costs
# O(CRs x length) in a multibyte string (a CRLF heredoc of 512 KB takes minutes).
_fp_nocr() {
  case "$2" in *"$_fp_cr"*) ;; *) printf -v "$1" '%s' "$2"; return 0 ;; esac
  _fp_split "$_fp_cr" "$2"
  printf -v "$1" '%s' ${_FP_A[@]+"${_FP_A[@]}"}
}

# _fp_trimnl VAR TEXT: VAR = TEXT with its run of trailing newlines cut, measured without a regex:
# a tail slice doubles until it holds a non-newline, then a binary search closes on the run's
# length — O(log run) slices, each tested by one `case` glob. Both earlier trims failed open: the
# `while … "${v%"$_fp_nl"}"` loop re-scanned the whole string once per trailing newline (a command
# ending in 50,000 real newlines: 41-48 s per guard, past the 5 s hook timeout), and the regex
# `($_fp_nl+)$` that replaced it is O(run^2) on glibc when the run is followed by any other text —
# glibc retries the match from every newline (`rm -rf ~/proj`, 50,000 newlines, `#`: 22-39 s per
# guard on Debian; MSYS's engine is linear there, so no Windows run saw it). The search runs under
# LC_ALL=C, where lengths and slices count bytes (a newline byte never occurs inside a UTF-8
# sequence, and an old bash's multibyte length can stop counting at an invalid byte); LC_ALL is set
# and restored explicitly rather than by `local`, whose restore an old bash might not re-apply.
_fp_trimnl() {
  local _ft_n _ft_lo=1 _ft_hi=1 _ft_m _ft_t _ft_ls="${LC_ALL+x}" _ft_lv="${LC_ALL-}"
  case "$2" in *"$_fp_nl") ;; *) printf -v "$1" '%s' "$2"; return 0 ;; esac
  LC_ALL=C
  _ft_n=${#2}
  # The last _ft_lo bytes are all newlines; the last _ft_hi are not (or _ft_hi = _ft_lo = _ft_n).
  while [ "$_ft_hi" -lt "$_ft_n" ]; do
    _ft_m=$((_ft_hi * 2)); [ "$_ft_m" -le "$_ft_n" ] || _ft_m=$_ft_n
    _ft_t="${2:_ft_n-_ft_m}"
    case "$_ft_t" in *[!"$_fp_nl"]*) _ft_hi=$_ft_m; break ;; esac
    _ft_lo=$_ft_m _ft_hi=$_ft_m
  done
  while [ $((_ft_hi - _ft_lo)) -gt 1 ]; do
    _ft_m=$(((_ft_lo + _ft_hi) / 2)); _ft_t="${2:_ft_n-_ft_m}"
    case "$_ft_t" in *[!"$_fp_nl"]*) _ft_hi=$_ft_m ;; *) _ft_lo=$_ft_m ;; esac
  done
  printf -v "$1" '%s' "${2:0:_ft_n-_ft_lo}"
  if [ -n "$_ft_ls" ]; then LC_ALL="$_ft_lv"; else unset LC_ALL; fi
}

# _fp_clean VAR…: drop CRs and trailing newlines from each VAR — what the full logic's old
# `$(jq -r … | tr -d '\r')` captures did to every payload field.
_fp_clean() {
  local _fc_v _fc_s
  for _fc_v in "$@"; do
    _fp_nocr _fc_s "${!_fc_v}"
    _fp_trimnl _fc_s "$_fc_s"
    printf -v "$_fc_v" '%s' "$_fc_s"
  done
}

# _fp_lines ERE TEXT: 0 when one LINE of TEXT matches (grep's unit), 1 when none does, 2 when TEXT
# has over 64 lines (undecidable: every [[ =~ ]] compiles the ERE anew, ~2.6 ms a line on MSYS;
# the full logic's one grep decides). The whole-text test runs first and is a superset for EREs
# whose only anchors are (^|X) / (X|$) with X matching newline. Empty lines are skipped: none of
# the fast-path EREs can match one.
_fp_lines() {
  local _fl_l
  [[ $2 =~ $1 ]] || return 1
  case "$2" in *"$_fp_nl"*) ;; *) return 0 ;; esac
  _fp_split "$_fp_nl" "$2"
  [ "${#_FP_A[@]}" -le 64 ] || return 2
  for _fl_l in ${_FP_A[@]+"${_FP_A[@]}"}; do [[ $_fl_l =~ $1 ]] && return 0; done
  return 1
}

# _fp_collapse VAR PATH: an absolute PATH with its '.' and '..' segments folded lexically (no
# filesystem access; '..' at the root stays there); any other PATH unchanged. A segment stack, so
# linear in the path.
_fp_collapse() {
  local _fk_s IFS=/
  local -a _fk_k=()
  case "$2" in /*) ;; *) printf -v "$1" '%s' "$2"; return 0 ;; esac
  _fp_split / "$2"
  for _fk_s in ${_FP_A[@]+"${_FP_A[@]}"}; do
    case "$_fk_s" in
      ''|.) ;;
      ..) [ "${#_fk_k[@]}" -gt 0 ] && unset '_fk_k[${#_fk_k[@]}-1]' ;;
      *) _fk_k[${#_fk_k[@]}]="$_fk_s" ;;
    esac
  done
  printf -v "$1" '/%s' "${_fk_k[*]-}"
}

# _fp_lower VAR TEXT: ASCII A-Z to a-z (bash 3.2 has no ${x,,}; explicit letter lists, since a
# [A-Z] range can match lower case under a collating locale).
_fp_lower() {
  local _fw_s="$2" _fw_o="" _fw_c _fw_u _fw_i
  case "$_fw_s" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;; *) printf -v "$1" '%s' "$_fw_s"; return 0 ;; esac
  for ((_fw_i = 0; _fw_i < ${#_fw_s}; _fw_i++)); do
    _fw_c="${_fw_s:$_fw_i:1}"
    case "$_fw_c" in [ABCDEFGHIJKLMNOPQRSTUVWXYZ]) _fw_u="${_fp_uc%%"$_fw_c"*}"; _fw_c="${_fp_lc:${#_fw_u}:1}" ;; esac
    _fw_o="$_fw_o$_fw_c"
  done
  printf -v "$1" '%s' "$_fw_o"
}

# _fp_path VAR PATH [lex]: lib.sh sb_normalize_path's lexical steps (backslashes to '/', the
# \\?\ and \\.\ prefixes, the loopback admin share). With "lex", a drive path X:/… is also spelled
# /x/…, as cygpath -u spells it, on a Windows host (cygpath on PATH, or an MSYS/Cygwin bash).
_fp_path() {
  local _fq_p="$2" _fq_d
  _fq_p=${_fq_p//"$_fp_bs"/"/"}
  _fq_p="${_fq_p#"//?/"}"; _fq_p="${_fq_p#"//./"}"
  case "$_fq_p" in
    //localhost/[A-Za-z]\$/*)  _fq_d="${_fq_p#//localhost/}";  _fq_d="${_fq_d%%\$*}"; _fq_p="$_fq_d:${_fq_p#//localhost/[A-Za-z]\$}" ;;
    //127.0.0.1/[A-Za-z]\$/*)  _fq_d="${_fq_p#//127.0.0.1/}";  _fq_d="${_fq_d%%\$*}"; _fq_p="$_fq_d:${_fq_p#//127.0.0.1/[A-Za-z]\$}" ;;
  esac
  if [ "${3:-}" = lex ]; then
    case "$_fq_p" in
      [A-Za-z]:/*)
        if command -v cygpath >/dev/null 2>&1 || [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
          _fp_lower _fq_d "${_fq_p%%:*}"; _fq_p="/$_fq_d${_fq_p#?:}"
        fi ;;
    esac
  fi
  printf -v "$1" '%s' "$_fq_p"
}

# _fp_esc VAR TEXT: TEXT as a JSON string body (\ " \n \r \t escaped, other control chars dropped).
_fp_esc() {
  local _fe_s="$2"
  _fe_s=${_fe_s//"$_fp_bs"/"$_fp_bs$_fp_bs"}; _fe_s=${_fe_s//"$_fp_q"/"$_fp_bs$_fp_q"}
  _fe_s=${_fe_s//"$_fp_nl"/"${_fp_bs}n"}; _fe_s=${_fe_s//"$_fp_cr"/"${_fp_bs}r"}; _fe_s=${_fe_s//"$_fp_tab"/"${_fp_bs}t"}
  _fe_s=${_fe_s//[[:cntrl:]]/}
  printf -v "$1" '%s' "$_fe_s"
}

# _fp_emit ask|deny REASON: the verdict, in the hookSpecificOutput shape the guards emit.
_fp_emit() {
  local _fm_r; _fp_esc _fm_r "$2"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$_fm_r"
}

# _fp_audit HOOK VERDICT RULE TARGET REASON SESSION: one audit-log.jsonl row in lib.sh
# sb_log_audit's shape (extra.fastpath marks the source), appended by one printf >> (D120).
_fp_audit() {
  local _fa_bd="${BRAIN_DIR:-$HOME/.second-brain}" _fa_ts _fa_h _fa_v _fa_r _fa_t _fa_e _fa_s
  _fa_bd=${_fa_bd//"$_fp_bs"/"/"}
  [ -d "$_fa_bd" ] || mkdir -p "$_fa_bd" || return 0
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC0 printf -v _fa_ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    _fa_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  _fp_esc _fa_h "$1"; _fp_esc _fa_v "$2"; _fp_esc _fa_r "$3"; _fp_esc _fa_t "$4"; _fp_esc _fa_e "$5"; _fp_esc _fa_s "$6"
  printf '{"ts":"%s","hook":"%s","verdict":"%s","rule":"%s","target":"%s","reason":"%s","session_id":"%s","extra":{"fastpath":true}}\n' \
    "$_fa_ts" "$_fa_h" "$_fa_v" "$_fa_r" "$_fa_t" "$_fa_e" "$_fa_s" >> "$_fa_bd/audit-log.jsonl"
}
# <<< sb-guard-fastpath

# --- B7 fast path: credentialed egress decided before lib.sh / jq / grep ----------------------
# The same gate and patterns as the full logic below (FG_NET mirrors its keyword grep, FG_RES its
# scan() patterns), applied with builtins, line by line like grep. Only an ask is decided here;
# anything else — no match, or a payload field _fp_str cannot decode — falls through to the full
# logic. A fast-path ask skips sb_buddy_event (lib.sh's): the verdict and its audit row are what
# must arrive before the hook timeout.
FG_NET='(^|[^A-Za-z_])(curl|wget|nc|netcat|ssh|scp|sftp|rsync|httpie|ftp|git|gh|python|node|aws|openssl)([^A-Za-z_]|$)'
FG_LABELS=(jwt aws-access-key github-pat anthropic-key openai-key slack-token pem-private bearer-blob credential-file-upload)
FG_RES=(
  'ey[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  'AKIA[0-9A-Z]{16}'
  '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,})'
  'sk-ant-(api|admin)[0-9]*-[A-Za-z0-9_-]{20,}'
  'sk-(proj-[A-Za-z0-9_-]{20,}|[A-Za-z0-9]{40,})'
  'xox[abprs]-[A-Za-z0-9-]{10,}'
  'BEGIN[[:space:]]+(RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED)?[[:space:]]*PRIVATE[[:space:]]+KEY'
  '[Bb]earer[[:space:]]+[A-Za-z0-9+/=_-]{40,}'
  '@[^[:space:]]*(\.ssh/(id_rsa|id_ed25519|id_ecdsa|authorized_keys)|\.aws/credentials|\.netrc|\.npmrc|\.git-credentials|\.docker/config\.json|\.kube/config|\.credentials\.json|\.pem|\.p12)([[:space:]]|$)'
)
_fg_reason() {  # _fg_reason TOOL LABELS -> FG_REASON (the one reason text, fast path and full logic)
  FG_REASON="Outbound info-flow guard: tool '$1' invocation appears to carry credential-shaped content ($2). HarnessAudit treats credentialed egress as the sar_flow boundary-violation channel. Confirm intent — the agent should not be sending real secrets over the wire. Kill switch: SB_FLOW_GUARD=off."
}
_fg_fast() {
  local tool hay sid="" u="" pr="" rc i labels=""
  _fp_str tool_name || return 1
  tool="$_FP"
  case "$tool" in
    Bash)      _fp_str command || return 1; _fp_nocr hay "$_FP" ;;
    WebFetch)  _fp_str url; rc=$?; [ "$rc" = 2 ] && return 1; u="$_FP"
               _fp_str prompt; rc=$?; [ "$rc" = 2 ] && return 1; pr="$_FP"
               hay="$u $pr" ;;
    WebSearch) _fp_str query || return 1; _fp_nocr hay "$_FP" ;;
    *) return 1 ;;
  esac
  _fp_trimnl hay "$hay"
  [ -n "$hay" ] || return 1
  if [ "$tool" = Bash ]; then _fp_lines "$FG_NET" "$hay" || return 1; fi
  for ((i = 0; i < ${#FG_RES[@]}; i++)); do
    _fp_lines "${FG_RES[$i]}" "$hay"; rc=$?
    [ "$rc" = 2 ] && return 1
    [ "$rc" = 0 ] && labels="${labels:+$labels,}${FG_LABELS[$i]}"
  done
  [ -n "$labels" ] || return 1
  _fp_str session_id && sid="$_FP"
  _fg_reason "$tool" "$labels"
  _fp_audit "flow-guard.sh" "ask" "info-flow:$labels" "$tool:($labels)" "$FG_REASON" "$sid"
  _fp_emit ask "$FG_REASON"
  return 0
}
_fg_fast && exit 0

# --- Full logic (the fast path could not decide) -----------------------------------------------
_fp_raw_all
[ -z "$RAW" ] && exit 0

# Tool, session and the tool-specific haystack: builtin decode when every field is decidable,
# else ONE jq, NUL-framed (the old form spent one jq for tool+session and one for the haystack,
# and sourced lib.sh up front — it is sourced only on the ask path now). If RAW is not a JSON
# object jq errors → TOOL empty → exit 0 (fail-soft). CRs dropped except in the WebFetch
# haystack, and trailing newlines trimmed, as the old captures did.
TOOL="" SESSION_ID="" HAYSTACK=""
_fg_fields() {
  local rc u="" pr=""
  _fp_str tool_name; rc=$?; [ "$rc" = 2 ] && return 1; TOOL="$_FP"
  _fp_str session_id; rc=$?; [ "$rc" = 2 ] && return 1; SESSION_ID="$_FP"
  case "$TOOL" in
    Bash)      _fp_str command; rc=$?; [ "$rc" = 2 ] && return 1; HAYSTACK="$_FP" ;;
    WebFetch)  _fp_str url; rc=$?; [ "$rc" = 2 ] && return 1; u="$_FP"
               _fp_str prompt; rc=$?; [ "$rc" = 2 ] && return 1; pr="$_FP"
               HAYSTACK="$u $pr" ;;
    WebSearch) _fp_str query; rc=$?; [ "$rc" = 2 ] && return 1; HAYSTACK="$_FP" ;;
  esac
  return 0
}
if ! _fg_fields; then
  TOOL="" SESSION_ID="" HAYSTACK=""
  {
    IFS= read -r -d '' TOOL; IFS= read -r -d '' SESSION_ID; IFS= read -r -d '' HAYSTACK
  } < <(_fp_feed "$RAW" jq -j '(.tool_name // ""), "\u0000", (.session_id // ""), "\u0000",
               (if .tool_name == "Bash" then (.tool_input.command // "")
                elif .tool_name == "WebFetch" then ([.tool_input.url // "", .tool_input.prompt // ""] | join(" "))
                elif .tool_name == "WebSearch" then (.tool_input.query // "")
                else "" end), "\u0000"' 2>/dev/null)
fi
_fp_clean TOOL SESSION_ID
[ -z "${TOOL:-}" ] && exit 0

# Only outbound channels concern us.
case "$TOOL" in
  Bash|WebFetch|WebSearch) ;;
  *) exit 0 ;;
esac
[ "$TOOL" = WebFetch ] || _fp_nocr HAYSTACK "$HAYSTACK"
_fp_trimnl HAYSTACK "$HAYSTACK"
[ -z "$HAYSTACK" ] && exit 0

# Bash gate: require a network tool keyword in addition to the credential
# pattern. Without this, a local `echo $TOKEN > file` would be flagged —
# noise without exfil risk.
# Note: `http` is intentionally NOT in the keyword list — it appears as
# a URL substring in many local commands (grep over access.log, paths
# containing http-* names) and would trip the egress gate on grep/awk/sed
# operations that never touch the network. httpie has the binary name
# `http` but the keyword match is bounded — keeping only `httpie` is the
# conservative choice (the few power-users running httpie can disable the
# guard or use curl).
# D103: git/gh/python/node/aws/openssl added — the two most realistic egress
# shapes this guard missed were `git push` with an embedded token (github-pat
# pattern already matches; only the gate keyword was missing) and a script
# runtime (python/node) POSTing a secret. A plain `git status`/`python -m x`
# never trips the guard — the credential-pattern scan below still has to match.
if [ "$TOOL" = "Bash" ]; then
  _fp_feed "$HAYSTACK" grep -qE "$FG_NET" || exit 0
fi

# Pattern set: FG_LABELS[i] ↔ FG_RES[i] (defined with the fast path above — one list for both
# paths). We collect all matches and report the labels. Keep each pattern narrow so we don't
# accidentally match readable English text.
# OpenAI: matches both legacy keys (`sk-` + 40+ base62) and the current
# project-scoped format (`sk-proj-` + body). Hyphens allowed inside the
# body to accommodate `sk-proj-...`. Anthropic and Slack tokens are
# matched by their dedicated patterns too — duplicate matches just
# add labels, they don't break anything.
# D103: credential-shaped FILE upload via curl/httpie's `@path` syntax (-d @file,
# -F field=@file). No secret VALUE appears in the command text here — only a
# path naming a known credential file — so this needs its own pattern rather
# than reusing the literal-secret scans.
# ONE grep with every pattern (-e each) says whether ANY can match; only then the per-pattern
# scan that names them (the old form ran all nine greps on every egress-shaped call). An error
# (exit 2) counts as a hit, so the per-pattern scan then decides exactly as before.
# A big haystack keeps only the lines that ONE pattern matched (grep is line-based: a line one
# pattern matches is among them), so the per-pattern greps read those, not the whole text again.
FG_ARGS=()
for _p in "${FG_RES[@]}"; do FG_ARGS+=(-e "$_p"); done
FG_SCAN="$HAYSTACK"
if [ "${#HAYSTACK}" -le 8192 ]; then
  _fp_feed "$HAYSTACK" grep -qE ${FG_ARGS[@]+"${FG_ARGS[@]}"}; [ $? -eq 1 ] && exit 0
else
  FG_SCAN=$(_fp_feed "$HAYSTACK" grep -E ${FG_ARGS[@]+"${FG_ARGS[@]}"}); _rc=$?
  [ "$_rc" -eq 1 ] && exit 0
  [ "$_rc" -eq 0 ] || FG_SCAN="$HAYSTACK"
fi
MATCHED_LABELS=""
for ((_i = 0; _i < ${#FG_RES[@]}; _i++)); do
  _fp_feed "$FG_SCAN" grep -qE "${FG_RES[$_i]}" && MATCHED_LABELS="${MATCHED_LABELS:+$MATCHED_LABELS,}${FG_LABELS[$_i]}"
done

[ -z "$MATCHED_LABELS" ] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Fail-soft on lib.sh source so the guard still emits its decision JSON
# even if audit logging is unavailable.
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
fi

# Decision: ask. The audit-log TARGET intentionally carries only the
# matched labels — NOT the haystack content — because the haystack
# contains the secret value we just detected. Never log raw haystack
# slices: even a short prefix carries enough of e.g. a JWT into the
# log to be re-recognized by downstream consumers. Labels alone give
# /second-brain:audit and the SAR summary everything they need.
TARGET="${TOOL}:(${MATCHED_LABELS})"
_fg_reason "$TOOL" "$MATCHED_LABELS"

sb_log_audit "flow-guard.sh" "ask" "info-flow:${MATCHED_LABELS}" "$TARGET" "$FG_REASON" "$SESSION_ID"
command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$SESSION_ID" guard alert "Held for your OK: credential-shaped data heading out (${MATCHED_LABELS:0:60})." flow-guard 300

_fp_emit ask "$FG_REASON"

exit 0
