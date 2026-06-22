#!/bin/bash
# Tests session-load.sh persona injection at SessionStart:
#   - the FULL persona-card + installed-catalog are NOT injected (removed 0.32.0 as a redundant
#     USER.md paraphrase / per-session noise); USER.md (force-emitted) carries the identity.
#   - EXCEPT the persona-card's ## Charter, which IS injected once per session (0.33.8) — the
#     standing operating ethos, NEW content not in USER.md, so the partnership ethos actively
#     governs every session. persona-card.md is seeded by persona-context.sh / setup.
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

init_sandbox() {
  local name="$1"
  SANDBOX="$TMP/$name"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain/projects/test-slug" \
           "$SANDBOX/repo/test-slug"
  export HOME="$SANDBOX"
  export BRAIN_DIR="$SANDBOX/.second-brain"
  cd "$SANDBOX/repo/test-slug" || fail "cd failed in $name"
  cat > "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" <<'EOF'
# PROJECT: test-slug
## Goal
seeded.
EOF
}

run_session_load() {
  jq -nc --arg cwd "$SANDBOX/repo/test-slug" \
    '{session_id:"x", cwd:$cwd, hook_event_name:"SessionStart"}' \
    | bash "$SCRIPT" 2>/dev/null
}

# --- Test 1 (inverted): persona-card present → NOT injected at SessionStart -----------
init_sandbox "no-persona-emit"
cat > "$BRAIN_DIR/persona-card.md" <<'EOF'
# Persona

## Identity
- sessionstart-test-marker
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'sessionstart-test-marker' \
  && fail "persona-card must NOT be injected at SessionStart in 0.32.0 (got: $OUT)"
echo "$OUT" | grep -q 'Persona (loaded at session start' \
  && fail "persona-card session-start header must be gone (got: $OUT)"
pass "persona-card is NOT injected at SessionStart (removed in 0.32.0)"

# --- Test 2 (inverted): installed-catalog present → NOT injected --------------------
init_sandbox "no-catalog-emit"
cat > "$BRAIN_DIR/.installed-catalog.json" <<'EOF'
{ "plugins": [{"name":"second-brain"}], "agents": [{"name":"a1"}], "skills": [{"name":"s1"}] }
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'Installed specialists:' \
  && fail "installed-catalog must NOT be injected at SessionStart in 0.32.0 (got: $OUT)"
pass "installed-catalog is NOT injected at SessionStart (removed in 0.32.0)"

# --- Test 3 (positive control): USER.md IS still loaded (the identity path that replaced it) --
init_sandbox "user-md-loads"
cat > "$BRAIN_DIR/USER.md" <<'EOF'
# User Profile

## Hard Rules
- user-md-identity-marker
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'user-md-identity-marker' \
  || fail "USER.md identity must still load at SessionStart (got: $OUT)"
pass "USER.md identity still loads at SessionStart (replaces the per-session card)"

# --- Test 4 (0.33.8): the persona ## Charter (and ONLY it) IS injected at SessionStart -------
init_sandbox "charter-emit"
cat > "$BRAIN_DIR/persona-card.md" <<'EOF'
# Persona

## Identity
- identity-should-not-emit

## Charter
- charter-marker-knows-when-to-act-and-when-to-step-back

## How to engage me
- engage-should-not-emit
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'charter-marker-knows-when-to-act-and-when-to-step-back' \
  || fail "persona ## Charter must be injected at SessionStart in 0.33.8 (got: $OUT)"
echo "$OUT" | grep -q 'identity-should-not-emit' \
  && fail "only the Charter section may emit, not Identity (got: $OUT)"
echo "$OUT" | grep -q 'engage-should-not-emit' \
  && fail "only the Charter section may emit, not later sections (got: $OUT)"
pass "persona ## Charter IS injected at SessionStart; other card sections stay out"

echo
echo "ALL PASS"
