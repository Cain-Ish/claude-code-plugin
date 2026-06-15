#!/bin/bash
# B0 (SP-B): config.json reader. Env-overrides-config precedence is exercised at the
# consumer sites; here we pin the raw readers across missing/partial/false/true/typo —
# especially the jq `//` false-trap (a `false` must NOT read as the default-on).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
export BRAIN_DIR="$(mktemp -d)"
source "$ROOT/scripts/lib.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
CF="$BRAIN_DIR/config.json"

# 1. No file → defaults
[ "$(sb_config_get .auto_improve off)" = "off" ] && pass "missing file → get default" || fail "missing file get"
[ "$(sb_config_bool .auto_improve off)" = "off" ] && pass "missing file → bool default" || fail "missing file bool"

# 2. auto_improve:false must stay off — even when the default is ON (the // false-trap)
printf '{"auto_improve": false}\n' > "$CF"
[ "$(sb_config_bool .auto_improve off)" = "off" ] && pass "false → off" || fail "false bool"
[ "$(sb_config_bool .auto_improve on)" = "off" ] && pass "false honored even when default=on (no // trap)" || fail "false read as on — // trap!"

# 3. auto_improve:true → on
printf '{"auto_improve": true}\n' > "$CF"
[ "$(sb_config_bool .auto_improve off)" = "on" ] && pass "true → on" || fail "true bool"

# 4. partial file → present key wins, absent keys fall back
printf '{"auto_improve": true}\n' > "$CF"
[ "$(sb_config_get .drainer.batch 5)" = "5" ] && pass "absent key → default" || fail "absent key"
[ "$(sb_config_bool .maintainer.auto off)" = "off" ] && pass "absent bool key → default" || fail "absent bool"

# 5. nested get reads the value
printf '{"drainer": {"batch": 9}}\n' > "$CF"
[ "$(sb_config_get .drainer.batch 5)" = "9" ] && pass "nested get reads value" || fail "nested get"

# 6. malformed file → default, no crash
printf 'not json{{\n' > "$CF"
[ "$(sb_config_get .auto_improve off)" = "off" ] && pass "malformed → get default" || fail "malformed get"
[ "$(sb_config_bool .auto_improve off)" = "off" ] && pass "malformed → bool default" || fail "malformed bool"

# 7. ensure-dirs seeds an automation-ON config.json (0.30.0: it's an automation plugin —
#    on by default so a fresh install self-maintains without the user remembering to opt in).
B2=$(mktemp -d); BRAIN_DIR="$B2" bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
[ -f "$B2/config.json" ] && pass "ensure-dirs seeds config.json" || fail "ensure-dirs did not seed config.json"
[ "$(jq -r '.auto_improve' "$B2/config.json" 2>/dev/null)" = "true" ]  && pass "seeded auto_improve=true (on by default)"  || fail "seeded auto_improve not true"
[ "$(jq -r '.auto_maintain' "$B2/config.json" 2>/dev/null)" = "true" ] && pass "seeded auto_maintain=true (on by default)" || fail "seeded auto_maintain not true"
[ "$(jq -r '.auto_accept' "$B2/config.json" 2>/dev/null)" = "safe" ]   && pass "seeded auto_accept=safe (prudent on)"       || fail "seeded auto_accept not safe"
# SP-D: the seed self-documents the retention block; wiki_archive_ttl_days=0 (the irreversible store stays off)
[ "$(jq -r '.retention.wiki_archive_ttl_days' "$B2/config.json" 2>/dev/null)" = "0" ] && pass "seeded retention.wiki_archive_ttl_days=0 (irreversible store off)" || fail "retention block not seeded / wiki-archive not off"
[ "$(jq -r '.retention.embeddings_cache_gc' "$B2/config.json" 2>/dev/null)" = "true" ] && pass "seeded retention.embeddings_cache_gc=true (the leak GC on)" || fail "embeddings_cache_gc not seeded true"
# idempotent: a user's EXPLICIT off is not clobbered to the new on-default on re-run
printf '{"auto_improve": false}\n' > "$B2/config.json"; BRAIN_DIR="$B2" bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
[ "$(jq -r '.auto_improve' "$B2/config.json" 2>/dev/null)" = "false" ] && pass "ensure-dirs does not clobber an existing config (explicit off preserved)" || fail "clobbered user config (forced the on-default over an explicit off)"

rm -rf "$BRAIN_DIR" "$B2"; echo; echo "ALL PASS"
