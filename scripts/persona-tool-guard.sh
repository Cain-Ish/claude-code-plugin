#!/bin/bash
# persona-tool-guard.sh — Layer 3 PreToolUse hook, rules-based (no LLM)
# Reads tool_input from STDIN JSON, matches against persona-rules.json (user) or
# persona-rules.default.json (plugin shipped). Returns hookSpecificOutput with
# permissionDecision and optional updatedInput.
#
# Every verdict (ask/deny/rewrite) is appended to audit-log.jsonl via
# sb_log_audit so /second-brain:audit can summarize what the safety
# layer did this session.
#
# Kill switch: SB_PERSONA_GATE=off
# Always exits 0.
set -u

[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

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

# Session Intent Spine — phase transitions. implement → verify only when a Bash
# span's FIRST TOKEN is a verification runner: substring matching flipped on
# `cat .eslintrc.json` / a commit message mentioning a test path; anchoring on the
# command word cannot. verify → implement when a file edit lands after verification
# (the edit invalidates the evidence, and a residual false flip self-heals).
# Pure bash — parameter expansion, read/set builtins, case-globs: zero extra spawns
# on the hot path. Fail-open: a read/write failure never touches the guard verdict.
# Kill switch checked before any spine work. Reads TOOL CMD SESSION_ID BRAIN_DIR; runs from the
# fast path too (before lib.sh), hence its own SB_HOOK_PROFILE shim. sb_buddy_event is lib.sh's,
# so a phase change decided on the fast path updates the phase file without the buddy line.
_ptg_spine() {
  [ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_INTENT_SPINE:=off}"
  if [ "${SB_INTENT_SPINE:-on}" != "off" ] && [ -n "$SESSION_ID" ]; then
    _SPINE_SID="${SESSION_ID//[^A-Za-z0-9_-]/}"; _SPINE_SID="${_SPINE_SID:0:64}"
    _SPINE_PHF="$BRAIN_DIR/.injected/$_SPINE_SID.phase"
    if [ -n "$_SPINE_SID" ] && [ -f "$_SPINE_PHF" ]; then
      _SPINE_CUR=""
      IFS= read -r _SPINE_CUR < "$_SPINE_PHF" 2>/dev/null || true
      case "$TOOL" in
        Write|Edit|MultiEdit|NotebookEdit)
          [ "$_SPINE_CUR" = "verify" ] && { printf 'implement' > "$_SPINE_PHF" 2>/dev/null || true
            command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$_SPINE_SID" phase focused "Back to implement — an edit landed after verification; re-run the checks before done." persona-tool-guard 600; } ;;
        Bash)
          # A command over 8192 characters is not evaluated (degrades toward no flip): the
          # here-string reads below must stay short — a 64 KiB one hangs on MSYS (see _fp_feed).
          # Below bash 4.3 (_fp_ob) the limit is 1024: the ${v//pat/rep} passes below cost
          # O(matches x length^2) there — 2.4 s for 8,185 ';' on bash 3.2 (F8 item 18 probe), 13 ms
          # at 1,000.
          _SPINE_MAX=8192; [ "$_fp_ob" = 1 ] && _SPINE_MAX=1024
          if [ "$_SPINE_CUR" = "implement" ] && [ -n "$CMD" ] && [ "${#CMD}" -le "$_SPINE_MAX" ]; then
            # Strip quoted content FIRST (split on the quote char; even-indexed
            # segments are outside quotes) so a separator inside a string literal —
            # a commit message saying "old; npm test" — never forms a span. Accepted
            # residuals (display-phase heuristics; both degrade toward NO-flip):
            # escaped quotes and `bash -c '…'`/`sh -c '…'` indirection are not
            # anchored into, and cross-nested odd-quote text (a lone `"` inside
            # '…') fails the parity guard below. Newlines fold to ';' beforehand so
            # multi-line commands keep span boundaries through the single-line read.
            # Quote-parity guard: a sentinel char is appended so a legitimate
            # closing quote at end-of-string still yields a trailing segment —
            # balanced quotes then always produce an ODD segment count. EVEN =
            # unterminated quote = invalid shell bash rejects without executing,
            # so the phase is never evaluated for it.
            _SPINE_TXT="${CMD//$'\n'/;} x"
            _SPINE_OK=1
            IFS='"' read -ra _SPINE_QSEG <<< "$_SPINE_TXT"
            [ $((${#_SPINE_QSEG[@]} % 2)) -eq 0 ] && _SPINE_OK=0
            _SPINE_TXT=""; _SPINE_I=0
            for _SPINE_SEG in ${_SPINE_QSEG[@]+"${_SPINE_QSEG[@]}"}; do
              [ $((_SPINE_I % 2)) -eq 0 ] && _SPINE_TXT="$_SPINE_TXT $_SPINE_SEG"
              _SPINE_I=$((_SPINE_I + 1))
            done
            IFS="'" read -ra _SPINE_QSEG <<< "$_SPINE_TXT"
            [ $((${#_SPINE_QSEG[@]} % 2)) -eq 0 ] && _SPINE_OK=0
            _SPINE_TXT=""; _SPINE_I=0
            for _SPINE_SEG in ${_SPINE_QSEG[@]+"${_SPINE_QSEG[@]}"}; do
              [ $((_SPINE_I % 2)) -eq 0 ] && _SPINE_TXT="$_SPINE_TXT $_SPINE_SEG"
              _SPINE_I=$((_SPINE_I + 1))
            done
            [ "$_SPINE_OK" = "1" ] || _SPINE_TXT=""   # parity failed — nothing to evaluate
            # Subshell/group/backtick punctuation becomes whitespace so it can
            # never glue to a token: `(npm test)` must anchor on npm.
            _SPINE_TXT="${_SPINE_TXT//\(/ }"; _SPINE_TXT="${_SPINE_TXT//\)/ }"
            _SPINE_TXT="${_SPINE_TXT//\{/ }"; _SPINE_TXT="${_SPINE_TXT//\}/ }"
            _SPINE_TXT="${_SPINE_TXT//\`/ }"
            # Split into spans on &&, single & (background), ;, |; per span, skip
            # leading env assignments (same span discipline as the verify gate's
            # anti-game scan) so only the command word anchors.
            _SPINE_SPANS="${_SPINE_TXT//&&/$'\n'}"
            _SPINE_SPANS="${_SPINE_SPANS//&/$'\n'}"
            _SPINE_SPANS="${_SPINE_SPANS//;/$'\n'}"
            _SPINE_SPANS="${_SPINE_SPANS//|/$'\n'}"
            while IFS= read -r _SPINE_SPAN; do
              [ -n "$_SPINE_SPAN" ] || continue
              set -f; set -- $_SPINE_SPAN; set +f
              while [ $# -gt 0 ]; do
                case "$1" in [A-Za-z_]*=*) shift ;; *) break ;; esac
              done
              [ $# -gt 0 ] || continue
              _T1="${1:-}"; _T2="${2:-}"; _T3="${3:-}"
              _SPINE_HIT=0
              case "$_T1" in
                vitest|jest|pytest|tsc|eslint) _SPINE_HIT=1 ;;
                npx) case "$_T2" in vitest|jest|pytest|tsc|eslint) _SPINE_HIT=1 ;; esac ;;
                npm) case "$_T2" in
                       test|t) _SPINE_HIT=1 ;;
                       run) case "$_T3" in test*) _SPINE_HIT=1 ;; esac ;;
                     esac ;;
                make) case "$_T2" in test*) _SPINE_HIT=1 ;; esac ;;
                go|cargo) [ "$_T2" = "test" ] && _SPINE_HIT=1 ;;
                bash|sh) case "$_T2" in *tests/test-*.sh|*run-all.sh) _SPINE_HIT=1 ;; esac ;;
                *tests/test-*|*run-all.sh) _SPINE_HIT=1 ;;
              esac
              if [ "$_SPINE_HIT" = "1" ]; then
                printf 'verify' > "$_SPINE_PHF" 2>/dev/null || true
                command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$_SPINE_SID" phase pleased "Verify phase — checks are running; the Stop gate will accept this as evidence." persona-tool-guard 600
                break
              fi
            done <<< "$_SPINE_SPANS"
          fi ;;
      esac
    fi
  fi
  return 0
}

# _ptg_abs PATH CWD: _PTG_ABS = PATH made absolute (against CWD; ~ and ~/… from HOME, spelled as a
# target is: _ptg_homes) with '.'/'..' folded lexically (D155: "$CWD/../../etc/shadow" must not
# prefix-match $CWD). The ~ arm is quoted (GC3/GX2a, R3B): an unquoted ~/* pattern is tilde-expanded
# itself, so a literal ~/.ssh/id_rsa went to $CWD/~/.ssh/id_rsa — in scope, no credential match. A
# drive path left in its X:/ form (cygpath failed, GS3) is absolute too.
_PTG_ABS=""
_ptg_abs() {
  case "$1" in
    /*|[A-Za-z]:/*) _PTG_ABS="$1" ;;
    "~"|"~/"*) _ptg_homes; _PTG_ABS="${_PTG_H[0]:-${HOME:-}}${1#"~"}" ;;
    *)   _PTG_ABS="$2/$1" ;;
  esac
  _fp_collapse _PTG_ABS "$_PTG_ABS"
}
# _ptg_scope PATH CWD ALLOW PROJECT: the resource-scope test, shared by the fast path and the full
# logic. _PTG_ABS as _ptg_abs; true when it lies inside an ALLOW prefix (newline-separated; $HOME,
# then $CWD, then $PROJECT substituted — HOME first, so a literal "$CWD" inside HOME is not
# expanded twice) or an SB_RESOURCE_SCOPE_EXTRA one (colon-separated, like PATH). PROJECT is the
# session's project root (CLAUDE_PROJECT_DIR, normalized like CWD): the payload's cwd follows the
# session's shell `cd`, so $CWD alone left the project's own worktrees out of scope once a session
# had cd'd into one of them (GW, R3). A prefix that comes out empty (no project root) is skipped:
# an empty prefix would put every absolute path in scope.
_ptg_scope() {
  local _ps_x _ps_pre
  _ptg_abs "$1" "$2"
  _ps_x="${SB_RESOURCE_SCOPE_EXTRA:-}"; _ps_x=${_ps_x//:/"$_fp_nl"}
  _fp_split "$_fp_nl" "$3$_fp_nl$_ps_x"
  for _ps_pre in ${_FP_A[@]+"${_FP_A[@]}"}; do
    # Quoted replacements (GC6): bash 5.2's patsub_replacement makes an unquoted '&' the matched text.
    _ps_pre=${_ps_pre//\$HOME/"$HOME"}
    _ps_pre=${_ps_pre//\$CWD/"$2"}
    _ps_pre=${_ps_pre//\$PROJECT/"${4:-}"}
    # A trailing separator is no part of the root (GT9, R3B): C:\w\repo\ and a drive root C:\ came
    # out /c/w/repo/ and /c/, which no target matched as "<root>/…".
    case "$_ps_pre" in ?*/) _ps_pre="${_ps_pre%/}" ;; esac
    [ -n "$_ps_pre" ] || continue
    case "$_PTG_ABS" in "$_ps_pre"|"$_ps_pre"/*) return 0 ;; esac
  done
  return 1
}
_ptg_scope_reason() {  # _ptg_scope_reason ABS -> _PTG_SR, the out-of-scope ask's one reason text
  _PTG_SR="Path '$1' is outside the project resource scope. HarnessAudit shows agents most often violate boundaries by applying reasonable tools to unauthorized resources. Confirm intent or extend scope via SB_RESOURCE_SCOPE_EXTRA."
}
# _ptg_proj VAR: VAR = CLAUDE_PROJECT_DIR as a scope prefix — CRs dropped, one trailing '/' cut
# (a root of '/' stays '/'); the caller normalizes it as it does CWD.
_ptg_proj() {
  local _pp_p
  _fp_nocr _pp_p "${CLAUDE_PROJECT_DIR:-}"
  case "$_pp_p" in ?*/) _pp_p="${_pp_p%/}" ;; esac
  printf -v "$1" '%s' "$_pp_p"
}

# Credential stores (G1, R3): a Read of one asks, on the fast path and in the full logic alike,
# whatever the resource scope says — a session started in HOME has ~/.ssh in scope, and
# SB_RESOURCE_SCOPE=off drops the scope ask altogether. The list is symlink-guard's (the guard
# that guards writes into these; tests/test-persona-tool-guard.sh locks the lists together, tiers
# included): tier:label:path entries under HOME (and USERPROFILE: _ptg_homes), then under APPDATA
# (Windows: gh keeps its tokens in %APPDATA%\GitHub CLI\hosts.yml, gcloud its in %APPDATA%\gcloud).
# The tier is symlink-guard's Write verdict (P-C2: deny for the stores denied at 407fa24, ask for those
# 0.56.0 added); a Read of either tier asks here. Each entry is the path itself or anything inside
# it — a file has nothing inside, and ~/.claude is no entry (plans/, projects/ and settings.json live
# there). GX6 (R3B) added gcloud, azure, .git-credentials, .npmrc, .docker/config.json, .kube/config,
# .pypirc and the APPDATA list; P-S8 _netrc, .config/git/credentials, .pgpass, .vault-token, cargo's,
# terraform's and RubyGems' tokens. symlink-guard's /etc arm is not mirrored:
# /etc is outside every default scope root already (an out-of-scope ask), and reading /etc/hosts or
# /etc/os-release is routine — a project kept under /etc would ask on every Read. Case-insensitive
# (nocasematch), as there: NTFS and default APFS are, and on Linux it only widens toward an ask.
_PTG_CRED_H=(deny:ssh:.ssh deny:gnupg:.gnupg deny:aws:.aws deny:claude-config:.config/claude deny:gh-config:.config/gh deny:passwordstore:.password-store deny:netrc:.netrc deny:claude-oauth:.claude/.credentials.json ask:gcloud:.config/gcloud ask:azure:.azure ask:git-credentials:.git-credentials ask:npmrc:.npmrc ask:docker-config:.docker/config.json ask:kube-config:.kube/config ask:pypirc:.pypirc ask:netrc:_netrc ask:git-credentials:.config/git/credentials ask:pgpass:.pgpass ask:vault-token:.vault-token ask:cargo-credentials:.cargo/credentials ask:cargo-credentials:.cargo/credentials.toml ask:terraform-credentials:.terraform.d/credentials.tfrc.json ask:gem-credentials:.gem/credentials)
_PTG_CRED_A=('ask:gh-hosts:GitHub CLI/hosts.yml' ask:gcloud:gcloud)
# _ptg_clabel ENTRY: _PTG_CL = ENTRY's label (tier:label:path).
_ptg_clabel() { local _pk_r="${1#*:}"; _PTG_CL="${_pk_r%%:*}"; }
# _ptg_homes: _PTG_H = the directories _PTG_CRED_H is spelled under, _PTG_HA those _PTG_CRED_A is,
# each as _ptg_fpath spells a target (lexically, a drive form as /x/…: the full logic's cygpath spelling
# of a drive path that sits under no MSYS mount — see _ptg_mnt), without repeats: HOME, then USERPROFILE
# (GX6, R3B: with HOME pointed elsewhere, the native tools keep ~/.ssh and ~/.claude/.credentials.json
# under the Windows profile still), and APPDATA; each also in its physical spelling (a junction or a
# symlinked profile; GT10, R3B — builtin cd -P, cwd restored, no subshell: symlink-guard's
# _sg_homes). Once per run.
_PTG_H=() _PTG_HA=() _PTG_H_RD=0
_ptg_homes() {
  local _ph_v _ph_s _ph_o="$PWD"
  [ "$_PTG_H_RD" = 1 ] && return 0
  _PTG_H_RD=1 _PTG_H=() _PTG_HA=()
  for _ph_v in HOME USERPROFILE APPDATA; do
    _ph_s="${!_ph_v:-}"
    [ -n "$_ph_s" ] || continue
    _ptg_hadd "$_ph_v" "$_ph_s"
    # P-C6: no physical spelling for a UNC value (//… or \\…): `cd -P` into an unreachable share
    # blocks (~2.7 s per share on Windows, longer for a host that never answers) — past the hook
    # budget with two of them, and the call ran.
    case "$_ph_s" in //*|"$_fp_bs$_fp_bs"*) continue ;; esac
    if CDPATH= cd -P -- "$_ph_s" 2>/dev/null; then _ptg_hadd "$_ph_v" "$PWD"; cd -- "$_ph_o" 2>/dev/null; fi
  done
  return 0
}
_ptg_hadd() {  # _ptg_hadd VAR DIR: DIR spelled as a target, appended to _PTG_H (_PTG_HA for APPDATA) unless there
  local _pa_h _pa_x
  _ptg_fpath _pa_h "$2"; _pa_h="${_pa_h%/}"
  [ -n "$_pa_h" ] || return 0
  if [ "$1" = APPDATA ]; then
    for _pa_x in ${_PTG_HA[@]+"${_PTG_HA[@]}"}; do [ "$_pa_x" = "$_pa_h" ] && return 0; done
    _PTG_HA[${#_PTG_HA[@]}]="$_pa_h"
  else
    for _pa_x in ${_PTG_H[@]+"${_PTG_H[@]}"}; do [ "$_pa_x" = "$_pa_h" ] && return 0; done
    _PTG_H[${#_PTG_H[@]}]="$_pa_h"
  fi
}
# _ptg_cred ABS: _PTG_CL = the credential store ABS is (or is inside), under any _PTG_H / _PTG_HA
# spelling; false when none.
_PTG_CL=""
_ptg_cred() {
  local _pc_h _pc_e _pc_p _pc_o=0
  _PTG_CL=""
  _ptg_homes
  shopt -q nocasematch && _pc_o=1
  shopt -s nocasematch
  for _pc_h in ${_PTG_H[@]+"${_PTG_H[@]}"}; do
    for _pc_e in "${_PTG_CRED_H[@]}"; do
      _pc_p="$_pc_h/${_pc_e#*:*:}"
      case "$1" in "$_pc_p"|"$_pc_p"/*) _ptg_clabel "$_pc_e"; break 2 ;; esac
    done
  done
  if [ -z "$_PTG_CL" ]; then
    for _pc_h in ${_PTG_HA[@]+"${_PTG_HA[@]}"}; do
      for _pc_e in "${_PTG_CRED_A[@]}"; do
        _pc_p="$_pc_h/${_pc_e#*:*:}"
        case "$1" in "$_pc_p"|"$_pc_p"/*) _ptg_clabel "$_pc_e"; break 2 ;; esac
      done
    done
  fi
  [ "$_pc_o" = 1 ] || shopt -u nocasematch
  [ -n "$_PTG_CL" ]
}
_ptg_cred_reason() {  # _ptg_cred_reason ABS LABEL -> _PTG_SR, the credential Read ask's reason text
  _PTG_SR="Read of '$1' opens a credential store ($2). Reading a secret is the first step of credential exfiltration, the classic goal of a prompt injection. Confirm intent."
}
_ptg_alias_reason() {  # _ptg_alias_reason PATH WHAT -> _PTG_SR: a Read no store can be compared with
  _PTG_SR="Read of '$1' uses $2, a Windows spelling persona-tool-guard cannot compare with the credential stores (~/.ssh, ~/.aws, ~/.netrc, …), so it may open one. Confirm intent."
}
# _ptg_w32 VAR PATH: PATH with each component's trailing dots and spaces dropped, as Win32 opens it:
# .ssh.\id_rsa and ".ssh \id_rsa" are .ssh\id_rsa (GS2, R3B). '.', '..' and all-dot names stay. The
# trailing run is measured by one shortest-suffix cut per component, not a loop per character.
_ptg_w32() {
  local _pw_s _pw_t IFS=/
  local -a _pw_a=()
  case "$2/" in *[.\ ]/*) ;; *) printf -v "$1" '%s' "$2"; return 0 ;; esac
  _fp_split / "$2"
  for _pw_s in ${_FP_A[@]+"${_FP_A[@]}"}; do
    case "$_pw_s" in
      .|..) ;;
      *[.\ ]) _pw_t="${_pw_s%[!.\ ]*}"; _pw_s="${_pw_s:0:${#_pw_t}+1}" ;;
    esac
    _pw_a[${#_pw_a[@]}]="$_pw_s"
  done
  printf -v "$1" '%s' "${_pw_a[*]-}"
}
# _ptg_credread NORM ABS: the credential-store check of a Read (G1; GS2/GC2/GX2, R3B), shared by the
# fast path and the full logic. NORM is the target as normalized (_fp_path: \\?\UNC\localhost\C$\…
# and \\localhost\c$\… are the drive), ABS as _ptg_abs made it absolute. 0 = ask: _PTG_CRR (rule),
# _PTG_CRT (target), _PTG_SR (reason). 1 = no credential store. 2 = an 8.3 short-name component (SSH~1
# is .ssh) the lexical match cannot read: the fast path stands down, the full logic asks test -ef
# (_ptg_inode). On a Windows host, before the match: a target still spelled //… (a UNC share — another
# machine's, or this one's under its own name — or a \\?\ device path naming no drive: Volume{…},
# GLOBALROOT) or holding a ':' past its drive (NTFS stream syntax: .netrc::$DATA is .netrc,
# .ssh::$INDEX_ALLOCATION the directory) cannot be compared with any store and asks
# (windows-alias:unc, windows-alias:stream); every component is matched as Win32 opens it (_ptg_w32).
# Elsewhere ':' is a file-name character, // is /, and there are no 8.3 names.
_PTG_CRR="" _PTG_CRT=""
_ptg_credread() {
  local _pr_t _pr_a="$2" _pr_w=0
  _PTG_CRR="" _PTG_CRT=""
  if _ptg_win; then
    _pr_w=1
    case "$1" in
      //*) _PTG_CRR=windows-alias:unc _PTG_CRT="$1"; _ptg_alias_reason "$1" "a UNC or device path"; return 0 ;;
    esac
    case "$1" in [A-Za-z]:*) _pr_t="${1:2}" ;; *) _pr_t="$1" ;; esac
    case "$_pr_t" in
      *:*) _PTG_CRR=windows-alias:stream _PTG_CRT="$1"; _ptg_alias_reason "$1" "NTFS stream syntax (a ':' past the drive)"; return 0 ;;
    esac
    _ptg_w32 _pr_a "$2"
  fi
  if _ptg_cred "$_pr_a"; then
    _PTG_CRR=credential-read _PTG_CRT="$2"; _ptg_cred_reason "$2" "$_PTG_CL"; return 0
  fi
  if [ "$_pr_w" = 1 ]; then
    case "$_pr_a" in *~[0-9]*) return 2 ;; esac
  fi
  return 1
}
# _ptg_inode ABS: _PTG_CL = the credential store ABS is, or lies in, by identity (test -ef: device and
# inode) rather than by spelling — for a target with an 8.3 short-name component, which no lexical
# match reads (GC2/GX2c, R3B; symlink-guard's _sg_inode). ABS and each existing ancestor is compared
# with every store under every _PTG_H spelling: builtins only. 1 = none; _PTG_INO=proven when ABS
# itself exists (its identity was compared), else unknown (nothing on disk answered for it).
_PTG_INO=""
_ptg_inode() {
  local _pi_p="$1" _pi_h _pi_e _pi_n=0
  _PTG_CL="" _PTG_INO=unknown
  _ptg_homes
  [ -e "$1" ] && _PTG_INO=proven
  while [ "$_pi_n" -lt 128 ]; do
    if [ -e "$_pi_p" ]; then
      for _pi_h in ${_PTG_H[@]+"${_PTG_H[@]}"}; do
        for _pi_e in "${_PTG_CRED_H[@]}"; do
          [ "$_pi_p" -ef "$_pi_h/${_pi_e#*:*:}" ] && { _ptg_clabel "$_pi_e"; return 0; }
        done
      done
      for _pi_h in ${_PTG_HA[@]+"${_PTG_HA[@]}"}; do
        for _pi_e in "${_PTG_CRED_A[@]}"; do
          [ "$_pi_p" -ef "$_pi_h/${_pi_e#*:*:}" ] && { _ptg_clabel "$_pi_e"; return 0; }
        done
      done
    fi
    case "$_pi_p" in /*/*) _pi_p="${_pi_p%/*}" ;; *) break ;; esac
    _pi_n=$((_pi_n + 1))
  done
  return 1
}

# _ptg_linked ABS: true when ABS or one of its ancestors is a symbolic link or a junction ([ -L ]:
# builtins, at most 128 steps). P-S2: the credential match reads spellings, and a link inside the
# project into a store (proj/sshlink -> ~/.ssh) spells none — such a target goes to _ptg_inode, which
# compares it and its existing ancestors with the stores by identity. A //… target (UNC: a stat
# there can block for seconds) is never walked.
_ptg_linked() {
  local _pz_p="$1" _pz_n=0
  case "$_pz_p" in //*) return 1 ;; esac
  while [ "$_pz_n" -lt 128 ]; do
    [ -L "$_pz_p" ] && return 0
    case "$_pz_p" in /*/*) _pz_p="${_pz_p%/*}" ;; *) return 1 ;; esac
    _pz_n=$((_pz_n + 1))
  done
  return 1
}

# _ptg_mnt PATH: true when the drive path PATH (X:/…, '/'-separated) may not be spelled /x/… by
# cygpath -u — it lies under an MSYS/Cygwin mount other than its drive's own /x one (Git-Bash
# mounts %TEMP% at /tmp and its install dir at /), or the mount table cannot be read. The full logic
# spells such a path by the mount's name (C:/Users/me/AppData/Local/Temp/x is /tmp/x, in scope), the
# fast path only lexically, so it must not decide one. Builtins only: /proc/mounts is read once
# per call (MSYS emulates it in-process, no fork). Its lines are "SOURCE MOUNTPOINT TYPE OPTS N N"
# with spaces kept raw in SOURCE ("C:/Program Files/Git /"), so the line is cut from the right; a
# \040-escaped space is unescaped as well. Matched case-insensitively (a posix=0 mount is): wider
# only toward "undecidable".
_PTG_MNT="" _PTG_MNT_RD=0
_ptg_mnt() {
  local _pm_l _pm_r _pm_s _pm_m _pm_d _pm_o=0 _pm_hit=1
  if [ "$_PTG_MNT_RD" = 0 ]; then
    _PTG_MNT_RD=1
    [ -r /proc/mounts ] && IFS= read -r -d '' _PTG_MNT < /proc/mounts
  fi
  [ -n "$_PTG_MNT" ] || return 0
  _fp_split "$_fp_nl" "$_PTG_MNT"
  shopt -q nocasematch && _pm_o=1
  shopt -s nocasematch
  for _pm_l in ${_FP_A[@]+"${_FP_A[@]}"}; do
    _pm_r="${_pm_l% * * * *}"
    [ "$_pm_r" != "$_pm_l" ] || continue
    _pm_m="${_pm_r##* }" _pm_s="${_pm_r% *}"
    _pm_s=${_pm_s//\\040/ }
    case "$_pm_s" in
      [A-Za-z]:) _fp_lower _pm_d "${_pm_s:0:1}"; [ "$_pm_m" = "/$_pm_d" ] && continue ;;
      [A-Za-z]:/*) ;;
      *) continue ;;
    esac
    _pm_s="${_pm_s%/}"
    case "$1" in "$_pm_s"|"$_pm_s"/*) _pm_hit=0; break ;; esac
  done
  [ "$_pm_o" = 1 ] || shopt -u nocasematch
  return "$_pm_hit"
}
# _ptg_fpath VAR PATH: VAR = PATH as `_fp_path … lex` spells it (the lexical steps, then a drive path
# X:/… as /x/… on a Windows host), in one pass. 1 when cygpath -u may spell that drive path
# otherwise (_ptg_mnt), so the full logic's spelling of it is unknown here. A path past 4096
# characters is not looked up: the full logic keeps its lexical spelling too (_ptg_norm, G3).
# The Windows-host test is _fp_path's (_ptg_win).
# _ptg_win: true on a Windows host (MSYS/Cygwin bash, or cygpath on PATH) — asked once per run and
# OSTYPE first: `command -v` searches PATH on every call, ~30 ms each over a long Windows PATH on a
# loaded MSYS box.
_PTG_WIN=""
_ptg_win() {
  if [ -z "$_PTG_WIN" ]; then
    _PTG_WIN=0
    if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || command -v cygpath >/dev/null 2>&1; then _PTG_WIN=1; fi
  fi
  [ "$_PTG_WIN" = 1 ]
}
_ptg_fpath() {
  local _pf_p _pf_d _pf_r=0
  _fp_path _pf_p "$2"
  case "$_pf_p" in
    [A-Za-z]:/*)
      if _ptg_win; then
        # The bound is _ptg_norm's: the length before the lexical steps.
        [ "${#2}" -le 4096 ] && _ptg_mnt "$_pf_p" && _pf_r=1
        _fp_lower _pf_d "${_pf_p:0:1}"; _pf_p="/$_pf_d${_pf_p:2}"
      fi ;;
  esac
  printf -v "$1" '%s' "$_pf_p"
  return "$_pf_r"
}
# _ptg_long_reason TOOL PATH -> _PTG_SR: the path-too-long ask's reason (G3, shared by both paths).
_ptg_long_reason() {
  local _pl_p
  _fp_cap _pl_p "$2" 256
  _PTG_SR="$1 target '$_pl_p' is ${#2} characters long. Past 4096, persona-tool-guard matches it in its lexical spelling only (a longer path cannot be safely normalized inside the hook's time budget — on Windows cygpath truncates it), so it asks rather than pass it unchecked. Confirm the target."
}

# --- B7 fast path: the plugin's LOCKED rules, decided before lib.sh / jq ----------------------
# Certain only while the effective rules can be nothing but the shipped defaults: the default file
# is present and no user layer (persona-rules.json) or repo layer (projects/<slug>/rules.json) can
# move a verdict this table decides (_ptg_layer_ok). Then each rule below is in force at exactly
# its shipped action (ask), and the full logic would reach the same verdict —
# tests/test-persona-tool-guard.sh runs both paths over one corpus and requires the same verdict,
# reason and rule, and pins this table to the default's locked rules. Patterns mirror
# persona-rules.default.json as the full logic applies them: case-insensitively (grep -i: the path
# lowercased, [Xx] classes on the command), \b as a [^[:alnum:]_] boundary, command rules line by
# line (grep's unit), in the default file's order (the full logic keeps the first ask it meets).
_PTG_RE_PUSH='[Gg][Ii][Tt] [Pp][Uu][Ss][Hh].*(--[Ff][Oo][Rr][Cc][Ee]|-[Ff])[^[:alnum:]_](.*[^[:alnum:]_])?([Mm][Aa][Ii][Nn]|[Mm][Aa][Ss][Tt][Ee][Rr])([^[:alnum:]_]|$)'
_PTG_RE_RMRF='(^|[^[:alnum:]_])[Rr][Mm][[:space:]]+(-[a-zA-Z]*[Rr][a-zA-Z]*[Ff][a-zA-Z]*|-[a-zA-Z]*[Ff][a-zA-Z]*[Rr][a-zA-Z]*)([^[:alnum:]_]|$)'
_PTG_RE_HOT='(user\.md|project\.md|persona-card\.md|persona-rules\.json|plugin\.json)$'
_PTG_RE_SCRIPTS='/(claude-code-plugin|second-brain)/([^/]+/)?(scripts|hooks)/[^/]+\.(sh|json)$'
_PTG_RE_PRULES='persona-rules(\.default)?\.json$'
_PTG_RE_RRULES='/projects/[^/]+/rules(\.pending)?\.json$'
_PTG_RE_CACHE='/\.rules-effective\.json$'
_PTG_RE_INJ='/\.second-brain/\.injected/'
# The default's resource_scope (enabled; Write/Edit/MultiEdit/Read among its tools), pinned by the test.
_PTG_RS_ALLOW=$'$CWD\n$PROJECT\n$HOME/.second-brain\n$HOME/knowledge\n/tmp\n/var/tmp'
_PTG_RULE="" _PTG_REASON="" _PTG_SFX=""
_ptg_set() { [ -n "$_PTG_RULE" ] || { _PTG_RULE="$1$_PTG_SFX"; _PTG_REASON="$2"; }; }
# _ptg_cache_ok CACHE: false when an effective-rules cache was written after its signature (or has
# none). lib.sh writes the cache, then its .sig; a cache newer than that is a hand edit, and the
# full logic must see it on THIS call — it re-verifies the lock invariant, logs, and rebuilds.
_ptg_cache_ok() { [ ! -e "$1" ] || { [ -e "$1.sig" ] && ! [ "$1" -nt "$1.sig" ]; }; }
# _ptg_layer_ok LAYER user|repo (SEC-M3, RR-RL1): true when an existing layer cannot move a
# verdict this table decides. A rule needs no "tool"/scope key to do that: lib.sh's merge lets a
# HIGHER layer raise a LOCKED rule's action by "name" alone (a repo layer's bare
# {"name":"warn-rm-rf","action":"deny"} overrides the shipped ask) — RR-RL1 found this table
# answering ask while the full logic denied, and the override going unlogged, because the old
# comment here claimed a re-declared rule needed "tool" or a scope block, which is false. So any
# quoted "name" key stands the fast path down too: learned advisories (merge-persona-signals.sh
# arms warn-only .learned[] entries after 3 sightings, seeding a repo layer as
# {"schema":2,"rules":[],"learned":[]}) carry only event/pattern/action/message, never "name" — a
# literal quoted "name" cannot occur unescaped inside a JSON string, so this never misfires on an
# advisory. Stand down, too, where the full logic has something to log (D154): a layer that is not
# one whole {…} object, or a user layer with nothing to evaluate (no learned entry: no "event"). A
# \u escape (a key spelled around this test), a NUL, over 256 KiB, or an unreadable file: stand down.
_ptg_layer_ok() {
  local _pl_t=""
  [ -f "$1" ] && [ -r "$1" ] || return 1
  IFS= read -r -d '' -n 262144 _pl_t < "$1" && return 1
  case "$_pl_t" in '{'*'}'|'{'*'}'"$_fp_nl"|'{'*'}'"$_fp_cr$_fp_nl") ;; *) return 1 ;; esac
  case "$_pl_t" in *'"tool"'*|*_scope*|*'"name"'*|*"$_fp_bs"u*) return 1 ;; esac
  [ "$2" = repo ] && return 0
  case "$_pl_t" in *'"event"'*) return 0 ;; esac
  return 1
}
_ptg_fast() {
  local tool sid="" cmd="" path="" lc root me pf a="" b="" bd f slug="" rc cwd tgt proj amb=0 plen=0 cr=0
  _fp_str tool_name || return 1
  tool="$_FP"
  # Read (G1): no rule in the default names it, but resource_scope covers it and a credential store
  # asks — both decided below, without the locked-rule table.
  case "$tool" in Bash|Write|Edit|MultiEdit|Read) ;; *) return 1 ;; esac
  # P must be the default this table mirrors — the one beside this script: CLAUDE_PLUGIN_ROOT's copy
  # is that same file, or byte-identical to it. A different P (another plugin version, an edited
  # default) goes to the full logic, which reads whatever P actually says.
  me="${0%/*}"; [ "$me" = "$0" ] && me=.
  root="${CLAUDE_PLUGIN_ROOT:-$me/..}"
  pf="$root/scripts/persona-rules.default.json"
  [ -f "$pf" ] && [ -f "$me/persona-rules.default.json" ] || return 1
  if ! [ "$pf" -ef "$me/persona-rules.default.json" ]; then
    IFS= read -r -d '' a < "$pf"; IFS= read -r -d '' b < "$me/persona-rules.default.json"
    [ "$a" = "$b" ] || return 1
  fi
  bd="${BRAIN_DIR:-$HOME/.second-brain}"; bd=${bd//"$_fp_bs"/"/"}
  # SB_RULES_LAYERS=off: a user file REPLACES the defaults (no lock carries over) — stand down.
  if [ -e "$bd/persona-rules.json" ]; then
    [ "${SB_RULES_LAYERS:-on}" != off ] && _ptg_layer_ok "$bd/persona-rules.json" user || return 1
  fi
  _fp_str session_id && sid="$_FP"
  f="${sid//[^A-Za-z0-9_-]/}"; f="${f:0:64}"
  if [ -n "$f" ] && [ -f "$bd/.injected/$f.slug" ]; then
    IFS= read -r slug < "$bd/.injected/$f.slug"; slug="${slug//"$_fp_cr"/}"
  fi
  if [ -n "$slug" ]; then
    case "$slug" in
      .|..|*[!A-Za-z0-9._-]*) _ptg_cache_ok "$bd/.rules-effective.json" || return 1 ;;
      *) if [ -e "$bd/projects/$slug/rules.json" ]; then _ptg_layer_ok "$bd/projects/$slug/rules.json" repo || return 1; fi
         _ptg_cache_ok "$bd/projects/$slug/.rules-effective.json" || return 1 ;;
    esac
  else
    for f in "$bd"/projects/*/rules.json; do [ -e "$f" ] || continue; _ptg_layer_ok "$f" repo || return 1; done
    for f in "$bd"/projects/*/.rules-effective.json "$bd/.rules-effective.json"; do _ptg_cache_ok "$f" || return 1; done
  fi
  _PTG_RULE="" _PTG_REASON="" _PTG_SFX=""
  if [ "$tool" = Bash ]; then
    _fp_str command || return 1
    _fp_nocr cmd "$_FP"
    _fp_trimnl cmd "$cmd"
    [ -n "$cmd" ] || return 1
    # Over 64 lines (_fp_lines 2): the full logic's one grep decides.
    _fp_lines "$_PTG_RE_PUSH" "$cmd"; rc=$?; [ "$rc" = 2 ] && return 1
    [ "$rc" = 0 ] && _ptg_set warn-force-push-main "Force-push to main/master is destructive. Confirm intent."
    _fp_lines "$_PTG_RE_RMRF" "$cmd"; rc=$?; [ "$rc" = 2 ] && return 1
    [ "$rc" = 0 ] && _ptg_set warn-rm-rf "rm -rf is destructive and irreversible. Confirm target before proceeding."
  else
    _fp_str file_path || return 1
    _fp_nocr path "$_FP"
    case "$path" in ''|*"$_fp_nl"*) return 1 ;; esac
    plen=${#path}
    # The payload cwd before the target is spelled: a root-relative target goes on its drive (P-S1,
    # _fp_rroot); one that cannot be placed is the full logic's (it asks).
    _fp_str cwd; rc=$?; [ "$rc" = 2 ] && return 1
    _fp_nocr cwd "$_FP"
    _fp_trimnl cwd "$cwd"
    case "$cwd" in *"$_fp_nl"*) return 1 ;; esac
    _fp_rroot path "$path" "$cwd" || return 1
    _ptg_fpath path "$path" || amb=1
    if [ "$tool" != Read ]; then
      _fp_lower lc "$path"
      case "$tool" in Edit) _PTG_SFX=-edit ;; MultiEdit) _PTG_SFX=-multiedit ;; esac
      if [ "$tool" = Write ] && [[ $lc =~ $_PTG_RE_HOT ]]; then
        _ptg_set warn-direct-write-hot-tier "Direct Write to hot-tier files bypasses pin tools' dedupe and size caps. Prefer pin_to_user / pin_to_project MCP tools."
      fi
      [[ $lc =~ $_PTG_RE_SCRIPTS ]] && _ptg_set warn-self-edit-plugin-scripts "Editing a plugin hook script or hooks.json modifies the safety layer itself. Confirm intent — this is the kind of change an injection attack would try to make."
      [[ $lc =~ $_PTG_RE_PRULES ]] && _ptg_set warn-self-edit-persona-rules "persona-rules.json controls every PreToolUse guard decision. Confirm intent — disabling rules silently is the classic prompt-injection escalation path."
      [[ $lc =~ $_PTG_RE_RRULES ]] && _ptg_set warn-self-edit-repo-rules "projects/<key>/rules.json is the repo layer of the PreToolUse guard — confirm intent; use /second-brain:rules promote|demote"
      [[ $lc =~ $_PTG_RE_CACHE ]] && _ptg_set warn-self-edit-rules-cache "The effective-rules cache is derived from the rule layers — edit the layer (persona-rules.json or projects/<key>/rules.json), never the cache."
      [[ $lc =~ $_PTG_RE_INJ ]] && _ptg_set warn-self-edit-injected "~/.second-brain/.injected/ holds the per-session caches the hooks inject into every session and subagent (role cards, slug memos). A direct write there is hook-authority injection — confirm intent."
    fi
  fi
  tgt="${path:-${cmd:0:200}}"
  # File tools, in the full logic's order (G1): with no rule hit, the asks below are this call's only
  # possible verdicts under the default rules, so they are decided here too — before, a Read and any
  # file call no locked rule matched went to the full logic (3.7 s median for a Read of another
  # user's ~/.ssh on a loaded MSYS box, cancelled at 5 s and the file read). What neither path asks
  # about (in scope, no rule) still goes to the full logic: this path never allows.
  # - Past 4096 characters (G3): no scope test or credential test — the rule's ask, else
  #   path-too-long's.
  # - A Read of a credential store asks (_ptg_cred), whatever the scope says.
  # - L3: an out-of-scope target asks before any rule does (resource_scope), with the full logic's
  #   test. Targets are spelled as the full logic spells them — except a drive path cygpath would
  #   respell under an MSYS mount (amb, _ptg_mnt): with a rule hit the call asks all the same (the
  #   reason may name the scope where the full logic names the rule); without one this path stands
  #   down rather than risk a false ask.
  if [ "$tool" != Bash ]; then
    # The full logic's _PTG_LONG: the length before the lexical steps (a \\?\ prefix counts).
    if [ "$plen" -gt 4096 ]; then
      if [ -z "$_PTG_RULE" ]; then
        _ptg_long_reason "$tool" "$path"
        _PTG_RULE=path-too-long _PTG_REASON="$_PTG_SR"
      fi
    else
      [ -n "$cwd" ] || cwd="$PWD"
      _ptg_fpath cwd "$cwd" || amb=1
      _ptg_proj proj
      case "$proj" in *"$_fp_nl"*) return 1 ;; esac
      [ -z "$proj" ] || _ptg_fpath proj "$proj" || amb=1
      if [ "$tool" = Read ]; then
        [ "$amb" = 0 ] || return 1
        _ptg_abs "$path" "$cwd"
        # An 8.3 short name (2) takes test -ef: the full logic's. So does a target reached through a
        # link (P-S2: _ptg_linked) that no store's spelling names.
        _ptg_credread "$path" "$_PTG_ABS"; rc=$?
        [ "$rc" = 2 ] && return 1
        [ "$rc" = 1 ] && _ptg_linked "$_PTG_ABS" && return 1
        [ "$rc" = 0 ] && { _PTG_RULE="$_PTG_CRR" _PTG_REASON="$_PTG_SR" tgt="$_PTG_CRT"; cr=1; }
      fi
      if [ "$cr" = 0 ] && [ "${SB_RESOURCE_SCOPE:-on}" != off ] \
         && ! _ptg_scope "$path" "$cwd" "$_PTG_RS_ALLOW" "$proj"; then
        [ "$amb" = 0 ] || [ -n "$_PTG_RULE" ] || return 1
        _ptg_scope_reason "$_PTG_ABS"
        _PTG_RULE=resource-scope-out-of-scope _PTG_REASON="$_PTG_SR" tgt="$_PTG_ABS"
      fi
    fi
  fi
  [ -n "$_PTG_RULE" ] || return 1
  local TOOL="$tool" CMD="$cmd" SESSION_ID="$sid" BRAIN_DIR="$bd"
  _ptg_spine
  _fp_emit ask "$_PTG_REASON"
  _fp_audit persona-tool-guard.sh ask "$_PTG_RULE" "$tgt" "$_PTG_REASON" "$sid"
  return 0
}
_ptg_fast && exit 0

# --- Full logic (the fast path could not decide) -----------------------------------------------
_fp_raw_all
[ -z "$RAW" ] && exit 0

# The five payload fields: builtin decode (_fp_str) when every one is decidable — a Claude Code
# payload always is — else ONE jq, NUL-framed so a multi-line value cannot shift the others (the
# 0.33.38 form spent two spawns and read four fields as lines). Line-per-field -r was chosen
# over @tsv because @tsv backslash-escapes values (Windows file_path backslashes); NUL framing
# needs no unescaping either. Garbage stdin → jq fails → TOOL empty → exit 0 (fail-soft).
# CRs are dropped and trailing newlines trimmed, as the old `jq -r … | tr -d '\r'` + $(…)/read did.
TOOL="" SESSION_ID="" CWD="" PATH_INPUT="" CMD=""
# _ptg_rawcred: jq missing and a payload the builtins cannot decode (P-F1/P-C1: on bash < 4.3,
# _fp_ob, that is every payload; on bash 5 a duplicated key, a \u escape, one past 64 KiB), so no
# field — no target — was read. The credential-store floor by spelling over the raw payload instead:
# a payload naming the tool Read that holds a store's path as a path — each '\' read as '/' (JSON's
# '\\' is then '//'), a separator before it, and after it a separator or a string's closing quote —
# asks; _PTG_CL = the store. Unanchored (the raw text has no single spelling of HOME), so a project's
# own .ssh directory asks too: the degraded mode's price. 1 = no Read, or no store. 2 = no store in a
# Read payload past 4096 characters: its target may be past path-too-long's bound, which cannot be
# measured without a decode, so it asks as path-too-long's floor would (a Read payload is a few
# hundred bytes); past 64 KiB it is not scanned at all. Builtins only.
_ptg_rawcred() {
  local _rw_t _rw_e _rw_p _rw_q _rw_o=0
  _PTG_CL=""
  case "$RAW" in *'"Read"'*) ;; *) return 1 ;; esac
  [ "${#RAW}" -le 65536 ] || return 2
  _fp_split "$_fp_bs" "$RAW"; _fp_joinsl _rw_t
  shopt -q nocasematch && _rw_o=1
  shopt -s nocasematch
  for _rw_e in "${_PTG_CRED_H[@]}" "${_PTG_CRED_A[@]}"; do
    _rw_p="${_rw_e#*:*:}"
    _fp_split / "$_rw_p"; printf -v _rw_q '%s//' ${_FP_A[@]+"${_FP_A[@]}"}; _rw_q="${_rw_q%//}"
    case "$_rw_t" in
      *"/$_rw_p/"*|*"/$_rw_p$_fp_q"*|*"/$_rw_q/"*|*"/$_rw_q$_fp_q"*) _ptg_clabel "$_rw_e"; break ;;
    esac
  done
  [ "$_rw_o" = 1 ] || shopt -u nocasematch
  [ -n "$_PTG_CL" ] && return 0
  [ "${#RAW}" -gt 4096 ] && return 2
  return 1
}
_ptg_fields() {
  local v rc
  for v in TOOL:tool_name SESSION_ID:session_id CWD:cwd PATH_INPUT:file_path CMD:command; do
    _fp_str "${v#*:}"; rc=$?
    [ "$rc" = 2 ] && return 1
    printf -v "${v%%:*}" '%s' "$_FP"
  done
  return 0
}
if ! _ptg_fields; then
  TOOL="" SESSION_ID="" CWD="" PATH_INPUT="" CMD="" _FP_JST=""
  # The command comes last and unframed, read whole by _fp_rest (buffered, not byte by byte); the
  # CRs go in the same stream (`tr`, one spawn) rather than by _fp_nocr, which cut a 150k-line
  # command from Windows jq (CRLF output) into 150k fields: ~0.4 s on MSYS (F8 item 20).
  {
    IFS= read -r -d '' _FP_JST; IFS= read -r -d '' TOOL; IFS= read -r -d '' SESSION_ID; IFS= read -r -d '' CWD
    IFS= read -r -d '' PATH_INPUT; _fp_rest CMD
  } < <(_fp_feed "$RAW" jq -j '(if ([.tool_name, .session_id, .cwd, .tool_input.file_path, .tool_input.command] | map(strings) | any(contains("\u0000"))) then "nul" else "ok" end), "\u0000", (.tool_name // ""), "\u0000", (.session_id // ""), "\u0000", (.cwd // ""), "\u0000",
               (.tool_input.file_path // ""), "\u0000", (.tool_input.command // "")' 2>/dev/null | tr -d '\r')
  _FP_RRC=$?
  [ "$_FP_RRC" -gt 1 ] && _FP_JST=nul   # a failed read of the last field: undecidable, like a NUL
  if [ "$_FP_JST" = nul ]; then
    _fp_audit "persona-tool-guard.sh" "ask" "nul-field" "$TOOL" "field holds a NUL character" "${SESSION_ID:-}" full
    _fp_emit ask "second-brain persona-tool-guard.sh cannot check this call: a field it reads holds a NUL character, which bash cannot represent. Confirm the call."
    exit 0
  fi
  if [ -z "$TOOL" ]; then
    case "$RAW" in *'"tool_name"'*)
      _fp_jqfail "persona-tool-guard.sh" "${#RAW}" && { _fp_emit ask "second-brain persona-tool-guard.sh could not read this call (jq failed on the payload; details in error-log.jsonl), so it cannot check it. Confirm the call."; exit 0; }
      # jq is missing, so no field was read (P-F1/P-C1): the credential-store floor by spelling.
      _ptg_rawcred; _ptg_rc=$?
      if [ "$_ptg_rc" != 1 ]; then
        if [ "$_ptg_rc" = 0 ]; then
          _ptg_rr=credential-read
          _PTG_SR="persona-tool-guard.sh cannot decode this Read call without jq (not on PATH), and its payload names a credential store ($_PTG_CL). Reading a secret is the first step of credential exfiltration, the classic goal of a prompt injection. Confirm intent."
        else
          _ptg_rr=path-too-long
          _PTG_SR="persona-tool-guard.sh cannot decode this Read call without jq (not on PATH), and its payload (${#RAW} characters) may hold a target past 4096 characters, which it cannot measure or match safely. Confirm the call."
        fi
        _fp_emit ask "$_PTG_SR"
        _fp_audit "persona-tool-guard.sh" "ask" "$_ptg_rr" "Read(undecoded)" "$_PTG_SR" "" full
        _fp_err "persona-tool-guard.sh" "jq is not on PATH: the undecoded Read call above was asked about after all ($_ptg_rr: its raw payload names a credential store, or is too long to measure)"
        exit 0
      fi ;;
    esac
  fi
fi
_fp_clean TOOL SESSION_ID CWD PATH_INPUT CMD
# The payload is not read again: freeing it (and the last split) keeps every later fork cheap — MSYS
# copies the whole heap per fork, ~0.25 s more over this path's forks with a 450 KB payload held.
RAW="" _FP_RAW="" _FP_A=()
[ -z "${TOOL:-}" ] && exit 0
_PTG_CWD0="$CWD"
[ -z "${CWD:-}" ] && CWD="$PWD"

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source lib.sh for sb_log_audit. Fail-soft: if the source fails, define a
# no-op so guard decisions still emit JSON to Claude (the guard's primary
# job) even when audit logging is unavailable.
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
  sb_log_error() { :; }
  sb_normalize_path() {
    # _fp_path's lexical steps (backslashes, the \\?\ and \\.\ prefixes, D182): linear, where the
    # ${1//\\//} and ${p#"//?/"} forms were O(n^2) on a long path (final review, 0.54.1).
    local p; _fp_path p "$1"
    case "$p" in [A-Za-z]:/*) command -v cygpath >/dev/null 2>&1 && p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p") ;; esac
    printf '%s' "$p"
  }
fi
# _ptg_norm_read: _ptg_norm's cygpath answers on stdin, one line per path, into its VARs in order
# (reads _ptg_norm's locals through bash's dynamic scope).
_ptg_norm_read() {
  while IFS= read -r _pn_p; do
    [ "$_pn_i" -lt ${#_pn_vars[@]} ] || break
    [ -n "$_pn_p" ] && printf -v "${_pn_vars[$_pn_i]}" '%s' "$_pn_p"
    _pn_i=$((_pn_i + 1))
  done
}
# _ptg_norm VAR…: sb_normalize_path for each VAR — its lexical steps as builtins (_fp_path mirrors
# lib.sh's canonical ones), then ONE cygpath -u for every drive-letter path among them. Each old
# $(sb_normalize_path …) paid a fork plus its own $(cygpath …): ~20 ms apiece on a quiet MSYS box,
# ~55 under load, twice per Edit. A value holding a newline keeps the one-call-per-path form.
# G3 (0.54.1 final review): a value past 4096 characters keeps its lexical spelling (/x/… for a
# drive path, as the fast path spells it) and reaches no cygpath, which truncates a path longer than
# 32,767 characters at its input while still exiting 0 (MSYS2, measured 2026-10-01) — the file name at
# the end of a 40,000-character path was gone before any rule saw it. The full logic asks about such a
# target at least.
_ptg_norm() {
  local _pn_v _pn_p _pn_out _pn_i=0 _pn_e=0
  local -a _pn_vars=() _pn_args=()
  for _pn_v in "$@"; do
    _pn_p="${!_pn_v}"
    if [ "${#_pn_p}" -gt 4096 ]; then _fp_path _pn_p "$_pn_p" lex; printf -v "$_pn_v" '%s' "$_pn_p"; continue; fi
    case "$_pn_p" in *"$_fp_nl"*) printf -v "$_pn_v" '%s' "$(sb_normalize_path "$_pn_p")"; continue ;; esac
    _fp_path _pn_p "$_pn_p"
    printf -v "$_pn_v" '%s' "$_pn_p"
    case "$_pn_p" in [A-Za-z]:/*) _pn_vars+=("$_pn_v"); _pn_args+=("$_pn_p") ;; esac
  done
  [ ${#_pn_args[@]} -gt 0 ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    _pn_out=$(cygpath -u ${_pn_args[@]+"${_pn_args[@]}"} 2>/dev/null) || _pn_out=""
    [ -n "$_pn_out" ] && _fp_feed "$_pn_out" _ptg_norm_read
    # A cygpath that answered fewer lines than it was given paths (failed, or takes one path):
    # the rest one call each, as sb_normalize_path would.
    while [ "$_pn_i" -lt ${#_pn_vars[@]} ]; do
      _pn_p=$(cygpath -u "${_pn_args[$_pn_i]}" 2>/dev/null) && [ -n "$_pn_p" ] && printf -v "${_pn_vars[$_pn_i]}" '%s' "$_pn_p"
      _pn_i=$((_pn_i + 1))
    done
  fi
  # GS3 (R3B): a value still in its drive form (cygpath failed, answered nothing, or is missing) is
  # spelled as the fast path spells it, /x/… — _ptg_abs took C:/… for a relative path: joined to the
  # cwd, in scope, no credential prefix matched, and nothing said so. Logged once per call.
  for _pn_v in ${_pn_vars[@]+"${_pn_vars[@]}"}; do
    case "${!_pn_v}" in
      [A-Za-z]:/*)
        _fp_path _pn_p "${!_pn_v}" lex; printf -v "$_pn_v" '%s' "$_pn_p"
        [ "$_pn_e" = 1 ] || { _pn_e=1; _fp_err "persona-tool-guard.sh" "cygpath -u left a drive path in its drive form (cygpath failed or is missing); matched it lexically as ${_pn_p:0:200}"; } ;;
    esac
  done
  return 0
}

# Windows git-bash sends 'C:\…' paths; the scope allowlist and self-edit regexes
# are all forward-slash / $HOME-prefix based, so an un-normalized backslash path
# matches NOTHING (drive-letter absolutes fall through to the "$CWD/…" relative
# case and then trivially prefix-match $CWD — the resource-scope fail-open).
# Normalize the target to the /c/… POSIX form first, and the working dir with it in the same
# cygpath call when there is a target (only the resource-scope check reads CWD, and only for one).
# _PTG_LONG: the target is past _ptg_norm's 4096-character bound (G3) — the floor below the rules.
# _PTG_PROJ: the session's project root, the scope's $PROJECT root (GW), normalized in the same call.
# This and the credential floor below are decided before the rules are read (P-F1): neither needs a
# rule, and a rules read that cannot run (no jq: _ptg_rd_fail) still applies both.
_PTG_LONG=0; [ "${#PATH_INPUT}" -gt 4096 ] && _PTG_LONG=1
# P-S1: a root-relative target goes on the payload cwd's drive, else CLAUDE_PROJECT_DIR's
# (_fp_rroot); _PTG_RR=1 when a \-rooted one has neither — the credential floor below asks for a Read.
# The cwd as the payload gave it: $PWD, the fallback above, names no native drive.
_PTG_RR=0
if [ -n "$PATH_INPUT" ]; then _fp_rroot PATH_INPUT "$PATH_INPUT" "$_PTG_CWD0" || _PTG_RR=1; fi
_ptg_proj _PTG_PROJ
if [ -n "$PATH_INPUT" ]; then
  if [ -n "$_PTG_PROJ" ]; then _ptg_norm PATH_INPUT CWD _PTG_PROJ; else _ptg_norm PATH_INPUT CWD; fi
fi

# --- Credential-store Read (G1, R3) -----------------------------------------
# A Read of ~/.ssh, ~/.aws, ~/.claude/.credentials.json, … asks, whatever the resource scope says
# (in scope when the session runs in HOME; no scope ask at all under SB_RESOURCE_SCOPE=off). The
# fast path asks the same; _ptg_cred holds the list (symlink-guard's) and why /etc is not on it.
# Not past 4096 characters: the path-too-long floor below asks for such a target anyway.
# A floor below the rules (GX3, R3B), as path-too-long is: decided here, applied after the rule loop
# unless a rule asked or denied — its ask used to exit ahead of the loop and weaken a user or repo
# rule that DENIES the Read to an ask. It stands in for the resource-scope ask as well (the fast
# path's order: the credential ask, then the scope one). Decided before the rules are read (P-F1):
# with jq missing they cannot be, and _ptg_rd_fail applies this floor and path-too-long's itself.
_PTG_CR_RULE="" _PTG_CR_TGT="" _PTG_CR_REASON=""
# The Windows spellings (GS2/GC2/GX2, R3B) are _ptg_credread's; an 8.3 short name is resolved here
# by identity (_ptg_inode) and asks unless the target exists and neither it nor an existing ancestor
# is a store.
if [ "$TOOL" = Read ] && [ "$_PTG_RR" = 1 ]; then
  # P-S1: a \-rooted target with no drive to put it on — it may open any drive's credential store.
  _ptg_alias_reason "$PATH_INPUT" "a root-relative path (one leading '\\', no drive) while the call names no drive to resolve it on"
  _PTG_CR_RULE=windows-alias:root-relative _PTG_CR_TGT="$PATH_INPUT" _PTG_CR_REASON="$_PTG_SR"
elif [ "$TOOL" = Read ] && [ -n "$PATH_INPUT" ] && [ "$_PTG_LONG" = 0 ]; then
  _ptg_abs "$PATH_INPUT" "$CWD"
  _ptg_credread "$PATH_INPUT" "$_PTG_ABS"; _ptg_rc=$?
  if [ "$_ptg_rc" = 2 ]; then
    if _ptg_inode "$_PTG_ABS"; then
      _PTG_CRR=credential-read _PTG_CRT="$_PTG_ABS"; _ptg_cred_reason "$_PTG_ABS" "$_PTG_CL"; _ptg_rc=0
    elif [ "$_PTG_INO" != proven ]; then
      _PTG_CRR=windows-alias:8.3 _PTG_CRT="$_PTG_ABS"; _ptg_alias_reason "$_PTG_ABS" "an NTFS 8.3 short name (NAME~1) that names no existing file"; _ptg_rc=0
    fi
  elif [ "$_ptg_rc" = 1 ] && _ptg_linked "$_PTG_ABS" && _ptg_inode "$_PTG_ABS"; then
    # P-S2: through a link (proj/sshlink -> ~/.ssh) — the target or an existing ancestor IS a store.
    _PTG_CRR=credential-read _PTG_CRT="$_PTG_ABS"; _ptg_cred_reason "$_PTG_ABS" "$_PTG_CL, reached through a link"; _ptg_rc=0
  fi
  [ "$_ptg_rc" = 0 ] && _PTG_CR_RULE="$_PTG_CRR" _PTG_CR_TGT="$_PTG_CRT" _PTG_CR_REASON="$_PTG_SR"
fi

USER_RULES="$BRAIN_DIR/persona-rules.json"
DEFAULT_RULES="$PLUGIN_ROOT/scripts/persona-rules.default.json"
RULES_FILE=""
# D154 usability check, reused below for whichever candidate (layered effective file, user file,
# or — never checked, trusted as shipped — the plugin default) ends up as RULES_FILE.
D154_CHECK='(.rules | type) == "array" and ((.rules | length) > 0 or (((.learned // []) | type) == "array" and ((.learned // []) | length) > 0) or ((.tool_scope | type) == "object") or ((.resource_scope | type) == "object"))'
# Slice 3 (docs/plans/2026-09-24-repo-brain.md §3): the layered plugin+user+repo effective rules
# file, when usable, REPLACES the plain user/default selection below entirely (repo layer, cache,
# lock enforcement — see sb_rules_effective in lib.sh). SB_RULES_LAYERS=off or an absent/broken
# sb_rules_effective falls straight through to today's user-then-default behavior, unchanged.
EFF=""
EFF_SLUG=""
if command -v sb_rules_effective >/dev/null 2>&1; then
  # The session's slug memo (session-load.sh writes it) read in place: sb_session_slug does
  # exactly this read, but through a $(…) fork; it still resolves when the memo is absent.
  _ptg_sid="${SESSION_ID//[^A-Za-z0-9_-]/}"; _ptg_sid="${_ptg_sid:0:64}"
  if [ -n "$_ptg_sid" ] && [ -f "$BRAIN_DIR/.injected/$_ptg_sid.slug" ]; then
    IFS= read -r EFF_SLUG < "$BRAIN_DIR/.injected/$_ptg_sid.slug"; EFF_SLUG="${EFF_SLUG//"$_fp_cr"/}"
  fi
  [ -n "$EFF_SLUG" ] || EFF_SLUG="$(sb_session_slug "$SESSION_ID")"
  EFF=$(sb_rules_effective "$EFF_SLUG" 2>/dev/null)
  EFF="${EFF//$'\r'/}"
fi
# The effective-rules cache (sb_rules_effective's own file) is an attacker-adjacent artifact
# once layering is on: Write/Edit/MultiEdit to it now asks (warn-self-edit-rules-cache* below),
# but a cache written before that guard existed, or by a session that bypassed it, could still
# silently disarm every locked rule. Before trusting EFF, verify every rule the PLUGIN layer
# locks (authoritative for a shared name) plus every USER-layer lock whose name the plugin does
# not also lock, is STILL present in it, by name, with the SAME tool/match_command/match_path,
# an action rank at least as strict, AND still carrying lock:true itself (a cache entry that
# kept every gated field but dropped the lock would otherwise pass here and let the next
# layer override it freely) — all inside the ONE jq spawn that also reads the rules (--rawfile,
# same idiom sb_rules_effective itself uses). A disabled locked rule
# (lock:true, enabled:false) is exempt — sb_rules_effective's own final filter drops disabled
# rules from the effective set, so such a U rule would fail this invariant forever otherwise.
# A cache that fails this is discarded and rebuilt exactly once; if the rebuild still fails, the
# guard falls through to today's user/default selection — fail-SAFE, never fail-open.
EFF_LOCK_INVARIANT='
def fld($o;$k;$d): if ($o|type)=="object" and ($o|has($k)) then $o[$k] else $d end;
def rankOf($a): ({deny:4, ask:3, rewrite:2, warn:1}[$a] // 0);
def lockedof($raw): (if ($raw|length)==0 then [] else (($raw | try fromjson catch {}) | (.rules // []) | map(select(type=="object" and fld(.;"lock";false)==true and fld(.;"enabled";true)!=false))) end);
. as $eff
| lockedof($p) as $lp
| ($lp | map(.name)) as $pnames
| (lockedof($u) | map(select(.name as $n | ($pnames | index($n)) == null))) as $lu
| ($lp + $lu) as $locked
| ($locked | all(. as $L
    | (($eff.rules // []) | map(select(.name==$L.name)) | first) as $E
    | ($E != null)
      and (fld($E;"tool";null) == fld($L;"tool";null))
      and (fld($E;"match_command";null) == fld($L;"match_command";null))
      and (fld($E;"match_path";null) == fld($L;"match_path";null))
      and ((rankOf(fld($E;"action";"warn"))) >= (rankOf(fld($L;"action";"warn"))))
      and (fld($E;"lock";false)==true)
  ))
'
EFF_CHECK="$D154_CHECK"' and ('"$EFF_LOCK_INVARIANT"')'
EFF_PF="$DEFAULT_RULES"; [ -f "$EFF_PF" ] || EFF_PF=/dev/null
EFF_UF="$USER_RULES"; [ -f "$EFF_UF" ] || EFF_UF=/dev/null

# Iterate matching rules. ONE jq enumerates every tool-matching rule as a fixed
# 6-line frame (name/action/match_command/match_path/replace/reason) + a sentinel
# line — the old form re-parsed the whole rules file per index and then
# spawned one jq per FIELD (1+5N spawns; ~8 default Bash rules ≈ 40 spawns/call).
# Raw -r lines preserve regex strings byte-for-byte (no @tsv backslash mangling);
# rule fields are single-line by construction, and reason/replace get their
# newlines folded defensively so a multiline value cannot break the framing.
# Learned rules (.learned[], auto-armed by merge-persona-signals.sh) are
# normalized into the same frame AFTER the authored rules, so an authored
# ask/deny always wins over a learned advisory on the same input (first match
# exits). Their event field maps onto the frame: bash -> match_command against
# Bash, file -> match_path against the file-touching tools. Only action=warn
# is honored from .learned — a poisoned learned entry can therefore never
# escalate itself into a deny/rewrite.
RULE_FRAMES='
  (.rules[] | select(.tool == $t) |
    (.name // "anonymous"),
    (.action // ""),
    (.match_command // ""),
    (.match_path // ""),
    ((.replace // "") | gsub("[\r\n]"; " ")),
    ((.reason // "") | gsub("[\r\n]"; " ")),
    "--SB-RULE-END--"),
  (.learned[]? | select((.action // "") == "warn") |
   select(((.event // "") == "bash" and $t == "Bash")
       or ((.event // "") == "file" and ($t == "Edit" or $t == "Write" or $t == "MultiEdit"))) |
    ("learned:" + .event + ":" + ((.pattern // "")[0:40])),
    "warn",
    (if .event == "bash" then (.pattern // "") | gsub("[\r\n]"; " ") else "" end),
    (if .event == "file" then (.pattern // "") | gsub("[\r\n]"; " ") else "" end),
    "",
    ((.message // "") | gsub("[\r\n]"; " ")),
    "--SB-RULE-END--")
'
# _ptg_rules_data FILE CHECK: everything the rest of this guard reads from a rules file, in ONE jq
# (the old form spent a spawn per question — lock check, both scope flags, the scope tool test, the
# allowlist, the rule frames: up to 6 jq, ~30 ms each on MSYS, on every call). RD lines: CHECK's
# verdict ("true" when it held — jq -e's meaning: an error anywhere fails, else the last document
# decides), tool_scope.enabled, resource_scope.enabled, the resource-scope tool test, both
# allowlists (\u001f-joined), then the rule frames. A file holding several JSON documents keeps
# the old per-call meanings: flags from the first document, lists and rules from all of them,
# and no resource-scope tool match (the old test compared the whole multi-line output to "yes").
# G3 (R3, 2026-10-07): 0 = CHECK held; 1 = it did not — a file that is not JSON, or a CHECK that
# errors on it, is caught inside the program and reads as "did not" (jq -e's meaning, as before);
# 2 = jq itself failed: a non-zero exit, or output without the closing mark (killed, out of memory,
# the file gone), so the file's verdict is unknown (_PTG_RD_RC = jq's status). Before, 2 was 1: the
# unchecked default read went on with no rules at all (resource scope and every rule left to the
# full logic off, the call passed silently), and the layered read logged a lock-invariant failure
# and deleted a cache that was never shown bad. A 2 asks (_ptg_rd_fail).
_PTG_RD_RC=0
_ptg_rules_data() {
  _PTG_RD_RC=0
  RD=$(jq -rn --arg t "$TOOL" --rawfile p "$EFF_PF" --rawfile u "$EFF_UF" '
(try [inputs] catch null) as $all
| ($all // []) as $docs
| ($docs[0] // {}) as $d0
| (if ($docs|length) == 0 then "false"
   else ([$docs[] | (try ('"$2"') catch "\u0000err")] | if any(. == "\u0000err") then "false" else (last | if . == false or . == null then "false" else "true" end) end) end),
  (try (($d0.tool_scope.enabled // false) | tostring) catch "false"),
  (try (($d0.resource_scope.enabled // false) | tostring) catch "false"),
  (if ($docs|length) == 1 then (try ($d0.resource_scope.tools // [] | index($t) | if . == null then "no" else "yes" end) catch "no") else "multi" end),
  ([$docs[] | (try .tool_scope.allowlist[] catch empty) | tostring | gsub("[\r\n\u001f]"; " ")] | join("\u001f")),
  ([$docs[] | (try .resource_scope.allowlist[] catch empty) | tostring | gsub("[\r\n\u001f]"; " ")] | join("\u001f")),
  ($docs[] | try ('"$RULE_FRAMES"') catch empty),
  "--SB-RD-END--"
' "$1" 2>/dev/null) || _PTG_RD_RC=$?
  RD="${RD//$'\r'/}"
  if [ "$_PTG_RD_RC" != 0 ]; then RD=""; return 2; fi
  case "$RD" in
    *"$_fp_nl--SB-RD-END--") RD="${RD%"$_fp_nl--SB-RD-END--"}" ;;
    *) RD=""; return 2 ;;
  esac
  [ "${RD%%$'\n'*}" = true ]
}
# _ptg_rd_fail FILE: _ptg_rules_data's 2 — jq failed reading FILE, so not one rule can be checked
# (the resource scope included). Logged with the real cause, audited, asked: the _fp_jqfail pattern
# (a guard that cannot read its rules must not pass the call silently). Builtins only, so it holds
# with lib.sh unsourceable as well. jq absent from PATH is _fp_jqfail's other case (GC4, R3B): logged,
# and the call passes — SessionStart's banner reports the missing jq; asking here asked on every call
# the fast path left undecided, every allow included. The two floors below the rules need no rule
# and still ask (P-F1): a credential-store Read (_PTG_CR_RULE, decided above) and a target past 4096
# characters (_PTG_LONG). Before, this exit came first — with a user or repo layer standing the fast
# path down, a Read of ~/.ssh/id_rsa passed with no verdict.
_ptg_rd_fail() {
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "$_PTG_CR_RULE" ]; then
      _fp_err "persona-tool-guard.sh" "jq is not on PATH: the rules at $1 could not be read; the credential-store Read floor ($_PTG_CR_RULE) asked"
      _fp_emit ask "$_PTG_CR_REASON"
      _fp_audit "persona-tool-guard.sh" "ask" "$_PTG_CR_RULE" "$_PTG_CR_TGT" "$_PTG_CR_REASON" "${SESSION_ID:-}" full
      exit 0
    fi
    if [ "$_PTG_LONG" = 1 ]; then
      _ptg_long_reason "$TOOL" "$PATH_INPUT"
      _fp_err "persona-tool-guard.sh" "jq is not on PATH: the rules at $1 could not be read; the path-too-long floor asked"
      _fp_emit ask "$_PTG_SR"
      _fp_audit "persona-tool-guard.sh" "ask" "path-too-long" "$PATH_INPUT" "$_PTG_SR" "${SESSION_ID:-}" full
      exit 0
    fi
    _fp_err "persona-tool-guard.sh" "jq is not on PATH: the rules at $1 could not be read and the call passed unchecked"
    exit 0
  fi
  local _pr_m="jq exited $_PTG_RD_RC reading the rules at $1"
  [ "$_PTG_RD_RC" = 0 ] && _pr_m="$_pr_m, its output cut short (no closing mark)"
  _fp_err "persona-tool-guard.sh" "$_pr_m — asked instead of checking the call against no rules"
  _fp_audit "persona-tool-guard.sh" "ask" "rules-unreadable" "$1" "$_pr_m" "${SESSION_ID:-}" full
  _fp_emit ask "second-brain persona-tool-guard.sh could not read its rules (jq failed on $1; details in error-log.jsonl), so it cannot check this call. Confirm the call."
  exit 0
}

RD=""
eff_ok=0
if [ -n "$EFF" ] && [ -s "$EFF" ]; then
  if [ "${SB_RULES_LAYERS:-on}" = "off" ]; then
    # No cache exists in this mode (sb_rules_effective returns the raw U/P file directly) —
    # the lock invariant has nothing to protect; keep today's plain D154 check.
    _ptg_rules_data "$EFF" "$D154_CHECK"; _ptg_rc=$?
    [ "$_ptg_rc" = 2 ] && _ptg_rd_fail "$EFF"
    [ "$_ptg_rc" = 0 ] && eff_ok=1
  else
    _ptg_rules_data "$EFF" "$EFF_CHECK"; _ptg_rc=$?
    [ "$_ptg_rc" = 2 ] && _ptg_rd_fail "$EFF"
    [ "$_ptg_rc" = 0 ] && eff_ok=1
    if [ "$eff_ok" = "0" ]; then
      sb_log_error "persona-tool-guard.sh" "rules-effective cache at $EFF failed the lock invariant — rebuilt in place" 1
      # G3: rebuilt in place, never deleted first. An emptied .sig makes sb_rules_effective rebuild
      # (it writes a temp file and renames it over the cache), so a guard running beside this one,
      # which may just have been handed this path, still reads a whole file. The old `rm` left it
      # none: its jq failed and it logged one more lock-invariant failure, or now would ask.
      : > "$EFF.sig" 2>/dev/null
      EFF=$(sb_rules_effective "$EFF_SLUG" 2>/dev/null)
      EFF="${EFF//$'\r'/}"
      if [ -n "$EFF" ] && [ -s "$EFF" ]; then
        _ptg_rules_data "$EFF" "$EFF_CHECK"; _ptg_rc=$?
        [ "$_ptg_rc" = 2 ] && _ptg_rd_fail "$EFF"
        [ "$_ptg_rc" = 0 ] && eff_ok=1
      fi
      if [ "$eff_ok" = "0" ]; then
        sb_log_error "persona-tool-guard.sh" "rules-effective rebuilt cache STILL fails lock invariant — falling back to user/default rules; repo layer NOT applied" 1
      fi
    fi
  fi
fi
if [ "$eff_ok" = "1" ]; then
  RULES_FILE="$EFF"
elif [ -f "$USER_RULES" ]; then
  # D154: an existing user rules file that is EMPTY, not valid JSON, or whose
  # `.rules` is not an array with SOMETHING to evaluate must not silently
  # disarm every PreToolUse rule (a truncated write from
  # merge-persona-signals.sh, or a prompt-injected Edit that leaves the file
  # invalid, both land here). `{}` and bare `{"rules":[]}` both parse fine but
  # leave nothing to evaluate — an empty rules array with no learned rules and
  # no tool_scope/resource_scope config either is never a legitimate "user
  # disabled every rule" signal (there is no UI for that), so it is treated
  # the same as corruption. `.rules:[]` alongside a non-empty `.learned[]`, or
  # alongside a deliberately-configured tool_scope/resource_scope block (even
  # with enabled:false — that is still an intentional declaration, not
  # silence), stays valid. Fall back to the shipped defaults and say so, loud,
  # once — `-s` guards the check against jq 1.6's "empty input exits 0".
  _ptg_rc=1
  if [ -s "$USER_RULES" ]; then _ptg_rules_data "$USER_RULES" "$D154_CHECK"; _ptg_rc=$?; fi
  [ "$_ptg_rc" = 2 ] && _ptg_rd_fail "$USER_RULES"
  if [ "$_ptg_rc" = 0 ]; then
    RULES_FILE="$USER_RULES"
  else
    RD=""
    sb_log_error "persona-tool-guard.sh" "user persona-rules.json at $USER_RULES is empty, not valid JSON, or has no non-empty .rules array — falling back to persona-rules.default.json" 1
    [ -f "$DEFAULT_RULES" ] && RULES_FILE="$DEFAULT_RULES"
  fi
elif [ -f "$DEFAULT_RULES" ]; then
  RD=""
  RULES_FILE="$DEFAULT_RULES"
fi
if [ -z "$RULES_FILE" ]; then
  # D154: previously a bare `exit 0` — no rules to evaluate silently became an
  # ALLOW for every tool call. A PreToolUse guard that cannot validate a single
  # rule has no basis to allow anything through; fail SAFE with a deny instead.
  sb_log_error "persona-tool-guard.sh" "no usable persona rules (checked $USER_RULES and $DEFAULT_RULES) — denying (fail-safe)" 1
  _fp_emit deny "persona-tool-guard: rules unavailable"
  exit 0
fi
# The data read above belongs to RULES_FILE whenever its check held; otherwise (the trusted
# default, or the file chosen after a failed cache) read it now, unchecked as before. G3: a jq that
# failed asks (_ptg_rd_fail); a default that is not JSON at all is no usable rules — denied, as the
# D154 block above denies when there is no rules file.
if [ "${RD%%$'\n'*}" != true ]; then
  _ptg_rules_data "$RULES_FILE" true; _ptg_rc=$?
  [ "$_ptg_rc" = 2 ] && _ptg_rd_fail "$RULES_FILE"
  if [ "$_ptg_rc" != 0 ]; then
    _fp_err "persona-tool-guard.sh" "the rules at $RULES_FILE are not JSON (or empty) — denying (fail-safe)"
    _fp_emit deny "persona-tool-guard: rules unavailable"
    exit 0
  fi
fi
_RDR="$RD" _L=""
_ptg_pop() {  # next RD line into _L
  case "$_RDR" in *"$_fp_nl"*) _L="${_RDR%%"$_fp_nl"*}"; _RDR="${_RDR#*"$_fp_nl"}" ;; *) _L="$_RDR"; _RDR="" ;; esac
}
_ptg_pop
_ptg_pop; TS_ENABLED="$_L"
_ptg_pop; RS_ENABLED="$_L"
_ptg_pop; RS_TOOL_IN="$_L"
_ptg_pop; TS_ALLOW=${_L//"$_fp_us"/"$_fp_nl"}
_ptg_pop; RS_ALLOW=${_L//"$_fp_us"/"$_fp_nl"}
RULE_STREAM="$_RDR"

_ptg_spine

# --- Verdict first, its audit row after (perf, R3 2026-10-07; GS5, R3B) ------------------------
# sb_log_audit spends ~7 process creations (date, mkdir, two jq, tr, their subshells: 0.5-1.5 s on a
# loaded MSYS box, where one creation costs 50 ms at p50 and 300-550 ms at p90), and they ran before
# the answer. Every verdict below is printed first; its row follows from this process, by
# _fp_audit (builtins: no lib.sh, no fork, so it is on disk when the hook exits, with the late flag
# of its own moment). R3's detached sb_log_audit job was lost with a hook the CLI killed, and no test
# read its row.
_ptg_log() {  # _ptg_log VERDICT RULE TARGET REASON
  _fp_audit "persona-tool-guard.sh" "$1" "$2" "$3" "$4" "$SESSION_ID" full
}
_ptg_verdict() {  # _ptg_verdict ask|deny RULE TARGET REASON: the verdict, then its row
  _fp_emit "$1" "$4"
  _ptg_log "$@"
}

# --- Tool-scope guard (sar_tool channel) ---------------------------------
# Ask before a tool is invoked when it's outside the declared allowlist.
# Per HarnessAudit, out-of-scope tool use is one of three L1 boundary-
# violation channels (alongside resource-scope and info-flow). Disabled
# by default — opt-in via tool_scope.enabled=true in persona-rules.json
# or per-session via SB_TOOL_SCOPE_EXTRA (colon-separated, like PATH).
# Run BEFORE resource-scope: if the tool itself is off-limits, the path
# check is moot. Kill switch: SB_TOOL_SCOPE=off.
if [ "${SB_TOOL_SCOPE:-on}" != "off" ]; then
  if [ "${TS_ENABLED:-false}" = "true" ]; then
    in_tool_scope=0
    _ptg_extra="${SB_TOOL_SCOPE_EXTRA:-}"; _ptg_extra=${_ptg_extra//:/"$_fp_nl"}
    _fp_split "$_fp_nl" "$TS_ALLOW$_fp_nl$_ptg_extra"
    for allowed_tool in ${_FP_A[@]+"${_FP_A[@]}"}; do
      if [ "$allowed_tool" = "$TOOL" ]; then in_tool_scope=1; break; fi
    done
    if [ "$in_tool_scope" = "0" ]; then
      TS_REASON="Tool '$TOOL' is not in the declared tool_scope allowlist. HarnessAudit treats out-of-scope tool use as one of three L1 boundary-violation channels. Confirm intent or extend via SB_TOOL_SCOPE_EXTRA (colon-separated)."
      _ptg_verdict ask tool-scope-out-of-scope "$TOOL" "$TS_REASON"
      exit 0
    fi
  fi
fi

# --- Resource-scope guard -------------------------------------------------
# Ask before file-touching tools target a path outside the configured
# allowlist. Per the paper: 50%+ of agents apply reasonable tools to
# unauthorized RESOURCES — this is the dominant boundary-violation mode.
# Run BEFORE rule iteration so an out-of-scope path is gated even when no
# named rule matches it. Kill switch: SB_RESOURCE_SCOPE=off.
# F-C (0.54.1 final review): _ptg_scope lexically collapses the WHOLE target, which is quadratic on a
# payload-sized path — above ~400 KB the scope ask arrived past the 5 s hook timeout (fail-open). A
# target over 4096 characters (_PTG_LONG) is left to the path-too-long floor below: it also asks (and
# a deny rule stays reachable), so skipping the scope collapse here loses no verdict and no time.
if [ "${SB_RESOURCE_SCOPE:-on}" != "off" ] && [ -n "$PATH_INPUT" ] && [ "$_PTG_LONG" = 0 ] && [ -z "$_PTG_CR_RULE" ]; then
  if [ "${RS_ENABLED:-false}" = "true" ]; then
    # Is this tool subject to scope checking?
    if [ "$RS_TOOL_IN" = "yes" ]; then
      # Relative targets resolve against $CWD; '.'/'..' fold lexically before the prefix match
      # (D155 — no filesystem access: this guard does not realpath its targets). _ptg_scope is the
      # fast path's test too.
      if ! _ptg_scope "$PATH_INPUT" "$CWD" "$RS_ALLOW" "$_PTG_PROJ"; then
        abs_path="$_PTG_ABS"
        _ptg_scope_reason "$abs_path"; SCOPE_REASON="$_PTG_SR"
        _ptg_verdict ask resource-scope-out-of-scope "$abs_path" "$SCOPE_REASON"
        exit 0
      fi
    fi
  fi
fi

[ -z "$RULE_STREAM" ] && [ "$_PTG_LONG" = 0 ] && [ -z "$_PTG_CR_RULE" ] && exit 0

# Pre-filter: ONE grep per field says whether ANY rule pattern can match (grep -E with every
# pattern as a -e argument is true exactly when one of them matches a line); the per-rule greps
# below then run only when one can — on a benign call, none. Same grep, same -iE, same subject as
# the per-rule test, so no rule can match there and be skipped here. An error (exit 2, e.g. an
# invalid learned pattern) counts as a hit: the per-rule loop then decides exactly as before.
# Both loops read the frames on stdin through _fp_feed, as the greps read CMD/PATH_INPUT: a
# here-string of payload-sized text can hang on MSYS.
_ptg_cmd_pats=() _ptg_path_pats=()
_ptg_collect() {
while IFS= read -r rule_name && IFS= read -r action && IFS= read -r match_cmd \
      && IFS= read -r match_path && IFS= read -r replace && IFS= read -r reason \
      && IFS= read -r _sentinel; do
  [ "$_sentinel" = "--SB-RULE-END--" ] || break
  [ -n "$match_cmd" ] && _ptg_cmd_pats+=(-e "$match_cmd")
  [ -n "$match_path" ] && _ptg_path_pats+=(-e "$match_path")
done
}
_fp_feed "$RULE_STREAM" _ptg_collect
# A big command keeps only the lines some pattern matched (grep is line-based: a line one rule
# matches is among them), so each rule's grep below reads those, not the whole command again.
CMD_HIT=0 PATH_HIT=0 CMD_SCAN="$CMD"
if [ -n "$CMD" ] && [ ${#_ptg_cmd_pats[@]} -gt 0 ]; then
  if [ "${#CMD}" -le 8192 ]; then
    _fp_feed "$CMD" grep -qiE ${_ptg_cmd_pats[@]+"${_ptg_cmd_pats[@]}"}; [ $? -ne 1 ] && CMD_HIT=1
  else
    CMD_SCAN=$(_fp_feed "$CMD" grep -iE ${_ptg_cmd_pats[@]+"${_ptg_cmd_pats[@]}"}); _ptg_rc=$?
    [ "$_ptg_rc" -ne 1 ] && CMD_HIT=1
    [ "$_ptg_rc" -eq 0 ] || CMD_SCAN="$CMD"
  fi
fi
if [ -n "$PATH_INPUT" ] && [ ${#_ptg_path_pats[@]} -gt 0 ]; then
  _fp_feed "$PATH_INPUT" grep -qiE ${_ptg_path_pats[@]+"${_ptg_path_pats[@]}"}; [ $? -ne 1 ] && PATH_HIT=1
fi

V_RANK=0; V_ACTION=""; V_RULE=""; V_REASON=""; V_TARGET=""; V_MATCH=""; V_REPLACE=""
_ptg_match() {
while IFS= read -r rule_name && IFS= read -r action && IFS= read -r match_cmd \
      && IFS= read -r match_path && IFS= read -r replace && IFS= read -r reason \
      && IFS= read -r _sentinel; do
  # Frame check: the 7th line of every rule frame is the sentinel token (non-empty: $() strips trailing newlines, so an empty sentinel would silently drop the LAST rule). A
  # non-empty value here means a field slipped the frame (multiline leak) —
  # stop matching rather than mis-apply rules to the wrong fields. Fail-soft.
  [ "$_sentinel" = "--SB-RULE-END--" ] || break

  # `--` ends option parsing: rule patterns include learned (transcript-derived)
  # content, and a pattern starting with '-' must be a regex, never a grep flag.
  #
  # -i is LOAD-BEARING, not cosmetic. Windows (NTFS) and default macOS (APFS) are
  # case-INSENSITIVE: `Persona-Rules.json` and `persona-rules.json` are the SAME FILE,
  # but a case-sensitive regex matches only the second. Without -i, a write steered to a
  # case-varied path overwrote the guard's own rules file — or any scripts/hooks file —
  # WITHOUT the `ask` gate firing, removing the human checkpoint that the self-edit rule
  # itself calls "the classic prompt-injection escalation path". Measured on Windows
  # before this fix: persona-rules.json -> ask, Persona-Rules.json -> allowed silently.
  # On case-SENSITIVE Linux -i only widens matching, i.e. it fails toward `ask`, never
  # toward allow. Regression-locked in tests/test-persona-tool-guard.sh.
  if [ -n "$match_cmd" ]; then
    [ -z "$CMD" ] && continue
    [ "$CMD_HIT" = 1 ] || continue
    _fp_feed "$CMD_SCAN" grep -qiE -- "$match_cmd" || continue
  fi
  if [ -n "$match_path" ]; then
    [ -z "$PATH_INPUT" ] && continue
    [ "$PATH_HIT" = 1 ] || continue
    _fp_feed "$PATH_INPUT" grep -qiE -- "$match_path" || continue
  fi

  target="${PATH_INPUT:-${CMD:0:200}}"

  # ACCUMULATE, do not exit on first match. The previous loop exited on the first matching
  # rule, so rule ORDER in the JSON decided the verdict. The shipped default listed the
  # `strip-silent-fallback` REWRITE rule first, and a rewrite must emit permissionDecision
  # "allow" (updatedInput requires it) — so `rm -rf x ` and `git push --force
  # origin main ` were AUTO-APPROVED with no prompt, while the same commands
  # without the redirect hit the ask rules. A guard that gets weaker as the command gets more
  # dangerous is inverted. Now: most restrictive verdict wins (deny > ask > rewrite > warn); a
  # rewrite is applied only when no stricter rule matched. Measured 2026-08-23, sandbox probes.
  case "$action" in
    deny)    [ "$V_RANK" -lt 4 ] && { V_RANK=4; V_ACTION=deny;    V_RULE="$rule_name"; V_REASON="$reason"; V_TARGET="$target"; } ;;
    ask)     [ "$V_RANK" -lt 3 ] && { V_RANK=3; V_ACTION=ask;     V_RULE="$rule_name"; V_REASON="$reason"; V_TARGET="$target"; } ;;
    rewrite) [ "$V_RANK" -lt 2 ] && { V_RANK=2; V_ACTION=rewrite; V_RULE="$rule_name"; V_REASON="$reason"; V_TARGET="$target"; V_MATCH="$match_cmd"; V_REPLACE="$replace"; } ;;
    warn)    [ "$V_RANK" -lt 1 ] && { V_RANK=1; V_ACTION=warn;    V_RULE="$rule_name"; V_REASON="$reason"; V_TARGET="$target"; } ;;
  esac
done
}
_fp_feed "$RULE_STREAM" _ptg_match

# GX3: the credential Read floor (decided above the scope check): a rule's ask or deny stands.
if [ -n "$_PTG_CR_RULE" ] && [ "$V_RANK" -lt 3 ]; then
  V_RANK=3 V_ACTION=ask V_RULE="$_PTG_CR_RULE" V_TARGET="$_PTG_CR_TGT" V_REASON="$_PTG_CR_REASON"
fi

# G3: a target past 4096 characters was matched in its lexical spelling only (_ptg_norm) — every rule
# saw all of it, but not cygpath's spelling (an MSYS mount name such as /tmp). A call no rule asked
# about or denied is asked about; a verdict a rule gave stands, under that rule's name.
if [ "$_PTG_LONG" = 1 ] && [ "$V_RANK" -lt 3 ]; then
  _ptg_long_reason "$TOOL" "$PATH_INPUT"
  V_RANK=3 V_ACTION=ask V_RULE=path-too-long V_TARGET="$PATH_INPUT" V_REASON="$_PTG_SR"
fi

case "$V_ACTION" in
  deny|ask)
    _ptg_verdict "$V_ACTION" "$V_RULE" "$V_TARGET" "$V_REASON"
    ;;
  rewrite)
    # Only reached when NO deny/ask rule matched. SOH (\x01) as the sed delimiter: `|` would
    # error on grouped alternations and silently zero NEW_CMD; SOH cannot occur in a command.
    # If either operand contains SOH, pass the command through unchanged rather than corrupt it.
    SOH=$'\x01'
    REWRITE_OK=1
    case "$V_MATCH$V_REPLACE" in
      *"$SOH"*) NEW_CMD="$CMD" ;;
      *)
        NEW_CMD=$(printf '%s' "$CMD" | sed -E "s${SOH}${V_MATCH}${SOH}${V_REPLACE}${SOH}g" 2>/dev/null)
        SED_RC=$?
        # D156: only SOH-in-operand was guarded. Any OTHER sed failure
        # (unterminated s command from a replace ending in backslashes, a bad
        # backreference, ...) left NEW_CMD empty while this branch still
        # unconditionally emitted permissionDecision:allow with
        # updatedInput.command:"" — corrupting the call AND skipping the
        # user's normal permission prompt. Fail to ask instead.
        if [ "$SED_RC" -ne 0 ] || { [ -z "$NEW_CMD" ] && [ -n "$CMD" ]; }; then REWRITE_OK=0; fi
        ;;
    esac
    if [ "$REWRITE_OK" = "0" ]; then
      FAIL_REASON="Rewrite rule '$V_RULE' produced an invalid replacement (sed could not safely apply match_command/replace) — refusing to auto-allow an unverifiable rewrite. Original reason: $V_REASON"
      _ptg_verdict ask "$V_RULE" "$V_TARGET" "$FAIL_REASON"
    else
      # The rewritten command reaches jq on stdin, not as an --arg: a native jq.exe on Windows gets
      # no command line past ~32 KB and prints nothing, which left the tool to run UNrewritten with
      # no row saying so. A jq that still yields nothing now logs and asks instead.
      _ptg_rw=$(printf '%s' "$NEW_CMD" | jq -Rsc --arg r "$V_REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r,updatedInput:{command:.}}}' 2>/dev/null)
      if [ -n "$_ptg_rw" ]; then
        printf '%s
' "$_ptg_rw"
        _ptg_log rewrite "$V_RULE" "$V_TARGET" "$V_REASON"
      else
        FAIL_REASON="Rewrite rule '$V_RULE' matched, but the rewritten command could not be emitted (jq produced no output, ${#NEW_CMD} chars) — refusing to run it unrewritten without confirmation. Original reason: $V_REASON"
        _ptg_verdict ask "$V_RULE" "$V_TARGET" "$FAIL_REASON"
        sb_log_error "persona-tool-guard.sh" "rewrite rule $V_RULE: jq produced no output for a ${#NEW_CMD}-char rewritten command; asked instead" 1
      fi
    fi
    ;;
  warn)
    # Advisory-only: additionalContext, deliberately NO permissionDecision — an advisory must
    # never widen permissions, only inform.
    jq -nc --arg r "$V_REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'  || true
    _ptg_log warn "$V_RULE" "$V_TARGET" "$V_REASON"
    ;;
esac

exit 0
