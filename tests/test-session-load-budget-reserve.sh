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
# A ~1300B persona-card (budget-gated, cap 1200) — distinct bullets so dedup keeps them.
{ printf '## Identity\n'; for i in $(seq 1 22); do printf -- '- distinct observed persona pattern number %s with padding bytes here xyz\n' "$i"; done; } > "$B/persona-card.md"
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

rm -rf "$B" "$PROJDIR" "$STUB"; echo; echo "ALL PASS"
