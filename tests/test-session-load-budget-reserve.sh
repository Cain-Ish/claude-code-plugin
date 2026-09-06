#!/bin/bash
# 0.29.0: forced priority-1 sections (USER.md + PROJECT.md) are emitted `force`
# AFTER the budget-gated banners. Pre-fix, banners could spend up to 8000B and the
# forced content piled on top — pushing total past Claude Code's 10K-char hook
# ceiling, which truncates from the END (exactly the Never/Always rules `force`
# guarantees). The fix RESERVES the forced sections' actual bytes from the banner
# budget. ORACLE: the real output length (a byte fact) + grep for the tail markers.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
. "$ROOT/scripts/lib.sh" >/dev/null 2>&1

STUB=$(mktemp -d); printf '#!/bin/bash\nexit 0\n' >"$STUB/claude"; chmod +x "$STUB/claude"
B=$(mktemp -d); PROJDIR=$(mktemp -d)
SLUG=$(sb_slug_from_dir "$PROJDIR")
mkdir -p "$B/projects/$SLUG" "$B/transcripts"

# Large forced sections, each UNDER its own emit cap (USER 6000, PROJECT 3000) so the
# tail marker isn't lost to the section's own head -c — only the 10K total cap is in play.
# Near-cap forced content (USER < 6000, PROJECT < 3000) so the marker survives each
# section cap; together ~8700B leaves a small banner room under the 9500 HARD_CAP.
{ printf -- '---\ntitle: u\n---\n'; for i in $(seq 1 78); do printf 'Never paste secrets in logs — rule %s, with extra context bytes to fill it.\n' "$i"; done; printf 'NEVER_RULE_TAIL_MARKER\n'; } > "$B/USER.md"
{ printf -- '---\ntitle: p\n---\n'; for i in $(seq 1 52); do printf 'PROJECT decision %s with some descriptive bytes here.\n' "$i"; done; printf 'PROJECT_TAIL_MARKER\n'; } > "$B/projects/$SLUG/PROJECT.md"
touch -t 202001010000 "$B/USER.md"
printf '{"slug":"%s","path":"%s","plan_done":0,"plan_total":0}\n' "$SLUG" "$PROJDIR" > "$B/projects.jsonl"
# A persona-card with a near-cap ## Charter (force-emitted at SessionStart + reserved in the budget)
# plus Identity bullets (non-charter card content is NOT injected). The Charter exercises the THIRD
# forced section so this guard catches the 10K-ceiling regression it would otherwise miss.
{ printf '## Identity\n'; for i in $(seq 1 22); do printf -- '- distinct observed persona pattern number %s with padding bytes here xyz\n' "$i"; done; \
  printf '\n## Charter\n'; for i in $(seq 1 6); do printf -- '- charter ethos bullet %s — partner who knows when to act, padding xyz.\n' "$i"; done; printf -- '- CHARTER_TAIL_MARKER\n'; } > "$B/persona-card.md"
# pile up transcripts + an error-log so several banners (capture / auth / health) fire too
for i in $(seq 1 6); do : > "$B/transcripts/s$i.txt"; done
for i in $(seq 1 5); do printf '{"timestamp":"2026-06-14T00:00:0%sZ","script":"stop-extract.sh","message":"llm-extraction-failed","exit_code":0}\n' "$i"; done > "$B/error-log.jsonl"

OUT=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" bash "$SL" 2>/dev/null)
LEN=${#OUT}
echo "  forced: USER=$(wc -c <"$B/USER.md")B PROJECT=$(wc -c <"$B/projects/$SLUG/PROJECT.md")B → output=${LEN} chars"

[ "$LEN" -le 10000 ] || fail "SessionStart output ${LEN} > 10000 char ceiling — banners crowded forced content past the cap"
pass "total SessionStart output ≤ 10000 (under Claude's hook ceiling)"
printf '%s' "$OUT" | grep -q 'NEVER_RULE_TAIL_MARKER' || fail "USER.md priority-1 tail truncated — the rules force must guarantee"
printf '%s' "$OUT" | grep -q 'PROJECT_TAIL_MARKER' || fail "PROJECT.md tail truncated"
pass "both forced sections (USER.md + PROJECT.md) land INTACT under the cap"
printf '%s' "$OUT" | grep -q 'CHARTER_TAIL_MARKER' \
  || fail "persona ## Charter (the 3rd forced section) did not land at SessionStart"
pass "persona Charter lands at SessionStart, reserved within the 10K ceiling"

# --- section-priority: an over-cap PROJECT.md must still inject its payload ---
# 2026-07 incident: the live PROJECT.md sat at ~8KB while the emit cap is 3000B; the
# blunt head cut kept whatever was at the TOP (Goal/State/Plan) and silently dropped
# Conventions, Recent decisions, and Open blockers — the operational payload the hot
# tier exists to deliver — at EVERY SessionStart. Selection must be by section
# priority, not file order; the State tail is what gives way.
{ printf -- '---\ntitle: p\n---\n# PROJECT: x\n\n## Goal\nGoal line here.\n\n## State\n'
  for i in $(seq 1 80); do printf -- '- state filler %s with plenty of descriptive padding bytes for volume.\n' "$i"; done
  printf -- '- STATE_DEEP_TAIL_MARKER\n\n## Conventions\n- CONVENTION_MARKER keep tests green.\n\n## Recent decisions\n- [decision] DECISION_MARKER chose X.\n\n## Open blockers\n- [active] BLOCKER_MARKER fix Y.\n'
} > "$B/projects/$SLUG/PROJECT.md"
PSZ=$(wc -c < "$B/projects/$SLUG/PROJECT.md" | tr -d ' ')
[ "$PSZ" -gt 3000 ] || fail "fixture too small ($PSZ B) — must exceed the 3000B emit cap"
OUT=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" bash "$SL" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'BLOCKER_MARKER'    || fail "over-cap PROJECT.md: blockers dropped (head-cut instead of section priority)"
printf '%s' "$OUT" | grep -q 'DECISION_MARKER'   || fail "over-cap PROJECT.md: decisions dropped"
printf '%s' "$OUT" | grep -q 'CONVENTION_MARKER' || fail "over-cap PROJECT.md: conventions dropped"
printf '%s' "$OUT" | grep -q 'STATE_DEEP_TAIL_MARKER' && fail "over-cap PROJECT.md: State deep tail survived — nothing was trimmed, cap not honored?"
pass "over-cap PROJECT.md: blockers+decisions+conventions injected; State tail gave way"

# --- D162: a NON-canonical section (outside the fixed $pri list) must be named in
# the breadcrumb when dropped, not vanish silently. The priority loop only ever
# tracks $pri names in `dropped`; a "## Architecture" heading was never added to
# `picked` OR `dropped`, so it disappeared from both the render AND the audit trail.
{ printf -- '---\ntitle: p\n---\n# PROJECT: x\n\n## Goal\nGoal line here.\n\n## Architecture\n'
  for i in $(seq 1 80); do printf -- '- arch filler %s with plenty of descriptive padding bytes for volume.\n' "$i"; done
  printf -- '- ARCH_MARKER\n\n## State\n- STATE_MARKER small.\n\n## Recent decisions\n- [decision] DECISION_MARKER2 chose X.\n\n## Open blockers\n- [active] BLOCKER_MARKER2 fix Y.\n'
} > "$B/projects/$SLUG/PROJECT.md"
PSZ2=$(wc -c < "$B/projects/$SLUG/PROJECT.md" | tr -d ' ')
[ "$PSZ2" -gt 3000 ] || fail "D162 fixture too small ($PSZ2 B) — must exceed the 3000B emit cap"
: > "$B/audit-log.jsonl"
OUT=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" bash "$SL" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'ARCH_MARKER' && fail "D162: Architecture unexpectedly survived — fixture no longer over-cap?"
grep -q 'hot-tier-sections' "$B/audit-log.jsonl" 2>/dev/null || fail "D162: no over-cap breadcrumb at all"
grep -q 'Architecture' "$B/audit-log.jsonl" 2>/dev/null \
  || fail "D162: breadcrumb dropped the non-canonical 'Architecture' section silently (no mention in audit-log)"
pass "D162: a dropped non-canonical section is named in the breadcrumb"

rm -rf "$B" "$PROJDIR" "$STUB"; echo; echo "ALL PASS"
