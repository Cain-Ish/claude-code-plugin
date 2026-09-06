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

# R3 PATH-stub (idiom copied from tests/test-normalize-path.sh): the real
# `claude plugin validate` costs ~2s per invocation and dominates this suite's wall
# time (~34s). Every subtest asserts validate-plugin.sh's OWN structural checks
# (jq/grep/file) — so a stub that exits 0 with no output turns the `claude plugin
# validate` block into a no-op for those cases WITHOUT weakening any FAIL assertion
# (each broken fixture still trips the script's own check). The real CLI is still
# exercised once, in the dedicated real-CLI case (Case 1).
STUB_BIN="$SANDBOX/stubbin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$STUB_BIN/claude"

PASS=0
FAIL=0
PLUGIN_FOR_VALIDATOR=""

setup_skeleton() {
  local root="$SANDBOX/plugin"
  rm -rf "$root"
  mkdir -p "$root/.claude-plugin" "$root/hooks" "$root/scripts" \
           "$root/skills/setup" "$root/skills/improve" "$root/agents" \
           "$root/mcp"

  # Baseline fixture must be a COMPLETE, valid manifest (incl. author) so that
  # `claude plugin validate --strict` — which treats manifest-completeness
  # warnings as errors — passes on the unbroken skeleton. Each subtest then
  # breaks exactly ONE thing and asserts the validator catches that.
  cat > "$root/.claude-plugin/plugin.json" <<'JSON'
{"name":"x","description":"y","version":"0.0.0","author":{"name":"test"},"mcpServers":"./.claude-plugin/mcp.json"}
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

  # D185: every tracked surface — including output_styles — needs an explicit
  # numeric cap; a key missing here now FAILS the validator (see case below),
  # so the baseline fixture must carry all five even though this skeleton
  # doesn't use outputStyles at all.
  cat > "$root/.claude-plugin/surface-budget.json" <<'JSON'
{"skills": 99, "agents": 99, "scripts": 99, "tests": 99, "output_styles": 99, "upgrade_skill_max_bytes": 999999}
JSON

  cat > "$root/skills/setup/SKILL.md" <<'MD'
---
name: setup
description: Setup
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(echo *)
---
body
MD

  cat > "$root/skills/improve/SKILL.md" <<'MD'
---
name: improve
description: Improve
user-invocable: true
disable-model-invocation: false
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

  cat > "$root/.claude-plugin/mcp.json" <<'JSON'
{"mcpServers":{"knowledge-base":{"type":"stdio","command":"node","args":["${CLAUDE_PLUGIN_ROOT}/mcp/dist/server.bundle.js"],"alwaysLoad":true}}}
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
  local name="$1" expected_exit="$2" real_cli="${3:-}"
  local actual_exit stub_prefix="$STUB_BIN:"
  # Dedicated real-CLI case: leave PATH untouched so the real `claude` is found.
  [ "$real_cli" = "real" ] && stub_prefix=""
  PATH="$stub_prefix$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_FOR_VALIDATOR" bash "$SCRIPT" >"$SANDBOX/out" 2>&1
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

# Case 1: clean skeleton passes. DEDICATED real-CLI case — runs the real
# `claude plugin validate --strict` end-to-end against a valid plugin so the CLI
# integration stays covered. Every other case stubs claude for speed (see run_case).
setup_skeleton
run_case "clean skeleton passes" 0 real

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
rm "$PLUGIN_FOR_VALIDATOR/.claude-plugin/mcp.json"
run_case "missing .claude-plugin/mcp.json fails" 1
assert_output_contains "FAIL: required file missing: .claude-plugin/mcp.json"

# Case 7: corrupt mcp/package.json → FAIL
setup_skeleton
echo "{ not json" > "$PLUGIN_FOR_VALIDATOR/mcp/package.json"
run_case "corrupt mcp/package.json fails" 1
assert_output_contains "FAIL: mcp/package.json is not valid JSON"

# Case 6b: the ${CLAUDE_PLUGIN_ROOT:-.} default form → FAIL. Claude Code substitutes
# ONLY the bare ${CLAUDE_PLUGIN_ROOT} token to an absolute path; the ${VAR:-default}
# shell form is NOT applied, so the path collapses to cwd-relative and the server
# starts only inside the plugin dir (the P0). (0.24.35 inverts the backwards 0.24.5 guard.)
setup_skeleton
printf '%s\n' '{"mcpServers":{"kb":{"type":"stdio","command":"node","args":["${CLAUDE_PLUGIN_ROOT:-.}/mcp/dist/server.bundle.js"]}}}' \
  > "$PLUGIN_FOR_VALIDATOR/.claude-plugin/mcp.json"
run_case "\${CLAUDE_PLUGIN_ROOT:-.} default in mcp.json fails" 1
assert_output_contains "not anchored by"
# Case 6c: a bare relative bundle path (no var at all) is the SAME cwd-relative bug
# shape and must ALSO fail — a guard that only rejects the :- form would miss it.
setup_skeleton
printf '%s\n' '{"mcpServers":{"kb":{"type":"stdio","command":"node","args":["mcp/dist/server.bundle.js"]}}}' \
  > "$PLUGIN_FOR_VALIDATOR/.claude-plugin/mcp.json"
run_case "bare relative bundle path in mcp.json fails" 1
assert_output_contains "not anchored by"
# and the bare ${CLAUDE_PLUGIN_ROOT}/ form (the only one CC substitutes) passes the check
setup_skeleton
printf '%s\n' '{"mcpServers":{"kb":{"type":"stdio","command":"node","args":["${CLAUDE_PLUGIN_ROOT}/mcp/dist/server.bundle.js"]}}}' \
  > "$PLUGIN_FOR_VALIDATOR/.claude-plugin/mcp.json"
run_case "bare \${CLAUDE_PLUGIN_ROOT} in mcp.json passes" 0
assert_output_contains "OK: all plugin files valid"

# Case 6d: a root .mcp.json must NOT exist — it is double-read as a project-scoped
# MCP config (CLAUDE_PLUGIN_ROOT unset there) and reintroduces the startup failure.
# The manifest must live at .claude-plugin/mcp.json, referenced from plugin.json.
setup_skeleton
printf '%s\n' '{"mcpServers":{}}' > "$PLUGIN_FOR_VALIDATOR/.mcp.json"
run_case "root .mcp.json present fails" 1
assert_output_contains "root .mcp.json"

# Case 6e: plugin.json must wire the relocated manifest via "mcpServers" — the file
# is no longer auto-discovered the way a root .mcp.json would be, so without the
# reference CC never loads the server.
setup_skeleton
jq 'del(.mcpServers)' "$PLUGIN_FOR_VALIDATOR/.claude-plugin/plugin.json" > "$PLUGIN_FOR_VALIDATOR/.claude-plugin/plugin.json.tmp"
mv "$PLUGIN_FOR_VALIDATOR/.claude-plugin/plugin.json.tmp" "$PLUGIN_FOR_VALIDATOR/.claude-plugin/plugin.json"
run_case "plugin.json missing mcpServers reference fails" 1
assert_output_contains 'plugin.json has no "mcpServers"'

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

# Case 11b: a surface-budget.json missing a tracked key (D185) must FAIL, not
# silently skip that surface's cap entirely — the old `continue`-on-empty
# behavior let an unbudgeted (or typo'd) key grow without limit forever.
setup_skeleton
jq 'del(.tests)' "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json" > "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json.tmp"
mv "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json.tmp" "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json"
run_case "surface-budget.json missing a tracked key fails" 1
assert_output_contains "surface-budget.json has no 'tests' key"

# Case 11c: a non-numeric value for a tracked key (D185) must ALSO FAIL — same
# silent-skip bug, different corruption shape (typo, string, null-as-string).
setup_skeleton
jq '.scripts = "many"' "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json" > "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json.tmp"
mv "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json.tmp" "$PLUGIN_FOR_VALIDATOR/.claude-plugin/surface-budget.json"
run_case "surface-budget.json non-numeric value fails" 1
assert_output_contains "surface-budget.json key 'scripts' is not numeric"

# Case 12: the SHIPPED tree must validate with ZERO WARN lines.
# A WARN that nobody clears is worse than no check: `SESSION_START_MATCHERS` froze at
# "startup|resume|clear|compact" while hooks.json moved to "startup|resume|clear|fork" in
# 0.34.0, so validate-plugin warned on EVERY run for ~11 releases and the noise became
# invisible. `fork` is a real SessionStart source (code.claude.com/docs/en/hooks lists
# startup, resume, clear, compact, fork); the validator's list was simply stale. This case
# binds the real tree, not a fixture, so any future drift of this class fails instead of
# warning forever. ORACLE: the shipped hooks.json + the shipped validator.
real_out=$(PATH="$STUB_BIN:$PATH" bash "$SCRIPT" "$REPO_ROOT" 2>&1)
real_ec=$?
warns=$(printf '%s\n' "$real_out" | grep -c '^WARN:' || true)
if [ "$real_ec" -eq 0 ] && [ "$warns" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "PASS: shipped tree validates with no WARN lines"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: shipped tree — exit $real_ec, $warns WARN line(s); a standing WARN must be fixed, not tolerated"
  printf '%s\n' "$real_out" | grep -E '^(WARN|FAIL):' | head -5
fi
echo "-----------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
