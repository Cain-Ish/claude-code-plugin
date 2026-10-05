#!/usr/bin/env bash
# run-all-timeout: 240
# (tests 9-12 wait on real detached refreshes; ~50s standalone on a loaded Windows box)
# pins: SB_HEADLESS_CONTEXT - opt-in test (5b): asserts =on restores the catalog for a headless child
# Tests for scripts/discover-installed.sh — the SessionStart hook that enumerates
# installed plugins/agents/skills into $BRAIN_DIR/.installed-catalog.json.
#
# WHY THIS FILE EXISTS (0.45.0): this hook had NO test at all, and it was
# silently broken in production. hooks/hooks.json declares a 10s timeout; the
# pre-0.45.0 implementation spawned 2 awk + 1 jq PER FILE, measured at 52.4s on a
# 964-skill / 320-agent install base. It was therefore killed at 10s every single
# SessionStart. Worse, the catalog is written at the very END of the script, so a
# killed run never refreshes the cache -> the plugins tree stays newer than the
# cache file -> the NEXT session takes the slow path and is killed again. A
# permanent starvation loop, triggered by any `/plugin update`, with no error
# surfaced anywhere. Reproduced end-to-end 2026-08-21:
#     fast path (cache fresh):                 1241ms  EXIT=0
#     after touching ~/.claude/plugins/cache: 12057ms  EXIT=124 (killed)
#     cache mtime after the killed run:        UNCHANGED
#
# The perf case below encodes the ACTUAL contract — "must finish inside the
# timeout hooks.json declares for it" — rather than a magic number, so it stays
# meaningful if that timeout is ever retuned.
set -u
# The headless-child gate (R1#2) keys on these: inherited values must not no-op every case below.
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED SB_HEADLESS_CONTEXT
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/discover-installed.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/discover-installed.sh not found"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

# mkplugin <root> <name> <version> <n_agents> <n_skills> [crlf]
mkplugin() {
  local root="$1" name="$2" ver="$3" na="$4" ns="$5" crlf="${6:-}"
  local d="$root/$name"
  mkdir -p "$d/.claude-plugin" "$d/agents" "$d/skills"
  jq -nc --arg n "$name" --arg v "$ver" \
    '{name:$n, description:("desc for " + $n), version:$v}' > "$d/.claude-plugin/plugin.json"
  local i
  for (( i=1; i<=na; i++ )); do   # not `seq 1 "$na"`: BSD seq counts DOWN from 1 to 0 (issue #101)
    if [ -n "$crlf" ]; then
      printf -- '---\r\nname: %s-agent-%s\r\ndescription: agent %s of %s\r\n---\r\n\r\nbody\r\n' \
        "$name" "$i" "$i" "$name" > "$d/agents/a$i.md"
    else
      printf -- '---\nname: %s-agent-%s\ndescription: agent %s of %s\n---\n\nbody\n' \
        "$name" "$i" "$i" "$name" > "$d/agents/a$i.md"
    fi
  done
  for (( i=1; i<=ns; i++ )); do
    mkdir -p "$d/skills/s$i"
    printf -- '---\nname: %s-skill-%s\ndescription: skill %s of %s\n---\n\nbody\n' \
      "$name" "$i" "$i" "$name" > "$d/skills/s$i/SKILL.md"
  done
}

# --- Test 1: catalog shape + attribution -------------------------------------
P1="$TMP/plugins1"; B1="$TMP/b1"; mkdir -p "$P1" "$B1"
mkplugin "$P1" "alpha" "1.2.3" 2 3
mkplugin "$P1" "beta"  "0.1.0" 1 1
OUT=$(env BRAIN_DIR="$B1" bash "$SCRIPT" "$P1" 2>/dev/null) || fail "1: script exited non-zero"
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 || fail "1: output is not valid JSON"
[ "$(printf '%s' "$OUT" | jq -r '.plugins | length')" = "2" ] || fail "1: expected 2 plugins"
[ "$(printf '%s' "$OUT" | jq -r '.agents  | length')" = "3" ] || fail "1: expected 3 agents"
[ "$(printf '%s' "$OUT" | jq -r '.skills  | length')" = "4" ] || fail "1: expected 4 skills"
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.generated_at | type == "string"' >/dev/null || fail "1: missing generated_at"
[ "$(printf '%s' "$OUT" | jq -r '.plugins[] | select(.name=="alpha") | .version')" = "1.2.3" ] \
  || fail "1: plugin version not carried"
[ "$(printf '%s' "$OUT" | jq -r '.agents[] | select(.name=="alpha-agent-1") | .plugin')" = "alpha" ] \
  || fail "1: agent not attributed to its plugin"
[ "$(printf '%s' "$OUT" | jq -r '.skills[] | select(.name=="beta-skill-1") | .description')" = "skill 1 of beta" ] \
  || fail "1: skill description not extracted"
# every record must carry exactly the documented keys
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.agents[] | has("name") and has("description") and has("plugin")' >/dev/null \
  || fail "1: agent record shape changed"
pass "catalog shape, counts, attribution, version"

# --- Test 2: the catalog file is written, not just streamed -------------------
[ -f "$B1/.installed-catalog.json" ] || fail "2: .installed-catalog.json not written"
diff <(printf '%s\n' "$OUT") "$B1/.installed-catalog.json" >/dev/null 2>&1 \
  || fail "2: stdout and catalog file disagree"
pass "catalog file written and matches stdout"

# --- Test 3: CRLF frontmatter (Windows-authored .md) -------------------------
P3="$TMP/plugins3"; B3="$TMP/b3"; mkdir -p "$P3" "$B3"
mkplugin "$P3" "crlfplug" "1.0.0" 2 0 crlf
OUT3=$(env BRAIN_DIR="$B3" bash "$SCRIPT" "$P3" 2>/dev/null) || fail "3: script exited non-zero"
[ "$(printf '%s' "$OUT3" | jq -r '.agents | length')" = "2" ] || fail "3: CRLF frontmatter not parsed"
[ -n "$OUT3" ] && printf '%s' "$OUT3" | jq -e '.agents[] | select(.description | test("\r"))' >/dev/null 2>&1 \
  && fail "3: CR leaked into a description value"
pass "CRLF frontmatter parsed, no CR leakage"

# --- Test 4: nameless frontmatter is skipped ---------------------------------
P4="$TMP/plugins4"; B4="$TMP/b4"; mkdir -p "$P4" "$B4"
mkplugin "$P4" "gamma" "1.0.0" 1 0
printf -- '---\ndescription: no name here\n---\n\nbody\n' > "$P4/gamma/agents/noname.md"
OUT4=$(env BRAIN_DIR="$B4" bash "$SCRIPT" "$P4" 2>/dev/null)
[ "$(printf '%s' "$OUT4" | jq -r '.agents | length')" = "1" ] || fail "4: nameless agent was not skipped"
pass "frontmatter without name: skipped"

# --- Test 5: cache fast-path returns identical content ------------------------
OUT5=$(env BRAIN_DIR="$B1" bash "$SCRIPT" "$P1" 2>/dev/null) || fail "5: fast path exited non-zero"
[ "$OUT5" = "$OUT" ] || fail "5: fast-path output differs from the freshly built catalog"
pass "cache fast-path returns identical catalog"

# --- Test 5b (R1#2): a foreign headless child (`claude -p`: ATTENDED=0 or ENTRYPOINT=sdk-cli) gets
# no catalog and writes nothing — not even the brain dir. SB_HEADLESS_CONTEXT=on opts back in.
for hl in CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli; do
  BHL="$TMP/b-headless-${hl%%=*}"
  OUTHL=$(env BRAIN_DIR="$BHL" "$hl" bash "$SCRIPT" "$P1" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "5b ($hl): headless child exited $rc"
  [ -z "$OUTHL" ] || fail "5b ($hl): headless child printed output: $OUTHL"
  [ ! -e "$BHL" ] || fail "5b ($hl): headless child wrote state: $(find "$BHL" | head -5 | tr '\n' ' ')"
done
OUTHL=$(env BRAIN_DIR="$B1" SB_HEADLESS_CONTEXT=on CLAUDE_CODE_SESSION_ATTENDED=0 bash "$SCRIPT" "$P1" 2>/dev/null)
[ "$OUTHL" = "$OUT" ] || fail "5b: SB_HEADLESS_CONTEXT=on did not restore the catalog for a headless child"
pass "headless child: no output, no state; SB_HEADLESS_CONTEXT=on serves the catalog"

# --- Test 6: PERF LOCK — must finish inside its own hooks.json timeout --------
# Read the declared budget rather than hardcoding it, so retuning hooks.json
# retunes this lock. Falls back to 10 (the 0.44.0 value) if the entry moves.
BUDGET=$(jq -r '
  [ .hooks.SessionStart[]?.hooks[]?
    | select(.command | test("discover-installed"))
    | .timeout ] | first // empty' "$ROOT/hooks/hooks.json" 2>/dev/null | tr -d '\r')
case "$BUDGET" in ''|*[!0-9]*) BUDGET=10 ;; esac

P6="$TMP/plugins6"; B6="$TMP/b6"; mkdir -p "$P6" "$B6"
# 200 agents + 200 skills across 2 plugins. The pre-0.45.0 implementation spent
# 3 process spawns per file (awk name, awk description, jq assemble) = ~1200
# spawns here, which blows the budget on any real machine.
mkplugin "$P6" "big1" "1.0.0" 100 100
mkplugin "$P6" "big2" "1.0.0" 100 100
T_START=$(date +%s)
OUT6=$(env BRAIN_DIR="$B6" bash "$SCRIPT" "$P6" 2>/dev/null) || fail "6: script exited non-zero"
T_ELAPSED=$(( $(date +%s) - T_START ))
[ "$(printf '%s' "$OUT6" | jq -r '.agents | length')" = "200" ] || fail "6: wrong agent count under load"
[ "$(printf '%s' "$OUT6" | jq -r '.skills | length')" = "200" ] || fail "6: wrong skill count under load"
if [ "$T_ELAPSED" -gt "$BUDGET" ]; then
  fail "6: PERF — 400 files took ${T_ELAPSED}s, over the ${BUDGET}s timeout hooks.json declares.
       A killed run never writes the catalog, so the cache stays stale and every
       later session re-enters the slow path. Do not spawn a process per file."
fi
pass "perf: 400 files discovered in ${T_ELAPSED}s (budget ${BUDGET}s)"

# --- Test 7: hostile / malformed frontmatter cannot corrupt the catalog -------
# The 0.45.0 implementation frames records with US (0x1f) between awk and jq, so a
# third-party plugin's SKILL.md is now UNTRUSTED INPUT to a parser. These cases lock
# the framing against forgery and the JSON against breakage. Verified equivalent to
# the pre-0.45.0 output on every case here EXCEPT the 0x1f one, where the old code
# passed the raw control character straight into the JSON value and this one strips
# it — a deliberate divergence, not a regression.
P7="$TMP/plugins7"; B7="$TMP/b7"; mkdir -p "$P7" "$B7"
mkplugin "$P7" "hostile" "1.0.0" 0 0
A7="$P7/hostile/agents"
printf -- '---\nname: quoteful\ndescription: has "quotes": and a \\ backslash and {"json":"bomb"}\n---\nbody\n' > "$A7/a1.md"
printf -- '---\nname: forger\ndescription: before\037FORGED\037PLUGIN\n---\nbody\n'                              > "$A7/a2.md"
printf -- 'just a body, no fences\n'                                                                            > "$A7/a3.md"
printf -- '---\nname: real\ndescription: real desc\n---\n\nbody\n\n---\nname: fake-from-body\n---\n'             > "$A7/a4.md"
printf -- '---\ndescription: nameless\n---\nbody\n'                                                             > "$A7/a5.md"
printf -- '---\nname: spaced\ndescription: file has spaces\n---\nbody\n'                                        > "$A7/a file with spaces.md"
printf -- '---\nname: "quoted-name"\ndescription: "quoted desc"\n---\nbody\n'                                    > "$A7/a7.md"

OUT7=$(env BRAIN_DIR="$B7" bash "$SCRIPT" "$P7" 2>/dev/null) || fail "7: script exited non-zero on hostile input"
[ -n "$OUT7" ] && printf '%s' "$OUT7" | jq -e . >/dev/null 2>&1 || fail "7: hostile frontmatter produced invalid JSON"
[ "$(printf '%s' "$OUT7" | jq -r '.agents | length')" = "5" ] \
  || fail "7: expected 5 agents (a3 no-frontmatter and a5 no-name are skipped)"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="quoteful") | .description')" \
  = 'has "quotes": and a \ backslash and {"json":"bomb"}' ] || fail "7: quotes/backslash/JSON payload mangled"
# Field forgery: the injected 0x1f bytes must be stripped, NOT treated as separators.
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="forger") | .description')" = "beforeFORGEDPLUGIN" ] \
  || fail "7: 0x1f in a description was not neutralised"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="forger") | .plugin')" = "hostile" ] \
  || fail "7: a description forged the plugin attribution field"
# A `---` rule in the BODY must not resurrect frontmatter parsing.
[ -z "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="fake-from-body") | .name')" ] \
  || fail "7: a --- rule in the body was parsed as frontmatter"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="spaced") | .description')" = "file has spaces" ] \
  || fail "7: filename containing spaces was dropped by the find -exec batch"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="quoted-name") | .description')" = "quoted desc" ] \
  || fail "7: quoted frontmatter values not unquoted"
pass "hostile frontmatter: valid JSON, no field forgery, no body-fence bleed"

# --- Test 8: a hostile plugin.json `name` cannot FORGE catalog records ---------
# Found in review of the 0.45.0 rewrite, 2026-08-21. `name` is spliced into the
# 0x1f record stream as its third field, but unlike nm/ds it does NOT come from a
# line-oriented awk read -- it comes from a third-party plugin.json, so it can carry
# a literal NEWLINE. Before the fix, a name of the form
#     evil<NL>FAKE-NAME<US>FAKE-DESC<US>FAKE-PLUGIN
# appended a real extra line that `jq -Rc` parsed as a complete agent record backed
# by NO FILE AT ALL. Test 7 covers 0x1f inside .md frontmatter and did NOT catch
# this: the forgery vector is the newline, and only plugin.json can supply one.
# The fixture is built with printf escapes so no literal control byte lives in this
# source file (a stray 0x1f is invisible in review and easy to lose in an edit).
P8="$TMP/plugins8"; B8="$TMP/b8"; mkdir -p "$P8/evil/.claude-plugin" "$P8/evil/agents" "$B8"
printf -- '---\nname: real-agent\ndescription: legit\n---\nbody\n' > "$P8/evil/agents/real.md"
HOSTILE_NAME=$(printf 'evil\nFAKE-NAME\037FAKE-DESC\037FAKE-PLUGIN')
jq -nc --arg n "$HOSTILE_NAME" '{name:$n, description:"d", version:"1"}' \
  > "$P8/evil/.claude-plugin/plugin.json"
# Sanity-check the fixture itself: if the newline did not survive into the JSON
# string, this whole case would pass vacuously and lock nothing.
jq -e '.name | contains("\n")' "$P8/evil/.claude-plugin/plugin.json" >/dev/null 2>&1 \
  || fail "8: fixture lost the embedded newline in plugin.json name -- test would pass vacuously"

OUT8=$(env BRAIN_DIR="$B8" bash "$SCRIPT" "$P8" 2>/dev/null) || fail "8: script exited non-zero"
[ -n "$OUT8" ] && printf '%s' "$OUT8" | jq -e . >/dev/null 2>&1 || fail "8: forged-name fixture produced invalid JSON"
if [ -n "$OUT8" ] && printf '%s' "$OUT8" | jq -e '.agents[] | select(.name=="FAKE-NAME")' >/dev/null 2>&1; then
  fail "8: a hostile plugin.json name FORGED an agent record backed by no file"
fi
[ "$(printf '%s' "$OUT8" | jq -r '.agents | length')" = "1" ] \
  || fail "8: expected exactly the 1 real agent record"
[ "$(printf '%s' "$OUT8" | jq -r '.agents[0].name')" = "real-agent" ] \
  || fail "8: the legitimate agent record was lost"
pass "hostile plugin.json name cannot forge catalog records"

# --- Tests 9-12: a CACHED catalog is served at once; the refresh runs detached ---------
# B7 (2026-09-28): this hook was cancelled at its 10s timeout in 12 of 25 sessions (avg 34s
# when cancelled) and the real catalog stayed at its 2026-09-24 copy. Claude Code writes a
# `.in_use/<pid>` file under every plugin version at each session start, so the
# `find -newer` check saw a "changed" tree on EVERY start and rebuilt synchronously under
# load. Contract now: with a cache present the hook prints the cache and returns; freshness
# check and rebuild run in ONE detached process guarded by an mkdir lock; `.in_use` churn is
# not a change; a failed refresh logs to error-log.jsonl and never clobbers the cache.
LOCK_NAME=".installed-catalog.lock"
SENTINEL='{"generated_at":"sentinel","plugins":[],"agents":[],"skills":[]}'
REAL_JQ=$(command -v jq)
# wait_unlocked <brain>: poll until the detached refresh has released its lock (<=60s).
wait_unlocked() {
  local i=0
  while [ -d "$1/$LOCK_NAME" ] && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
  [ ! -d "$1/$LOCK_NAME" ]
}
# refresh_rows <brain>: count completed-refresh rows the detached child logged.
refresh_rows() {
  local n
  n=$(grep -c 'gate=installed-catalog-refresh' "$1/audit-log.jsonl" 2>/dev/null)
  printf '%s' "${n:-0}"
}
# A jq shim for the DETACHED child only (the serve path must never call jq): the first call
# marks start, sleeps, then marks done — so "done exists when the hook returned" proves the
# hook waited on its refresh (inherited stdout pipe, or a synchronous rebuild).
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/jq" <<'EOF'
#!/bin/bash
if [ -n "${DI_SHIM_MARK:-}" ] && [ ! -f "$DI_SHIM_MARK.start" ]; then
  : > "$DI_SHIM_MARK.start"; sleep "${DI_SHIM_SLEEP:-4}"; : > "$DI_SHIM_MARK.done"
fi
# Test 12: fail only the final catalog assembly (the only --slurpfile call), so sb_log_error's
# own jq still works and the failure row can land.
if [ "${DI_SHIM_FAIL_ASSEMBLY:-0}" = "1" ]; then
  for a in "$@"; do [ "$a" = "--slurpfile" ] && exit 5; done
fi
# Test 14: a probe line on stderr, once per shim invocation — proves the detached refresh
# child's stderr lands in a FILE (not silently /dev/null'd), independent of di_log's own
# jsonl writes (which go through stdout/append, not stderr).
[ -n "${DI_SHIM_STDERR_MSG:-}" ] && echo "$DI_SHIM_STDERR_MSG" >&2
exec "$DI_REAL_JQ" "$@"
EOF
chmod +x "$SHIM/jq"

# --- Test 9: stale cache -> served immediately, ONE detached refresh, lock stops a second --
P9="$TMP/plugins9"; B9="$TMP/b9"; mkdir -p "$P9" "$B9"
mkplugin "$P9" "alpha" "1.0.0" 1 1
env BRAIN_DIR="$B9" bash "$SCRIPT" "$P9" >/dev/null 2>&1 || fail "9: initial synchronous build failed"
printf '%s\n' "$SENTINEL" > "$B9/.installed-catalog.json"
touch -t 202001010000 "$B9/.installed-catalog.json"          # older than the tree: stale
mkplugin "$P9" "newplug" "2.0.0" 1 0                          # a real install happened
MARK9="$TMP/mark9"
OUT9=$(env BRAIN_DIR="$B9" PATH="$SHIM:$PATH" DI_REAL_JQ="$REAL_JQ" DI_SHIM_MARK="$MARK9" \
  bash "$SCRIPT" "$P9" 2>/dev/null) || fail "9: hook exited non-zero on a stale cache"
[ -f "$MARK9.done" ] && fail "9: hook returned only after the refresh finished (it waited on the child)"
[ "$OUT9" = "$SENTINEL" ] || fail "9: stale cache was not served as-is (got a rebuilt catalog synchronously)"
[ -d "$B9/$LOCK_NAME" ] || fail "9: no refresh was scheduled (lock dir absent after return)"
# Second session while the first refresh is still in flight: serve, do not spawn another.
OUT9B=$(env BRAIN_DIR="$B9" PATH="$SHIM:$PATH" DI_REAL_JQ="$REAL_JQ" DI_SHIM_MARK="$MARK9" \
  bash "$SCRIPT" "$P9" 2>/dev/null) || fail "9: second hook exited non-zero"
[ "$OUT9B" = "$SENTINEL" ] || fail "9: second hook did not serve the cache"
wait_unlocked "$B9" || fail "9: refresh lock never released"
[ "$(jq -r '.plugins | length' "$B9/.installed-catalog.json")" = "2" ] \
  || fail "9: detached refresh did not rebuild the catalog with the new plugin"
[ "$(refresh_rows "$B9")" = "1" ] || fail "9: expected exactly 1 refresh, got $(refresh_rows "$B9")"
pass "stale cache served immediately; one detached refresh; lock blocks a second"

# --- Test 10: `.in_use/<pid>` churn is not a plugin change ------------------------------
P10="$TMP/plugins10"; B10="$TMP/b10"; mkdir -p "$P10" "$B10"
mkplugin "$P10" "alpha" "1.0.0" 1 1
mkdir -p "$P10/alpha/.in_use"                                  # exists since install
find "$P10" -exec touch -t 202001010000 {} +
printf '%s\n' "$SENTINEL" > "$B10/.installed-catalog.json"     # fresh cache (mtime now)
: > "$P10/alpha/.in_use/4242"; touch -t 203001010000 "$P10/alpha/.in_use/4242"
OUT10=$(env BRAIN_DIR="$B10" bash "$SCRIPT" "$P10" 2>/dev/null) || fail "10: hook exited non-zero"
[ "$OUT10" = "$SENTINEL" ] || fail "10: .in_use churn triggered a synchronous rebuild"
wait_unlocked "$B10" || fail "10: lock never released"
[ "$(cat "$B10/.installed-catalog.json")" = "$SENTINEL" ] || fail "10: .in_use churn triggered a rebuild"
[ "$(refresh_rows "$B10")" = "0" ] || fail "10: .in_use churn was counted as a refresh"
pass ".in_use/<pid> churn does not invalidate the catalog"

# --- Test 11: a lock left by a dead refresh is reclaimed, loudly --------------------------
P11="$TMP/plugins11"; B11="$TMP/b11"; mkdir -p "$P11" "$B11"
mkplugin "$P11" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B11/.installed-catalog.json"
touch -t 202001010000 "$B11/.installed-catalog.json"
mkdir "$B11/$LOCK_NAME"; touch -t 202001010000 "$B11/$LOCK_NAME"
OUT11=$(env BRAIN_DIR="$B11" bash "$SCRIPT" "$P11" 2>/dev/null) || fail "11: hook exited non-zero"
[ "$OUT11" = "$SENTINEL" ] || fail "11: stale cache not served"
wait_unlocked "$B11" || fail "11: reclaimed lock never released"
[ "$(jq -r '.plugins | length' "$B11/.installed-catalog.json")" = "1" ] \
  || fail "11: stale lock blocked the refresh forever"
grep -q 'reclaimed an abandoned refresh lock .*(no owner pid recorded, and the lock is older than' "$B11/error-log.jsonl" 2>/dev/null \
  || fail "11: reclaiming a dead refresh's lock was silent or misworded (no 'no owner pid recorded' reclaim row)"
# F8: the child names the same reason ("owner pid unknown, not alive" claimed a liveness check
# that never ran — no pid was on record to check).
grep -q 'refresh started on a reclaimed lock (no owner pid recorded' "$B11/error-log.jsonl" 2>/dev/null \
  || fail "11: the refresh child's row must carry the reclaim reason ($(grep 'reclaimed lock' "$B11/error-log.jsonl" | head -1))"
pass "dead refresh's lock is reclaimed and logged"

# --- Test 12: a failed refresh fails LOUD and keeps the old catalog -----------------------
P12="$TMP/plugins12"; B12="$TMP/b12"; mkdir -p "$P12" "$B12"
mkplugin "$P12" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B12/.installed-catalog.json"
touch -t 202001010000 "$B12/.installed-catalog.json"
OUT12=$(env BRAIN_DIR="$B12" PATH="$SHIM:$PATH" DI_REAL_JQ="$REAL_JQ" DI_SHIM_FAIL_ASSEMBLY=1 \
  bash "$SCRIPT" "$P12" 2>/dev/null) || fail "12: hook exited non-zero"
[ "$OUT12" = "$SENTINEL" ] || fail "12: stale cache not served"
wait_unlocked "$B12" || fail "12: lock not released after a failed refresh"
[ "$(cat "$B12/.installed-catalog.json")" = "$SENTINEL" ] \
  || fail "12: a failed refresh clobbered the cached catalog"
grep -q '"script":"discover-installed.sh".*refresh failed' "$B12/error-log.jsonl" 2>/dev/null \
  || fail "12: a failed refresh left no error-log row"
pass "failed refresh logs to error-log.jsonl and keeps the old catalog"

# --- Test 13: a lock mkdir failure that is NOT "already exists" logs loudly ---------------
# review fix: the old code fell straight into the mtime staleness probe on ANY mkdir failure;
# a probe against a path that isn't even a directory finds nothing and returns 0 silently, so
# a real failure (permission denied, a plain file occupying the path, a read-only BRAIN_DIR)
# left no trace at all.
P13="$TMP/plugins13"; B13="$TMP/b13"; mkdir -p "$P13" "$B13"
mkplugin "$P13" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B13/.installed-catalog.json"
touch -t 202001010000 "$B13/.installed-catalog.json"
: > "$B13/$LOCK_NAME"     # a PLAIN FILE occupies the lock path -> mkdir fails, not "exists as a dir"
OUT13=$(env BRAIN_DIR="$B13" bash "$SCRIPT" "$P13" 2>/dev/null) || fail "13: hook exited non-zero"
[ "$OUT13" = "$SENTINEL" ] || fail "13: stale cache not served"
grep -q 'could not create the refresh lock' "$B13/error-log.jsonl" 2>/dev/null \
  || fail "13: a non-EEXIST mkdir failure on the lock path was silent"
rm -f "$B13/$LOCK_NAME"
pass "a lock mkdir failure that is not 'already exists' logs loudly"

# --- Test 14: the detached refresh child's stderr is captured to a file under BRAIN_DIR ---
# review fix: `>/dev/null 2>&1` used to drop a raw bash-level crash or subprocess diagnostic
# on the floor — the only trace of a broken refresh was whatever di_log itself managed to
# write, which is nothing if the crash happens before/around a di_log call.
P14="$TMP/plugins14"; B14="$TMP/b14"; mkdir -p "$P14" "$B14"
mkplugin "$P14" "alpha" "1.0.0" 1 1
env BRAIN_DIR="$B14" bash "$SCRIPT" "$P14" >/dev/null 2>&1 || fail "14: initial synchronous build failed"
printf '%s\n' "$SENTINEL" > "$B14/.installed-catalog.json"
touch -t 202001010000 "$B14/.installed-catalog.json"
OUT14=$(env BRAIN_DIR="$B14" PATH="$SHIM:$PATH" DI_REAL_JQ="$REAL_JQ" DI_SHIM_STDERR_MSG="probe-stderr-14" \
  bash "$SCRIPT" "$P14" 2>/dev/null) || fail "14: hook exited non-zero"
[ "$OUT14" = "$SENTINEL" ] || fail "14: stale cache not served"
wait_unlocked "$B14" || fail "14: refresh lock never released"
grep -q 'probe-stderr-14' "$B14/.installed-catalog-refresh.err" 2>/dev/null \
  || fail "14: detached child's stderr was not captured to a file under BRAIN_DIR"
pass "detached refresh child's stderr is captured to a file under BRAIN_DIR"

# --- Test 15: SEC-L3 — a LIVE lock owner within LOCK_MAX_AGE_MIN is never reclaimed --------
# Controller addendum: age alone used to decide reclaim, so a refresh genuinely still running
# past LOCK_STALE_MIN had its lock stolen out from under it — and its own later rmdir (in
# di_cleanup, once it finally finished) then deleted the NEW owner's lock instead of its own.
# RR-CR2 (below, test 15b) adds a much wider hard ceiling on top of this: this case stays well
# under it (30 min < LOCK_MAX_AGE_MIN=60 min) to prove the ceiling does not fire early.
# Local time, not -u: touch -t reads its stamp as LOCAL time (a UTC stamp is hours off anywhere
# east or west of UTC — 2.5 h old at +02:00, past the ceiling; in the future at -05:00).
AGE30=$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M)
# An empty stamp or a failed touch would leave the lock brand new, and 15 would pass vacuously.
case "$AGE30" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) fail "15: no 30-minutes-ago stamp from date -v/-d (got '$AGE30')" ;; esac
P15="$TMP/plugins15"; B15="$TMP/b15"; mkdir -p "$P15" "$B15"
mkplugin "$P15" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B15/.installed-catalog.json"
touch -t 202001010000 "$B15/.installed-catalog.json"
mkdir "$B15/$LOCK_NAME"
sleep 30 & LIVE_PID15=$!
printf '%s' "$LIVE_PID15" > "$B15/$LOCK_NAME/pid"
# Age the lock AFTER writing its pid file: creating a file inside a directory resets the
# directory's mtime, which is what the age probe reads.
touch -t "$AGE30" "$B15/$LOCK_NAME" || fail "15: touch -t $AGE30 failed — the lock is not 30 min old, the case would prove nothing"   # 30 min old: past LOCK_STALE_MIN, under the ceiling
[ -n "$(find "$B15/$LOCK_NAME" -maxdepth 0 -mmin +20)" ] || fail "15: the lock is not aged past LOCK_STALE_MIN after touch -t $AGE30"
OUT15=$(env BRAIN_DIR="$B15" bash "$SCRIPT" "$P15" 2>/dev/null); RC15=$?
sleep 1   # give a WRONGLY-scheduled refresh a moment to have started, if this regressed
# The owner is still the live one, and nothing reclaimed: an early ceiling (LOCK_MAX_AGE_MIN at
# LOCK_STALE_MIN) reclaims this lock and hands it to a new refresh — caught here, not only by timing.
PID15_NOW=$(cat "$B15/$LOCK_NAME/pid" 2>/dev/null)
kill "$LIVE_PID15" 2>/dev/null; wait "$LIVE_PID15" 2>/dev/null
[ "$RC15" -eq 0 ] || fail "15: hook exited non-zero"
[ "$OUT15" = "$SENTINEL" ] || fail "15: stale cache not served"
[ -d "$B15/$LOCK_NAME" ] || fail "15: the live owner's lock vanished (reclaimed while its owner was alive)"
[ "$PID15_NOW" = "$LIVE_PID15" ] || fail "15: the lock's owner changed from the live pid $LIVE_PID15 to '$PID15_NOW' (reclaimed under the ceiling)"
grep -q reclaim "$B15/error-log.jsonl" 2>/dev/null && fail "15: a reclaim was logged for a live owner under LOCK_MAX_AGE_MIN: $(grep reclaim "$B15/error-log.jsonl" | head -2)"
[ "$(refresh_rows "$B15")" = "0" ] || fail "15: a refresh ran despite a live lock owner"
[ "$(cat "$B15/.installed-catalog.json")" = "$SENTINEL" ] || fail "15: catalog rebuilt despite a live lock owner"
rm -f "$B15/$LOCK_NAME/pid"; rmdir "$B15/$LOCK_NAME" 2>/dev/null || rm -rf "$B15/$LOCK_NAME"
pass "a live lock owner well under LOCK_MAX_AGE_MIN is never reclaimed"

# --- Test 15b: RR-CR2 — a LIVE owner PAST LOCK_MAX_AGE_MIN IS reclaimed (likely pid reuse) --
# Without a hard ceiling, a pid the OS recycled to an unrelated live process wedges the catalog
# refresh forever: kill -0 keeps succeeding, so the dead-owner branch (test 16) never fires and
# no fallback exists once a pid is on record. Past LOCK_MAX_AGE_MIN the lock is reclaimed anyway,
# logged distinctly ("likely pid reuse") from the dead-owner case so an operator can tell them apart.
P15B="$TMP/plugins15b"; B15B="$TMP/b15b"; mkdir -p "$P15B" "$B15B"
mkplugin "$P15B" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B15B/.installed-catalog.json"
touch -t 202001010000 "$B15B/.installed-catalog.json"
mkdir "$B15B/$LOCK_NAME"
sleep 30 & LIVE_PID15B=$!
printf '%s' "$LIVE_PID15B" > "$B15B/$LOCK_NAME/pid"
touch -t 202001010000 "$B15B/$LOCK_NAME"   # after the pid write (see 15): years old, past any ceiling
OUT15B=$(env BRAIN_DIR="$B15B" bash "$SCRIPT" "$P15B" 2>/dev/null) || fail "15b: hook exited non-zero"
[ "$OUT15B" = "$SENTINEL" ] || fail "15b: stale cache not served"
wait_unlocked "$B15B" || fail "15b: reclaimed lock never released"
kill "$LIVE_PID15B" 2>/dev/null; wait "$LIVE_PID15B" 2>/dev/null
[ "$(jq -r '.plugins | length' "$B15B/.installed-catalog.json")" = "1" ] \
  || fail "15b: a refresh never ran despite the lock exceeding LOCK_MAX_AGE_MIN with a live owner"
grep -q 'is alive but the lock is older than' "$B15B/error-log.jsonl" 2>/dev/null \
  || fail "15b: reclaiming a live-but-expired lock was silent or misworded (no distinct log row)"
# The child's row carries the reclaiming hook's reason, not a fixed "died" story (F8).
grep -q 'refresh started on a reclaimed lock (owner pid [0-9]* is alive but' "$B15B/error-log.jsonl" 2>/dev/null \
  || fail "15b: the refresh child's row must carry the live-owner reason ($(grep 'reclaimed lock' "$B15B/error-log.jsonl" | head -1))"
pass "a live lock owner past LOCK_MAX_AGE_MIN is reclaimed as likely pid reuse, and logged"

# --- Test 15c: a FAILING age probe is logged, and the lock is treated as held -----------------
# F8: `find … -mmin … 2>/dev/null` that fails printed nothing — the same as a young lock — so the
# refresh was skipped silently every session. A find that fails only on -mmin (the age probe),
# with a lock whose owner recorded no pid (the LOCK_STALE_MIN probe path).
P15C="$TMP/plugins15c"; B15C="$TMP/b15c"; FSHIM="$TMP/findshim"; mkdir -p "$P15C" "$B15C" "$FSHIM"
mkplugin "$P15C" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B15C/.installed-catalog.json"
touch -t 202001010000 "$B15C/.installed-catalog.json"
mkdir "$B15C/$LOCK_NAME"
REAL_FIND=$(command -v find)
printf '#!/bin/sh\ncase "$*" in *-mmin*) echo "find: simulated -mmin failure" >&2; exit 2 ;; esac\nexec "%s" "$@"\n' "$REAL_FIND" > "$FSHIM/find"
chmod +x "$FSHIM/find"
OUT15C=$(env BRAIN_DIR="$B15C" PATH="$FSHIM:$PATH" bash "$SCRIPT" "$P15C" 2>/dev/null) || fail "15c: hook exited non-zero"
[ "$OUT15C" = "$SENTINEL" ] || fail "15c: stale cache not served"
grep -q 'could not age the refresh lock .*exited 2' "$B15C/error-log.jsonl" 2>/dev/null \
  || fail "15c: a failing find -mmin age probe was silent (no 'could not age the refresh lock' row)"
[ -d "$B15C/$LOCK_NAME" ] || fail "15c: a lock whose age could not be probed was removed"
grep -q reclaim "$B15C/error-log.jsonl" 2>/dev/null && fail "15c: a lock whose age could not be probed was reclaimed"
rmdir "$B15C/$LOCK_NAME"
pass "a failing lock-age probe is logged and the lock is treated as held (never reclaimed on no evidence)"

# --- Test 15d (O6): a lock that VANISHES between the check and the age probe is a benign release
# race (its owner finished and released it), not an error. The probe's find then fails with "No
# such file" and lock_older_than logged an error-severity "could not age the refresh lock" row for
# a perfectly healthy session. The shim removes the lock the instant the -mmin probe runs, then
# fails the way find does on a missing path. Expect: no error row, the hook still exits 0 and
# serves the cache; the lock stays gone (this session does not race to recreate it).
P15D="$TMP/plugins15d"; B15D="$TMP/b15d"; DSHIM="$TMP/findshim-d"; mkdir -p "$P15D" "$B15D" "$DSHIM"
mkplugin "$P15D" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B15D/.installed-catalog.json"
touch -t 202001010000 "$B15D/.installed-catalog.json"
mkdir "$B15D/$LOCK_NAME"
printf '#!/bin/sh\ncase "$*" in *-mmin*) rmdir "%s"; echo "find: No such file or directory" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
  "$B15D/$LOCK_NAME" "$REAL_FIND" > "$DSHIM/find"
chmod +x "$DSHIM/find"
OUT15D=$(env BRAIN_DIR="$B15D" PATH="$DSHIM:$PATH" bash "$SCRIPT" "$P15D" 2>/dev/null) || fail "15d: hook exited non-zero"
[ "$OUT15D" = "$SENTINEL" ] || fail "15d: stale cache not served"
[ ! -d "$B15D/$LOCK_NAME" ] || fail "15d: the shim did not simulate the vanished lock (case proves nothing)"
grep -q 'could not age the refresh lock' "$B15D/error-log.jsonl" 2>/dev/null \
  && fail "15d: a lock that vanished in a benign release race was logged as an error-severity row"
pass "a lock that vanished between the check and the age probe is not an error (O6)"

# --- Test 16: SEC-L3 — a DEAD lock owner is reclaimed IMMEDIATELY, age irrelevant ----------
P16="$TMP/plugins16"; B16="$TMP/b16"; mkdir -p "$P16" "$B16"
mkplugin "$P16" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B16/.installed-catalog.json"
touch -t 202001010000 "$B16/.installed-catalog.json"
mkdir "$B16/$LOCK_NAME"    # freshly created just now -> young, no mtime staleness of its own
( exit 0 ) & DEAD_PID16=$!; wait "$DEAD_PID16" 2>/dev/null   # guaranteed dead by the time we check
printf '%s' "$DEAD_PID16" > "$B16/$LOCK_NAME/pid"
OUT16=$(env BRAIN_DIR="$B16" bash "$SCRIPT" "$P16" 2>/dev/null) || fail "16: hook exited non-zero"
[ "$OUT16" = "$SENTINEL" ] || fail "16: stale cache not served"
wait_unlocked "$B16" || fail "16: reclaimed lock never released"
[ "$(jq -r '.plugins | length' "$B16/.installed-catalog.json")" = "1" ] \
  || fail "16: a dead-owner lock blocked the refresh"
grep -q 'reclaimed an abandoned refresh lock' "$B16/error-log.jsonl" 2>/dev/null \
  || fail "16: reclaiming a dead-owner lock was silent (no error-log row)"
pass "a dead lock owner is reclaimed immediately (lock age irrelevant) and logged"

# --- Test 17: unit test of di_cleanup — logs a non-zero exit; releases only an OWNED lock -
# Deterministic (no signals, no timing races): extracts di_log/di_cleanup verbatim and drives
# them directly, the same "extract a block" technique test-session-load-embed-banner.sh uses.
extract_fn() {   # extract_fn <name> <file> -> the function body, header through the closing
                 # bare "}" (both di_log and di_cleanup in this script are written that way).
  awk -v name="$1" '$0 == name"() {" { p = 1 } p { print } p && $0 == "}" { exit }' "$2"
}
RUNNER17="$TMP/runner17.sh"
{
  echo 'set -u'
  extract_fn di_log "$SCRIPT"
  extract_fn lock_drop "$SCRIPT"
  extract_fn di_cleanup "$SCRIPT"
  cat <<'EOF'
MODE="refresh"
LOCK_STALE_MIN=10
OUT_FILE="$BRAIN_DIR/.installed-catalog.json"
TMP_PLUGINS=""; TMP_AGENTS_RAW=""; TMP_SKILLS_RAW=""; TMP_AGENTS=""; TMP_SKILLS=""
mkdir -p "$LOCK_DIR" 2>/dev/null
if [ "${OWNER_MODE:-self}" = "self" ]; then printf '%s' "$$" > "$LOCK_DIR/pid"
else printf '%s' "$OWNER_MODE" > "$LOCK_DIR/pid"; fi
trap di_cleanup EXIT
exit "${EXIT_CODE:-0}"
EOF
} > "$RUNNER17"
[ -s "$RUNNER17" ] || fail "17: could not build the di_cleanup unit runner"

# 17a: OWNED lock (pid == our own $$) + a non-zero exit -> logs the exit AND releases the lock.
B17A="$TMP/b17a"; mkdir -p "$B17A"
LOCK17A="$B17A/.installed-catalog.lock"; ERR17A="$B17A/.installed-catalog-refresh.err"
env EXIT_CODE=7 OWNER_MODE=self BRAIN_DIR="$B17A" LOCK_DIR="$LOCK17A" DI_REFRESH_ERR="$ERR17A" \
  DI_LIB="$TMP/no-such-lib.sh" bash "$RUNNER17"
grep -q 'exited non-zero (ec=7)' "$B17A/error-log.jsonl" 2>/dev/null \
  || fail "17a: di_cleanup did not log a non-zero exit"
[ -d "$LOCK17A" ] && fail "17a: di_cleanup did not release a lock it owns"
pass "17a: di_cleanup logs a non-zero exit and releases a lock it owns"

# 17b: lock owned by ANOTHER pid (reclaimed out from under us) + a clean exit -> no non-zero
# row, and the lock is left ALONE (removing it would delete the new owner's lock).
B17B="$TMP/b17b"; mkdir -p "$B17B"
LOCK17B="$B17B/.installed-catalog.lock"; ERR17B="$B17B/.installed-catalog-refresh.err"
env EXIT_CODE=0 OWNER_MODE=999999999 BRAIN_DIR="$B17B" LOCK_DIR="$LOCK17B" DI_REFRESH_ERR="$ERR17B" \
  DI_LIB="$TMP/no-such-lib.sh" bash "$RUNNER17"
[ -f "$B17B/error-log.jsonl" ] && grep -q 'exited non-zero' "$B17B/error-log.jsonl" \
  && fail "17b: a clean (ec=0) exit logged a non-zero-exit row"
[ -d "$LOCK17B" ] || fail "17b: di_cleanup released a lock it does NOT own"
[ "$(cat "$LOCK17B/pid" 2>/dev/null)" = "999999999" ] \
  || fail "17b: the other owner's pid file was disturbed"
pass "17b: di_cleanup never touches a lock owned by a different pid"

# --- Test 18: RR-SF3 — a failed pid-file write is logged, not silent ----------------------
# Deterministic (extract_fn technique, as test 17): drives schedule_refresh directly with a
# shadowed `printf` builtin that fails ONLY the pid-write's exact 2-arg shape and value
# (`printf '%-10s' "$child_pid"`; the lock's placeholder write has the same shape but carries this
# process's own pid, `$$`, so it is let through) — every other printf call (di_log's own fallback
# row, etc.) still runs for real, so the failure is isolated to the one line under test.
RUNNER18="$TMP/runner18.sh"
{
  echo 'set -u'
  extract_fn di_log "$SCRIPT"
  extract_fn lock_create "$SCRIPT"
  extract_fn lock_drop "$SCRIPT"
  extract_fn schedule_refresh "$SCRIPT"
  cat <<'EOF'
MODE="serve"
SELF="$SCRIPT_PATH"
LOCK_STALE_MIN=10
LOCK_MAX_AGE_MIN=60
OUT_FILE="$BRAIN_DIR/.installed-catalog.json"
printf() {
  if [ "$1" = '%-10s' ] && [ "$#" = 2 ] && [ "$2" != "$$" ]; then return 1; fi
  command printf "$@"
}
schedule_refresh
EOF
} > "$RUNNER18"
[ -s "$RUNNER18" ] || fail "18: could not build the schedule_refresh unit runner"
B18="$TMP/b18"; mkdir -p "$B18"
LOCK18="$B18/.installed-catalog.lock"; ERR18="$B18/.installed-catalog-refresh.err"
mkdir -p "$TMP/plugins18"
env BRAIN_DIR="$B18" LOCK_DIR="$LOCK18" DI_REFRESH_ERR="$ERR18" PLUGINS_ROOT="$TMP/plugins18" \
  SCRIPT_PATH="$SCRIPT" DI_LIB="$TMP/no-such-lib.sh" bash "$RUNNER18"
sleep 1   # let the detached child (real, unshimmed printf) start and finish quickly
grep -q 'could not write the refresh lock.*pid file' "$B18/error-log.jsonl" 2>/dev/null \
  || fail "18: a failed pid-file write was not logged (error-log: $(cat "$B18/error-log.jsonl" 2>/dev/null))"
wait_unlocked "$B18" || true
pass "18: RR-SF3 — a failed pid-file write logs loudly instead of failing silently"

# --- Test 19 (O13): the refresh lock is never observable WITHOUT its owner pid. The lock was a
# bare `mkdir` with the pid written only after the detached child was spawned (tens of ms on
# MSYS), so a concurrent hook that probed in that gap saw a pidless lock and took the age-fallback
# path on a lock that was live. The lock is now built in a temp dir that already holds a pid and
# renamed into place; release renames it away before emptying it. A tight watcher polls for the
# bad state (lock present, pid missing/empty) from before the hook starts until the refresh has
# released, over several parallel hooks (the loser of the rename must leave nothing behind).
P19="$TMP/plugins19"; B19="$TMP/b19"; mkdir -p "$P19" "$B19"
mkplugin "$P19" "alpha" "1.0.0" 1 1
printf '%s\n' "$SENTINEL" > "$B19/.installed-catalog.json"
touch -t 202001010000 "$B19/.installed-catalog.json"
W19_STOP="$TMP/w19.stop"; W19_BAD="$TMP/w19.bad"; W19_SEEN="$TMP/w19.seen"; rm -f "$W19_STOP" "$W19_BAD" "$W19_SEEN"
(
  L="$B19/$LOCK_NAME"
  while [ ! -e "$W19_STOP" ]; do
    if [ -d "$L" ]; then
      : > "$W19_SEEN"
      # (the diagnostic is the lock's listing at the moment of the miss)
      [ -s "$L/pid" ] || { [ -d "$L" ] && echo "$(ls -la "$L" 2>&1 | tr '\n' '|')" >> "$W19_BAD"; }
    fi
  done
) &
W19_PID=$!
H19=""
for n in 1 2 3 4 5 6; do
  env BRAIN_DIR="$B19" bash "$SCRIPT" "$P19" >/dev/null 2>&1 &
  H19="$H19 $!"
done
# Every hook has returned (each holds or lost the lock) before the release is awaited, and the lock
# has been seen at least once — else wait_unlocked would pass on a lock nobody had made yet.
# shellcheck disable=SC2086
wait $H19
i=0; while [ ! -e "$W19_SEEN" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
wait_unlocked "$B19" || fail "19: refresh lock never released (lock: $(ls -A "$B19/$LOCK_NAME" 2>&1 | tr '\n' ' ') pid=[$(cat "$B19/$LOCK_NAME/pid" 2>&1)]; siblings: $(ls -A "$B19" | tr '\n' ' '); audit tail: $(tail -n 3 "$B19/audit-log.jsonl" 2>&1 | cut -c1-240 | tr '\n' '|'); errors: $(cut -c1-240 "$B19/error-log.jsonl" 2>&1 | tr '\n' '|'); refresh stderr: $(head -c 300 "$B19/.installed-catalog-refresh.err" 2>&1 | tr '\n' '|'))"
: > "$W19_STOP"; wait "$W19_PID" 2>/dev/null
[ -e "$W19_SEEN" ] || fail "19: the watcher never saw a lock (case proves nothing)"
[ ! -e "$W19_BAD" ] || fail "19: the lock was observable without its owner pid: $(head -c 600 "$W19_BAD")"
# The lock path is free the instant the release renames it away; emptying the carcass follows.
i=0; while [ "$i" -lt 40 ] && [ -n "$(find "$B19" -maxdepth 1 -name '.installed-catalog.lock*')" ]; do sleep 0.25; i=$((i + 1)); done
LEFT19=$(find "$B19" -maxdepth 1 -name '.installed-catalog.lock*' | wc -l | tr -d ' ')
[ "$LEFT19" -eq 0 ] || fail "19: lock scaffolding left behind after the refresh ($(find "$B19" -maxdepth 1 -name '.installed-catalog.lock*'))"
# Contention between live hooks is not an error and never reclaims a live lock (the placeholder pid
# lock_create leaves is replaced by the child's a few ms later; a hook that read the old one and
# probed it after its writer exited used to reclaim a RUNNING refresh's lock).
[ ! -s "$B19/error-log.jsonl" ] || fail "19: parallel hooks logged errors: $(cut -c1-300 "$B19/error-log.jsonl")"
pass "the refresh lock is never observable without its owner pid; parallel hooks leave no scaffolding (O13)"

# Test 5 left a detached freshness check running in $B1; let it finish before the EXIT trap
# removes $TMP (Windows cannot delete a directory a live process still holds open).
wait_unlocked "$B1" || true

echo; echo "ALL PASS"
