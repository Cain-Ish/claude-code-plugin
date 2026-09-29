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
# Credential-dir prefixes (after realpath, case-insensitive):
#   $HOME/.ssh, $HOME/.gnupg, $HOME/.aws, $HOME/.config/claude,
#   $HOME/.config/gh, $HOME/.netrc (file), /etc, $HOME/.password-store,
#   $HOME/.claude/.credentials.json (file — the OAuth token; the ~/.claude
#   TREE is deliberately not a prefix, it holds legitimate write targets).
#
# Verdict: deny. Reason carries which credential dir matched (no content
# leaked).
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
_fp_re='^[[:space:]]*:[[:space:]]*$' _fp_rebs='(\\+)$'
_fp_uc=ABCDEFGHIJKLMNOPQRSTUVWXYZ _fp_lc=abcdefghijklmnopqrstuvwxyz
# bash < 4.3 runs even a one-match ${v//pat/rep} in O(candidates x length^2) (4.3 added the
# fixed-length match jump): there _fp_at leaves a payload over 16 KiB to jq.
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
  while case "$RAW" in *"$_fp_nl") true ;; *) false ;; esac; do RAW="${RAW%"$_fp_nl"}"; done
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
# or KEY may be spelled with a \u escape. JSON escapes every quote inside a string, so a "KEY"
# followed by ':' is always a real key, never text inside a value.
_fp_at() {
  local _fa_f _fa_i=0
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
    [ "$_fp_ob" = 1 ] && return 2
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

# _fp_join VAR FROM TO: VAR = fields FROM..TO of _FP_A joined by the '"' _fp_split cut out.
_fp_join() {
  local IFS="$_fp_q"
  printf -v "$1" '%s' "${_FP_A[*]:$2:$(($3 - $2 + 1))}"
}

# _fp_str KEY: _FP = the decoded string value of the ONE "KEY": "…" pair in the payload.
# 0 = found; 1 = absent; 2 = undecidable (_fp_at's cases, a value that runs past the 16 KiB read,
# or an escape left to jq: \u \b \f). The value ends at the first '"' not escaped: a field that
# ends in an odd run of backslashes ended at an escaped quote.
_fp_str() {
  local _fs_v _fs_f _fs_t _fs_s _fs_n
  _FP=""
  _fp_at "$1" || return $?
  _fs_s=$_FP_I _fs_n=$(( ${#_FP_A[@]} - 1 ))
  while :; do
    [ "$_FP_I" -lt "$_fs_n" ] || return 2
    _fs_f="${_FP_A[$_FP_I]}"
    case "$_fs_f" in *"$_fp_bs") ;; *) break ;; esac
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

# _fp_clean VAR…: drop CRs and trailing newlines from each VAR — what the full logic's old
# `$(jq -r … | tr -d '\r')` captures did to every payload field.
_fp_clean() {
  local _fc_v _fc_s
  for _fc_v in "$@"; do
    _fp_nocr _fc_s "${!_fc_v}"
    while case "$_fc_s" in *"$_fp_nl") true ;; *) false ;; esac; do _fc_s="${_fc_s%"$_fp_nl"}"; done
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
_sg_homes() {
  local _sh_h _sh_p="" _sh_o="$PWD"
  if [ "$1" = lex ]; then _fp_path _sh_h "$HOME" lex; else _sg_norm _sh_h "$HOME"; fi
  _sh_h="${_sh_h%/}"
  if [ -n "${HOME:-}" ] && CDPATH= cd -P -- "$HOME" 2>/dev/null; then
    _sh_p="$PWD"; cd -- "$_sh_o" 2>/dev/null
    if [ "$1" = lex ]; then _fp_path _sh_p "$_sh_p" lex; else _sg_norm _sh_p "$_sh_p"; fi
    _sh_p="${_sh_p%/}"
  fi
  _SG_H=()
  [ -n "$_sh_h" ] && _SG_H+=("$_sh_h")
  [ -n "$_sh_p" ] && [ "$_sh_p" != "$_sh_h" ] && _SG_H+=("$_sh_p")
  return 0
}

# _sg_cred_match PATH…: _SG_LABEL = the credential dir/file the first matching PATH is, or is
# under. Case-INSENSITIVE (nocasematch, bash 3.1+): NTFS and default APFS are case-insensitive, so
# /c/Users/me/.SSH/ IS ~/.ssh there — a case-varied path must not slip the check. On
# case-sensitive Linux this can over-match a literally distinct ~/.SSH dir; acceptable — a rare
# false deny is fail-safe, a missed credential write is not. (It replaced a `printf | tr` per
# prefix per candidate: ~36 processes, ~1 s of this guard's 1.5 s on MSYS.) The directory node
# itself matches as well as anything under it: a Write to exactly ~/.ssh must not slip past.
_SG_LABEL=""
_sg_cred_match() {
  local _sc_c _sc_h _sc_e _sc_p
  _SG_LABEL=""
  shopt -s nocasematch
  for _sc_c in "$@"; do
    [ -n "$_sc_c" ] || continue
    for _sc_h in ${_SG_H[@]+"${_SG_H[@]}"}; do
      for _sc_e in ssh:.ssh gnupg:.gnupg aws:.aws claude-config:.config/claude gh-config:.config/gh passwordstore:.password-store; do
        _sc_p="$_sc_h/${_sc_e#*:}"
        case "$_sc_c" in "$_sc_p"|"$_sc_p"/*) _SG_LABEL="${_sc_e%%:*}"; break 3 ;; esac
      done
    done
    case "$_sc_c" in /etc|/etc/*) _SG_LABEL=etc; break ;; esac
    # Single credential FILES, not prefix trees: ~/.claude must NOT be a prefix — plans/,
    # projects/ (memory), settings.json live there and are legitimate write targets.
    for _sc_h in ${_SG_H[@]+"${_SG_H[@]}"}; do
      case "$_sc_c" in
        "$_sc_h/.netrc") _SG_LABEL=netrc; break 2 ;;
        "$_sc_h/.claude/.credentials.json") _SG_LABEL=claude-oauth; break 2 ;;
      esac
    done
  done
  shopt -u nocasematch
  [ -n "$_SG_LABEL" ]
}

_sg_deny() {  # _sg_deny TOOL FILE_PATH RESOLVED LABEL SESSION
  local _sd_r="Write to '$2' resolves to '$3' which is inside the credential directory '$4'. Symlink-guard denies to prevent credential overwrite or exfil. Suppress: SB_SYMLINK_GUARD=off."
  _fp_audit "symlink-guard.sh" "deny" "credential-dir:$4" "$1($2)" "$_sd_r" "$5"
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
  local _sa_r _sa_p _sa_s _sa_m
  _SG_MAPPED=""
  command -v cygpath >/dev/null 2>&1 || [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || return 1
  _sa_r=${2//"$_fp_bs"/"/"}
  _fp_path _sa_p "$2"
  case "${_sa_p#[A-Za-z]:}" in
    *:*) _sa_m="Write to '$2' uses NTFS stream syntax (a ':' after the drive), which can name another file or a directory itself (.ssh::\$INDEX_ALLOCATION is ~/.ssh). Symlink-guard denies it. Suppress: SB_SYMLINK_GUARD=off."
         _fp_audit "symlink-guard.sh" "deny" "windows-alias:stream" "$1($2)" "$_sa_m" "$3"
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
  _sa_m="Write to '$2' is a UNC network path: symlink-guard cannot tell whether that share leads to a credential directory on this machine. Confirm the target. Suppress: SB_SYMLINK_GUARD=off."
  _fp_audit "symlink-guard.sh" "ask" "windows-alias:unc" "$1($2)" "$_sa_m" "$3"
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
# _sg_inode LINK: _SG_LABEL when LINK is the same file (device + inode, `test -ef`) as a
# credential dir, a file directly in one, or /etc and its direct entries — the classic escape
# (a repo file symlinked to ~/.ssh/authorized_keys) decided with no readlink.
_sg_inode() {
  local _si_h _si_e _si_d _si_f
  _SG_LABEL=""
  for _si_h in ${_SG_H[@]+"${_SG_H[@]}"}; do
    for _si_e in ssh:.ssh gnupg:.gnupg aws:.aws claude-config:.config/claude gh-config:.config/gh passwordstore:.password-store; do
      _si_d="$_si_h/${_si_e#*:}"
      [ -d "$_si_d" ] || continue
      for _si_f in "$_si_d" "$_si_d"/* "$_si_d"/.[!.]*; do
        [ -e "$_si_f" ] && [ "$1" -ef "$_si_f" ] && { _SG_LABEL="${_si_e%%:*}"; return 0; }
      done
    done
    [ "$1" -ef "$_si_h/.netrc" ] && { _SG_LABEL=netrc; return 0; }
    [ "$1" -ef "$_si_h/.claude/.credentials.json" ] && { _SG_LABEL=claude-oauth; return 0; }
  done
  for _si_f in /etc /etc/*; do [ -e "$_si_f" ] && [ "$1" -ef "$_si_f" ] && { _SG_LABEL=etc; return 0; }; done
  return 1
}
_sg_fast() {
  local tool fp lit lex sid=""
  _fp_str tool_name || return 1
  tool="$_FP"
  case "$tool" in Write|Edit|MultiEdit) ;; *) return 1 ;; esac
  _fp_str file_path || return 1
  _fp_nocr fp "$_FP"
  case "$fp" in ''|*"$_fp_nl"*) return 1 ;; esac
  case "$fp" in '~'*) fp="$HOME${fp#\~}" ;; esac
  _fp_str session_id && sid="$_FP"
  _sg_alias "$tool" "$fp" "$sid"
  case $? in 0) return 0 ;; 2) fp="$_SG_MAPPED" ;; esac
  _fp_path lit "$fp" lex
  _sg_homes lex
  if _sg_phys "$lit"; then
    _sg_cred_match "$_SG_PHYS" "$lit" && { _sg_deny "$tool" "$lit" "$_SG_PHYS" "$_SG_LABEL" "$sid"; return 0; }
  else
    # Unresolved ('..', a deep path, a leaf symlink): the literal target, and its '..' folded
    # lexically — a path that names a credential dir outright is denied here, as the full logic's
    # literal match would; anything else goes to realpath there.
    _fp_collapse lex "$lit"
    _sg_cred_match "$lit" "$lex" && { _sg_deny "$tool" "$lit" "$lex" "$_SG_LABEL" "$sid"; return 0; }
    [ -n "$_SG_LEAF" ] && _sg_inode "$_SG_LEAF" \
      && { _sg_deny "$tool" "$lit" "$_SG_LEAF (a symlink to a $_SG_LABEL entry)" "$_SG_LABEL" "$sid"; return 0; }
  fi
  return 1
}
_sg_fast && exit 0

# --- Full logic (the fast path could not decide) -----------------------------------------------
_fp_raw_all
[ -z "$RAW" ] && exit 0

# Fields: builtin decode when the payload is a JSON object and each field is decidable, else ONE
# jq (NUL-framed; the old form spent four spawns: object check + one per field). A non-object
# payload → no fields → exit 0 (the old fail-soft). CRs dropped, trailing newlines trimmed, as the
# old `jq -r … | tr -d '\r'` inside $(…) did.
TOOL="" FILE_PATH="" SESSION_ID=""
_sg_fields() {
  local _sf_obj='^[[:space:]]*[{]' _sf_v _sf_rc
  [[ $RAW =~ $_sf_obj ]] || return 1
  for _sf_v in TOOL:tool_name FILE_PATH:file_path SESSION_ID:session_id; do
    _fp_str "${_sf_v#*:}"; _sf_rc=$?
    [ "$_sf_rc" = 2 ] && return 1
    printf -v "${_sf_v%%:*}" '%s' "$_FP"
  done
  return 0
}
if ! _sg_fields; then
  TOOL="" FILE_PATH="" SESSION_ID=""
  {
    IFS= read -r -d '' TOOL; IFS= read -r -d '' FILE_PATH; IFS= read -r -d '' SESSION_ID
  } < <(_fp_feed "$RAW" jq -j 'if type == "object" then (.tool_name // ""), "\u0000", (.tool_input.file_path // ""), "\u0000", (.session_id // ""), "\u0000" else empty end' 2>/dev/null)
fi
_fp_clean TOOL FILE_PATH SESSION_ID

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

# Windows alias spellings (UNC, stream syntax), as on the fast path: a big payload whose file_path
# came after 16 KiB of content reaches only this logic.
_sg_alias "$TOOL" "$FILE_PATH" "$SESSION_ID"
case $? in 0) exit 0 ;; 2) FILE_PATH="$_SG_MAPPED" ;; esac

# The target as the fast path spells it too — lexical /x/ drive form, '..' folded. cygpath -u maps a
# drive path under an MSYS mount (%TEMP% is /tmp) to the mount's name, which a HOME spelled /c/…
# never prefixes; this spelling does.
_fp_path SG_LEX "$FILE_PATH" lex
_fp_collapse SG_LEX "$SG_LEX"

# Windows git-bash sends 'C:\…' / 'C:/…'; normalize to the /c/… POSIX form the
# credential prefixes use BEFORE realpath (so it resolves) and again AFTER (GNU
# realpath re-emits C:/ form on Windows — normalizing its OUTPUT is the G-HOOK-2
# fix: without it the credential-dir prefixes never match and the guard is inert).
_sg_norm FILE_PATH "$FILE_PATH"

# Resolve through symlinks. -m: missing-component-tolerant (Write targets the
# file may not exist yet); we still resolve the parent's symlinks.
RESOLVED=$(realpath -m -- "$FILE_PATH" 2>/dev/null)        # GNU coreutils: follows leaf + parent, missing-tolerant
[ -z "$RESOLVED" ] && RESOLVED=$(greadlink -f -- "$FILE_PATH" 2>/dev/null)  # macOS Homebrew coreutils
if [ -z "$RESOLVED" ]; then
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
  _rem="$FILE_PATH"
  case "$_rem" in
    /*) _res="/" ;;
    *)  _res="$PWD/" ;;
  esac
  while [ -n "$_rem" ]; do
    _rem="${_rem#/}"
    _seg="${_rem%%/*}"
    case "$_rem" in */*) _rem="${_rem#*/}" ;; *) _rem="" ;; esac
    case "$_seg" in
      ""|".") continue ;;
      "..")
        _res="${_res%/}"; _res="${_res%/*}"; [ -z "$_res" ] && _res="/"
        continue
        ;;
    esac
    _cand="${_res%/}/$_seg"
    if _rp=$(cd "$_cand" 2>/dev/null && pwd -P); then
      _res="$_rp"
    elif [ -L "$_cand" ]; then
      _tgt=$(readlink -- "$_cand" 2>/dev/null)
      # D183 (follow-up): splicing the target string directly into $_res left
      # any '..' INSIDE a relative target unresolved (`ln -s ../../.ssh/id_rsa
      # repo/notes.txt` produced ".../repo/../../.ssh/id_rsa" verbatim, which
      # never prefix-matches the real credential dir). Re-enter the walk
      # instead: push the target's segments back onto $_rem so the SAME '..'
      # popping logic above collapses them against $_res (relative target) or
      # against '/' (absolute target), rather than a raw lexical splice.
      case "$_tgt" in
        /*) _res="/"; _rem="${_tgt#/}${_rem:+/$_rem}" ;;
        *)  _rem="$_tgt${_rem:+/$_rem}" ;;
      esac
    else
      _res="${_res%/}/$_seg"
    fi
  done
  RESOLVED="$_res"
fi
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
    _fp_audit "symlink-guard.sh" "deny" "ntfs-8.3-shortname" "${TOOL}(${FILE_PATH})" "$SHORTNAME_REASON" "$SESSION_ID"
    _fp_emit deny "$SHORTNAME_REASON"
    exit 0
  fi
fi

# Credential match on the RESOLVED target and on the LITERAL (normalized, unresolved) one: when the
# resolver degrades (realpath absent, a HOME spelling pwd -P rewrites), a path that names a
# credential dir outright must still be denied. Resolved-only let a literal ~/.ssh write through
# on the GitHub Windows runner. Label order: resolved first, as before.
_sg_homes full
_SG_HF=(${_SG_H[@]+"${_SG_H[@]}"})
_sg_homes lex
_SG_H+=(${_SG_HF[@]+"${_SG_HF[@]}"})
_sg_cred_match "$RESOLVED" "$FILE_PATH" "$SG_LEX" || exit 0
_sg_deny "$TOOL" "$FILE_PATH" "$RESOLVED" "$_SG_LABEL" "$SESSION_ID"
exit 0
