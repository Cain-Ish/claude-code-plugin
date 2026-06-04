#!/bin/bash
# End-to-end: raw-scan-cli previews + captures high-signal docs into a project's raw inbox,
# honors git-ignore, dedups on re-run; the setup skill wires the CLI.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
CLI="$ROOT/mcp/dist/tools/raw-scan-cli.bundle.js"
SKILL="$ROOT/skills/setup/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

grep -q 'raw-scan-cli.bundle.js' "$SKILL" || fail "setup skill does not invoke raw-scan-cli"
grep -qE 'allowed-tools:.*Bash\(node \*\)' "$SKILL" || fail "setup skill missing Bash(node *) allowed-tool"
# The preview and capture are separate bash fences (separate shells), so each must recompute
# SCAN_ROOT_DIR itself — the `SCAN_ROOT_DIR=$(git rev-parse ...)` assignment must appear twice
# (once per fence). A single occurrence means the capture fence references an unset var and the
# scan silently does nothing. (Step 1's slug uses a different assignment, so it isn't counted.)
N_ROOT=$(grep -cE 'SCAN_ROOT_DIR=\$\(git rev-parse' "$SKILL")
[ "${N_ROOT:-0}" -ge 2 ] || fail "setup capture fence does not recompute SCAN_ROOT_DIR (found $N_ROOT, need >=2)"
pass "setup skill wires the scan CLI (preview + capture both self-contained)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node"; echo; echo "ALL PASS"; exit 0; }
[ -f "$CLI" ] || { echo "SKIP: CLI bundle not built"; echo; echo "ALL PASS"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo; echo "ALL PASS"; exit 0; }

T=$(mktemp -d); export BRAIN_DIR="$T" SB_ACTIVE_SLUG=demo
mkdir -p "$T/projects/demo"; : > "$T/projects/demo/PROJECT.md"
R=$(mktemp -d)
( cd "$R" && git init -q && git config user.email t@t && git config user.name t )
printf '# Readme\nx\n' > "$R/README.md"
mkdir -p "$R/docs"; printf '# G\nx\n' > "$R/docs/guide.md"; printf '# sec\nx\n' > "$R/docs/secret-ignored.md"
printf 'docs/secret-ignored.md\n' > "$R/.gitignore"   # git-ignored → must be excluded

OUT=$(SCAN_ROOT="$R" node "$CLI" --dry-run)
echo "$OUT" | grep -q 'README.md' || fail "dry-run missing README.md ($OUT)"
echo "$OUT" | grep -q 'docs/guide.md' || fail "dry-run missing docs/guide.md"
echo "$OUT" | grep -q 'secret-ignored' && fail "dry-run included a git-ignored file"
[ -z "$(ls -A "$T/projects/demo/raw" 2>/dev/null)" ] || fail "dry-run wrote items"
pass "dry-run previews high-signal docs, excludes git-ignored, writes nothing"

OUT=$(SCAN_ROOT="$R" node "$CLI")
echo "$OUT" | grep -q 'Captured 2, skipped 0' || fail "capture count wrong ($OUT)"
grep -lq '^captured_by: setup-scan$' "$T/projects/demo/raw"/*.md || fail "items not stamped setup-scan"
pass "capture writes 2 setup-scan items"

OUT=$(SCAN_ROOT="$R" node "$CLI")
echo "$OUT" | grep -q 'Captured 0, skipped 2' || fail "re-run not idempotent ($OUT)"
pass "re-run dedups (idempotent)"

rm -rf "$T" "$R"
echo; echo "ALL PASS"
