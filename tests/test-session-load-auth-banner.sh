#!/usr/bin/env bash
# Verify the SessionStart auth-mode banner block in scripts/session-load.sh
# emits the right text for each of the three auth modes, and is suppressible
# via SB_AUTH_LINE=off.
#
# Strategy: extract the banner block (lines between sentinel markers) into a
# tiny standalone runner that uses the lightweight sb_append shim defined
# inline. Avoids running the full session-load.sh (which depends on jq,
# project state, persona signals, etc.).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$SCRIPT_DIR/scripts/session-load.sh"

# Extract the banner block. Anchors: "# 0a-bis. Auth-mode line" to first "# 0b."
BLOCK=$(awk '
  /^# 0a-bis\. Auth-mode line/ {p=1}
  p {print}
  p && /^# 0b\./ {exit}
' "$SOURCE" | sed '$d')   # drop the trailing "# 0b." marker

[ -n "$BLOCK" ] || { echo "FAIL: could not extract auth banner block"; exit 1; }

# Build a tiny runner that defines sb_append as a stdout-only stub and runs
# the extracted block under whatever env we pass in.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/runner.sh" <<'EOF'
sb_append() {
  # $1 = body, $2 = source-tag, $3 = byte cap. Print tag-prefixed lines.
  printf '[%s]\n%s\n' "$2" "$1"
}
EOF
echo "$BLOCK" >> "$TMP/runner.sh"

run_with() {
  env -i HOME="$HOME" PATH="$1" "${@:2}" bash "$TMP/runner.sh"
}

# Mode 1: API key set → api-key line
out=$(run_with "$PATH" ANTHROPIC_API_KEY="sk-ant-test-1234567890")
echo "$out" | grep -q "mode: api-key" \
  || { echo "FAIL Mode 1: expected 'mode: api-key', got:"; echo "$out"; exit 1; }
echo "$out" | grep -q "sk-ant-tes" \
  || { echo "FAIL Mode 1: expected key prefix, got:"; echo "$out"; exit 1; }
# Key full value must NOT be leaked
echo "$out" | grep -q "sk-ant-test-1234567890" \
  && { echo "FAIL Mode 1: full API key leaked into banner"; exit 1; }
echo "PASS Mode 1: api-key banner emits prefix only"

# Mode 2: no key, claude on PATH (use real claude location)
# Build a tmp dir with a stub `claude` executable.
mkdir -p "$TMP/claudebin"
cat > "$TMP/claudebin/claude" <<'CL'
#!/usr/bin/env bash
exit 0
CL
chmod +x "$TMP/claudebin/claude"
out=$(run_with "$TMP/claudebin:$PATH")
echo "$out" | grep -q "mode: subscription" \
  || { echo "FAIL Mode 2: expected 'mode: subscription', got:"; echo "$out"; exit 1; }
echo "$out" | grep -qE "recursive-claude|OAuth" \
  || { echo "FAIL Mode 2: expected recursive-claude/OAuth note, got:"; echo "$out"; exit 1; }
echo "PASS Mode 2: subscription banner emits OAuth limitation"

# Mode 3: no key, no claude on PATH
# Strip claude from PATH by passing only /usr/bin etc.
out=$(run_with "/usr/bin:/bin")
echo "$out" | grep -q "mode: none" \
  || { echo "FAIL Mode 3: expected 'mode: none', got:"; echo "$out"; exit 1; }
echo "PASS Mode 3: none banner emits sb auth doctor hint"

# Mode 4: SB_AUTH_LINE=off → empty output
out=$(run_with "$PATH" ANTHROPIC_API_KEY="sk-ant-x" SB_AUTH_LINE=off)
[ -z "$(echo "$out" | grep -E 'mode:')" ] \
  || { echo "FAIL Mode 4: SB_AUTH_LINE=off did not suppress, got:"; echo "$out"; exit 1; }
echo "PASS Mode 4: SB_AUTH_LINE=off suppresses banner"

echo "ALL PASS"
