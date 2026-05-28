#!/bin/bash
# Tests for the C1-B HYBRID SessionStart persona-card emit in session-load.sh.
# The doctrinal path is SessionStart load (Anthropic recommends per-session,
# not per-turn). persona-context.sh keeps a per-turn safety-net emit against
# the v2.10 "persona disappears after turn 1" regression — that emit is tested
# separately in tests/test-persona-context.sh.
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

# --- Test 1: persona-card present → emitted at SessionStart -----------
init_sandbox "persona-emit"
cat > "$BRAIN_DIR/persona-card.md" <<'EOF'
# Persona

## Identity
- sessionstart-test-marker

## Style
- terse
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'sessionstart-test-marker' \
  || fail "persona-card content missing from session-load output (got: $OUT)"
echo "$OUT" | grep -q 'Persona (loaded at session start' \
  || fail "persona-card header missing (got: $OUT)"
pass "persona-card emitted at SessionStart with marker header"

# --- Test 2: no persona-card.md → no persona section emitted ---------
init_sandbox "persona-missing"
OUT=$(run_session_load)
echo "$OUT" | grep -q 'Persona (loaded at session start' \
  && fail "persona-card header should NOT appear when persona-card.md absent (got: $OUT)"
pass "no persona section when persona-card.md missing"

# --- Test 3: SB_PERSONA_GATE=off suppresses the SessionStart emit too --
init_sandbox "kill-switch"
cat > "$BRAIN_DIR/persona-card.md" <<'EOF'
# Persona

## Identity
- should-not-appear
EOF
OUT=$(SB_PERSONA_GATE=off run_session_load)
echo "$OUT" | grep -q 'should-not-appear' \
  && fail "SB_PERSONA_GATE=off should suppress SessionStart persona emit (got: $OUT)"
pass "SB_PERSONA_GATE=off suppresses SessionStart persona emit"

# --- Test 4: USER.md-duplicate bullets stripped from persona section -
init_sandbox "dedup"
cat > "$BRAIN_DIR/USER.md" <<'EOF'
# User Profile

## Hard Rules
- Zero AI attribution in commits
EOF
cat > "$BRAIN_DIR/persona-card.md" <<'EOF'
# Persona

## Identity
- Zero AI attribution in commits
- distinct-card-only-bullet
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'distinct-card-only-bullet' \
  || fail "card-only bullet should appear in persona section (got: $OUT)"
# The duplicate bullet should appear once (from USER.md), not twice.
DUP_COUNT=$(echo "$OUT" | grep -c 'Zero AI attribution in commits')
[ "$DUP_COUNT" -le 1 ] \
  || fail "USER.md-duplicate bullet should be stripped from persona section (count=$DUP_COUNT, got: $OUT)"
pass "USER.md-duplicate bullets stripped from SessionStart persona emit"

# --- Test 5: installed-catalog summary emitted when present ----------
init_sandbox "catalog"
cat > "$BRAIN_DIR/.installed-catalog.json" <<'EOF'
{
  "plugins": [{"name": "second-brain"}, {"name": "ralph-loop"}],
  "agents": [{"name": "a1"}, {"name": "a2"}, {"name": "a3"}],
  "skills": [{"name": "s1"}, {"name": "s2"}]
}
EOF
OUT=$(run_session_load)
echo "$OUT" | grep -q 'Installed specialists:' \
  || fail "catalog summary header missing (got: $OUT)"
echo "$OUT" | grep -q 'second-brain' \
  || fail "plugin name missing from catalog (got: $OUT)"
echo "$OUT" | grep -q '3 agents' \
  || fail "agent count missing (got: $OUT)"
echo "$OUT" | grep -q '2 skills' \
  || fail "skill count missing (got: $OUT)"
pass "installed-catalog summary emitted with plugin + counts"

# --- Test 6: missing catalog file → no catalog line emitted ----------
init_sandbox "no-catalog"
OUT=$(run_session_load)
echo "$OUT" | grep -q 'Installed specialists:' \
  && fail "catalog line should NOT appear when .installed-catalog.json missing (got: $OUT)"
pass "no catalog line when .installed-catalog.json missing"

echo
echo "ALL PASS"
