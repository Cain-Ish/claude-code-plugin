#!/usr/bin/env bash
# Enforce the R6 release policy: release narrative lives in the release commit
# body (pre-1.0 diet — the old CHANGELOG.md is preserved on the archive/docs
# branch); a release with a real precondition/action gets
# skills/upgrade/migrations/<version>.md (which the upgrade runner
# context-loads only for hops that cross it). And the runner SKILL.md itself
# must stay lean — it regrew to 113KB once (44K tokens loaded per
# /second-brain:upgrade) before the R6 split.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# Migration files must parse as the runner expects: <semver>.md only.
BAD=$(ls "$ROOT/skills/upgrade/migrations/" 2>/dev/null | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.md$' || true)
[ -z "$BAD" ] || fail "non-semver file(s) in skills/upgrade/migrations/: $BAD"
echo "PASS: migrations/ contains only <version>.md files"

# The lean-runner cap (R6): SKILL.md must never regrow into a changelog.
BYTES=$(wc -c < "$ROOT/skills/upgrade/SKILL.md" | tr -d ' ')
[ "$BYTES" -le 8192 ] \
  || fail "skills/upgrade/SKILL.md is ${BYTES}B (cap 8192) — release narrative belongs in the release commit body, actions in migrations/<version>.md"
echo "PASS: upgrade SKILL.md within the 8KB lean-runner cap (${BYTES}B)"

echo "ALL PASS"
