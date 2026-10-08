#!/bin/bash
# symlink-guard.sh — PreToolUse hook for Write/Edit/MultiEdit.
#
# Closes gap G-HOOK-2: symlinked wiki paths bypassed the write guard.
# Blocks writes whose path (after symlink resolution) lands inside a known
# credential-bearing directory. Defense against the symlink-escape exfil
# scenario where Claude is instructed to write a benign-looking file that is
# actually a symlink into ~/.ssh, ~/.gnupg, etc.
#
# Anthropic doctrine: "Symlink resolution has to happen before path validation,
# not after." (engineering/how-we-contain-claude). We realpath first, then
# match the *resolved* path against the credential-dir list.
#
# In scope:
#   - Write / Edit / MultiEdit — any tool that mutates a file.
#
# Out of scope:
#   - Bash — uses flow-guard for credential-shaped egress.
#   - Read — read-only; not a write-escape risk.
#
# Credential stores (after realpath, case-insensitive; _SG_CRED_H / _SG_CRED_A below), in two tiers:
#   DENY — under $HOME and $USERPROFILE: .ssh, .gnupg, .aws, .config/claude, .config/gh,
#   .password-store, and the files .netrc, .claude/.credentials.json (the OAuth token; the ~/.claude
#   TREE is deliberately not a prefix, it holds legitimate write targets); /etc.
#   ASK (P-C2: the stores added in 0.56.0) — under $HOME and $USERPROFILE: .config/gcloud, .azure,
#   and the files .git-credentials, .npmrc, .docker/config.json, .kube/config, .pypirc, _netrc,
#   .config/git/credentials, .pgpass, .vault-token, .cargo/credentials(.toml),
#   .terraform.d/credentials.tfrc.json, .gem/credentials; under %APPDATA%: GitHub CLI/hosts.yml, gcloud.
#
# Verdict: deny (DENY tier) or ask (ASK tier; the strictest store any spelling names wins). Reason
# carries which credential store matched (no content leaked).
#
# No lib.sh (B7): it only ever supplied sb_normalize_path and sb_log_audit, which the shared
# fast-path block below mirrors with builtins; sourcing it cost ~100 ms per Write/Edit on MSYS.
#
# Kill switch: SB_SYMLINK_GUARD=off
# Always exits 0; decision flows through hookSpecificOutput JSON.
set -u

[ "${SB_SYMLINK_GUARD:-on}" = "off" ] && exit 0

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

# --- Credential targets (shared by the fast path and the full logic) -------------------------
# _sg_norm VAR PATH: lib.sh sb_normalize_path — the lexical steps, then cygpath -u for a drive
# path (Windows git-bash sends 'C:\…' / 'C:/…'; the credential prefixes are /c/… POSIX form).
_sg_norm() {
  local _sn_p _sn_u
  _fp_path _sn_p "$2"
  case "$_sn_p" in
    [A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then
        _sn_u=$(cygpath -u "$_sn_p" 2>/dev/null) && [ -n "$_sn_u" ] && _sn_p="$_sn_u"
      fi ;;
  esac
  printf -v "$1" '%s' "$_sn_p"
}

# _sg_homes lex|full: _SG_H = the HOME spellings the credential prefixes are built from, in the
# SAME normalized form as the target (a GitHub Windows runner sets HOME='D:\a\_temp\…'; a shell
# started from cmd/PowerShell can too — a raw-$HOME prefix then never matched the /c/… path and a
# ~/.ssh write was ALLOWED), plus HOME's PHYSICAL spelling (junction, 8.3 short name, symlinked
# profile): the resolved target comes out of `pwd -P`/realpath in that spelling. Builtin cd -P,
# cwd restored: no subshell.
# GX6 (R3B): USERPROFILE joins HOME (with HOME pointed elsewhere the native tools keep their stores
# under the Windows profile still) and _SG_HA spells APPDATA, both lexically and physically only —
# native Windows paths under no MSYS mount, so no cygpath spawn.
# P-C6: a UNC value (//… or \\…) gets no physical spelling: `cd -P` into an unreachable share blocks
# (~2.7 s per share on Windows, longer for a host that resolves and never answers) — two of them put
# a deny past the hook budget, and the Write ran. Its lexical spelling is still matched.
_sg_unc() { case "$1" in //*|"$_fp_bs$_fp_bs"*) return 0 ;; esac; return 1; }
_sg_homes() {
  local _sh_h _sh_p="" _sh_o="$PWD" _sh_v _sh_s _sh_z _sh_q
  if [ "$1" = lex ]; then _fp_path _sh_h "$HOME" lex; else _sg_norm _sh_h "$HOME"; fi
  _sh_h="${_sh_h%/}"
  if [ -n "${HOME:-}" ] && ! _sg_unc "$HOME" && CDPATH= cd -P -- "$HOME" 2>/dev/null; then
    _sh_p="$PWD"; cd -- "$_sh_o" 2>/dev/null
    if [ "$1" = lex ]; then _fp_path _sh_p "$_sh_p" lex; else _sg_norm _sh_p "$_sh_p"; fi
    _sh_p="${_sh_p%/}"
  fi
  _SG_H=() _SG_HA=()
  [ -n "$_sh_h" ] && _SG_H+=("$_sh_h")
  [ -n "$_sh_p" ] && [ "$_sh_p" != "$_sh_h" ] && _SG_H+=("$_sh_p")
  # F-E: a HOME spelled in a drive form that lies UNDER an MSYS mount (e.g. /c/…/AppData/Local/Temp =
  # /tmp) has no /c/… spelling that the resolved target matches — realpath/pwd -P return the mount name
  # (/tmp/…), which no prefix above does. Add HOME's mount spelling via the cygpath round trip (-m to
  # the drive form, -u to the mount name), in the `full` mode whose output the RESOLVED match uses.
  # A normal HOME (C:\Users\name) round-trips back to its own /c/… form and is deduped out, so this
  # costs real users nothing beyond the probe. Windows only.
  if [ "$1" = full ] && command -v cygpath >/dev/null 2>&1 && [ ${#_SG_H[@]} -gt 0 ]; then
    local _sh_e _sh_x _sh_m _sh_u _sh_dup
    local -a _sh_base=(${_SG_H[@]+"${_SG_H[@]}"})
    for _sh_e in ${_sh_base[@]+"${_sh_base[@]}"}; do
      _sh_m=$(cygpath -m -- "$_sh_e" 2>/dev/null) && [ -n "$_sh_m" ] || continue
      _sh_u=$(cygpath -u -- "$_sh_m" 2>/dev/null) && [ -n "$_sh_u" ] || continue
      _sh_u="${_sh_u%/}"
      _sh_dup=0
      for _sh_x in ${_SG_H[@]+"${_SG_H[@]}"}; do [ "$_sh_x" = "$_sh_u" ] && { _sh_dup=1; break; }; done
      [ "$_sh_dup" = 0 ] && _SG_H+=("$_sh_u")
    done
  fi
  for _sh_v in USERPROFILE APPDATA; do
    _sh_s="${!_sh_v:-}"
    [ -n "$_sh_s" ] || continue
    _sh_q=""
    if ! _sg_unc "$_sh_s" && CDPATH= cd -P -- "$_sh_s" 2>/dev/null; then _sh_q="$PWD"; cd -- "$_sh_o" 2>/dev/null; fi
    for _sh_z in "$_sh_s" "$_sh_q"; do
      [ -n "$_sh_z" ] || continue
      _fp_path _sh_z "$_sh_z" lex; _sh_z="${_sh_z%/}"
      [ -n "$_sh_z" ] || continue
      if [ "$_sh_v" = APPDATA ]; then _SG_HA+=("$_sh_z"); else _SG_H+=("$_sh_z"); fi
    done
  done
  return 0
}

# _sg_cred_match PATH…: _SG_LABEL = the credential dir/file a PATH is, or is under, and _SG_TIER its
# tier (deny|ask). Case-INSENSITIVE (nocasematch, bash 3.1+): NTFS and default APFS are
# case-insensitive, so /c/Users/me/.SSH/ IS ~/.ssh there — a case-varied path must not slip the
# check. On case-sensitive Linux this can over-match a literally distinct ~/.SSH dir; acceptable — a
# rare false deny is fail-safe, a missed credential write is not. (It replaced a `printf | tr` per
# prefix per candidate: ~36 processes, ~1 s of this guard's 1.5 s on MSYS.) The directory node
# itself matches as well as anything under it: a Write to exactly ~/.ssh must not slip past. The
# strictest store any PATH names wins: a deny-tier match ends the search, an ask-tier one is kept
# while the remaining PATHs are looked at.
# The stores (GX6, R3B: the list grew; persona-tool-guard's credential Read check holds the same two,
# tests/test-persona-tool-guard.sh locks them together, tiers included): tier:label:path under every
# _SG_H spelling (HOME, USERPROFILE), then under every _SG_HA one (APPDATA). Each entry is the path or
# anything inside it — a file has nothing inside, and ~/.claude is no entry: plans/, projects/
# (memory) and settings.json live there and are legitimate write targets. Tiers (P-C2, 0.56.0
# policy): the stores denied at 407fa24 — and /etc — are DENY; the stores this release added (GX6,
# P-S8) are ASK: "edit my ~/.npmrc" is routine, and a deny there left no per-call approve. A Read of
# either tier asks (persona-tool-guard). P-S8 added _netrc (curl's name on Windows), git's XDG
# credential file, .pgpass, .vault-token, cargo's two, terraform's and RubyGems'.
_SG_CRED_H=(deny:ssh:.ssh deny:gnupg:.gnupg deny:aws:.aws deny:claude-config:.config/claude deny:gh-config:.config/gh deny:passwordstore:.password-store deny:netrc:.netrc deny:claude-oauth:.claude/.credentials.json ask:gcloud:.config/gcloud ask:azure:.azure ask:git-credentials:.git-credentials ask:npmrc:.npmrc ask:docker-config:.docker/config.json ask:kube-config:.kube/config ask:pypirc:.pypirc ask:netrc:_netrc ask:git-credentials:.config/git/credentials ask:pgpass:.pgpass ask:vault-token:.vault-token ask:cargo-credentials:.cargo/credentials ask:cargo-credentials:.cargo/credentials.toml ask:terraform-credentials:.terraform.d/credentials.tfrc.json ask:gem-credentials:.gem/credentials)
_SG_CRED_A=('ask:gh-hosts:GitHub CLI/hosts.yml' ask:gcloud:gcloud)
_SG_LABEL="" _SG_TIER=""
# _sg_cred_hit ENTRY: a matched store, recorded unless one was already; a deny-tier one replaces an
# ask-tier one and is true (stop looking).
_sg_cred_hit() {
  local _sk_r="${1#*:}"
  if [ "${1%%:*}" = deny ]; then _SG_TIER=deny _SG_LABEL="${_sk_r%%:*}"; return 0; fi
  [ -n "$_SG_LABEL" ] || _SG_TIER=ask _SG_LABEL="${_sk_r%%:*}"
  return 1
}
_sg_cred_match() {
  local _sc_c _sc_h _sc_e _sc_p
  _SG_LABEL="" _SG_TIER=""
  shopt -s nocasematch
  for _sc_c in "$@"; do
    [ -n "$_sc_c" ] || continue
    case "$_sc_c" in /etc|/etc/*) _SG_TIER=deny _SG_LABEL=etc; break ;; esac
    for _sc_h in ${_SG_H[@]+"${_SG_H[@]}"}; do
      for _sc_e in "${_SG_CRED_H[@]}"; do
        _sc_p="$_sc_h/${_sc_e#*:*:}"
        case "$_sc_c" in "$_sc_p"|"$_sc_p"/*) _sg_cred_hit "$_sc_e" && break 3 ;; esac
      done
    done
    for _sc_h in ${_SG_HA[@]+"${_SG_HA[@]}"}; do
      for _sc_e in "${_SG_CRED_A[@]}"; do
        _sc_p="$_sc_h/${_sc_e#*:*:}"
        case "$_sc_c" in "$_sc_p"|"$_sc_p"/*) _sg_cred_hit "$_sc_e" && break 3 ;; esac
      done
    done
  done
  shopt -u nocasematch
  [ -n "$_SG_LABEL" ]
}

# _sg_short VAR TEXT: TEXT cut to 256 characters for a reason or an audit target. _fp_esc runs one
# ${v//…} pass per escaped character class, O(matches x length) in a UTF-8 locale: a 50,000-newline
# path spelled out in a deny cost ~2.8 s per escape on MSYS (three per verdict), and the verdict
# only needs to name the target, not reproduce it.
_sg_short() {
  if [ "${#2}" -le 256 ]; then printf -v "$1" '%s' "$2"; else printf -v "$1" '%s' "${2:0:256}… (${#2} characters)"; fi
}

# _sg_segs VAR PATH: how many of PATH's components realpath -m has to walk. Empty and '.' fields cost
# it nothing (2,048 of them: ~60 ms on MSYS, against ~2 s for 256 real ones), so they do not count
# (G1, 0.54.1 final review: counting them sent a './'-padded link into ~/.ssh to an ask, not a deny).
_sg_segs() {
  local _sz_s _sz_n=0
  _fp_split / "$2"
  for _sz_s in ${_FP_A[@]+"${_FP_A[@]}"}; do
    case "$_sz_s" in ''|.) ;; *) _sz_n=$((_sz_n + 1)) ;; esac
  done
  printf -v "$1" '%s' "$_sz_n"
}

# _sg_drive_homes: on a Windows host, _SG_H gains every HOME spelling's drive form, spelled /x/… as
# the lexical target is — one cygpath -m of the short HOME paths. A HOME under an MSYS mount (/tmp is
# %TEMP%) has no /c/… spelling of its own, and a target past the cap never reaches cygpath to be
# spelled the mount's way instead.
_sg_drive_homes() {
  local _sd_o _sd_l
  command -v cygpath >/dev/null 2>&1 && [ ${#_SG_H[@]} -gt 0 ] || return 0
  _sd_o=$(cygpath -m ${_SG_H[@]+"${_SG_H[@]}"} 2>/dev/null) || return 0
  _fp_split "$_fp_nl" "${_sd_o//"$_fp_cr"/}"
  for _sd_l in ${_FP_A[@]+"${_FP_A[@]}"}; do
    _fp_path _sd_l "$_sd_l" lex
    _SG_H+=("${_sd_l%/}")
  done
}

# _sg_resolve VAR PATH: PATH through its symlinks, missing components tolerated (a Write may create
# them): GNU realpath -m, then Homebrew greadlink -f, then a walk for stock BSD/macOS.
_sg_resolve() {
  local _sr_r _sr_rem _sr_res _sr_seg _sr_cand _sr_rp _sr_tgt
  _sr_r=$(realpath -m -- "$2" 2>/dev/null)        # GNU coreutils: follows leaf + parent, missing-tolerant
  [ -z "$_sr_r" ] && _sr_r=$(greadlink -f -- "$2" 2>/dev/null)  # macOS Homebrew coreutils
  if [ -z "$_sr_r" ]; then
    # Stock BSD/macOS (no GNU realpath/greadlink, or BSD realpath which lacks `-m`).
    # D183: walk the path component-by-component from the root, resolving symlinks
    # at each STILL-EXISTING ancestor via `cd … && pwd -P` (bash 3.2 / BSD safe).
    # Once a component does not exist yet (the common case for a Write that
    # creates new directories), lexically collapse the REMAINING '.'/'..'
    # segments against the last resolved ancestor instead of returning the raw
    # unresolved tail — `cd` failing on ONE missing directory must not
    # short-circuit into a lexical passthrough that leaves '..' unresolved (a
    # Write to <repo>/<newdir>/../../../.ssh/id_rsa was silently ALLOWED before
    # this fix, and a symlinked ancestor with a not-yet-created child, e.g.
    # <repo>/link-to-.ssh/sub/id_rsa, was too). Fail CLOSED throughout.
    _sr_rem="$2"
    case "$_sr_rem" in
      /*) _sr_res="/" ;;
      *)  _sr_res="$PWD/" ;;
    esac
    while [ -n "$_sr_rem" ]; do
      _sr_rem="${_sr_rem#/}"
      _sr_seg="${_sr_rem%%/*}"
      case "$_sr_rem" in */*) _sr_rem="${_sr_rem#*/}" ;; *) _sr_rem="" ;; esac
      case "$_sr_seg" in
        ""|".") continue ;;
        "..")
          _sr_res="${_sr_res%/}"; _sr_res="${_sr_res%/*}"; [ -z "$_sr_res" ] && _sr_res="/"
          continue
          ;;
      esac
      _sr_cand="${_sr_res%/}/$_sr_seg"
      if _sr_rp=$(cd "$_sr_cand" 2>/dev/null && pwd -P); then
        _sr_res="$_sr_rp"
      elif [ -L "$_sr_cand" ]; then
        _sr_tgt=$(readlink -- "$_sr_cand" 2>/dev/null)
        # D183 (follow-up): splicing the target string directly into $_sr_res left
        # any '..' INSIDE a relative target unresolved (`ln -s ../../.ssh/id_rsa
        # repo/notes.txt` produced ".../repo/../../.ssh/id_rsa" verbatim, which
        # never prefix-matches the real credential dir). Re-enter the walk
        # instead: push the target's segments back onto $_sr_rem so the SAME '..'
        # popping logic above collapses them against $_sr_res (relative target) or
        # against '/' (absolute target), rather than a raw lexical splice.
        case "$_sr_tgt" in
          /*) _sr_res="/"; _sr_rem="${_sr_tgt#/}${_sr_rem:+/$_sr_rem}" ;;
          *)  _sr_rem="$_sr_tgt${_sr_rem:+/$_sr_rem}" ;;
        esac
      else
        _sr_res="${_sr_res%/}/$_sr_seg"
      fi
    done
    _sr_r="$_sr_res"
  fi
  printf -v "$1" '%s' "$_sr_r"
}

# _sg_verdict TOOL FILE_PATH RESOLVED LABEL SESSION: the credential-store verdict, by _SG_TIER — a
# deny for the deny tier, an ask for the ask tier (P-C2).
_sg_verdict() {
  local _sd_p _sd_x _sd_r
  _sg_short _sd_p "$2"; _sg_short _sd_x "$3"
  if [ "$_SG_TIER" = ask ]; then
    _sd_r="Write to '$_sd_p' resolves to '$_sd_x', inside the credential store '$4' (it holds a token or a password). Symlink-guard asks before any write there: confirm that this edit is intended. Suppress: SB_SYMLINK_GUARD=off."
    _fp_audit "symlink-guard.sh" "ask" "credential-dir:$4" "$1($_sd_p)" "$_sd_r" "$5" "$_SG_FULL"
    _fp_emit ask "$_sd_r"
    return 0
  fi
  _sd_r="Write to '$_sd_p' resolves to '$_sd_x' which is inside the credential directory '$4'. Symlink-guard denies to prevent credential overwrite or exfil. Suppress: SB_SYMLINK_GUARD=off."
  _fp_audit "symlink-guard.sh" "deny" "credential-dir:$4" "$1($_sd_p)" "$_sd_r" "$5" "$_SG_FULL"
  _fp_emit deny "$_sd_r"
}

# _sg_alias TOOL PATH SESSION (SEC-H2): on a Windows host, PATH can name a local file without its
# drive path, and neither cygpath nor realpath resolves the spelling, so the credential prefixes
# never saw it — a UNC path (\\LOCALHOST\C$\…, \\<machine>\C$\…, \\?\UNC\…,
# \\0--1.ipv6-literal.net\C$\…) or NTFS stream syntax (.ssh::$INDEX_ALLOCATION and
# .ssh:$I30:$INDEX_ALLOCATION name the directory itself). Stream syntax (a ':' after the drive) is
# never a plain file: deny. An administrative share (X$) is mapped to its drive: returns 2 with
# _SG_MAPPED = X:/…, which the caller checks like any other target. Any other UNC target: ask —
# where a share leads cannot be told. 0 = verdict emitted; 1 = not an alias spelling.
_SG_MAPPED=""
_sg_alias() {
  local _sa_r _sa_p _sa_s _sa_m _sa_d _sa_t=""
  _SG_MAPPED=""
  command -v cygpath >/dev/null 2>&1 || [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || return 1
  _sg_short _sa_d "$2"
  # F-B (0.54.1 final review): `${2//\\//}` and `${_sa_p#[A-Za-z]:}` were both O(n^2) on MSYS, and
  # _sg_alias runs before the literal credential match — a 200 KB backslash path denied past the 5 s
  # timeout (the Write then ran). Backslash->slash goes through the linear split/join _fp_path uses
  # (trailing separator re-added, as there); the drive strip is an O(1) offset.
  case "$2" in
    *"$_fp_bs"*)
      case "$2" in *"$_fp_bs") _sa_t=/ ;; esac
      _fp_split "$_fp_bs" "$2"; _fp_joinsl _sa_r; _sa_r="$_sa_r$_sa_t" ;;
    *) _sa_r="$2" ;;
  esac
  _fp_path _sa_p "$2"
  case "$_sa_p" in [A-Za-z]:*) _sa_t=${_sa_p:2} ;; *) _sa_t=$_sa_p ;; esac
  case "$_sa_t" in
    *:*) _sa_m="Write to '$_sa_d' uses NTFS stream syntax (a ':' after the drive), which can name another file or a directory itself (.ssh::\$INDEX_ALLOCATION is ~/.ssh). Symlink-guard denies it. Suppress: SB_SYMLINK_GUARD=off."
         _fp_audit "symlink-guard.sh" "deny" "windows-alias:stream" "$1($_sa_d)" "$_sa_m" "$3" "$_SG_FULL"
         _fp_emit deny "$_sa_m"
         return 0 ;;
  esac
  case "$_sa_r" in //*) ;; *) return 1 ;; esac
  case "$_sa_p" in [A-Za-z]:/*) return 1 ;; esac
  case "$_sa_r" in //[?.]/[Uu][Nn][Cc]/*) _sa_r="//${_sa_r#//?/???/}" ;; esac
  _sa_s="${_sa_r#//}"; _sa_s="${_sa_s#*/}"
  case "$_sa_s" in
    [A-Za-z]\$)   _SG_MAPPED="${_sa_s%\$}:/"; return 2 ;;
    [A-Za-z]\$/*) _SG_MAPPED="${_sa_s%%\$*}:${_sa_s#?\$}"; return 2 ;;
  esac
  _sa_m="Write to '$_sa_d' is a UNC network path: symlink-guard cannot tell whether that share leads to a credential directory on this machine. Confirm the target. Suppress: SB_SYMLINK_GUARD=off."
  _fp_audit "symlink-guard.sh" "ask" "windows-alias:unc" "$1($_sa_d)" "$_sa_m" "$3" "$_SG_FULL"
  _fp_emit ask "$_sa_m"
  return 0
}

# --- B7 fast path: credential targets decided before any process ------------------------------
# _sg_phys PATH: _SG_PHYS = PATH with every EXISTING directory component resolved physically
# (builtin cd -P in this shell, cwd restored: no subshell, no realpath) and the not-yet-created
# tail collapsed lexically against it — realpath -m's answer whenever the leaf itself is not a
# symlink. Returns 1 when it cannot tell without a process: the leaf IS a symlink (bash has no
# readlink); _SG_LEAF then names it for the inode check.
_sg_phys() {
  local _sp_p="$1" _sp_d _sp_t="" _sp_l _sp_o="$PWD" _sp_out _sp_rem _sp_seg
  _SG_PHYS="" _SG_LEAF=""
  case "$_sp_p" in /*) ;; *) _sp_p="$PWD/$_sp_p" ;; esac
  # A '..' segment, or over 64 segments, goes to the full logic's one realpath -m: the walk below
  # stats and trims once per missing component (an a/../a/.. path of 3.7 KB took 5.8 s, 14 KB 138 s).
  case "/$_sp_p/" in */../*) return 1 ;; esac
  _fp_split / "$_sp_p"
  [ "${#_FP_A[@]}" -le 64 ] || return 1
  _sp_d="${_sp_p%/*}"; _sp_l="${_sp_p##*/}"
  while [ -n "$_sp_d" ] && [ ! -d "$_sp_d" ]; do
    _sp_t="${_sp_d##*/}${_sp_t:+/$_sp_t}"; _sp_d="${_sp_d%/*}"
  done
  [ -n "$_sp_d" ] || _sp_d=/
  CDPATH= cd -P -- "$_sp_d" 2>/dev/null || return 1
  _sp_out="${PWD%/}"; cd -- "$_sp_o" 2>/dev/null
  if [ -z "$_sp_t" ] && [ -L "$_sp_out/$_sp_l" ]; then _SG_LEAF="$_sp_out/$_sp_l"; return 1; fi
  _sp_rem="$_sp_t${_sp_t:+/}$_sp_l"
  while [ -n "$_sp_rem" ]; do
    _sp_seg="${_sp_rem%%/*}"
    case "$_sp_rem" in */*) _sp_rem="${_sp_rem#*/}" ;; *) _sp_rem="" ;; esac
    case "$_sp_seg" in ""|.) ;; ..) _sp_out="${_sp_out%/*}" ;; *) _sp_out="$_sp_out/$_sp_seg" ;; esac
  done
  _SG_PHYS="${_sp_out:-/}"
  return 0
}
# _sg_inode LINK: _SG_LABEL (and _SG_TIER) when LINK is the same file (device + inode, `test -ef`)
# as a credential dir, a file directly in one, or /etc and its direct entries — the classic escape
# (a repo file symlinked to ~/.ssh/authorized_keys) decided with no readlink. LINK is one file, so
# the first store it is answers; the deny tier is tried first.
_sg_inode() {
  local _si_h _si_e
  _SG_LABEL="" _SG_TIER=""
  for _si_h in ${_SG_H[@]+"${_SG_H[@]}"}; do
    for _si_e in "${_SG_CRED_H[@]}"; do _sg_inode1 "$1" "$_si_h/${_si_e#*:*:}" "$_si_e" && return 0; done
  done
  _sg_inode1 "$1" /etc deny:etc: && return 0
  for _si_h in ${_SG_HA[@]+"${_SG_HA[@]}"}; do
    for _si_e in "${_SG_CRED_A[@]}"; do _sg_inode1 "$1" "$_si_h/${_si_e#*:*:}" "$_si_e" && return 0; done
  done
  return 1
}
# _sg_inode1 LINK STORE ENTRY: LINK is STORE, or (STORE a directory) one of its direct entries;
# _SG_TIER and _SG_LABEL from ENTRY (tier:label:path).
_sg_inode1() {
  local _s1_f _s1_r="${3#*:}"
  [ -e "$2" ] || return 1
  if [ -d "$2" ]; then
    for _s1_f in "$2" "$2"/* "$2"/.[!.]*; do
      [ -e "$_s1_f" ] && [ "$1" -ef "$_s1_f" ] && { _SG_TIER="${3%%:*}" _SG_LABEL="${_s1_r%%:*}"; return 0; }
    done
  elif [ "$1" -ef "$2" ]; then
    _SG_TIER="${3%%:*}" _SG_LABEL="${_s1_r%%:*}"; return 0
  fi
  return 1
}
_sg_fast() {
  local tool fp lit lex sid="" cwd rc
  _fp_str tool_name || return 1
  tool="$_FP"
  case "$tool" in Write|Edit|MultiEdit) ;; *) return 1 ;; esac
  _fp_str file_path || return 1
  _fp_nocr fp "$_FP"
  case "$fp" in ''|*"$_fp_nl"*) return 1 ;; esac
  case "$fp" in '~'*) fp="$HOME${fp#\~}" ;; esac
  # P-S1: a root-relative target goes on the payload cwd's drive (_fp_rroot); one that cannot be
  # placed is the full logic's (it asks).
  _fp_str cwd; rc=$?; [ "$rc" = 2 ] && return 1
  _fp_nocr cwd "$_FP"
  _fp_rroot fp "$fp" "$cwd" || return 1
  _fp_str session_id && sid="$_FP"
  _sg_alias "$tool" "$fp" "$sid"
  case $? in 0) return 0 ;; 2) fp="$_SG_MAPPED" ;; esac
  _fp_path lit "$fp" lex
  _sg_homes lex
  if _sg_phys "$lit"; then
    _sg_cred_match "$_SG_PHYS" "$lit" && { _sg_verdict "$tool" "$lit" "$_SG_PHYS" "$_SG_LABEL" "$sid"; return 0; }
  else
    # Unresolved ('..', a deep path, a leaf symlink): the literal target, and its '..' folded
    # lexically — a path that names a deny-tier store outright is denied here, as the full logic's
    # literal match would; anything else goes to realpath there. An ask-tier spelling is not decided
    # here: it may still lead into a deny-tier store (P-C2), which only the resolve can show.
    _fp_collapse lex "$lit"
    _sg_cred_match "$lit" "$lex" && [ "$_SG_TIER" = deny ] && { _sg_verdict "$tool" "$lit" "$lex" "$_SG_LABEL" "$sid"; return 0; }
    [ -n "$_SG_LEAF" ] && _sg_inode "$_SG_LEAF" \
      && { _sg_verdict "$tool" "$lit" "$_SG_LEAF (a symlink to a $_SG_LABEL entry)" "$_SG_LABEL" "$sid"; return 0; }
  fi
  return 1
}
_SG_FULL=""
_sg_fast && exit 0
# Every row from here on is the full logic's (_sg_verdict and _sg_alias are shared with the fast path).
_SG_FULL=full

# --- Full logic (the fast path could not decide) -----------------------------------------------
_fp_raw_all
[ -z "$RAW" ] && exit 0

# Fields: builtin decode when the payload is a JSON object and each field is decidable, else ONE
# jq (NUL-framed; the old form spent four spawns: object check + one per field). A non-object
# payload → no fields → exit 0 (the old fail-soft). CRs dropped, trailing newlines trimmed, as the
# old `jq -r … | tr -d '\r'` inside $(…) did.
TOOL="" FILE_PATH="" SESSION_ID="" CWD=""
_sg_fields() {
  local _sf_obj='^[[:space:]]*[{]' _sf_v _sf_rc
  [[ $RAW =~ $_sf_obj ]] || return 1
  for _sf_v in TOOL:tool_name FILE_PATH:file_path SESSION_ID:session_id CWD:cwd; do
    _fp_str "${_sf_v#*:}"; _sf_rc=$?
    [ "$_sf_rc" = 2 ] && return 1
    printf -v "${_sf_v%%:*}" '%s' "$_FP"
  done
  return 0
}
if ! _sg_fields; then
  TOOL="" FILE_PATH="" SESSION_ID="" CWD="" _FP_JST=""
  {
    IFS= read -r -d '' _FP_JST; IFS= read -r -d '' TOOL; IFS= read -r -d '' FILE_PATH; IFS= read -r -d '' SESSION_ID
    IFS= read -r -d '' CWD
  } < <(_fp_feed "$RAW" jq -j 'if type == "object" then (if ([.tool_name, .tool_input.file_path, .session_id, .cwd] | map(strings) | any(contains("\u0000"))) then "nul" else "ok" end), "\u0000", (.tool_name // ""), "\u0000", (.tool_input.file_path // ""), "\u0000", (.session_id // ""), "\u0000", (.cwd // ""), "\u0000" else empty end' 2>/dev/null)
  if [ "$_FP_JST" = nul ]; then
    _fp_audit "symlink-guard.sh" "ask" "nul-field" "$TOOL" "field holds a NUL character" "${SESSION_ID:-}" full
    _fp_emit ask "second-brain symlink-guard.sh cannot check this call: a field it reads holds a NUL character, which bash cannot represent. Confirm the call."
    exit 0
  fi
  if [ -z "$TOOL" ]; then
    case "$RAW" in *'"tool_name"'*)
      _fp_jqfail "symlink-guard.sh" "${#RAW}" && { _fp_emit ask "second-brain symlink-guard.sh could not read this call (jq failed on the payload; details in error-log.jsonl), so it cannot check it. Confirm the call."; exit 0; } ;;
    esac
  fi
fi
_fp_clean TOOL FILE_PATH SESSION_ID CWD

case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac
[ -z "$FILE_PATH" ] && exit 0

# Tilde expansion. tool_input.file_path is usually absolute already; tilde-
# prefixed paths arrive verbatim and need expansion before realpath.
case "$FILE_PATH" in
  '~'*) FILE_PATH="$HOME${FILE_PATH#\~}" ;;
esac

# P-S1: a Windows root-relative target (\Users\u\.ssh\x) goes on the payload cwd's drive, else
# CLAUDE_PROJECT_DIR's (_fp_rroot) — node opens it there. A \-rooted one with neither cannot be placed:
# it may land in any drive's credential directory, so it asks.
_fp_rroot FILE_PATH "$FILE_PATH" "$CWD"
if [ $? = 2 ]; then
  _sg_short _sg_rp "$FILE_PATH"
  _sg_rr="Write to '$_sg_rp' is root-relative (one leading '\\', no drive): Windows opens it on the current drive, which this call does not name, so symlink-guard cannot tell whether it lands in a credential directory. Confirm the target. Suppress: SB_SYMLINK_GUARD=off."
  _fp_audit "symlink-guard.sh" "ask" "windows-alias:root-relative" "$TOOL($_sg_rp)" "$_sg_rr" "$SESSION_ID" full
  _fp_emit ask "$_sg_rr"
  exit 0
fi

# Windows alias spellings (UNC, stream syntax), as on the fast path: a big payload whose file_path
# came after 16 KiB of content reaches only this logic.
_sg_alias "$TOOL" "$FILE_PATH" "$SESSION_ID"
case $? in 0) exit 0 ;; 2) FILE_PATH="$_SG_MAPPED" ;; esac

# The target as the fast path spells it too — lexical /x/ drive form, '..' folded. cygpath -u maps a
# drive path under an MSYS mount (%TEMP% is /tmp) to the mount's name, which a HOME spelled /c/…
# never prefixes; this spelling does.
_fp_path SG_LEX "$FILE_PATH" lex
# Its size before '..' folds (what realpath -m will walk), for the cap below: its characters and,
# under 4096 of them, its real components (_sg_segs; past 4096 the count is moot, and its loop over a
# 300 KB run of '/' would cost more than the answer is worth).
SG_LEN=${#SG_LEX} SG_SEGS=0
[ "$SG_LEN" -le 4096 ] && _sg_segs SG_SEGS "$SG_LEX"
_fp_collapse SG_LEX "$SG_LEX"

# The HOME spellings every credential match below compares against: HOME normalized, its physical
# spelling, and their lexical /x/ forms (the fast path's spelling of SG_LEX).
_sg_homes full
_SG_HF=(${_SG_H[@]+"${_SG_H[@]}"})
_sg_homes lex
_SG_H+=(${_SG_HF[@]+"${_SG_HF[@]}"})

# DA #2 (0.54.1): realpath -m is quadratic in the path's REAL components on MSYS (256 of them: ~2 s;
# 512: ~11 s; 2,048: no answer in 30 s), and a file_path past the fast path's 16 KiB read reached it
# before any credential match — a Write under ~/.ssh then got no verdict inside the 5 s timeout and
# ran. So the literal and lexical targets are matched first, and a path too long to resolve in time —
# over 256 REAL components (G1: '' and '.' fields cost realpath nothing, so they do not count) or
# 4096 characters — is handled by the block below without the quadratic resolve: the lexically folded
# target is matched and, when it is itself short enough, resolved. Both come before _sg_norm too
# (F8 item 18): cygpath -u takes seconds once a path holds newlines (4,096 of them: 0.4 s; 16,384:
# 5 s) and truncates a path longer than 32,767 characters at its input while still exiting 0 — so past
# the cap the raw target never reaches it, only the short spellings G1 uses below.
# _sg_full_hit TARGET: after a _sg_cred_match hit in the full logic — a deny-tier store denies at once;
# an ask-tier one is held (SG_ASK_L, SG_ASK_T) until the resolved target is known: an ask-tier
# spelling can lead into a deny-tier store (~/.azure linked to ~/.ssh), and the strictest wins (P-C2).
SG_ASK_L="" SG_ASK_T=""
_sg_full_hit() {
  if [ "$_SG_TIER" = deny ]; then _sg_verdict "$TOOL" "$FILE_PATH" "$1" "$_SG_LABEL" "$SESSION_ID"; exit 0; fi
  [ -n "$SG_ASK_L" ] || SG_ASK_L="$_SG_LABEL" SG_ASK_T="$1"
}
_sg_cred_match "$FILE_PATH" "$SG_LEX" && _sg_full_hit "$SG_LEX"
if [ "$SG_LEN" -gt 4096 ] || [ "$SG_SEGS" -gt 256 ]; then
  # G1 (0.54.1 final review): past the cap the target itself reaches no resolver — cygpath truncates a
  # path over 32,767 characters at its input, realpath -m is quadratic in real components. Two spellings stand
  # in for it: HOME's drive form, for a HOME under an MSYS mount the lexical target cannot match
  # otherwise; and the target folded (SG_LEX, already collapsed at the top of this block), when that
  # is under both limits — resolved, it denies a './' or 'a/../' run through a link into a credential
  # dir. Neither one can allow: no match still asks.
  # Free SG_LEX's split (up to ~300k fields for a run of '/') before the cygpath forks below: MSYS
  # copies the whole heap per fork.
  _FP_A=()
  _sg_drive_homes
  _sg_cred_match "$SG_LEX" && _sg_full_hit "$SG_LEX"
  # The drive-kept fold, from SG_LEX (collapsed) in constant time — not a second full-path collapse
  # (DA: that pass cost as much again and pushed the deny past the 5 s timeout). _sg_norm's cygpath -u
  # maps an MSYS mount only from the drive form (C:/…/Temp → /tmp), so the drive letter is taken from
  # FILE_PATH's own spelling (one linear _fp_path, no collapse) and the collapsed tail from SG_LEX.
  _fp_path _sg_fp "$FILE_PATH"
  case "$_sg_fp" in
    [A-Za-z]:/*)
      # SG_LEX is the collapsed lex form (/c/…). It keeps a leading "/<drive>/" EXCEPT when a '..' at
      # the drive root folds the drive component away (lex /c/../x collapses to /x). Windows clamps
      # '..' at the drive root, so there the fold is the drive plus SG_LEX whole; otherwise it is the
      # drive plus SG_LEX's tail. Cheap either way — one lowercase of the drive letter, no re-collapse
      # (Finding C: "${SG_LEX:2}" alone produced "C:sers/…" when the drive had been popped).
      _fp_lower _sg_dl "${_sg_fp:0:1}"
      case "$SG_LEX" in
        /"$_sg_dl"/*|"/$_sg_dl") _sg_fp="${_sg_fp:0:2}${SG_LEX:2}" ;;
        *) _sg_fp="${_sg_fp:0:2}$SG_LEX" ;;
      esac ;;
    *) _sg_fp="$SG_LEX" ;;
  esac
  # When the fold is itself short enough to hand a tool (<= 4096), run cygpath -u on it: that is one
  # cheap spawn (~35 ms at any length) and it maps an MSYS mount the lexical form cannot — /etc under
  # the Git root, a HOME under %TEMP% (F-D/F-E: HEAD mapped these by running cygpath -u on the raw
  # target past the cap, which this guard no longer does). The literal match on that mapped form runs
  # regardless of component count. The realpath resolve, quadratic in REAL components, stays behind the
  # 256 gate.
  if [ "${#_sg_fp}" -le 4096 ]; then
    _sg_norm _sg_fp "$_sg_fp"
    _sg_cred_match "$_sg_fp" && _sg_full_hit "$_sg_fp"
    _sg_segs _sg_fs "$_sg_fp"
    if [ "$_sg_fs" -le 256 ]; then
      _sg_resolve _sg_fr "$_sg_fp"; _sg_norm _sg_fr "$_sg_fr"
      _sg_cred_match "$_sg_fr" && _sg_full_hit "$_sg_fr"
    fi
  fi
  # A held ask-tier store asks under its own name (no deny-tier store was found on any spelling).
  if [ -n "$SG_ASK_L" ]; then
    _SG_TIER=ask; _sg_verdict "$TOOL" "$FILE_PATH" "$SG_ASK_T" "$SG_ASK_L" "$SESSION_ID"; exit 0
  fi
  _sg_short _sg_sp "$FILE_PATH"
  if [ "$SG_LEN" -gt 4096 ]; then _sg_why="$SG_LEN characters"; else _sg_why="$SG_SEGS components"; fi
  _sg_lr="Write to '$_sg_sp' is too long to resolve through its symlinks inside the hook's time budget ($_sg_why; the limits are 4096 characters and 256 components), so symlink-guard cannot tell whether it leads into a credential directory. Confirm the target. Suppress: SB_SYMLINK_GUARD=off."
  _fp_audit "symlink-guard.sh" "ask" "path-too-long" "$TOOL($_sg_sp)" "$_sg_lr" "$SESSION_ID" full
  _fp_emit ask "$_sg_lr"
  exit 0
fi

# Windows git-bash sends 'C:\…' / 'C:/…'; normalize to the /c/… POSIX form the
# credential prefixes use BEFORE realpath (so it resolves) and again AFTER (GNU
# realpath re-emits C:/ form on Windows — normalizing its OUTPUT is the G-HOOK-2
# fix: without it the credential-dir prefixes never match and the guard is inert).
_sg_norm FILE_PATH "$FILE_PATH"

# Resolve through symlinks (_sg_resolve). Missing-component-tolerant: the file a
# Write targets may not exist yet; its parents' symlinks are still resolved.
_sg_resolve RESOLVED "$FILE_PATH"
# Normalize realpath's OUTPUT to the /c/… form so it matches the credential
# prefixes (see the pre-realpath note above — this is the load-bearing half).
_sg_norm RESOLVED "$RESOLVED"

# D182: NTFS 8.3 short-name components ("SSH~1" for .ssh, "TMP~1.MKZ" for a
# longer temp dir) pass through realpath UNEXPANDED — a credential dir reached
# via its short alias never matches the long-form prefix list below. This was
# originally a blanket deny, but the pattern also matches ordinary long
# filenames that merely contain a tilde+digit (notes~1.md, a CI runner's
# RUNNER~1 temp dir) with nothing to expand — over-blocking normal project
# writes. When `cygpath` is available, ask Windows for the real long-form
# path and evaluate THAT instead: if the target exists, expand it directly;
# if only its parent exists (the common Write-a-new-file case), expand the
# parent and reattach the leaf — `cygpath -l -m` does not expand a leaf that
# is not itself present on disk. Deny outright, before the prefix match, only
# when expansion is unavailable (no cygpath, or nothing on the path exists to
# query) — that is the case this guard genuinely cannot resolve safely.
# 8.3 aliases exist only on Windows filesystems: on Linux/macOS a `NAME~1` component is an
# ordinary filename, so the rule applies only where cygpath is present (native Windows, or
# the suite's stubbed-cygpath Windows lane) or the host is MSYS/Cygwin ($OSTYPE, not a uname
# spawn). The component test runs line by line, as the grep it replaced did.
_sg_has_83() {
  local _s8_s _s8_l _s8_re='(^|/)[^/]*~[0-9]+(\.[^/.]*)?(/|$)'
  for _s8_s in "$@"; do
    _fp_split "$_fp_nl" "$_s8_s"
    for _s8_l in ${_FP_A[@]+"${_FP_A[@]}"}; do [[ $_s8_l =~ $_s8_re ]] && return 0; done
  done
  return 1
}
_sn_windows_host=0
if command -v cygpath >/dev/null 2>&1; then _sn_windows_host=1; else
  case "${OSTYPE:-}" in msys*|cygwin*) _sn_windows_host=1 ;; esac
fi
if [ "$_sn_windows_host" -eq 1 ] && _sg_has_83 "$FILE_PATH" "$RESOLVED"; then
  EXPANDED=""
  if command -v cygpath >/dev/null 2>&1; then
    if [ -e "$RESOLVED" ]; then
      EXPANDED=$(cygpath -l -m -- "$RESOLVED" 2>/dev/null | tr -d '\r')
    else
      _sn_parent="${RESOLVED%/*}"; _sn_leaf="${RESOLVED##*/}"
      if [ -n "$_sn_parent" ] && [ -e "$_sn_parent" ]; then
        _sn_pexp=$(cygpath -l -m -- "$_sn_parent" 2>/dev/null | tr -d '\r')
        [ -n "$_sn_pexp" ] && EXPANDED="$_sn_pexp/$_sn_leaf"
      fi
    fi
    [ -n "$EXPANDED" ] && _sg_norm EXPANDED "$EXPANDED"
  fi
  if [ -n "$EXPANDED" ]; then
    RESOLVED="$EXPANDED"
  else
    SHORTNAME_REASON="Write to '$FILE_PATH' (resolved '$RESOLVED') contains an NTFS 8.3 short-name path component (e.g. 'NAME~1') that could not be expanded back to its long form (no cygpath, or nothing on the path exists to query). Symlink-guard denies rather than risk a credential-dir alias slipping past the prefix check. Suppress: SB_SYMLINK_GUARD=off."
    _fp_audit "symlink-guard.sh" "deny" "ntfs-8.3-shortname" "${TOOL}(${FILE_PATH})" "$SHORTNAME_REASON" "$SESSION_ID" full
    _fp_emit deny "$SHORTNAME_REASON"
    exit 0
  fi
fi

# Credential match on the RESOLVED target and on the LITERAL (normalized, unresolved) one: when the
# resolver degrades (realpath absent, a HOME spelling pwd -P rewrites), a path that names a
# credential dir outright must still be denied. Resolved-only let a literal ~/.ssh write through
# on the GitHub Windows runner. The literal targets were matched before realpath (DA #2); they stay
# listed here as well, after the resolved one, in case a later edit drops that early check. The
# strictest store any of them names decides (P-C2): deny for the deny tier, ask for the ask tier; an
# ask-tier store held from the early match asks even if a later edit drops it from this list.
if _sg_cred_match "$RESOLVED" "$FILE_PATH" "$SG_LEX"; then
  _sg_verdict "$TOOL" "$FILE_PATH" "$RESOLVED" "$_SG_LABEL" "$SESSION_ID"
elif [ -n "$SG_ASK_L" ]; then
  _SG_TIER=ask; _sg_verdict "$TOOL" "$FILE_PATH" "$SG_ASK_T" "$SG_ASK_L" "$SESSION_ID"
fi
exit 0
