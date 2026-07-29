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

# --- resolver: clean cache returns rung 0 --------------------------------
rm -f "$BRAIN_DIR/model-availability.json"
[ "$(sb_resolve_model mid)" = "sonnet" ] || fail "clean resolve should return rung 0 (sonnet)"
[ "$(sb_resolve_model mid dispatch)" = "sonnet" ] || fail "dispatch surface resolve failed"
[ "$(sb_resolve_model deep)" = "opus" ] || fail "deep resolve should return opus"
pass "clean cache resolves to rung 0 on both surfaces"

# --- resolver: blocked rungs are skipped in order ------------------------
sb_model_cache_put headless sonnet blocked "test"
[ "$(sb_resolve_model mid)" = "s-1" ] || fail "blocked rung 0 must demote to rung 1"
sb_model_cache_put headless s-1 blocked "test"
[ "$(sb_resolve_model mid)" = "s-2" ] || fail "two blocked rungs must demote to rung 2"
pass "blocked rungs are skipped in ladder order"

# --- resolver: exhaustion returns rung 0 AND logs ------------------------
sb_model_cache_put headless s-2 blocked "test"
: > "$BRAIN_DIR/error-log.jsonl"
OUT=$(sb_resolve_model mid)
[ "$OUT" = "sonnet" ] || fail "exhausted ladder must still return rung 0, got '$OUT'"
grep -q 'model-ladder exhausted' "$BRAIN_DIR/error-log.jsonl" \
  || fail "exhaustion must be logged loud (fail loud, never silent)"
pass "exhausted ladder returns rung 0 and logs loud"

# --- resolver: pin becomes the first rung, still demotable ---------------
rm -f "$BRAIN_DIR/model-availability.json"
[ "$(SB_MODEL_TIER_MID=pinned-x sb_resolve_model mid)" = "pinned-x" ] \
  || fail "an operator pin must become rung 0"
[ "$(SB_EXTRACTOR_MODEL=legacy-x sb_resolve_model mid)" = "legacy-x" ] \
  || fail "a legacy per-caller pin must still work (back-compat)"
sb_model_cache_put headless pinned-x blocked "test"
: > "$BRAIN_DIR/error-log.jsonl"
[ "$(SB_MODEL_TIER_MID=pinned-x sb_resolve_model mid)" = "sonnet" ] \
  || fail "a blocked pin must demote rather than strand the operator"
grep -q 'model demotion' "$BRAIN_DIR/error-log.jsonl" \
  || fail "demoting away from an explicit pin must be logged"
pass "pin is rung 0, demotable, and demotion is logged"

# --- resolver: kill switch -----------------------------------------------
[ "$(SB_MODEL_ELASTIC=0 sb_resolve_model mid)" = "sonnet" ] \
  || fail "SB_MODEL_ELASTIC=0 must return rung 0 verbatim"
pass "SB_MODEL_ELASTIC=0 bypasses the ladder"

# --- verdict table --------------------------------------------------------
mkout(){ printf '%s' "$1" > "$TMP/out"; : > "$TMP/err"; }

mkout '{"is_error":true,"subtype":"success","result":"boom"}'
sb_model_blocked_verdict 1 "$TMP/out" "$TMP/err" || fail "exit!=0 + is_error:true must be a blocked verdict"
pass "primary signal: exit!=0 + is_error (subtype lies and must be ignored)"

mkout '{"is_error":false,"subtype":"success","result":"fine"}'
sb_model_blocked_verdict 0 "$TMP/out" "$TMP/err" && fail "a clean success must NOT be a blocked verdict"
pass "clean success is not a blocked verdict"

# Ordering: auth must pre-empt the primary signal even when both are present in the same blob --
# fixtures containing only an auth string can't prove this (they'd pass even if auth ran last).
mkout 'Not logged in. {"is_error":true,"result":"model not found"}'
sb_model_blocked_verdict 1 "$TMP/out" "$TMP/err" \
  && fail "auth signature must win over a co-occurring is_error+model-signature blob"
pass "auth check pre-empts the primary signal when both are present (ordering proof)"

# The wide 8-signature list is diagnostic output from a FAILED spawn (ec != 0) -- it must never
# be trusted on a clean exit, or this plugin's own extractor -- which summarizes sessions about
# model deprecation and API errors -- would blocklist a working model over its own prose.
for sig in "not_found_error" "model not found" "permission_error" \
           "does not have access" "was retired" "is deprecated" "invalid model"; do
  mkout "$sig"
  sb_model_blocked_verdict 1 "$TMP/out" "$TMP/err" || fail "signature not detected: $sig"
done
pass "secondary signatures detected on a failed spawn (non-zero exit)"

mkout "There's an issue with the selected model (claude-3-opus-20240229)"
sb_model_blocked_verdict 0 "$TMP/out" "$TMP/err" \
  || fail "the exit-0 poisoned-output phrase must still be detected after the exit-code split"
pass "exit-0 poisoned-output signature still detected (retired-but-known ID, exit 0)"

# Regression lock: a clean success whose CONTENT discusses model deprecation/not-found in prose
# (exactly what this repo's own extractor produces when summarizing a session about this
# feature) must never be misread as a blocked verdict.
mkout '{"is_error":false,"result":"The old API is deprecated and that model not found error was fixed."}'
sb_model_blocked_verdict 0 "$TMP/out" "$TMP/err" \
  && fail "extractor prose describing deprecation/not-found must NOT be a blocked verdict at exit 0"
pass "clean-exit content mentioning deprecation/not-found is not misread as a blocked verdict"

for authsig in "Not logged in" "please run /login" "Unauthorized" "invalid api key"; do
  mkout "$authsig"
  sb_model_blocked_verdict 1 "$TMP/out" "$TMP/err" && fail "auth failure misread as a model verdict: $authsig"
done
pass "auth failures are NOT model verdicts (auth check runs first)"

echo; echo "ALL PASS"
