#!/bin/bash
# discover-installed.sh — enumerate installed plugins/agents/skills under a plugins root.
# Usage: discover-installed.sh [plugins-root]            (SessionStart hook)
#        discover-installed.sh --refresh [plugins-root]  (internal: the detached refresh)
# Defaults: plugins-root=${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache}
# Writes JSON catalog to ${BRAIN_DIR:-~/.second-brain}/.installed-catalog.json and stdout.
#
# OFF THE STARTUP PATH (S0 B7, 2026-09-28). With a cached catalog the hook prints it and
# returns: no tree walk, no jq, no lib.sh. The freshness check and any rebuild run in ONE
# detached `--refresh` process guarded by an mkdir lock, so the hook cannot be killed at its
# 10s timeout however loaded the machine is. Measured before this: cancelled in 12 of 25
# sessions (avg 34s when cancelled), and the live catalog frozen at its 2026-09-24 copy —
# Claude Code writes `.in_use/<pid>` under every plugin version at each session start, so the
# old `find -newer` saw a "changed" tree on EVERY start and rebuilt synchronously. `.in_use`
# (and node_modules/.git) are now pruned from the freshness walk. Only a first run with no
# cache at all still builds synchronously (nothing to serve; that path is bounded below).
# The refresh fails LOUD (sb_log_error) and never replaces the cache with a failed build; a
# lock left by a refresh that died is reclaimed after LOCK_STALE_MIN minutes, loudly.
#
# PERFORMANCE IS A CORRECTNESS PROPERTY HERE (0.45.0). hooks/hooks.json gives this
# hook a 10s SessionStart budget. The previous implementation spawned three
# processes PER FILE (awk for `name`, awk for `description`, jq to assemble) and
# measured 52.4s against a 964-skill / 320-agent install base — killed at 10s every
# session. Because the catalog is written only at the END, a killed run never
# refreshes the cache, so the plugins tree stays newer than the cache file and the
# NEXT session re-enters the slow path and is killed again: a permanent starvation
# loop, tripped by any `/plugin update`, surfacing no error anywhere.
# This version spawns a BOUNDED number of processes per PLUGIN — not per file — via
# one `find -exec awk … {} +` batch per kind. The exact count is deliberately not
# written down here: an earlier draft said "2 jq + 2 find + 2 awk" and was already
# wrong (it omitted the `tr` sanitizer and the dirname/basename pair), and a hard
# number in a comment drifts silently the moment the loop changes (PR #91 review).
# What matters is the ORDER: per-plugin, never per-file. The machine-checked version
# of this claim is tests/test-discover-installed.sh test 6, which fails the build if
# 400 files no longer fit inside the timeout hooks.json declares.
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

MODE=serve
if [ "${1:-}" = "--refresh" ]; then MODE=refresh; shift; fi
PLUGINS_ROOT="${1:-${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache}}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
OUT_FILE="$BRAIN_DIR/.installed-catalog.json"
LOCK_DIR="$BRAIN_DIR/.installed-catalog.lock"
DI_REFRESH_ERR="$BRAIN_DIR/.installed-catalog-refresh.err"
LOCK_STALE_MIN=10          # only used when the lock carries no pid to check (SEC-L3 below)
LOCK_MAX_AGE_MIN=$((LOCK_STALE_MIN * 6))   # RR-CR2: hard ceiling even for a lock with a LIVE owner (pid reuse)
SELF="${BASH_SOURCE[0]:-$0}"
DI_LIB="${SELF%/*}/lib.sh"

mkdir -p "$BRAIN_DIR"

TMP_PLUGINS=""; TMP_AGENTS_RAW=""; TMP_SKILLS_RAW=""; TMP_AGENTS=""; TMP_SKILLS=""
di_cleanup() {
  # $? must be captured as the VERY FIRST statement — it is this process's own final exit
  # status (an unbound-variable abort under `set -u`, a signal, or an explicit `exit N`
  # elsewhere in this script), and every command below would overwrite it. A silently
  # swallowed non-zero exit here is exactly the failure mode this hook exists to avoid: a
  # detached background refresh (schedule_refresh) has no other reader of its exit status.
  local ec=$?
  local f
  for f in "$TMP_PLUGINS" "$TMP_AGENTS_RAW" "$TMP_SKILLS_RAW" "$TMP_AGENTS" "$TMP_SKILLS" "$OUT_FILE.tmp.$$"; do
    [ -n "$f" ] && [ -e "$f" ] && rm -f "$f"
  done
  if [ "$MODE" = refresh ]; then
    if [ "$ec" -ne 0 ]; then
      di_log "background catalog refresh exited non-zero (ec=$ec) — see $DI_REFRESH_ERR for its stderr" "$ec"
    fi
    # SEC-L3: only release the lock if it is still OURS. schedule_refresh writes the
    # detached child's own pid into $LOCK_DIR/pid; a lock with no pid on record predates
    # this fix (or the write raced with an even-faster reclaim) and is released as before,
    # but a lock whose recorded pid is SOMEONE ELSE'S means our own lock was reclaimed as
    # abandoned while we were still (slowly) running — removing it here would delete the
    # new owner's lock instead of the (already-gone) one we held.
    if [ -d "$LOCK_DIR" ]; then
      local owner
      owner=$(tr -d ' \t\r\n' < "$LOCK_DIR/pid" 2>/dev/null)
      if [ -z "$owner" ] || [ "$owner" = "$$" ]; then
        # rmdir requires an EMPTY directory — the pid file schedule_refresh writes inside
        # $LOCK_DIR must go first, or every release would fail with ENOTEMPTY.
        rm -f "$LOCK_DIR/pid" 2>/dev/null
        rmdir "$LOCK_DIR" 2>/dev/null \
          || di_log "could not release the refresh lock $LOCK_DIR — the next refresh waits ${LOCK_STALE_MIN} min to reclaim it" 1
      fi
    fi
  fi
  return 0
}
trap di_cleanup EXIT

# di_log <message> [exit_code]: sb_log_error (lib.sh, loaded on first use so the serve path
# never pays for it; gate= rows at exit 0 land in audit-log.jsonl), else a raw JSON row in
# error-log.jsonl — a failure must leave a trace even when lib.sh cannot load.
di_log() {
  declare -F sb_log_error >/dev/null || source "$DI_LIB"
  if declare -F sb_log_error >/dev/null; then
    sb_log_error "discover-installed.sh" "$1" "${2:-1}"
  else
    local m="${1//\\/\\\\}"; m="${m//\"/\\\"}"
    printf '{"timestamp":"%s","script":"discover-installed.sh","message":"%s","exit_code":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$m" "${2:-1}" >> "$BRAIN_DIR/error-log.jsonl"
  fi
}

# catalog_is_stale: true when a catalog input changed after the cache was written. ANY file in
# the tree counts, not just $PLUGINS_ROOT itself — directory mtime only bumps when entries at
# the immediate level change, so a plugin update inside a subdirectory would leave a root-only
# check stale indefinitely. Pruned: `.in_use` (Claude Code's per-session pid files — churn, not
# change), node_modules, .git. `head -n1` closes the pipe on the first hit, short-circuiting
# find portably — `-quit` is a GNU-only primary that BSD/macOS find rejects (its swallowed error
# empties the capture and the script then re-discovers on every single run). A missing plugins
# root is stale too: the rebuild then records an empty catalog, as before.
catalog_is_stale() {
  [ -d "$PLUGINS_ROOT" ] || return 0
  [ -n "$(find "$PLUGINS_ROOT" \( -name .in_use -o -name node_modules -o -name .git \) -prune \
            -o -newer "$OUT_FILE" -print 2>/dev/null | head -n1)" ]
}

# schedule_refresh: take the lock, start ONE detached refresh, return at once. The child gets
# </dev/null >/dev/null — a child holding the hook's stdout keeps Claude Code waiting on
# the pipe, which is what stretched cancelled runs to 34-67s (a 10s timeout); its stderr goes
# to $DI_REFRESH_ERR (under BRAIN_DIR) instead of /dev/null, so a crash this script's own
# di_log calls never see (a raw bash abort, a killed subprocess's own diagnostic) still leaves
# a trace. `trap '' HUP` survives the exec (what nohup does, without assuming nohup exists);
# `disown` drops it from the job table.
#
# SEC-L3: the lock's owner is the pid written to $LOCK_DIR/pid (the detached child's own pid —
# `$!` on a subshell that immediately `exec`s keeps the SAME pid, so no extra hop). Reclaim
# decisions are ownership-based, not age-based: a refresh genuinely still running past
# LOCK_STALE_MIN (a big install base, a loaded box) must NEVER have its lock stolen — a stolen
# lock's ORIGINAL owner still `rmdir`s it in its own di_cleanup when it eventually finishes,
# which would then delete the NEW owner's lock instead of the (already-gone) one it held. Age
# is used only as a fallback when no pid is on record at all (a lock predating this fix, or the
# tiny window between this process's own mkdir and its pid write racing a concurrent reclaim
# check) — a lock that young is presumed to still be mid-setup, not abandoned.
# Reclaim race on a genuinely dead owner: two hooks that both see a dead pid can each reclaim
# and start a refresh; both write the catalog atomically (tmp + mv), so the worst case is one
# redundant rebuild, never a torn file.
# lock_older_than MIN: 0 when $LOCK_DIR was last modified more than MIN minutes ago. A find that
# FAILS (the lock vanished under a concurrent release, a find without -mmin) used to look exactly
# like a young lock — no output — and so, silently, like a held one forever: it is logged, and still
# read as held (never reclaim on a probe that did not run). Only find's own output line — the path —
# counts as "old": a warning on stderr cannot pass for it.
lock_older_than() {
  local out rc
  out=$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$1" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    out="${out//$'\n'/ }"; out="${out//$'\r'/}"
    di_log "could not age the refresh lock $LOCK_DIR (find -mmin +$1 exited $rc: ${out:0:200}) — treating it as held this session" 1
    return 1
  fi
  case "$out" in "$LOCK_DIR"|*"
$LOCK_DIR") return 0 ;; esac
  return 1
}

schedule_refresh() {
  local reclaimed=0 owner="" reclaim_msg=""
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ ! -d "$LOCK_DIR" ]; then
      # mkdir failed for a reason OTHER than "already exists as a directory" (permission
      # denied, a plain file occupying the path, a missing/read-only BRAIN_DIR, ...). The old
      # code fell straight into the staleness probe below, which found nothing at a
      # nonexistent path and returned 0 with NO trace at all of a real, actionable failure.
      di_log "could not create the refresh lock $LOCK_DIR (mkdir failed and no lock directory exists there) — catalog refresh skipped this session" 1
      return 0
    fi
    owner=$(tr -d ' \t\r\n' < "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      # RR-CR2: a live pid normally owns the lock outright (SEC-L3) — but the OS recycles pids,
      # so a lock this old with a "live" owner is more likely PID REUSE (the original refresh is
      # long gone; its pid now names an unrelated process) than a refresh genuinely still running
      # LOCK_MAX_AGE_MIN after it started. Past that much wider bound, reclaim it too — otherwise
      # a reused pid wedges the catalog refresh forever, with no age fallback ever firing.
      lock_older_than "$LOCK_MAX_AGE_MIN" || return 0
      reclaim_msg="owner pid $owner is alive but the lock is older than ${LOCK_MAX_AGE_MIN} min — reclaiming as likely pid reuse"
    elif [ -z "$owner" ]; then
      lock_older_than "$LOCK_STALE_MIN" || return 0
      reclaim_msg="no owner pid recorded, and the lock is older than ${LOCK_STALE_MIN} min"
    else
      reclaim_msg="owner pid $owner not alive"
    fi
    # rmdir requires an empty directory — a dead owner's own pid file is still inside.
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    if ! rmdir "$LOCK_DIR" 2>/dev/null; then
      di_log "abandoned refresh lock $LOCK_DIR ($reclaim_msg) could not be removed — no catalog refresh until it is deleted by hand" 1
      return 0
    fi
    di_log "reclaimed an abandoned refresh lock $LOCK_DIR ($reclaim_msg)" 1
    mkdir "$LOCK_DIR" 2>/dev/null || return 0   # another hook reclaimed it first: its refresh runs
    reclaimed=1
  fi
  : > "$DI_REFRESH_ERR" 2>/dev/null
  ( trap '' HUP; export SB_DI_RECLAIMED="$reclaimed" SB_DI_RECLAIM_WHY="$reclaim_msg"; exec bash "$SELF" --refresh "$PLUGINS_ROOT" ) \
    </dev/null >/dev/null 2>"$DI_REFRESH_ERR" &
  local child_pid=$!
  # RR-SF3: an unchecked write here used to fail silently — a full/read-only BRAIN_DIR, or the
  # lock dir vanishing under a concurrent release, leaves $LOCK_DIR/pid empty or missing. The next
  # schedule_refresh then reads no owner at all and falls back to the SHORT LOCK_STALE_MIN age
  # probe on a lock that is really still live, letting it steal (or wait to steal) an active
  # refresh's lock. Loud, not fatal: the detached refresh itself already started.
  printf '%s' "$child_pid" > "$LOCK_DIR/pid" 2>/dev/null \
    || di_log "could not write the refresh lock's pid file $LOCK_DIR/pid (child $child_pid) — the next refresh may misjudge this one as ownerless" 1
  disown "$child_pid"
}

if [ "$MODE" = serve ] && [ -s "$OUT_FILE" ]; then
  cat "$OUT_FILE"
  schedule_refresh
  exit 0
fi

if [ "$MODE" = refresh ]; then
  # The reclaiming hook passes its own reason — a dead owner, no pid on record, or a live pid past
  # LOCK_MAX_AGE_MIN (likely reuse): a fixed "older than 10 min … died" here contradicted the last.
  [ "${SB_DI_RECLAIMED:-0}" = "1" ] && di_log "refresh started on a reclaimed lock (${SB_DI_RECLAIM_WHY:-no reason passed})" 1
  # Valid and fresh: nothing to do. An unparseable cache (an empty or torn write from an older
  # build) is rebuilt even when the tree is unchanged, or it would be served forever.
  if [ -s "$OUT_FILE" ] && ! catalog_is_stale \
     && jq -e 'type == "object" and has("plugins")' "$OUT_FILE" >/dev/null 2>&1; then
    exit 0
  fi
  DI_T0=$(date +%s)
fi

TMP_PLUGINS=$(mktemp)
TMP_AGENTS_RAW=$(mktemp)
TMP_SKILLS_RAW=$(mktemp)
TMP_AGENTS=$(mktemp)
TMP_SKILLS=$(mktemp)

# Frontmatter reader, batched over MANY .md files in one awk process.
# Emits one US(\037)-separated record per file: name \037 description \037 plugin.
# Records with an empty name are dropped in emit() below (`if (nm != "")`), matching
# the previous `[ -z "$aname" ] && continue`. The jq stage re-checks the same
# condition — belt and braces, since jq is what turns a line into a catalog record and
# should not depend on an upstream guarantee it cannot see (PR #91 review: the earlier
# wording credited jq alone and obscured where the filtering actually happens).
#   - The fence regex keeps `[ \t\r]*` because a CRLF-authored .md fence is `---\r`;
#     a strict /^---$/ would never toggle and the whole block would be invisible.
#   - Only the FIRST frontmatter block is read (fence==1), so a `---` rule inside
#     the body cannot resurrect parsing. The old per-key `exit` made that moot;
#     batching means we must be explicit.
#   - \037 is stripped from values so a hostile description cannot forge a field.
# Issue #100: NOT `FM_AWK=$(cat <<'AWKEOF' … )`. bash 3.2 (macOS /bin/bash) extracts a
# $(...) body by naive quote scanning that ignores the heredoc boundary, so the lone `'`
# inside the awk character class below swallowed the closing `)` and the whole script
# failed to PARSE — the SessionStart hook was dead on every macOS install. `read -d ''`
# needs no command substitution, so the 3.2 parser never scans the body.
IFS= read -r -d '' FM_AWK <<'AWKEOF' || true
function clean(v) {
  gsub(/\r/, "", v)
  gsub(/\037/, "", v)
  gsub(/^["'[:space:]]+/, "", v)
  gsub(/["'[:space:]]+$/, "", v)
  return v
}
function emit() {
  if (nm != "") printf "%s\037%s\037%s\n", nm, ds, PLUG
  nm = ""; ds = ""; fence = 0
}
FNR == 1 { emit() }
/^---[ \t\r]*$/ { fence++; next }
fence == 1 {
  if (nm == "" && $0 ~ /^name:/) {
    v = $0; sub(/^name:[ \t]*/, "", v); nm = clean(v)
  } else if (ds == "" && $0 ~ /^description:/) {
    v = $0; sub(/^description:[ \t]*/, "", v); ds = clean(v)
  }
}
END { emit() }
AWKEOF

if [ -d "$PLUGINS_ROOT" ]; then
  while IFS= read -r pj; do
    [ -f "$pj" ] || continue
    # One jq builds the plugin record (was three `jq -r` reads plus a `jq -nc`
    # assemble). gsub("\r";"") replaces the old `tr -d '\r'` without a second process.
    prec=$(jq -c 'select((.name // "") != "")
                  | {name: .name,
                     description: ((.description // "") | gsub("\r"; "")),
                     version:     ((.version     // "") | gsub("\r"; ""))}' "$pj" 2>/dev/null)
    [ -n "$prec" ] || continue
    printf '%s\n' "$prec" >> "$TMP_PLUGINS"
    # Sanitize the SAME characters clean() strips inside FM_AWK. $name is spliced
    # into the 0x1f record stream as the third field, so it is untrusted framing
    # input exactly like a description is — but it arrives from a THIRD-PARTY
    # plugin.json, not from a line-oriented awk read, so it can carry a literal
    # NEWLINE. Without \n and \037 stripping, a hostile plugin.json name of the form
    #   "evil\nFAKE-NAME\037FAKE-DESC\037FAKE-PLUGIN"
    # appends a genuine extra line to the stream, which `jq -Rc` then parses as a
    # fully FORGED agent/skill record backed by no file at all (reproduced 2026-08-21
    # during review of this rewrite; the header's anti-forgery claim covered only
    # nm/ds and silently did not hold for PLUG). Locked by test 8.
    name=$(jq -r '.name // empty' "$pj" 2>/dev/null | tr -d '\r\n\037')
    [ -n "$name" ] || continue

    # Resolve the plugin's root dir. plugin.json may live at <root>/plugin.json
    # or <root>/.claude-plugin/plugin.json.
    # Builtins, not $(dirname)/$(basename): this loop runs once per installed plugin on EVERY
    # SessionStart, and each spawn is ~30-60ms on MSYS (3 spawns x N plugins per start).
    plugin_dir="${pj%/*}"
    if [ "${plugin_dir##*/}" = ".claude-plugin" ]; then
      plugin_dir="${plugin_dir%/*}"
    fi

    # `-exec … {} +` batches every matching file into ONE awk invocation (a handful
    # for very large trees), instead of one process per file. POSIX; BSD/macOS-safe.
    # No match => awk is never invoked at all.
    [ -d "$plugin_dir/agents" ] && find "$plugin_dir/agents" -maxdepth 1 -name '*.md' -type f \
      -exec awk -v PLUG="$name" "$FM_AWK" {} + >> "$TMP_AGENTS_RAW" 2>/dev/null
    [ -d "$plugin_dir/skills" ] && find "$plugin_dir/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -type f \
      -exec awk -v PLUG="$name" "$FM_AWK" {} + >> "$TMP_SKILLS_RAW" 2>/dev/null
  done < <(find "$PLUGINS_ROOT" -name 'plugin.json' -type f 2>/dev/null | head -200)
fi

# One jq per kind converts the whole US-separated stream to JSONL. `-R` reads raw
# lines, so no shell quoting can corrupt a description.
us2json() {
  jq -Rc 'select(length > 0)
          | split(([31] | implode))   # US (0x1f); built from its code point so no
                                       # backslash escape can be mangled by an editor or sed
          | select(length >= 3)
          | select(.[0] != "")
          | {name: .[0], description: .[1], plugin: .[2]}'
}
# FAIL LOUD on a truncated category. A jq failure here would silently yield an
# EMPTY agents/skills list and a structurally valid catalog — the same
# silently-truncated-catalog failure this rewrite exists to end. This is a
# SessionStart hook, so it must not block: breadcrumb and continue with what we
# have, rather than swallow. Only fires when raw input existed but conversion
# produced nothing, so an install base with genuinely zero agents stays quiet.
convert_or_log() {
  local raw="$1" out="$2" kind="$3" rc=0
  us2json < "$raw" > "$out" 2>/dev/null || rc=$?
  # Gate on the EXIT CODE first, not just on an empty result. Checking only
  # `-s "$out"` misses the partial-truncation case this breadcrumb exists for: jq
  # emitting some records and then failing still leaves a non-empty file, so the
  # "fail loud" path stayed silent on the very failure mode it was added to catch
  # (PR #91 review). Record counts go in the message so a partial loss is
  # diagnosable from the log alone.
  local rawn outn
  rawn=$(grep -c . "$raw" 2>/dev/null | tr -d ' '); rawn=${rawn:-0}
  outn=$(grep -c . "$out" 2>/dev/null | tr -d ' '); outn=${outn:-0}
  if [ "$rc" -ne 0 ] || { [ -s "$raw" ] && [ ! -s "$out" ]; }; then
    printf '{"timestamp":"%s","script":"discover-installed.sh","message":"catalog %s conversion failed (jq rc=%s): %s input record(s) -> %s output record(s) — catalog is truncated","exit_code":1}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$rc" "$rawn" "$outn" \
      >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
  fi
}
convert_or_log "$TMP_AGENTS_RAW" "$TMP_AGENTS" agents
convert_or_log "$TMP_SKILLS_RAW" "$TMP_SKILLS" skills

# Slurp the JSONL streams into a single catalog object. A failed assembly must not replace the
# cache: it used to write an EMPTY file, which then read as fresh and was served every session.
DI_RC=0
DI_WHAT="synchronous catalog build"; [ "$MODE" = refresh ] && DI_WHAT="background catalog refresh"
CATALOG=$(jq -ns \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile p "$TMP_PLUGINS" \
  --slurpfile a "$TMP_AGENTS" \
  --slurpfile s "$TMP_SKILLS" \
  '{generated_at:$ts, plugins:$p, agents:$a, skills:$s}') || DI_RC=$?
if [ "$DI_RC" -ne 0 ] || [ -z "$CATALOG" ]; then
  di_log "$DI_WHAT failed: assembly jq rc=$DI_RC — kept the previous catalog" 1
  exit 0   # SessionStart must not block; the row above is the signal
fi

# Atomic replace (tmp + mv in the same dir): the hook may `cat` the cache at any moment.
if ! { echo "$CATALOG" > "$OUT_FILE.tmp.$$" && mv -f "$OUT_FILE.tmp.$$" "$OUT_FILE"; }; then
  di_log "$DI_WHAT failed: could not write $OUT_FILE — kept the previous catalog" 1
  exit 0
fi
if [ "$MODE" = refresh ]; then
  di_log "gate=installed-catalog-refresh bytes=${#CATALOG} secs=$(( $(date +%s) - DI_T0 )) reclaimed=${SB_DI_RECLAIMED:-0}" 0
else
  echo "$CATALOG"
fi
