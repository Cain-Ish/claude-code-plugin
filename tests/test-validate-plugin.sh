#!/bin/bash
# Smoke test for scripts/validate-plugin.sh.
# Builds an isolated minimal plugin skeleton in a temp dir and asserts:
#   - clean skeleton passes
#   - bad hooks.json (invalid JSON / missing matcher / matcher on no-matcher event) fails or warns
#   - missing runtime-referenced file fails
#   - bad shell-script syntax fails
#   - skill missing frontmatter fails
# Usage: bash tests/test-validate-plugin.sh

set -u

# Preconditions
for cmd in jq mktemp bash; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "test prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-plugin.sh"
TMPDIR_BASE="${TMPDIR:-/tmp}"
SANDBOX=$(mktemp -d "$TMPDIR_BASE/second-brain-validate-plugin.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
PLUGIN_FOR_VALIDATOR=""

setup_skeleton() {
  local root="$SANDBOX/plugin"
  rm -rf "$root"
  mkdir -p "$root/.claude-plugin" "$root/hooks" "$root/scripts" \
           "$root/skills/setup" "$root/skills/improve" "$root/agents" \
           "$root/mcp" "$root/docs"

  cat > "$root/.claude-plugin/plugin.json" <<'JSON'
{"name":"x","description":"y","version":"0.0.0"}
JSON

  cat > "$root/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup|resume|clear|compact", "hooks": [{"type":"command","command":"echo hi"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type":"command","command":"echo hi"}]}
    ]
  }
}
JSON

  cat > "$root/scripts/dummy.sh" <<'SH'
#!/bin/bash
exit 0
SH

  cat > "$root/skills/setup/SKILL.md" <<'MD'
---
name: setup
description: Setup
allowed-tools: Read Bash(echo *)
---
body
MD

  cat > "$root/skills/improve/SKILL.md" <<'MD'
---
name: improve
description: Improve
allowed-tools: Read Bash(echo *)
---
body
MD

  # Runtime-referenced files
  cat > "$root/scripts/improve-protocol.md" <<'MD'
# Improve protocol
MD
  cat > "$root/skills/improve/signal-patterns.md" <<'MD'
# Signal patterns
MD
  cat > "$root/docs/reflection-protocol.md" <<'MD'
# Reflection protocol
MD

  cat > "$root/.mcp.json" <<'JSON'
{"mcpServers":{}}
JSON
  cat > "$root/mcp/package.json" <<'JSON'
{"name":"x","version":"0.0.0"}
JSON

  cat > "$root/agents/foo.md" <<'MD'
---
name: foo
description: Foo
---
MD

  PLUGIN_FOR_VALIDATOR="$root"
}

run_case() {
  local name="$1" expected_exit="$2"
  local actual_exit
  CLAUDE_PLUGIN_ROOT="$PLUGIN_FOR_VALIDATOR" bash "$SCRIPT" >"$SANDBOX/out" 2>&1
  actual_exit=$?
  if [ "$actual_exit" = "$expected_exit" ]; then
    PASS=$((PASS + 1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL  $name (exit=$actual_exit expected=$expected_exit)"
    sed 's/^/        /' "$SANDBOX/out"
  fi
}

assert_output_contains() {
  local needle="$1"
  if grep -qF "$needle" "$SANDBOX/out"; then
    PASS=$((PASS + 1))
    echo "  PASS  output contains: $needle"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL  output missing: $needle"
    sed 's/^/        /' "$SANDBOX/out"
  fi
}

echo "test-validate-plugin.sh"
echo "-----------------------"

# Case 1: clean skeleton passes
setup_skeleton
run_case "clean skeleton passes" 0

# Case 2: bad hooks.json JSON
setup_skeleton
echo "{ not json" > "$PLUGIN_FOR_VALIDATOR/hooks/hooks.json"
run_case "invalid hooks.json fails" 1

# Case 3: SessionStart with undocumented matcher → WARN (still exit 0)
setup_skeleton
cat > "$PLUGIN_FOR_VALIDATOR/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type":"command","command":"echo hi"}]}
    ]
  }
}
JSON
run_case "SessionStart matcher '*' passes with warn" 0
assert_output_contains "WARN: hooks.json SessionStart"

# Case 4: UserPromptSubmit with matcher → WARN (still exit 0)
setup_skeleton
cat > "$PLUGIN_FOR_VALIDATOR/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "foo", "hooks": [{"type":"command","command":"echo hi"}]}
    ]
  }
}
JSON
run_case "UserPromptSubmit with matcher passes with warn" 0
assert_output_contains "WARN: hooks.json UserPromptSubmit"

# Case 5: PreCompact missing matcher → FAIL
setup_skeleton
cat > "$PLUGIN_FOR_VALIDATOR/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "PreCompact": [
      {"hooks": [{"type":"command","command":"echo hi"}]}
    ]
  }
}
JSON
run_case "PreCompact without matcher fails" 1
assert_output_contains "FAIL: hooks.json PreCompact"

# Case 6: missing runtime-referenced file → FAIL
setup_skeleton
rm "$PLUGIN_FOR_VALIDATOR/.mcp.json"
run_case "missing .mcp.json fails" 1
assert_output_contains "FAIL: required file missing: .mcp.json"

# Case 7: corrupt mcp/package.json → FAIL
setup_skeleton
echo "{ not json" > "$PLUGIN_FOR_VALIDATOR/mcp/package.json"
run_case "corrupt mcp/package.json fails" 1
assert_output_contains "FAIL: mcp/package.json is not valid JSON"

# Case 8: bad shell-script syntax → FAIL
setup_skeleton
echo "if then fi" > "$PLUGIN_FOR_VALIDATOR/scripts/dummy.sh"
run_case "shell-script syntax error fails" 1
assert_output_contains "has syntax errors"

# Case 9: SessionStart with two matcher groups (clear + full) → passes
setup_skeleton
cat > "$PLUGIN_FOR_VALIDATOR/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "clear", "hooks": [{"type":"command","command":"echo pre-clear"}]},
      {"matcher": "startup|resume|clear|compact", "hooks": [{"type":"command","command":"echo hi"}]}
    ]
  }
}
JSON
run_case "SessionStart with two matcher groups passes" 0

# Case 10: SKILL.md missing frontmatter → FAIL
setup_skeleton
echo "no frontmatter" > "$PLUGIN_FOR_VALIDATOR/skills/setup/SKILL.md"
run_case "skill missing frontmatter fails" 1
assert_output_contains "missing YAML frontmatter"

# Case 11: a body-level '---' thematic break must NOT leak into the parsed
# frontmatter. Here the real frontmatter (name, description) is missing
# allowed-tools; only a body section between two body '---' dividers contains
# it. A sed start/end range re-captures that body line and FALSE-PASSes the
# required-field check; the parser must stop at the first closing delimiter.
setup_skeleton
cat > "$PLUGIN_FOR_VALIDATOR/skills/setup/SKILL.md" <<'MD'
---
name: setup
description: Setup
---
intro body
---
allowed-tools: Read Bash(echo *)
---
more body
MD
run_case "body '---' divider does not leak into frontmatter" 1
assert_output_contains "setup/SKILL.md missing 'allowed-tools'"

echo "-----------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
