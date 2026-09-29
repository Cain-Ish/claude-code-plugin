#!/usr/bin/env bash
# run-all-timeout: 240
# (tests 9-12 wait on real detached refreshes; ~50s standalone on a loaded Windows box)
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
grep -q 'stale refresh lock' "$B11/error-log.jsonl" 2>/dev/null \
  || fail "11: reclaiming a dead refresh's lock was silent (no error-log row)"
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

# Test 5 left a detached freshness check running in $B1; let it finish before the EXIT trap
# removes $TMP (Windows cannot delete a directory a live process still holds open).
wait_unlocked "$B1" || true

echo; echo "ALL PASS"
