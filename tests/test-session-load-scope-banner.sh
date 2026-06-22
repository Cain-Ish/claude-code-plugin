#!/bin/bash
# Behavioral tests for session-load.sh SessionStart STDOUT — the parts that pure
# source-greps (test-project-plan-block.sh §7) can't prove: that the scope banner is
# actually EMITTED with the CORRECT project slug + EXACT plan/decision/blocker counts,
# that SB_SCOPE_BANNER=off suppresses it in OUTPUT, that a stale .active-session-slug pin
# from another project never leaks into the banner, and that the persona "Observed
# patterns" block emits only the qualifying ungraduated signals.
#
# Harness: CLAUDE_PROJECT_DIR points at a NAMED subdir of a tmp dir, so sb_detect_project
# (lib.sh case 4: standalone, no git, basename slug) yields a CONTROLLABLE slug — not the
# "scratch" collapse that a bare mktemp `tmp.*` basename would trigger.
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
# A `claude` stub on PATH keeps the auth-mode line deterministic (subscription path);
# it never affects the assertions below, which target the scope/persona blocks.
STUB="$TMP/stub"; mkdir -p "$STUB"; printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Seed a project sandbox with a chosen slug + PROJECT.md body. Globals set:
#   SANDBOX (HOME), BRAIN, PROJDIR (the CLAUDE_PROJECT_DIR), SLUG.
init_proj() {
  local name="$1" slug="$2"
  SANDBOX="$TMP/$name"
  BRAIN="$SANDBOX/.second-brain"
  PROJDIR="$SANDBOX/work/$slug"     # basename == slug (lib.sh case 4)
  SLUG="$slug"
  rm -rf "$SANDBOX"
  mkdir -p "$BRAIN/projects/$slug" "$PROJDIR"
}

# Run session-load.sh for the seeded project. $1 (optional) = extra env assignments.
run_load() {
  printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
    | env PATH="$STUB:$PATH" HOME="$SANDBOX" BRAIN_DIR="$BRAIN" \
          CLAUDE_PROJECT_DIR="$PROJDIR" ANTHROPIC_API_KEY="" ${1:-} \
          bash "$SCRIPT" 2>/dev/null
}

# A PROJECT.md of KNOWN shape: 2 open + 1 done plan items, 3 decisions, 1 active blocker.
# Expected banner counts: plan 2/3 · 3 decisions · 1 active blockers.
write_known_project() {  # $1 = path, $2 = eol ("lf" | "crlf")
  local out="$1" body
  body='# PROJECT: known
## Goal
seeded for counter test.

## Plan
- [ ] open plan item one
- [ ] open plan item two
- [x] done plan item three

## Recent decisions
- decision alpha
- decision beta
- decision gamma

## Open blockers
- [active] live blocker
- [resolved] dead blocker

## Cross-references
'
  if [ "${2:-lf}" = "crlf" ]; then
    # Append a CR to every line via POSIX printf (BSD/GNU-identical, unlike `sed 's/$/\r/'`
    # where BSD sed treats `\r` literally). awk is avoided: git-bash gawk text-mode I/O
    # would double the CR. `printf '%s\r\n'` emits exactly one CRLF per line everywhere.
    : > "$out"
    printf '%s\n' "$body" | while IFS= read -r _line; do printf '%s\r\n' "$_line"; done > "$out"
  else
    printf '%s' "$body" > "$out"
  fi
}

# ============================================================================
# CRITICAL — scope-banner EMIT: correct slug, kill switch, cross-project leak.
# ============================================================================

# 1. EMIT with the CORRECT slug.
init_proj "emit-alpha" "alpha-proj"
cat > "$BRAIN/projects/alpha-proj/PROJECT.md" <<'EOF'
# PROJECT: alpha-proj
## Goal
seeded.
EOF
OUT=$(run_load)
printf '%s' "$OUT" | grep -q '✓ second-brain: project memory loaded — alpha-proj' \
  || fail "scope banner not emitted with the correct slug (got: $OUT)"
pass "scope banner is EMITTED in STDOUT naming the correct slug (alpha-proj)"

# 2. CROSS-PROJECT LEAK detector: a STALE pin for a DIFFERENT project must not leak.
#    Seed .active-session-slug = beta-proj (a real, distinct project with its own
#    PROJECT.md). The run is scoped to alpha-proj via CLAUDE_PROJECT_DIR; the banner
#    must name alpha-proj and NEVER beta-proj.
mkdir -p "$BRAIN/projects/beta-proj"
cat > "$BRAIN/projects/beta-proj/PROJECT.md" <<'EOF'
# PROJECT: beta-proj
## Goal
the wrong project — must never be named.
EOF
printf 'beta-proj\n' > "$BRAIN/.active-session-slug"   # stale pin from a concurrent session
OUT=$(run_load)
printf '%s' "$OUT" | grep -q 'project memory loaded — alpha-proj' \
  || fail "scope banner must name alpha-proj even with a stale beta-proj pin (got: $OUT)"
printf '%s' "$OUT" | grep -q 'project memory loaded — beta-proj' \
  && fail "CROSS-PROJECT LEAK: banner named the stale-pinned beta-proj instead of alpha-proj (got: $OUT)"
pass "stale .active-session-slug pin does NOT leak into the scope banner (alpha, not beta)"

# 3. KILL SWITCH: SB_SCOPE_BANNER=off suppresses the banner in OUTPUT (not just source).
init_proj "emit-off" "gamma-proj"
cat > "$BRAIN/projects/gamma-proj/PROJECT.md" <<'EOF'
# PROJECT: gamma-proj
## Goal
seeded.
EOF
OUT_ON=$(run_load)
printf '%s' "$OUT_ON" | grep -q 'project memory loaded — gamma-proj' \
  || fail "control: banner should be ON by default (got: $OUT_ON)"
OUT_OFF=$(run_load "SB_SCOPE_BANNER=off")
printf '%s' "$OUT_OFF" | grep -q 'project memory loaded' \
  && fail "SB_SCOPE_BANNER=off did NOT suppress the banner in OUTPUT (got: $OUT_OFF)"
pass "SB_SCOPE_BANNER=off suppresses the scope banner in OUTPUT"

# ============================================================================
# HIGH — scope-banner COUNTERS: exact plan/decision/blocker counts (LF + CRLF).
# ============================================================================
EXPECT='project memory loaded — known-proj (plan 2/3 · 3 decisions · 1 active blockers)'

# 4. LF PROJECT.md → exact counts.
init_proj "counts-lf" "known-proj"
write_known_project "$BRAIN/projects/known-proj/PROJECT.md" lf
OUT=$(run_load)
printf '%s' "$OUT" | grep -qF "$EXPECT" \
  || fail "LF counts wrong — expected [$EXPECT] (got: $OUT)"
pass "scope banner counts are EXACT on LF PROJECT.md (plan 2/3 · 3 decisions · 1 active blockers)"

# 5. CRLF PROJECT.md → counts survive Windows line endings (session-load CRLF-normalizes
#    before the awk readers; without that, every `/^## Section$/` match fails and counts zero).
init_proj "counts-crlf" "known-proj"
write_known_project "$BRAIN/projects/known-proj/PROJECT.md" crlf
# sanity: the fixture really has CR bytes
od -An -tx1 "$BRAIN/projects/known-proj/PROJECT.md" | grep -q ' 0d' \
  || fail "CRLF fixture has no CR bytes — test would be vacuous"
OUT=$(run_load)
printf '%s' "$OUT" | grep -qF "$EXPECT" \
  || fail "CRLF counts wrong — expected [$EXPECT] (got: $OUT)"
pass "scope banner counts survive a CRLF PROJECT.md (Windows line endings)"

# ============================================================================
# HIGH — persona-signals EMIT: only qualifying ungraduated signals appear.
# ============================================================================
# Seed persona-signals.jsonl with:
#   (A) qualifying:  recent, ungraduated, count>=2   → MUST appear
#   (B) graduated:   recent, count>=2, graduated     → MUST NOT appear
#   (C) count==1:    recent, ungraduated, count==1   → MUST NOT appear
#   (D) stale:       count>=2, ungraduated, old date → MUST NOT appear (outside window)
init_proj "persona" "persona-proj"
cat > "$BRAIN/projects/persona-proj/PROJECT.md" <<'EOF'
# PROJECT: persona-proj
## Goal
seeded.
EOF
TODAY=$(date -u +%Y-%m-%d)
{
  printf '{"category":"workflow","signal":"QUALIFYING-prefers-tdd-loops","evidence":[],"confidence":"medium","first_seen":"%s","last_seen":"%s","count":3,"graduated":false}\n' "$TODAY" "$TODAY"
  printf '{"category":"style","signal":"GRADUATED-already-in-usermd","evidence":[],"confidence":"high","first_seen":"%s","last_seen":"%s","count":5,"graduated":true}\n' "$TODAY" "$TODAY"
  printf '{"category":"tooling","signal":"SINGLESEEN-only-once","evidence":[],"confidence":"low","first_seen":"%s","last_seen":"%s","count":1,"graduated":false}\n' "$TODAY" "$TODAY"
  printf '{"category":"workflow","signal":"STALE-beyond-the-window","evidence":[],"confidence":"medium","first_seen":"2020-01-01","last_seen":"2020-01-01","count":4,"graduated":false}\n'
} > "$BRAIN/persona-signals.jsonl"
OUT=$(run_load)
printf '%s' "$OUT" | grep -q '## Observed patterns' \
  || fail "persona 'Observed patterns' header missing (got: $OUT)"
printf '%s' "$OUT" | grep -qF -- '- [workflow] QUALIFYING-prefers-tdd-loops (seen 3x)' \
  || fail "qualifying ungraduated signal line missing/malformed (got: $OUT)"
printf '%s' "$OUT" | grep -q 'GRADUATED-already-in-usermd' \
  && fail "a GRADUATED signal must NOT appear in Observed patterns (got: $OUT)"
printf '%s' "$OUT" | grep -q 'SINGLESEEN-only-once' \
  && fail "a count==1 signal must NOT appear (count>=2 required) (got: $OUT)"
printf '%s' "$OUT" | grep -q 'STALE-beyond-the-window' \
  && fail "a stale (out-of-window) signal must NOT appear (got: $OUT)"
pass "persona Observed-patterns emits only the qualifying ungraduated signal"

echo
echo "ALL PASS"
