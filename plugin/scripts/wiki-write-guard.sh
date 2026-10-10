#!/bin/bash
# wiki-write-guard.sh — PreToolUse hook for Write/Edit/MultiEdit on wiki pages.
# Denies writes to ~/knowledge/wiki/**/*.md (excluding index.md) when the resulting
# content lacks YAML frontmatter. Forces every new wiki page to ship with the schema
# (title, description, type, created, updated, tags, related) so BM25 retrieval works
# and knowledge_validate stays clean.
#
# Kill switch: SB_PERSONA_GATE=off (shared with other persona-layer hooks)
# Always exits 0. Decision is conveyed via hookSpecificOutput JSON on stdout.
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

DENY_MSG="Wiki pages require YAML frontmatter. Prepend a block like:
---
title: \"<page title>\"
description: \"\"
type: <concepts|decisions|entities|issues|learnings|security|state|sources>
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags: []
related: []
---

Then retry the write. See existing pages in ~/knowledge/wiki/ for the schema."

# Legacy-wiki misroute deny, with the corrected canonical path (see the LEGACY branch below).
# Substituted on the lowercased path so a case-varied ".Second-Brain/Wiki" still yields a
# corrected path (the lowercase form is valid on the case-insensitive filesystems where case
# variants can occur at all). Builtin first-match substitution, as the old sed s||| did.
_wwg_legacy_msg() {  # _wwg_legacy_msg LOWERCASED-PATH -> WWG_MSG
  # The pattern goes in through a variable: bash 3.2 (macOS) splits ${v/PAT/REP} at the first '/'
  # even inside quotes, so ".second-brain/wiki" became the pattern ".second-brain" and the rest
  # joined the replacement — the deny named …/wiki/knowledge/wiki/wiki/… (macOS lane, F8).
  local _wl_s _wl_p=".second-brain/wiki"
  _wl_s=${1/"$_wl_p"/knowledge/wiki}
  WWG_MSG="Legacy wiki path — .second-brain/wiki is NOT the wiki. Pages written here are invisible to knowledge_search (the raw-drainer misroute bug class). The canonical wiki is KNOWLEDGE_DIR (~/knowledge/wiki). Write to: $_wl_s"
}

# --- B7 fast path: wiki direct writes decided before any process -------------------------------
# The legacy-tree misroute (path only), and a missing frontmatter fence when the first character
# of the new text settles it: a Write's content or an Edit's new_string that starts with anything
# but '-' or an escape (an empty new_string too — the full logic denies it). A Write that creates
# a page is decided here only when no forgotten page by that slug can be auto-restored instead (no
# archive log, or no archived <slug>.md) — the restore redirect must win then. MultiEdit's
# frontmatter test (every edits[] entry) stays with the full logic.
# The value's first field (_fp_at) holds its first character; an empty field that is not the last one
# is a closed empty string, and the last field is the read's end (its \037 sentinel is no character).
_wwg_first() {  # _wwg_first KEY -> _W1 = first char of the "KEY" string value ('' = empty); 1 = undecidable
  local _wf_f
  _W1=""
  _fp_at "$1" || return 1
  _wf_f="${_FP_A[$_FP_I]}"
  if [ "$_FP_I" -eq $(( ${#_FP_A[@]} - 1 )) ]; then _wf_f="${_wf_f%"$_fp_us"}"; [ -n "$_wf_f" ] || return 1; fi
  _W1="${_wf_f:0:1}"
  return 0
}
# _wwg_kdpage PATH: true when PATH is a page under KNOWLEDGE_DIR's wiki/<category>/ (G18, R3) — the
# wiki of a custom KNOWLEDGE_DIR (CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR, else KNOWLEDGE_DIR, else
# ~/knowledge, leading ~ expanded: lib.sh sb_knowledge_dir's order) that has no "knowledge" path
# segment, which the */knowledge/wiki/* arms never matched. Builtins only: both sides spelled
# lexically (_fp_path … lex) and lowered, as the arms compare. Like them it needs a category
# directory, so wiki/index.md stays out. Only a path with a /wiki/ segment pays for it (_fp_path
# asks `command -v cygpath` for a drive path).
_wwg_kdpage() {
  local _wk_d _wk_p
  case "$2" in */wiki/*.md) ;; *) return 1 ;; esac
  _wk_d="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
  _wk_d=${_wk_d/#\~/"$HOME"}   # quoted (GC6): an unquoted '&' in HOME would be the matched '~' on bash 5.2
  # A relative one ("kb", "./kb") is the working directory's (P-S6/P-C3), as every writer reads it:
  # lib.sh's sb_knowledge_dir and brain-paths.ts's resolveKnowledgeDir return it as is, so each opens
  # it against its own cwd. Compared as is, no absolute page path matched it and its wiki went
  # unchecked (GS8, R3B); GS8 then joined it to HOME, which checked a wiki no writer used.
  case "$_wk_d" in
    /*|"$_fp_bs"*|[A-Za-z]:/*|[A-Za-z]:"$_fp_bs"*|'') ;;
    ./*) _wk_d="$PWD/${_wk_d#./}" ;;
    *) _wk_d="$PWD/$_wk_d" ;;
  esac
  _fp_path _wk_d "$_wk_d" lex; _fp_collapse _wk_d "$_wk_d"; _wk_d="${_wk_d%/}"
  [ -n "$_wk_d" ] || return 1
  _fp_lower _wk_d "$_wk_d"
  _fp_path _wk_p "$1" lex; _fp_lower _wk_p "$_wk_p"
  case "$_wk_p" in "$_wk_d"/wiki/*/*.md) return 0 ;; esac
  return 1
}
_wwg_fast() {
  local tool fp lc slug bd f top="" legacy=0
  _fp_str tool_name || return 1
  tool="$_FP"
  case "$tool" in Write|Edit|MultiEdit) ;; *) return 1 ;; esac
  _fp_str file_path || return 1
  _fp_nocr fp "$_FP"
  [ -n "$fp" ] || return 1
  fp=${fp//"$_fp_bs"/"/"}
  _fp_lower lc "$fp"
  case "$lc" in */.second-brain/wiki/*.md) legacy=1 ;; */knowledge/wiki/*/*.md) ;; *) _wwg_kdpage "$fp" "$lc" || return 1 ;; esac
  case "$lc" in */knowledge/wiki/index.md) return 1 ;; esac
  if [ "$legacy" = 1 ]; then _wwg_legacy_msg "$lc"; _fp_emit deny "$WWG_MSG"; return 0; fi
  case "$tool" in
    Write)
      if [ ! -f "$fp" ]; then
        bd="${BRAIN_DIR:-$HOME/.second-brain}"; bd=${bd//"$_fp_bs"/"/"}
        if [ -f "$bd/wiki-archive-log.jsonl" ]; then
          _fp_lower slug "${fp##*/}"; slug="${slug%.md}"
          for f in "$bd"/wiki-archive/*/"$slug.md"; do [ -e "$f" ] && return 1; done
        fi
      fi
      _wwg_first content || return 1
      case "$_W1" in ''|-|"$_fp_bs") return 1 ;; esac
      _fp_emit deny "$DENY_MSG" ;;
    Edit)
      if [ -f "$fp" ]; then
        IFS= read -r -d '' -n 4 top < "$fp"
        case "$top" in ---*) return 1 ;; esac
      fi
      _wwg_first new_string || return 1
      case "$_W1" in -|"$_fp_bs") return 1 ;; esac
      _fp_emit deny "File $fp is missing YAML frontmatter and your edit doesn't add one. $DENY_MSG" ;;
    *) return 1 ;;
  esac
  return 0
}
_wwg_fast && exit 0

# --- Full logic (the fast path could not decide) -----------------------------------------------
_fp_raw_all
[ -z "$RAW" ] && exit 0

# Tool and target: builtin decode when decidable, else ONE jq (NUL-framed; the old form spent
# two jq + two tr on every Write/Edit, wiki or not). Garbage stdin → jq fails → TOOL empty → exit 0.
TOOL="" FILE_PATH=""
_wwg_fields() {
  local rc
  _fp_str tool_name; rc=$?; [ "$rc" = 2 ] && return 1; TOOL="$_FP"
  _fp_str file_path; rc=$?; [ "$rc" = 2 ] && return 1; FILE_PATH="$_FP"
  return 0
}
if ! _wwg_fields; then
  TOOL="" FILE_PATH="" _FP_JST=""
  { IFS= read -r -d '' _FP_JST; IFS= read -r -d '' TOOL; IFS= read -r -d '' FILE_PATH; } \
    < <(_fp_feed "$RAW" jq -j '(if ([.tool_name, .tool_input.file_path] | map(strings) | any(contains("\u0000"))) then "nul" else "ok" end), "\u0000", (.tool_name // ""), "\u0000", (.tool_input.file_path // ""), "\u0000"' 2>/dev/null)
  if [ "$_FP_JST" = nul ]; then
    _fp_audit "wiki-write-guard.sh" "ask" "nul-field" "$TOOL" "field holds a NUL character" "${SESSION_ID:-}" full
    _fp_emit ask "second-brain wiki-write-guard.sh cannot check this call: a field it reads holds a NUL character, which bash cannot represent. Confirm the call."
    exit 0
  fi
  if [ -z "$TOOL" ]; then
    case "$RAW" in *'"tool_name"'*)
      _fp_jqfail "wiki-write-guard.sh" "${#RAW}" && { _fp_emit ask "second-brain wiki-write-guard.sh could not read this call (jq failed on the payload; details in error-log.jsonl), so it cannot check it. Confirm the call."; exit 0; } ;;
    esac
  fi
fi
_fp_clean TOOL FILE_PATH
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac
[ -z "$FILE_PATH" ] && exit 0

# Windows git-bash sends 'C:\…\knowledge\wiki\…\x.md'; the backslash form never
# matches the '/'-separated glob below, so frontmatter enforcement + tombstone
# auto-restore were both inert on Windows. Convert to forward slashes (the
# match is a '/knowledge/wiki/' substring, so the C:/ drive form matches fine —
# no cygpath needed, and every downstream test/mkdir/mv accepts the mixed form).
FILE_PATH="${FILE_PATH//\\//}"

# Case-INSENSITIVE scope match (0.45.4): NTFS and default APFS are case-insensitive,
# so …/knowledge/Wiki/Page.md IS …/knowledge/wiki/page.md there — and before this a
# one-letter case change hit the `*) exit 0` arm below, silently bypassing frontmatter
# enforcement, tombstone auto-restore AND the legacy-misroute deny (the 0.45.2
# persona-tool-guard class, one guard over). Match on a lowercased COPY; $FILE_PATH
# keeps its casing for every file operation. On case-sensitive Linux this only widens
# matching — it fails toward deny/enforce, never toward silent allow. (tr, not ${x,,}:
# bash-3.2/BSD portable; a builtin loop, not a `tr` spawn, since B7.)
_fp_lower FP_LC "$FILE_PATH"

# Match any wiki page under a knowledge/wiki/<category>/ tree. We don't anchor on
# $HOME because tests use tmp dirs; matching on the literal "/knowledge/wiki/" segment
# is precise enough — no real project nests its own wiki under that path.
# The LEGACY branch (canonical-wiki invariant): any .md write into
# a literal ".second-brain/wiki/" tree is the raw-drainer misroute class — pages landed
# there LIVE, invisible to knowledge_search, until hand-moved. The prose pin in
# agents/raw-drainer.md can drift; this deny cannot. The adjacent-segment match cannot
# hit dream staging (".second-brain/dreams/<id>/staging/…"). Flagged here, denied below
# (deny() is not defined yet at this point in the file).
LEGACY_WIKI=0
case "$FP_LC" in
  */.second-brain/wiki/*.md) LEGACY_WIKI=1 ;;
  */knowledge/wiki/*/*.md) ;;
  *) _wwg_kdpage "$FILE_PATH" "$FP_LC" || exit 0 ;;
esac

# Skip the index — it's regenerated by knowledge_reindex and has its own format.
case "$FP_LC" in
  */knowledge/wiki/index.md) exit 0 ;;
esac

deny() {
  _fp_emit deny "$1"
  exit 0
}

# Legacy-wiki misroute: deny with the corrected canonical path. Fires for Write, Edit
# and MultiEdit alike — frontmatter cannot save a page written where search never looks.
if [ "$LEGACY_WIKI" = "1" ]; then
  _wwg_legacy_msg "$FP_LC"
  deny "$WWG_MSG"
fi

# True when the text's first 4 bytes hold a line that starts with '---' — exactly what the old
# `head -c 4 | grep -q '^---'` pipeline answered (the fence at byte 0, or right after a leading
# newline), without its two processes.
starts_with_frontmatter() {
  case "$1" in ---*|"$_fp_nl"---*) return 0 ;; esac
  return 1
}

# Tombstone / auto-restore: a Write that re-creates a FORGOTTEN page revives the
# original (move it back into the wiki) and is denied with a redirect to Edit.
# Only a fresh create (target absent) of a net-archived slug; restore is
# non-destructive. Fail-open: no log / not archived -> falls through to frontmatter.
# A path over 4096 characters or holding a newline names no file a Write can create, so there is
# no page to restore: the block is skipped before ${FILE_PATH##*/}, which costs basename x length
# (a 150k-newline basename took 6-8 s on glibc and bash 3.2; final review, 0.54.1).
_wwg_tomb=1
case "$FILE_PATH" in *"$_fp_nl"*) _wwg_tomb=0 ;; esac
[ "${#FILE_PATH}" -le 4096 ] || _wwg_tomb=0
if [ "$_wwg_tomb" = 1 ] && [ "$TOOL" = "Write" ] && [ ! -f "$FILE_PATH" ]; then
  # Canonical slugs are lowercase (sb_sanitize_slug), so lowercase the basename:
  # on NTFS/APFS, Vanished.MD recreates the forgotten page vanished.md and the
  # archive lookup must survive the casing.
  _fp_lower SLUG "${FILE_PATH##*/}"
  SLUG="${SLUG%.md}"
  GUARD_BD="${BRAIN_DIR:-$HOME/.second-brain}"
  # A basename over 255 characters names no archived page file (NAME_MAX), and a newline cannot
  # survive the helper's line-based lookup: neither can be an archived slug, so no spawn. F8 item
  # 18: a 50,000-character slug passed as an argument cost ~30 s on MSYS (two spawns converting it),
  # past the 5 s timeout on its own.
  ARCH=""
  case "$SLUG" in
    *"$_fp_nl"*) ;;
    *) [ "${#SLUG}" -gt 255 ] \
         || ARCH=$(BRAIN_DIR="$GUARD_BD" "$(dirname "$0")/wiki-archived-slugs.sh" --path "$SLUG" 2>/dev/null) || ARCH="" ;;
  esac
  if [ -n "$ARCH" ]; then
    ACAT=$(basename "$(dirname "$ARCH")")
    # Strip the /wiki/ suffix on the LOWERCASED copy, then project the prefix
    # LENGTH back onto the original so the restore target keeps on-disk casing.
    # (A case-varied "Wiki" segment made the plain ${FILE_PATH%/wiki/*} strip miss
    # entirely, deriving WIKIROOT=<full path>/wiki and mkdir-ing junk dirs.)
    _pre_lc="${FP_LC%/wiki/*}"
    WIKIROOT="${FILE_PATH:0:${#_pre_lc}}/wiki"
    mkdir -p "$WIKIROOT/$ACAT"
    # Only deny+log if the restore mv actually succeeded; otherwise fall through to
    # normal frontmatter handling (never block a write on a failed restore).
    if mv "$ARCH" "$WIKIROOT/$ACAT/$SLUG.md" 2>/dev/null; then
      printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
        "$SLUG" "$ACAT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GUARD_BD/wiki-archive-log.jsonl" 2>/dev/null || true
      deny "Auto-restored '$SLUG' from the cold-tier archive (it had been forgotten) to wiki/$ACAT/$SLUG.md. Re-open and Edit that file — do not recreate it."
    fi
  fi
fi

case "$TOOL" in
  Write)
    # G18 (R3): jq's own status, not the empty capture, says whether the content was read — an empty
    # CONTENT from a jq that failed let a bare page through (Edit/MultiEdit fail closed already). A
    # jq that ran and failed asks; a missing jq passes and is logged (_fp_jqfail's split: SessionStart
    # reports a missing jq).
    CONTENT=$(printf '%s' "$RAW" | jq -r '.tool_input.content // empty' 2>/dev/null | tr -d '\r'; exit "${PIPESTATUS[1]}")
    _wwg_rc=$?
    if [ "$_wwg_rc" -ne 0 ]; then
      if command -v jq >/dev/null 2>&1; then
        _fp_err "wiki-write-guard.sh" "jq exited $_wwg_rc reading the content of a ${#RAW}-char Write to $FILE_PATH; asked instead of passing it unchecked"
        _fp_emit ask "second-brain wiki-write-guard.sh could not read this wiki Write's content (jq failed; details in error-log.jsonl), so it cannot check its frontmatter. Confirm the call."
        exit 0
      fi
      _fp_err "wiki-write-guard.sh" "jq is not on PATH: the content of a Write to $FILE_PATH could not be read and the call passed unchecked"
    fi
    [ -z "$CONTENT" ] && exit 0
    if ! starts_with_frontmatter "$CONTENT"; then
      deny "$DENY_MSG"
    fi
    ;;
  Edit)
    # If the file already has frontmatter, an Edit can't remove it without an explicit
    # old_string that includes '---' — we treat that case as allowed and let the normal
    # tools handle correctness. We only block edits that touch a file currently missing
    # frontmatter AND whose new_string doesn't introduce one.
    if [ -f "$FILE_PATH" ]; then
      EXISTING=$(head -c 4 "$FILE_PATH" 2>/dev/null)
      case "$EXISTING" in
        '---'*) exit 0 ;;
      esac
    fi
    NEW_STR=$(printf '%s' "$RAW" | jq -r '.tool_input.new_string // empty' 2>/dev/null | tr -d '\r')
    if ! starts_with_frontmatter "$NEW_STR"; then
      deny "File $FILE_PATH is missing YAML frontmatter and your edit doesn't add one. $DENY_MSG"
    fi
    ;;
  MultiEdit)
    # Same logic: if the file lacks frontmatter, at least one edit must introduce it.
    if [ -f "$FILE_PATH" ]; then
      EXISTING=$(head -c 4 "$FILE_PATH" 2>/dev/null)
      case "$EXISTING" in
        '---'*) exit 0 ;;
      esac
    fi
    HAS_FM=$(printf '%s' "$RAW" \
      | jq -r '[.tool_input.edits[]?.new_string // ""] | map(select(startswith("---"))) | length' 2>/dev/null)
    if [ -z "$HAS_FM" ] || [ "$HAS_FM" = "0" ]; then
      deny "File $FILE_PATH is missing YAML frontmatter and no edit in the batch introduces one. $DENY_MSG"
    fi
    ;;
esac

exit 0
