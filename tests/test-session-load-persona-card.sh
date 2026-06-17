#!/bin/bash
# Tests that session-load.sh NO LONGER injects the persona-card or installed-catalog at
# SessionStart (removed in 0.32.0). USER.md — force-emitted as a priority-1 section — now
# carries the unique identity, so the card was a ~95% paraphrase re-sent every session and the
# catalog was per-session noise. Inverted from the old C1-B HYBRID assertions. persona-card.md
# is still SEEDED by persona-context.sh so persona-stats has a card to summarize.
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

echo
echo "ALL PASS"
