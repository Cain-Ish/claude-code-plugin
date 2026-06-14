#!/usr/bin/env bash
# tests/test-set-autonomy.sh — the autonomy consent WRITER (scripts/set-autonomy.mjs)
# that /second-brain:setup calls after the operator picks their tiers.
#
# ORACLES (never re-read the writer through its own claims):
#   1. JSON TYPE guard — `jq '.k | type'` on the REAL file. This is THE guard
#      against a boolean emitted as a quoted string, because the bash reader
#      can NOT catch that: `jq -r` strips the quotes, so "true" and true both
#      render as bare `true` and sb_config_bool reads both as "on". So the
#      `| type` assertions (T1) are load-bearing — do not delete them trusting
#      the round-trip below to cover types; it provably doesn't.
#   2. VALUE/SEMANTICS round-trip — feed the produced file to the REAL readers
#      (sb_config_bool / sb_config_get) and assert they yield on/off/safe. This
#      proves writer and readers agree on the resulting VALUE (independent of the
#      writer's own stdout). For the auto_accept string enum it is the primary
#      contract; for the booleans it is a value check, not a type check.
#   3. filesystem fact (file unchanged) for every fail-closed refusal.
set -u
unset CLAUDECODE 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
HELPER="$REPO_ROOT/scripts/set-autonomy.mjs"
LIB="$REPO_ROOT/scripts/lib.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$HELPER" ] || { echo "FAIL: writer missing at $HELPER"; exit 1; }

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Fresh sandbox brain dir; $1 = "seed" to pre-write a full config (with a
# retention block, to prove non-autonomy keys survive) or "empty" for no file.
new_brain() {
  BRAIN_DIR=$(mktemp -d)
  CFG="$BRAIN_DIR/config.json"
  if [ "${1:-}" = "seed" ]; then
    jq -n '{auto_improve:false,auto_maintain:false,auto_accept:"off",retention:{bak_ttl_days:14,dream_keep_count:3}}' > "$CFG"
  fi
  export BRAIN_DIR
}
# Read a value back through the REAL lib.sh reader (round-trip oracle).
read_bool() { ( export BRAIN_DIR="$1"; . "$LIB" >/dev/null 2>&1; sb_config_bool "$2" "$3" ); }
read_str()  { ( export BRAIN_DIR="$1"; . "$LIB" >/dev/null 2>&1; sb_config_get  "$2" "$3" ); }

# --- T1: full write — values, JSON types, and reader round-trip --------------
new_brain seed
node "$HELPER" --auto-improve true --auto-maintain false --auto-accept safe >/dev/null \
  || fail "T1: writer exited non-zero on a valid full write"
jq -e '.auto_improve == true'  "$CFG" >/dev/null || fail "T1: auto_improve not the boolean true"
jq -e '.auto_maintain == false' "$CFG" >/dev/null || fail "T1: auto_maintain not the boolean false"
jq -e '.auto_accept == "safe"' "$CFG" >/dev/null || fail "T1: auto_accept not the string safe"
# JSON TYPE guard — the ONLY check that catches a boolean emitted as a quoted
# string (the readers can't: jq -r strips quotes). Load-bearing; keep.
[ "$(jq -r '.auto_improve | type'  "$CFG")" = "boolean" ] || fail "T1: auto_improve written as $(jq -r '.auto_improve|type' "$CFG"), not boolean"
[ "$(jq -r '.auto_maintain | type' "$CFG")" = "boolean" ] || fail "T1: auto_maintain written as wrong JSON type"
[ "$(jq -r '.auto_accept | type'   "$CFG")" = "string"  ] || fail "T1: auto_accept written as wrong JSON type"
# VALUE round-trip through the real readers — proves writer/reader agree on the
# resulting value (on/off/safe), not the type. For auto_accept (string enum) this
# is the primary contract; for the booleans it's a value check.
[ "$(read_bool "$BRAIN_DIR" .auto_improve off)"  = "on"  ] || fail "T1: sb_config_bool disagrees — auto_improve not read as on"
# .auto_maintain default 'on' so an explicit false vs an absent key are
# distinguished. Forward-looking: every production reader of this key defaults
# OFF today, so this guards a hypothetical default-on consumer, not a live path.
[ "$(read_bool "$BRAIN_DIR" .auto_maintain on)"  = "off" ] || fail "T1: sb_config_bool — explicit false not read as off"
[ "$(read_str  "$BRAIN_DIR" .auto_accept off)"   = "safe" ] || fail "T1: sb_config_get disagrees — auto_accept not safe"
pass "T1: full write — correct values + JSON types (the type guard) + reader value round-trip"
rm -rf "$BRAIN_DIR"

# --- T2: merge preserves unrelated keys (retention.* not clobbered) ----------
new_brain seed
node "$HELPER" --auto-accept all >/dev/null || fail "T2: writer exited non-zero"
[ "$(jq -r '.retention.bak_ttl_days' "$CFG")" = "14" ]   || fail "T2: clobbered retention.bak_ttl_days"
[ "$(jq -r '.retention.dream_keep_count' "$CFG")" = "3" ] || fail "T2: clobbered retention.dream_keep_count"
[ "$(jq -r '.auto_accept' "$CFG")" = "all" ]             || fail "T2: auto_accept not updated"
[ "$(jq -r '.auto_improve' "$CFG")" = "false" ]          || fail "T2: untouched auto_improve changed"
pass "T2: partial update preserves retention.* and untouched tiers"
rm -rf "$BRAIN_DIR"

# --- T3: absent config.json → created, parseable, only the passed key set ----
new_brain empty
[ -f "$CFG" ] && fail "T3: precondition — config should be absent"
node "$HELPER" --auto-improve true >/dev/null || fail "T3: writer exited non-zero on absent file"
jq -e . "$CFG" >/dev/null 2>&1 || fail "T3: produced file is not valid JSON"
[ "$(jq -r '.auto_improve' "$CFG")" = "true" ] || fail "T3: auto_improve not set on created file"
pass "T3: absent config.json is created with valid JSON"
rm -rf "$BRAIN_DIR"

# --- T4: invalid values are rejected with NO write (fail-closed) -------------
new_brain seed
BEFORE=$(cat "$CFG")
node "$HELPER" --auto-accept maybe >/dev/null 2>&1 && fail "T4a: accepted invalid auto-accept value"
node "$HELPER" --auto-improve yes  >/dev/null 2>&1 && fail "T4b: accepted invalid boolean value"
node "$HELPER" --bogus-flag x      >/dev/null 2>&1 && fail "T4c: accepted unknown flag"
node "$HELPER"                     >/dev/null 2>&1 && fail "T4d: accepted a no-op call (no flags)"
[ "$(cat "$CFG")" = "$BEFORE" ] || fail "T4: config.json mutated by a rejected call"
pass "T4: invalid value / unknown flag / no-op all rejected, config untouched"
rm -rf "$BRAIN_DIR"

# --- T5: nested-spawn refusal (defense-in-depth, fail-closed) ----------------
new_brain seed
BEFORE=$(cat "$CFG")
SB_NESTED_SPAWN=1 node "$HELPER" --auto-maintain true --auto-accept all >/dev/null 2>&1 \
  && fail "T5: writer ENABLED autonomy inside a nested spawn"
[ "$(cat "$CFG")" = "$BEFORE" ] || fail "T5: config.json mutated under SB_NESTED_SPAWN=1"
pass "T5: refuses to enable autonomy inside a nested plugin spawn"
rm -rf "$BRAIN_DIR"

# --- T6: corrupt existing config is NOT clobbered ----------------------------
new_brain empty
printf 'this is not json {{{' > "$CFG"
BEFORE=$(cat "$CFG")
node "$HELPER" --auto-improve true >/dev/null 2>&1 && fail "T6: overwrote a corrupt config"
[ "$(cat "$CFG")" = "$BEFORE" ] || fail "T6: corrupt config was modified"
pass "T6: refuses to clobber an unparseable config.json"
rm -rf "$BRAIN_DIR"

echo "ALL PASS"
