#!/bin/bash
# Decision-ritual (0.48.0) locks for the SERVING side of decision capture:
#   1. EMIT-time collapse: [superseded]/[stale] decision bullets never reach the
#      SessionStart hot tier (the FILE keeps them — reversibility is untouched).
#   2. Newest-first: the most recent decision renders before older ones.
#   3. ## Handoff rides the hot tier under the over-cap section-priority render.
#   4. Source-scan: the persona-context behavioral tail names pin_to_project, so
#      the in-session capture instruction cannot silently drop out (prose promise
#      -> machine lock; the effect metric is gate=decision-capture in
#      test-merge-project-update.sh).
# Harness mirrors test-session-load-scope-banner.sh (controllable slug, stub claude).
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
STUB="$TMP/stub"; mkdir -p "$STUB"; printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

init_proj() {
  local name="$1" slug="$2"
  SANDBOX="$TMP/$name"
  BRAIN="$SANDBOX/.second-brain"
  PROJDIR="$SANDBOX/work/$slug"
  rm -rf "$SANDBOX"
  mkdir -p "$BRAIN/projects/$slug" "$PROJDIR"
}

run_load() {
  printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
    | env PATH="$STUB:$PATH" HOME="$SANDBOX" BRAIN_DIR="$BRAIN" \
          CLAUDE_PROJECT_DIR="$PROJDIR" ANTHROPIC_API_KEY="" \
          bash "$SCRIPT" 2>/dev/null
}

# ============================================================================
# 1+2. UNDER-CAP path: superseded/stale collapse + newest-first ordering.
# ============================================================================
init_proj "collapse" "dc-proj"
cat > "$BRAIN/projects/dc-proj/PROJECT.md" <<'EOF'
# PROJECT: dc-proj
## Goal
seeded for decision-capture render test.

## Recent decisions
- [2026-05-01] [decision] DEC-OLDEST survives
- [superseded] [decision] DEC-SUPERSEDED must not render
- [stale] [2026-01-01] [decision] DEC-STALE must not render
- [2026-05-03] [decision] DEC-NEWEST survives

## Open blockers
- [active] one live blocker
EOF
OUT=$(run_load)
printf '%s' "$OUT" | grep -q 'DEC-SUPERSEDED' \
  && fail "collapse: [superseded] bullet reached the hot tier (got: $OUT)"
printf '%s' "$OUT" | grep -q 'DEC-STALE' \
  && fail "collapse: [stale] bullet reached the hot tier"
printf '%s' "$OUT" | grep -q 'DEC-OLDEST' || fail "collapse: live bullet DEC-OLDEST was dropped"
printf '%s' "$OUT" | grep -q 'DEC-NEWEST' || fail "collapse: live bullet DEC-NEWEST was dropped"
FIRST=$(printf '%s' "$OUT" | grep -o 'DEC-NEWEST\|DEC-OLDEST' | head -1)
[ "$FIRST" = "DEC-NEWEST" ] || fail "ordering: expected DEC-NEWEST rendered before DEC-OLDEST (got first: $FIRST)"
# Reversibility: the FILE keeps every bullet — collapse is emit-only.
grep -q 'DEC-SUPERSEDED' "$BRAIN/projects/dc-proj/PROJECT.md" \
  || fail "collapse: the PROJECT.md file itself lost the superseded bullet (must be emit-only)"
pass "under-cap render drops [superseded]/[stale], keeps file intact, newest first"

# ============================================================================
# 3. OVER-CAP path: ## Handoff survives the section-priority render, and the
#    collapse also applies there (freed bytes return to the budget).
# ============================================================================
init_proj "overcap" "oc-proj"
{
  printf '# PROJECT: oc-proj\n## Goal\nseeded.\n\n'
  printf '## Recent decisions\n'
  printf -- '- [2026-05-01] [decision] OC-DEC-LIVE survives\n'
  printf -- '- [superseded] [decision] OC-DEC-DEAD must not render\n'
  printf '\n## Handoff\n\nin-flight: HANDOFF-SENTINEL step 4 of 6 in flight\n- see: scripts/session-load.sh:754 — priority list\n\n'
  printf '## Conventions\n'
  # Bulk filler to push the file well past the 2990B emit cap.
  i=0; while [ $i -lt 60 ]; do printf -- '- convention filler line %02d padding padding padding padding padding\n' "$i"; i=$((i+1)); done
  printf '\n## Open blockers\n- [active] OC-BLOCKER survives\n\n<!-- last_updated: 2026-05-01T00:00:00Z -->\n'
} > "$BRAIN/projects/oc-proj/PROJECT.md"
SZ=$(wc -c < "$BRAIN/projects/oc-proj/PROJECT.md" | tr -d ' ')
[ "$SZ" -gt 2990 ] || fail "overcap fixture is only ${SZ}B — must exceed the 2990B cap for the priority render to engage"
OUT=$(run_load)
printf '%s' "$OUT" | grep -q 'HANDOFF-SENTINEL' \
  || fail "overcap: ## Handoff content did not survive the priority render (got: $OUT)"
printf '%s' "$OUT" | grep -q 'OC-DEC-LIVE' || fail "overcap: live decision dropped"
printf '%s' "$OUT" | grep -q 'OC-DEC-DEAD' && fail "overcap: superseded bullet leaked through the priority render"
pass "over-cap render keeps ## Handoff (priority slot) and still collapses superseded"

# STARVING case (review finding): Recent-decisions ALONE overflows the budget —
# its truncation branch zeroes the remaining budget, so Handoff must be selected
# BEFORE it or the "priority slot" is a prose promise. This fixture is the
# collision the ordering exists to arbitrate.
init_proj "starve" "sv-proj"
{
  printf '# PROJECT: sv-proj\n## Goal\nseeded.\n\n'
  printf '## Recent decisions\n'
  i=0; while [ $i -lt 40 ]; do printf -- '- [2026-05-%02d] [decision] SV-DEC %02d chose alpha over beta because gamma (rejected: beta — long reasoning text to inflate bytes well past budget)\n' "$(( (i % 27) + 1 ))" "$i"; i=$((i+1)); done
  printf '\n## Handoff\n\nin-flight: STARVE-HANDOFF-SENTINEL still lands\n\n<!-- last_updated: 2026-05-01T00:00:00Z -->\n'
} > "$BRAIN/projects/sv-proj/PROJECT.md"
SZ=$(wc -c < "$BRAIN/projects/sv-proj/PROJECT.md" | tr -d ' ')
[ "$SZ" -gt 2990 ] || fail "starve fixture is only ${SZ}B — decisions section must overflow the cap alone"
OUT=$(run_load)
printf '%s' "$OUT" | grep -q 'STARVE-HANDOFF-SENTINEL' \
  || fail "starve: Handoff dropped when Recent-decisions overflowed the budget — priority slot is not real (got: $(printf '%s' "$OUT" | head -c 300))"
pass "Handoff survives even when Recent-decisions alone overflows the budget"

# ============================================================================
# 3b. CRLF regression: a Windows-line-ending PROJECT.md must still collapse
#     superseded bullets (the documented recurring bug class: CRLF defeats
#     /^## Section$/ awk readers unless normalization runs first — this locks
#     the normalize-before-render ordering for THIS filter specifically).
# ============================================================================
init_proj "crlf" "crlf-proj"
{
  printf '# PROJECT: crlf-proj\r\n## Goal\r\nseeded.\r\n\r\n'
  printf '## Recent decisions\r\n'
  printf -- '- [2026-05-01] [decision] CRLF-DEC-LIVE survives\r\n'
  printf -- '- [superseded] [decision] CRLF-DEC-DEAD must not render\r\n'
} > "$BRAIN/projects/crlf-proj/PROJECT.md"
od -An -tx1 "$BRAIN/projects/crlf-proj/PROJECT.md" | grep -q ' 0d' \
  || fail "crlf: fixture has no CR bytes — test would be vacuous"
OUT=$(run_load)
printf '%s' "$OUT" | grep -q 'CRLF-DEC-LIVE' || fail "crlf: live bullet dropped on CRLF PROJECT.md"
printf '%s' "$OUT" | grep -q 'CRLF-DEC-DEAD' \
  && fail "crlf: superseded bullet leaked — CRLF defeated the collapse filter"
pass "CRLF PROJECT.md still collapses superseded bullets (normalize-before-render locked)"

# ============================================================================
# 4. Source-scan: the in-session capture instruction is present in the
#    persona-context behavioral tail (prose promise -> machine lock).
# ============================================================================
grep -q 'pin_to_project' "$PLUGIN_ROOT/scripts/persona-context.sh" \
  || fail "source-scan: scripts/persona-context.sh no longer names pin_to_project — the in-session decision-capture instruction dropped out"
pass "persona-context tail names pin_to_project (in-session capture instruction armed)"

echo
echo "ALL PASS"
