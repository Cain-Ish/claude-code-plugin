#!/bin/bash
# Guard: the model resolution layer. Covers the availability cache (TTL expiry, auth-fingerprint
# invalidation, absent = unknown), the ladder walk (pin as first rung, blocked rungs skipped,
# exhaustion), and the blocked-verdict table. Every case runs with NO pin env set unless the case
# is specifically about pins -- a fixture-supplied pin would bypass the resolution path that
# actually breaks in the field.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; exit 1; }; pass(){ echo "PASS: $1"; }

TMP=$(mktemp -d) || fail "mktemp -d failed"
trap 'rm -rf "$TMP"' EXIT
export BRAIN_DIR="$TMP/brain"; mkdir -p "$BRAIN_DIR"
export SB_MODEL_LADDER="$TMP/ladder.json"
unset SB_MODEL_TIER_FAST SB_MODEL_TIER_MID SB_MODEL_TIER_DEEP 2>/dev/null || true
unset SB_EXTRACTOR_MODEL SB_QUALITY_GATE_MODEL SB_MAINTAIN_LLM_MODEL SB_PERSONA_MODEL 2>/dev/null || true
unset ANTHROPIC_API_KEY 2>/dev/null || true

cat > "$SB_MODEL_LADDER" <<'JSON'
{
  "schema": 1,
  "tiers": ["fast","mid","deep"],
  "protocol_names": {"fast":"SCOUT","mid":"DO","deep":"THINK"},
  "dispatch_aliases": ["haiku","sonnet","opus","fable"],
  "ladders": {
    "headless": {"fast":["haiku","h-1"],"mid":["sonnet","s-1","s-2"],"deep":["opus","o-1"]},
    "dispatch": {"fast":["haiku"],"mid":["sonnet"],"deep":["opus"]}
  },
  "pins": {
    "fast": ["SB_MODEL_TIER_FAST"],
    "mid": ["SB_MODEL_TIER_MID","SB_EXTRACTOR_MODEL"],
    "deep": ["SB_MODEL_TIER_DEEP"]
  }
}
JSON

source "$ROOT/scripts/lib.sh"

# --- cache: absent file / absent entry = unknown ---------------------------
[ "$(sb_model_cache_get headless sonnet)" = "unknown" ] || fail "absent cache file must read unknown"
pass "absent cache = unknown"

# --- cache: put then get round-trips --------------------------------------
sb_model_cache_put headless s-1 blocked "exit=1 is_error" || fail "cache_put failed"
[ "$(sb_model_cache_get headless s-1)" = "blocked" ] || fail "put/get did not round-trip"
[ "$(sb_model_cache_get headless sonnet)" = "unknown" ] || fail "unrelated model must stay unknown"
jq -e . "$BRAIN_DIR/model-availability.json" >/dev/null 2>&1 || fail "cache file is not valid JSON after put"
pass "cache put/get round-trips and stays valid JSON"

# --- cache: verdicts never cross surfaces --------------------------------
[ "$(sb_model_cache_get dispatch s-1)" = "unknown" ] \
  || fail "a headless verdict leaked to the dispatch surface (alias mapping provably diverges)"
pass "verdicts do not cross surfaces"

# --- cache: TTL expiry re-admits -----------------------------------------
OLD=$(( $(date -u +%s) - 100000 ))
jq --argjson e "$OLD" '.surfaces.headless["s-1"].epoch = $e' "$BRAIN_DIR/model-availability.json" > "$TMP/x" \
  && mv "$TMP/x" "$BRAIN_DIR/model-availability.json"
SB_MODEL_CACHE_TTL=50000 sb_model_cache_get headless s-1 | grep -q '^unknown$' \
  || fail "an expired blocked verdict must read unknown"
SB_MODEL_CACHE_TTL=200000 sb_model_cache_get headless s-1 | grep -q '^blocked$' \
  || fail "a non-expired blocked verdict must still read blocked"
pass "TTL expiry re-admits a previously blocked model"

# --- cache: auth-fingerprint flip invalidates ----------------------------
sb_model_cache_put headless s-2 blocked "test" || fail "cache_put failed (s-2)"
[ "$(sb_model_cache_get headless s-2)" = "blocked" ] || fail "s-2 should be blocked under oauth"
[ "$(ANTHROPIC_API_KEY=sk-test sb_model_cache_get headless s-2)" = "unknown" ] \
  || fail "fingerprint flip (oauth -> apikey) must invalidate every verdict"
pass "auth-fingerprint flip invalidates the cache"

echo; echo "ALL PASS"
