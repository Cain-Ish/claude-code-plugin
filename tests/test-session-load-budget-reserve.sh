#!/bin/bash
# pins: SB_REPO_CARD — kill-switch test: asserts =off restores the legacy sb_project_hot_render path
# 0.29.0: forced priority-1 sections (USER.md + PROJECT.md) are emitted `force`
# AFTER the budget-gated banners. Pre-fix, banners could spend up to 8000B and the
# forced content piled on top — pushing total past Claude Code's 10K-char hook
# ceiling, which truncates from the END (exactly the Never/Always rules `force`
# guarantees). The fix RESERVES the forced sections' actual bytes from the banner
# budget. ORACLE: the real output length (a byte fact) + grep for the tail markers.
# repo-brain Slice 2: PROJECT.md's forced content is now the small [Repo card] digest
# (default on) instead of a raw hot-tier dump — the tail marker moves into ## Direction,
# the section sb_project_hot_render's OWN priority-list logic is proven under
# SB_REPO_CARD=off further below (the legacy path this file has always exercised).
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
# review fix (P9): a SMALL PROJECT.md (well under 700B) still renders a card padded by the
# HARD (enforced) rules block (drawn from persona-rules.json, NOT from PROJECT.md — its bytes
# were never part of the reservation at all) plus the untrusted-reference banner — the
# reservation must cover the card's FULL fixed cap, not min(actual-file-size, cap), or a
# tiny PROJECT.md still lets the rendered card blow past what was reserved for it.
mkline() { local s="" i; for i in $(seq 1 15); do s="${s}0123456789"; done; printf '%s' "$s"; }
DL1="$(mkline)"; DL2="$(mkline)"; DL3="$(mkline)"
{ printf -- '---\ntitle: p\n---\n# PROJECT: x\n\n## Goal\nx\n\n## Direction\n%s\n%s\n%s\n\n## Open blockers\n- [active] PROJECT_TAIL_MARKER small bullet.\n' "$DL1" "$DL2" "$DL3"
} > "$B/projects/$SLUG/PROJECT.md"
PROJSZ0=$(wc -c < "$B/projects/$SLUG/PROJECT.md" | tr -d ' ')
[ "$PROJSZ0" -lt 700 ] || fail "fixture too large (${PROJSZ0}B) — must stay under 700B to exercise the reservation bug"
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

[ "$LEN" -le 10000 ] || fail "SessionStart output ${LEN} > 10000 char ceiling — banners crowded forced content past the cap (a tiny PROJECT.md under-reserved the card's room)"
pass "total SessionStart output ≤ 10000 (under Claude's hook ceiling)"
printf '%s' "$OUT" | grep -q 'NEVER_RULE_TAIL_MARKER' || fail "USER.md priority-1 tail truncated — the rules force must guarantee"
printf '%s' "$OUT" | grep -q 'PROJECT_TAIL_MARKER' || fail "the repo card's Open-blockers line (PROJECT.md's forced content, its LAST body section) truncated the tail"
pass "both forced sections (USER.md + the [Repo card] digest) land INTACT under the cap"
printf '%s' "$OUT" | grep -q 'CHARTER_TAIL_MARKER' \
  || fail "persona ## Charter (the 3rd forced section) did not land at SessionStart"
pass "persona Charter lands at SessionStart, reserved within the 10K ceiling"
# The banner close must appear exactly once, and strictly AFTER the marker (i.e. the marker's
# own Open-blockers bullet is inside the untrusted block and the banner closes cleanly after
# it — no stray/forged close earlier, no missing close at all).
BANNER_CLOSE_CT=$(printf '%s' "$OUT" | grep -c 'End untrusted reference')
[ "$BANNER_CLOSE_CT" = "1" ] || fail "expected exactly one 'End untrusted reference' in the output, got $BANNER_CLOSE_CT"
printf '%s' "$OUT" | awk '/PROJECT_TAIL_MARKER/{m=NR} /End untrusted reference/{e=NR} END{exit !(m>0 && e>0 && e>m)}' \
  || fail "the banner close must land AFTER PROJECT_TAIL_MARKER, not before/missing"
pass "the untrusted-reference banner closes exactly once, after the marker"

# --- repo card cap + kill switch (repo-brain Slice 2) ---
CARD=$(printf '%s' "$OUT" | awk '/\[Repo card/{f=1} f{print} /project memory loaded/{exit}')
CARD_BYTES=$(printf '%s' "$CARD" | wc -c | tr -d ' ')
[ "$CARD_BYTES" -le 1800 ] || fail "the [Repo card] block is ${CARD_BYTES}B > 1800B cap"
pass "the [Repo card] block stays within its 1800B cap"
printf '%s' "$OUT" | grep -q '^## Goal' && fail "the legacy '## Goal' raw render must NOT appear when the repo card is on (default)"
pass "the repo card replaces the legacy raw PROJECT.md render by default"

OUT_OFF=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" SB_REPO_CARD=off bash "$SL" 2>/dev/null)
[ "${#OUT_OFF}" -le 10000 ] || fail "SB_REPO_CARD=off SessionStart output ${#OUT_OFF} > 10000 char ceiling"
printf '%s' "$OUT_OFF" | grep -q '^## Goal' || fail "SB_REPO_CARD=off did not restore the legacy '## Goal' render"
printf '%s' "$OUT_OFF" | grep -q '\[Repo card' && fail "SB_REPO_CARD=off but the [Repo card] block still appeared"
pass "SB_REPO_CARD=off restores the legacy sb_project_hot_render '## Goal' render, no [Repo card]"

# --- section-priority: an over-cap PROJECT.md must still inject its payload (legacy path,
# SB_REPO_CARD=off — this is sb_project_hot_render's OWN priority-list behavior). ---
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
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" SB_REPO_CARD=off bash "$SL" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'BLOCKER_MARKER'    || fail "over-cap PROJECT.md: blockers dropped (head-cut instead of section priority)"
printf '%s' "$OUT" | grep -q 'DECISION_MARKER'   || fail "over-cap PROJECT.md: decisions dropped"
printf '%s' "$OUT" | grep -q 'CONVENTION_MARKER' || fail "over-cap PROJECT.md: conventions dropped"
printf '%s' "$OUT" | grep -q 'STATE_DEEP_TAIL_MARKER' && fail "over-cap PROJECT.md: State deep tail survived — nothing was trimmed, cap not honored?"
pass "over-cap PROJECT.md: blockers+decisions+conventions injected; State tail gave way"

# --- contract acceptance[9] (S2 review fix — MEDIUM, previously untested): sb_project_hot_render
# keeps ## Direction AHEAD of ## State in its priority list, so an over-cap file with BOTH
# sections present must land Direction intact while State's tail is what gives way — not the
# reverse. ---
{ printf -- '---\ntitle: p\n---\n# PROJECT: x\n\n## Goal\nGoal line here.\n\n'
  printf -- '## Direction\nDIRECTION_SURVIVES the over-cap render.\n\n## State\n'
  for i in $(seq 1 80); do printf -- '- state filler %s with plenty of descriptive padding bytes for volume.\n' "$i"; done
  printf -- '- STATE_DEEP_TAIL_MARKER_2\n'
} > "$B/projects/$SLUG/PROJECT.md"
PSZ3=$(wc -c < "$B/projects/$SLUG/PROJECT.md" | tr -d ' ')
[ "$PSZ3" -gt 3000 ] || fail "Direction-vs-State fixture too small ($PSZ3 B) — must exceed the 3000B emit cap"
OUT=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" SB_REPO_CARD=off bash "$SL" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'DIRECTION_SURVIVES' || fail "over-cap: ## Direction did not survive ahead of ## State"
printf '%s' "$OUT" | grep -q 'STATE_DEEP_TAIL_MARKER_2' && fail "over-cap: State deep tail survived — Direction should have taken priority instead"
pass "over-cap PROJECT.md: sb_project_hot_render keeps ## Direction ahead of ## State"

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
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" ANTHROPIC_API_KEY="" SB_REPO_CARD=off bash "$SL" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'ARCH_MARKER' && fail "D162: Architecture unexpectedly survived — fixture no longer over-cap?"
grep -q 'hot-tier-sections' "$B/audit-log.jsonl" 2>/dev/null || fail "D162: no over-cap breadcrumb at all"
grep -q 'Architecture' "$B/audit-log.jsonl" 2>/dev/null \
  || fail "D162: breadcrumb dropped the non-canonical 'Architecture' section silently (no mention in audit-log)"
pass "D162: a dropped non-canonical section is named in the breadcrumb"

rm -rf "$B" "$PROJDIR" "$STUB"; echo; echo "ALL PASS"
