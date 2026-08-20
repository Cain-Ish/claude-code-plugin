#!/bin/bash
# Guard: model-ladder.json is THE single source of truth for model selection. Validates the
# manifest, the alias-first invariant (a ladder that led with a pinned ID would silently stop
# picking up newly released models — the Opus 5 lesson), the dispatch alias enum (the Agent
# tool's model param is a schema-level enum: full IDs are rejected before any API call), and
# the source-scan tripwire that keeps model literals from leaking back into consumers.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
M="$ROOT/model-ladder.json"
fail(){ echo "FAIL: $1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$M" ] || fail "model-ladder.json missing"
jq -e . "$M" >/dev/null 2>&1 || fail "model-ladder.json is not valid JSON"
pass "manifest present + valid"

TIERS=$(jq -r '.tiers|join(" ")' "$M" | tr -d '\r')
[ "$TIERS" = "fast mid deep" ] || fail "tiers unexpected: $TIERS"
pass "tiers = fast mid deep"

ALIASES=$(jq -r '.dispatch_aliases|join(" ")' "$M" | tr -d '\r')
[ "$ALIASES" = "haiku sonnet opus fable" ] || fail "dispatch_aliases unexpected: $ALIASES"
pass "dispatch_aliases = the live-tested enum"

# every surface x tier ladder is non-empty
EMPTY=$(jq -r '.ladders|to_entries[]|.key as $s|.value|to_entries[]|select((.value|length)==0)|"\($s).\(.key)"' "$M" | tr -d '\r')
[ -z "$EMPTY" ] || fail "empty ladder(s):" "$EMPTY"
pass "no empty ladders"

# ALIAS-FIRST invariant: rung 0 of every ladder is a bare alias, never a pinned ID
BADFIRST=$(jq -r '.dispatch_aliases as $a|.ladders|to_entries[]|.key as $s|.value|to_entries[]
  |select((.value[0] as $f|$a|index($f))==null)|"\($s).\(.key)=\(.value[0])"' "$M" | tr -d '\r')
[ -z "$BADFIRST" ] || fail "ladder does not lead with an alias:" "$BADFIRST"
pass "alias-first invariant holds on every ladder"

# dispatch ladders may contain ONLY aliases (schema enum)
BADDISPATCH=$(jq -r '.dispatch_aliases as $a|.ladders.dispatch|to_entries[]
  |.key as $t|.value[]|select(($a|index(.))==null)|"\($t)=\(.)"' "$M" | tr -d '\r')
[ -z "$BADDISPATCH" ] || fail "dispatch ladder contains a non-alias (rejected at schema level):" "$BADDISPATCH"
pass "dispatch ladders are alias-only"

# every tier declares at least one pin env, and SB_MODEL_TIER_<TIER> is its first
for t in fast mid deep; do
  U=$(echo "$t" | tr 'a-z' 'A-Z')
  P=$(jq -r --arg t "$t" '.pins[$t][0] // ""' "$M" | tr -d '\r')
  [ "$P" = "SB_MODEL_TIER_$U" ] || fail "pins.$t[0] != SB_MODEL_TIER_$U (got '$P')"
done
pass "each tier's first pin env is SB_MODEL_TIER_<TIER>"

# TS mirror re-exports the manifest (no second copy of the data)
TS="$ROOT/mcp/src/constants/model-ladder.ts"
[ -f "$TS" ] || fail "mcp/src/constants/model-ladder.ts missing"
grep -q 'from "../../../model-ladder.json"' "$TS" \
  || fail "TS mirror does not import the repo-root manifest (it must never re-declare the data)"
for sym in TIERS SURFACES DISPATCH_ALIASES LADDERS PIN_ENVS PROTOCOL_NAMES; do
  grep -q "export const $sym" "$TS" || fail "TS mirror missing export: $sym"
done
pass "TS mirror imports the manifest and exports the six symbols"

# TRIPWIRE: no model-ID literal anywhere except the manifest. This is the guard that stops the
# whole bug class from regressing once the immediate pain is gone — a future call site that
# hardcodes a version fails the suite instead of shipping and breaking on a restricted org.
LIT=$(grep -rnE 'claude-(opus|sonnet|haiku|fable|mythos)-[0-9]' \
        "$ROOT/scripts" "$ROOT/skills" "$ROOT/agents" "$ROOT/mcp/src" "$ROOT/hooks" 2>/dev/null \
        | grep -vF 'model-ladder' || true)
[ -z "$LIT" ] && pass "no model-ID literal outside the manifest" \
  || fail "model-ID literal found (add a rung to model-ladder.json instead):" "$LIT"

echo; echo "ALL PASS"
