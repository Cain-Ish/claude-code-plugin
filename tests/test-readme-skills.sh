#!/bin/bash
# Guard: the SP-2/SP-5 skills are documented in the README. They shipped but were initially missing —
# README drift caught by the 0.24.16 whole-product audit. Keep this in sync if user-command skills
# are added. /second-brain:maintain is a command skill. capture is REFERENCE-ONLY since the 0.29.0
# surface-collapse (user-invocable:false, disable-model-invocation:true): nothing can invoke it, so
# the README names the CLI it documents (raw-capture-cli) and never the `/second-brain:capture`
# command. (Q-L8: this guard used to require "second-brain:capture" and passed on any mention.)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; README="$ROOT/README.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
for s in capture maintain; do
  [ -f "$ROOT/skills/$s/SKILL.md" ] || fail "skills/$s/SKILL.md missing (test stale?)"
done
grep -q "/second-brain:maintain" "$README" || fail "README does not document /second-brain:maintain"
grep -q 'raw-capture-cli.bundle.js' "$README" || fail "README does not name raw-capture-cli, the CLI the reference-only capture skill documents"
grep -qF '/second-brain:capture' "$README" \
  && fail "README presents /second-brain:capture as a command; the capture skill is reference-only and nothing can invoke it"
pass "README documents /second-brain:maintain and the capture CLI (raw-capture-cli), never a /second-brain:capture command"

# R6: the 5 de-vendored skills must not be sold as live /second-brain:* commands.
for s in brainstorming writing-plans test-driven-development verification-before-completion systematic-debugging; do
  grep -q "/second-brain:$s" "$ROOT/README.md" \
    && { echo "FAIL: README lists deleted skill /second-brain:$s (de-vendored in 0.24.42)"; exit 1; }
done
echo "PASS: no de-vendored skills in README"

# --- Hook-event count must match hooks.json (0.45.0) --------------------------
# README said "Eight hook events" while hooks.json declared NINE, and omitted
# PostToolUseFailure entirely — so the failure side of the observation ledger, the
# exact error->fix signal it exists to mine, was undocumented for users. Found by the
# 2026-08-21 audit, which fixed this defect class in .claude/skills but scoped its lock
# (tests/test-devdocs-stale-surface.sh) to dev docs only, leaving the USER-facing doc
# unguarded. ORACLE: hooks.json itself, not any prose count.
EVENTS=$(jq -r '.hooks | keys | length' "$ROOT/hooks/hooks.json" 2>/dev/null | tr -d '\r')
case "$EVENTS" in ''|*[!0-9]*) fail "could not read hook-event count from hooks.json" ;; esac
NUMWORD=$(awk -v n="$EVENTS" 'BEGIN{split("zero one two three four five six seven eight nine ten eleven twelve",w," ");print (n<=12? w[n+1] : n)}')
grep -qiE "^${NUMWORD} hook events" "$README" \
  || fail "README's hook-event count disagrees with hooks.json (live: $EVENTS = '$NUMWORD'); update the sentence AND the bullet list"
pass "README hook-event count matches hooks.json ($EVENTS)"

# Every event hooks.json declares must appear by name in the README bullet list. A count
# that matches while an event is missing is the drift that hid PostToolUseFailure.
for ev in $(jq -r '.hooks | keys[]' "$ROOT/hooks/hooks.json" 2>/dev/null | tr -d '\r'); do
  # Anchored to the LIST ITEM, not any bold run: a README could keep "**PostToolUseFailure**"
  # in prose or a heading while deleting its bullet, and an unanchored match would still pass.
  grep -qE "^- \*\*$ev\*\*" "$README" || fail "hooks.json declares '$ev' but README documents no bullet for it"
done
pass "every hooks.json event is documented in README by name"


# D015: a fresh clone wires no local pre-push gate (`git config --get core.hooksPath` is
# empty until `make hook-install` runs), and RELEASING.md's own mention of it is scoped to
# an "after tagging" release-manager checklist — a contributor who never releases would
# never see it. README is the first-contact doc; it must name the one-time setup step.
grep -qi 'make hook-install' "$README" || fail "README does not mention 'make hook-install' (D015: contributors never learn to wire the pre-push gate)"
pass "README documents 'make hook-install' as a contributor setup step"
grep -qi 'make hook-install' "$ROOT/RELEASING.md" || fail "RELEASING.md no longer documents 'make hook-install' (regression)"
pass "RELEASING.md still documents 'make hook-install'"

echo; echo "ALL PASS"
