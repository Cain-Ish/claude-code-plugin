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
# _FP_DL: the epoch ms from which this guard's verdict counts as late (G2; GS6/GC5/GX5, R3B): Claude
# Code had likely cancelled the hook and run the call. hook-timer's SB_HOOK_LATE_MS when this guard is
# its direct child (SB_HOOK_LATE_PID is $PPID; GT11: one inherited through a process the wrapped hook
# spawned is not this guard's); otherwise — the guards hooks.json does not wrap — this guard's own
# start plus the 5 s hook timeout less the same 2000 ms head start. Taken here, before the payload is
# read. bash 5 only (EPOCHREALTIME): before it there is no clock without a process, and no stamp.
_FP_DL=""
if [ -n "${EPOCHREALTIME:-}" ]; then
  _FP_DL=${EPOCHREALTIME//[!0-9]/}; _FP_DL=$(( 10#$_FP_DL / 1000 + 3000 ))
  case "${SB_HOOK_LATE_MS:-}" in ''|*[!0-9]*) ;; *) [ "${SB_HOOK_LATE_PID:-}" = "$PPID" ] && _FP_DL="$SB_HOOK_LATE_MS" ;; esac
fi
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

# _fp_rest VAR: VAR = the rest of stdin — the last, unframed field of a guard's NUL-framed jq read.
# `read -N` (bash >= 4.1) reads a pipe in buffered chunks; `read -d ''` takes one byte per syscall:
# 0.85 s for a 450 KB command from jq on MSYS inside the guard, 3.4 s from a bash writer (F8 item 20:
# the 150k-line command answered in 4.5 s on the Windows CI lane). NUL bytes are dropped, where the
# framed read split at them.
_fp_rest() {
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
    IFS= read -r -N 268435456 "$1"
  else
    IFS= read -r -d '' "$1"
  fi
  # 1 is the normal end of input (fewer than N characters, or no closing NUL); anything above it is a
  # failed read, passed on so the caller can refuse to decide on a field it may have only part of.
  local _fr_rc=$?
  [ "$_fr_rc" -le 1 ] && return 0
  return "$_fr_rc"
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
    # Past 65,536 characters jq decides (one spawn, ~0.1 s even at 1 MB): here every key costs a
    # cut of the whole payload, and five of them over a 1 MB Write of 333k escaped quotes took
    # 1.2 s on MSYS (F8 item 20) — for a payload that size the spawn is the cheap path.
    [ "${#_FP_RAW}" -le 65536 ] || return 2
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

# _fp_lower VAR TEXT: ASCII A-Z to a-z, byte for byte what `LC_ALL=C tr A-Z a-z` does (bash 3.2
# has no ${x,,}; explicit letter lists, since a [A-Z] range can match lower case under a collating
# locale). For each capital TEXT holds, TEXT is cut at it by word splitting and rejoined around its
# lower case by one printf: 26 linear passes at most, no process. The per-character loop this
# replaces copied the growing result once per character and indexed ${s:i:1} (O(i) in a UTF-8
# locale): O(n^2) — a 16 KB Write path took 1.8 s on MSYS (25 s on bash 3.2) and wiki-write-guard's
# full logic, which lowers any file_path, never answered a 50,000-character one (F8 item 18: rc=124
# past 60 s, a fail-open). ${s//X/x} per letter is no better on bash < 4.3 (4.4 s at 16 KB of
# capitals on 3.2). LC_ALL=C (set and restored as in _fp_trimnl) keeps the cut byte-exact. Like
# every _fp_split user, it overwrites _FP_A.
_fp_lower() {
  local _fw_s="$2" _fw_u _fw_l _fw_i=0 _fw_ls="${LC_ALL+x}" _fw_lv="${LC_ALL-}"
  case "$_fw_s" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;; *) printf -v "$1" '%s' "$_fw_s"; return 0 ;; esac
  LC_ALL=C
  while [ "$_fw_i" -lt 26 ]; do
    _fw_u="${_fp_uc:_fw_i:1}" _fw_l="${_fp_lc:_fw_i:1}"; _fw_i=$((_fw_i + 1))
    case "$_fw_s" in *"$_fw_u"*) ;; *) continue ;; esac
    # The '.' sentinel keeps a trailing capital's empty last field, which word splitting drops;
    # printf repeats "%s<lower>" per field, so the extra lower case and the sentinel come off after.
    _fp_split "$_fw_u" "$_fw_s."
    printf -v _fw_s "%s$_fw_l" ${_FP_A[@]+"${_FP_A[@]}"}
    _fw_s="${_fw_s%?}"; _fw_s="${_fw_s%.}"
  done
  printf -v "$1" '%s' "$_fw_s"
  if [ -n "$_fw_ls" ]; then LC_ALL="$_fw_lv"; else unset LC_ALL; fi
}

# _fp_path VAR PATH [lex]: lib.sh sb_normalize_path's lexical steps (backslashes to '/', the
# \?\ and \.\ prefixes, the loopback admin share). With "lex", a drive path X:/… is also spelled
# as cygpath -u would (/x/…, drive lowered) — on a Windows host only: elsewhere 'C:' is just a
# relative name. Linear in the path: the backslashes are cut out by word splitting and rejoined with
# '/' (a trailing one re-added — splitting drops it), and each prefix is sliced off only after a
# `case` saw it. The `${p//\//}` and `${p#"//?/"}` forms this replaces are O(n^2) whenever they
# scan a long path — a missing prefix is the common case — so a 100 KB target took 2.7 s per call
# on MSYS, and symlink-guard's deny (three calls deep) came after the 5 s hook timeout (final
# review, 0.54.1).
_fp_path() {
  local _fq_p="$2" _fq_d _fq_t=""
  case "$_fq_p" in
    *"$_fp_bs"*)
      case "$_fq_p" in *"$_fp_bs") _fq_t=/ ;; esac
      _fp_split "$_fp_bs" "$_fq_p"
      _fp_joinsl _fq_p
      _fq_p="$_fq_p$_fq_t" ;;
  esac
  # \\?\ and \\.\ (Win32 device paths) are cut before a drive only, and \\?\UNC\host\… is the UNC
  # path \\host\…. Any other device path (\\?\Volume{…}\, \\?\GLOBALROOT\…) keeps its //?/ prefix: it
  # names no drive path, so no scope root or credential prefix matches it (GS2/GX2b, R3B: the old
  # unconditional cut left Volume{…}/… and UNC/… relative — joined to the cwd, in scope).
  case "$_fq_p" in
    //[?.]/[A-Za-z]:*) _fq_p=${_fq_p:4} ;;
    //[?.]/[Uu][Nn][Cc]/*) _fq_p="//${_fq_p:8}" ;;
  esac
  # The loopback admin share is the drive itself, in any case (Windows host names are).
  case "$_fq_p" in
    //[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]/[A-Za-z]\$|//[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]/[A-Za-z]\$/*|//127.0.0.1/[A-Za-z]\$|//127.0.0.1/[A-Za-z]\$/*)
      _fq_d="${_fq_p:12:1}"; _fq_p="$_fq_d:/${_fq_p:15}" ;;
  esac
  if [ "${3:-}" = lex ]; then
    case "$_fq_p" in
      [A-Za-z]:/*)
        if command -v cygpath >/dev/null 2>&1 || [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
          _fp_lower _fq_d "${_fq_p:0:1}"; _fq_p="/$_fq_d${_fq_p:2}"
        fi ;;
    esac
  fi
  printf -v "$1" '%s' "$_fq_p"
}

# _fp_joinsl VAR: VAR = the _FP_A fields joined by '/' (the inverse of _fp_split / on a path).
_fp_joinsl() {
  local IFS=/
  printf -v "$1" '%s' "${_FP_A[*]-}"
}

# _fp_rroot VAR PATH CWD (P-S1): VAR = PATH — on a Windows host, spelled on a drive when it is
# root-relative there: one leading '\' or '/' (not a UNC or device path), no drive, and not an MSYS
# path (its first name a drive letter, or one of the Git/MSYS root's own: bin cmd dev etc mingw32
# mingw64 ucrt64 clang32 clang64 clangarm64 proc tmp usr). Claude Code hands node a model's
# /Users/u/.ssh/x as \Users\u\.ssh\x, and node opens it on the current drive — C:\Users\u\.ssh\x —
# where these guards read \… and /… under the MSYS root (C:\Program Files\Git\Users\…): no credential
# prefix matched, and the Write ran. The drive is the payload cwd's (a native X:\… or X:/… form),
# else CLAUDE_PROJECT_DIR's. 0 = VAR set (respelled or not); 2 = a '\'-rooted PATH with neither
# drive known — undecidable, the caller asks. A '/'-rooted one keeps its MSYS reading then, as it
# always had. Builtins only (_fp_path, _fp_lower: _FP_A is overwritten).
_fp_rroot() {
  local _fo_p="$2" _fo_d _fo_s
  printf -v "$1" '%s' "$_fo_p"
  case "$_fo_p" in
    "$_fp_bs$_fp_bs"*|"$_fp_bs/"*|"/$_fp_bs"*|//*) return 0 ;;
    "$_fp_bs"?*|/?*) ;;
    *) return 0 ;;
  esac
  [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || command -v cygpath >/dev/null 2>&1 || return 0
  _fp_path _fo_s "$_fo_p"; _fo_s="${_fo_s#/}"; _fo_s="${_fo_s%%/*}"
  _fp_lower _fo_s "$_fo_s"
  case "$_fo_s" in ?|bin|cmd|dev|etc|mingw32|mingw64|ucrt64|clang32|clang64|clangarm64|proc|tmp|usr) return 0 ;; esac
  for _fo_d in "$3" "${CLAUDE_PROJECT_DIR:-}"; do
    case "$_fo_d" in [A-Za-z]:"$_fp_bs"*|[A-Za-z]:/*) printf -v "$1" '%s:%s' "${_fo_d:0:1}" "$_fo_p"; return 0 ;; esac
  done
  case "$_fo_p" in "$_fp_bs"*) return 2 ;; esac
  return 0
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
  local _fm_r; _fp_cap _fm_r "$2" 2048; _fp_esc _fm_r "$_fm_r"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$_fm_r"
}

# _fp_late: _FP_LATE=1 once this guard's deadline (_FP_DL, above) has passed: a verdict written then
# was likely cancelled with the hook, and the call ran.
_FP_LATE=0
_fp_late() {
  local _fy_n="${EPOCHREALTIME:-}"
  _FP_LATE=0
  [ -n "$_FP_DL" ] && [ -n "$_fy_n" ] || return 0
  _fy_n="${_fy_n//[!0-9]/}"
  [ $(( 10#$_fy_n / 1000 )) -ge "$_FP_DL" ] && _FP_LATE=1
  return 0
}

# _fp_audit HOOK VERDICT RULE TARGET REASON SESSION [full]: one audit-log.jsonl row in lib.sh
# sb_log_audit's shape (extra.fastpath marks a fast-path verdict, extra.late a verdict past the
# deadline: _fp_late), appended by one printf >> (D120). "full": the full logic's row, unmarked —
# the guards write their full-logic rows here too, before they exit (GS5/GS7, R3B): no lib.sh and
# no fork, where a detached sb_log_audit (~7 process creations) was lost with a killed hook. A row
# that cannot be appended is logged (_fp_err).
_fp_audit() {
  local _fa_bd="${BRAIN_DIR:-$HOME/.second-brain}" _fa_ts _fa_h _fa_v _fa_r _fa_t _fa_e _fa_s _fa_x='"fastpath":true'
  [ "${7:-}" = full ] && _fa_x=""
  _fa_bd=${_fa_bd//"$_fp_bs"/"/"}
  [ -d "$_fa_bd" ] || mkdir -p "$_fa_bd" || return 0
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC0 printf -v _fa_ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    _fa_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  _fp_late; [ "$_FP_LATE" = 1 ] && _fa_x="${_fa_x:+$_fa_x,}"'"late":true'
  _fp_cap _fa_t "$4" 256; _fp_cap _fa_e "$5" 1024
  _fp_esc _fa_h "$1"; _fp_esc _fa_v "$2"; _fp_esc _fa_r "$3"; _fp_esc _fa_t "$_fa_t"; _fp_esc _fa_e "$_fa_e"; _fp_esc _fa_s "$6"
  printf '{"ts":"%s","hook":"%s","verdict":"%s","rule":"%s","target":"%s","reason":"%s","session_id":"%s","extra":{%s}}\n' \
    "$_fa_ts" "$_fa_h" "$_fa_v" "$_fa_r" "$_fa_t" "$_fa_e" "$_fa_s" "$_fa_x" >> "$_fa_bd/audit-log.jsonl" 2>/dev/null \
    || _fp_err "$1" "the $2 verdict's audit row (rule $3) could not be appended to $_fa_bd/audit-log.jsonl"
}
# _fp_cap VAR TEXT N: VAR = TEXT cut to N characters, with a visible "…(+M chars)" when cut. Every
# reason and audit target passes through it: _fp_esc's passes over a payload-sized path cost
# seconds, and a row of that size was lost outright where it reached a native jq.exe (no command
# line past ~32 KB).
_fp_cap() {
  if [ "${#2}" -le "$3" ]; then printf -v "$1" '%s' "$2"; return 0; fi
  printf -v "$1" '%s…(+%s chars)' "${2:0:$3}" "$(( ${#2} - $3 ))"
}

# _fp_err HOOK MESSAGE: one error-log.jsonl row in lib.sh sb_log_error's shape (exit_code 1),
# appended by one printf >> (the guards run without lib.sh, B7).
_fp_err() {
  local _fr_bd="${BRAIN_DIR:-$HOME/.second-brain}" _fr_ts _fr_h _fr_m
  _fr_bd=${_fr_bd//"$_fp_bs"/"/"}
  [ -d "$_fr_bd" ] || mkdir -p "$_fr_bd" || return 0
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC0 printf -v _fr_ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    _fr_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  _fp_esc _fr_h "$1"; _fp_cap _fr_m "$2" 1024; _fp_esc _fr_m "$_fr_m"
  printf '{"timestamp":"%s","script":"%s","message":"%s","exit_code":1}\n' "$_fr_ts" "$_fr_h" "$_fr_m" >> "$_fr_bd/error-log.jsonl"
}

# _fp_jqfail HOOK CHARS: the jq fallback read no tool name from a payload of CHARS characters that
# names one. Loud either way. 0 when jq is on PATH (it ran and failed: the caller asks, since a guard
# that cannot read a call must not pass it silently); 1 when jq is missing (main's behaviour: the
# call passes, and SessionStart's banner reports the missing jq).
_fp_jqfail() {
  if command -v jq >/dev/null 2>&1; then
    _fp_err "$1" "the jq fallback read no tool name from a $2-char payload that names one (jq failed); asked instead of passing the call"
    return 0
  fi
  _fp_err "$1" "jq is not on PATH: a $2-char payload could not be read and the call passed unchecked"
  return 1
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
  '@[^[:space:]@]*(\.ssh/(id_rsa|id_ed25519|id_ecdsa|authorized_keys)|\.aws/credentials|\.netrc|\.npmrc|\.git-credentials|\.docker/config\.json|\.kube/config|\.credentials\.json|\.pem|\.p12)([[:space:]]|$)'
)
# The full logic's jq copy (FG_JQ below). Oniguruma backtracks: a pattern whose unbounded run must
# be followed by something else is retried from every start inside a long run of its own characters,
# O(n^2) where grep and the fast path's ERE stay linear (GS1/GC1/GX1, R3B: 20K '@' 10.7 s, 100 KB of
# 'ey' 9-11 s, BEGIN + 80K spaces 17 s — past the 5 s timeout, so the call ran). Each copy matches
# the same lines as its FG_RES twin, in linear time; tests/test-flow-guard.sh holds the two paths to
# one verdict over a corpus and times the adversarial shapes.
# - credential-file-upload: its run excludes '@' in FG_RES itself (both paths): a match from an
#   earlier '@' still matches from the last '@' of its run, so no line changes verdict.
# - jwt: the first segment's run must end where its '.' is — the end of its run of token
#   characters — so whether some 'ey' in a run starts a match is decided by the first 'ey' of that
#   run with 10 characters after it. The copy starts only at a run's start (lookbehind), takes that
#   'ey' and the whole run atomically, and never retries later ones. Its last segment needs 10
#   characters, as {10,} with nothing after it does.
# - pem-private: BEGIN s+ X? s* is BEGIN s+ (X s*)?; every whitespace run is taken atomically (none
#   can hold the letters after it). The line bound ([^\S\n]) is FG_JQ's rewrite of [[:space:]].
FG_JQRES=("${FG_RES[@]}")
FG_JQRES[0]='(?<![A-Za-z0-9_-])(?>[A-Za-z0-9_-]*?ey[A-Za-z0-9_-]{10,})\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10}'
FG_JQRES[6]='BEGIN(?>[[:space:]]+)(?:(?:RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED)(?>[[:space:]]*))?PRIVATE(?>[[:space:]]+)KEY'
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

# #110 (R3, 2026-10-07): ONE jq reads the call and decides it. The old form piped the whole
# haystack to grep 3+N times (the egress gate, the combined pattern, one grep per label), each
# through _fp_feed (a second fork past 8 KB), then sourced lib.sh and wrote the audit and buddy
# rows before printing the verdict: a 512 KB credentialed heredoc took 3.7 s median (15 s max) on
# a loaded MSYS box, 50,000 interior newlines 6.7-7.3 s — past the 5 s timeout, so the call ran.
# Now jq builds the haystack the fast path reads (a Bash command, a WebSearch query, a WebFetch's
# url and prompt joined by a space; CRs dropped except in WebFetch's), applies FG_NET to a Bash
# command (the egress gate, D103: a local `echo $TOKEN > file` is no egress) and FG_JQRES (FG_RES's
# linear-time copy) to the haystack, and returns the indices of the patterns that matched. The verdict is printed before
# lib.sh is sourced; its rows follow from a detached job (_fg_log).
# Line semantics: grep and the fast path's _fp_lines match line by line; a jq regex sees the whole
# string, where [[:space:]] also matches a newline. So the quantified [[:space:]] runs (pem,
# bearer) are bounded to one line ([^\S\n]); every other pattern either cannot span a newline or
# ends in a boundary class a newline satisfies, as a line end does. tests/test-flow-guard.sh holds
# this form to the fast path's over one corpus. NUL-framed out: status, tool, session, indices, and
# a closing "end" (a jq cut short reads as a failed jq, never as "no match").
FG_JQ='
def str: if type == "string" then . elif . == null then "" else tojson end;
($ARGS.positional | map(gsub("\\[\\[:space:\\]\\](?<q>[+*])"; "[^\\S\\n]\(.q)"))) as $res
| (.tool_name | str) as $t
| (if $t == "Bash" then (.tool_input.command | str)
   elif $t == "WebFetch" then ([(.tool_input.url | str), (.tool_input.prompt | str)] | join(" "))
   elif $t == "WebSearch" then (.tool_input.query | str)
   else "" end
   | if $t == "WebFetch" then . else (split("\r") | join("")) end) as $h
| (if ([.tool_name, .session_id, .tool_input.command, .tool_input.url, .tool_input.prompt, .tool_input.query] | map(strings) | any(contains("\u0000"))) then "nul" else "ok" end),
  "\u0000", $t, "\u0000", (.session_id | str), "\u0000",
  (if $h == "" or ($t == "Bash" and ($h | test($net) | not)) then ""
   else [range(0; $res | length) as $i | select($h | test($res[$i])) | $i | tostring] | join(",") end),
  "\u0000", "end", "\u0000"
'
TOOL="" SESSION_ID="" FG_HITS="" _FP_JST="" _FG_END=""
{
  IFS= read -r -d '' _FP_JST; IFS= read -r -d '' TOOL; IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' FG_HITS; IFS= read -r -d '' _FG_END
} < <(_fp_feed "$RAW" jq -j --arg net "$FG_NET" "$FG_JQ" --args "${FG_JQRES[@]}" 2>/dev/null)
if [ "$_FP_JST" = nul ]; then
  _fp_audit "flow-guard.sh" "ask" "nul-field" "$TOOL" "field holds a NUL character" "${SESSION_ID:-}" full
  _fp_emit ask "second-brain flow-guard.sh cannot check this call: a field it reads holds a NUL character, which bash cannot represent. Confirm the call."
  exit 0
fi
# _fg_nojq: the full logic without jq (GS4/GX4, R3B) — e78111c's: the builtin decode, then the egress
# gate and FG_RES by grep, line by line. TOOL, SESSION_ID and MATCHED_LABELS for the verdict below;
# 1 = no verdict. A payload the builtins cannot decode (a \u, \b or \f escape, over 1000 escapes, over
# 64 KiB, a duplicated key) is logged (_fp_jqfail's rule for a missing jq; SessionStart's banner
# reports it) and scanned raw (_fg_rawscan, P-F3/P-S5): it used to pass — a 70 KB credentialed
# heredoc went out unasked.
_fg_nojq_undecided() {
  case "$RAW" in *'"tool_name"'*) _fp_jqfail "flow-guard.sh" "${#RAW}" ;; esac
  _fg_rawscan
}
# _fg_rawscan: the scan over the RAW payload. Every credential pattern is ASCII, which JSON never
# escapes, so the tokens stand in the raw text as they do in the decoded one. Each escape (\n, \",
# \\, \u…) and each quote is read as a space first (one sed), so a token or an egress word that
# follows a JSON escape or a string's quote is a word of its own. The egress gate (FG_NET) applies
# unless the call is a WebFetch or WebSearch — by its decoded tool name, else by the one its payload
# names; JSON keys never match it. TOOL stays as decoded, "(undecoded)" when it was not. Then FG_RES
# as _fg_nojq applies it. 1 = no verdict.
_fg_rawscan() {
  local hay scan p i rc web=0
  local -a args=()
  MATCHED_LABELS=""
  case "$RAW" in *'"tool_name"'*) ;; *) return 1 ;; esac
  hay=$(_fp_feed "$RAW" sed -e 's/\\./ /g' -e 's/"/ /g')
  [ -n "$hay" ] || hay="$RAW"
  case "$TOOL" in
    Bash) ;;
    WebFetch|WebSearch) web=1 ;;
    '') case "$RAW" in *'"WebFetch"'*|*'"WebSearch"'*) web=1 ;; esac ;;
    *) return 1 ;;
  esac
  if [ "$web" = 0 ]; then _fp_feed "$hay" grep -qE "$FG_NET" || return 1; fi
  for p in "${FG_RES[@]}"; do args+=(-e "$p"); done
  scan=$(_fp_feed "$hay" grep -E ${args[@]+"${args[@]}"}); rc=$?
  [ "$rc" = 1 ] && return 1
  [ "$rc" = 0 ] || scan="$hay"
  for ((i = 0; i < ${#FG_RES[@]}; i++)); do
    _fp_feed "$scan" grep -qE "${FG_RES[$i]}" && MATCHED_LABELS="${MATCHED_LABELS:+$MATCHED_LABELS,}${FG_LABELS[$i]}"
  done
  [ -n "$MATCHED_LABELS" ] || return 1
  TOOL="${TOOL:-(undecoded)}"
  _fp_err "flow-guard.sh" "jq is not on PATH: the undecodable call above was scanned raw and asked about after all ($MATCHED_LABELS)"
  return 0
}
_fg_nojq() {
  local rc u="" pr="" hay="" p i scan
  local -a args=()
  MATCHED_LABELS=""
  _fp_str tool_name; rc=$?; [ "$rc" = 2 ] && { _fg_nojq_undecided; return; }; TOOL="$_FP"
  _fp_str session_id; rc=$?; [ "$rc" = 2 ] && { _fg_nojq_undecided; return; }; SESSION_ID="$_FP"
  case "$TOOL" in
    Bash)      _fp_str command; rc=$? ;;
    WebSearch) _fp_str query; rc=$? ;;
    WebFetch)  _fp_str url; rc=$?; u="$_FP"
               if [ "$rc" != 2 ]; then _fp_str prompt; rc=$?; pr="$_FP"; _FP="$u $pr"; fi ;;
    *) return 1 ;;
  esac
  [ "$rc" = 2 ] && { _fg_nojq_undecided; return; }
  hay="$_FP"
  RAW="" _FP_RAW=""
  _fp_clean TOOL SESSION_ID
  [ "$TOOL" = WebFetch ] || _fp_nocr hay "$hay"
  _fp_trimnl hay "$hay"
  _FP_A=()
  [ -n "$hay" ] || return 1
  if [ "$TOOL" = Bash ]; then _fp_feed "$hay" grep -qE "$FG_NET" || return 1; fi
  # One grep with every pattern says whether any can match; only then one grep per label, over the
  # lines that one matched (an error, exit 2, counts as a hit: the per-label greps then decide).
  for p in "${FG_RES[@]}"; do args+=(-e "$p"); done
  scan=$(_fp_feed "$hay" grep -E ${args[@]+"${args[@]}"}); rc=$?
  [ "$rc" = 1 ] && return 1
  [ "$rc" = 0 ] || scan="$hay"
  for ((i = 0; i < ${#FG_RES[@]}; i++)); do
    _fp_feed "$scan" grep -qE "${FG_RES[$i]}" && MATCHED_LABELS="${MATCHED_LABELS:+$MATCHED_LABELS,}${FG_LABELS[$i]}"
  done
  [ -n "$MATCHED_LABELS" ]
}
if [ "$_FG_END" != end ]; then
  # No jq on PATH: e78111c's scan decides. jq failed, or stopped short: no verdict was read — a
  # payload that names a tool asks (_fp_jqfail); garbage stdin (no tool name at all) exits 0.
  if command -v jq >/dev/null 2>&1; then
    case "$RAW" in *'"tool_name"'*)
      _fp_jqfail "flow-guard.sh" "${#RAW}" && { _fp_emit ask "second-brain flow-guard.sh could not read this call (jq failed on the payload; details in error-log.jsonl), so it cannot check it. Confirm the call."; exit 0; } ;;
    esac
    exit 0
  fi
  _fg_nojq || exit 0
else
  # The payload is not read again: freeing it keeps every later fork cheap (MSYS copies the heap).
  RAW="" _FP_RAW=""
  _fp_clean TOOL SESSION_ID
  # Only outbound channels concern us; no pattern matched (or the egress gate did not), no verdict.
  case "$TOOL" in Bash|WebFetch|WebSearch) ;; *) exit 0 ;; esac
  [ -n "$FG_HITS" ] || exit 0
  MATCHED_LABELS=""
  _fp_split , "$FG_HITS"
  for _i in ${_FP_A[@]+"${_FP_A[@]}"}; do
    MATCHED_LABELS="${MATCHED_LABELS:+$MATCHED_LABELS,}${FG_LABELS[$_i]}"
  done
fi

# Decision: ask. The audit-log TARGET intentionally carries only the matched labels — NOT the
# haystack content — because the haystack contains the secret value we just detected. Never log
# raw haystack slices: even a short prefix carries enough of e.g. a JWT into the log to be
# re-recognized by downstream consumers. Labels alone give /second-brain:audit and the SAR summary
# everything they need.
TARGET="${TOOL}:(${MATCHED_LABELS})"
_fg_reason "$TOOL" "$MATCHED_LABELS"
_fp_emit ask "$FG_REASON"
# The verdict is out; its audit row follows at once, written by this process (_fp_audit: builtins,
# no fork — GS5, R3B), so it is on disk when the hook exits and carries the verdict's late flag.
_fp_audit "flow-guard.sh" "ask" "info-flow:${MATCHED_LABELS}" "$TARGET" "$FG_REASON" "$SESSION_ID" full

# The buddy line needs lib.sh and jq: it follows from a detached job, every fd redirected so the
# hook's stdout closes at once (1d82fc1's shape). SB_GUARD_LOG_SYNC=on writes it before exiting
# (tests). lib.sh unsourceable: the verdict and its row stand, the buddy line is lost — logged.
_fg_buddy() {
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
  if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
    _fp_err "flow-guard.sh" "lib.sh could not be sourced from $PLUGIN_ROOT/scripts: the buddy line for this ask (${MATCHED_LABELS:0:60}) is lost"
    return 0
  fi
  command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$SESSION_ID" guard alert "Held for your OK: credential-shaped data heading out (${MATCHED_LABELS:0:60})." flow-guard 300
  return 0
}
if [ "${SB_GUARD_LOG_SYNC:-off}" = on ]; then
  _fg_buddy
else
  ( _fg_buddy ) </dev/null >/dev/null 2>&1 &
fi

exit 0
