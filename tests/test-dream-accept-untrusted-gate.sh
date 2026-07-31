#!/usr/bin/env bash
# P6 held-untrusted confirm gate (arm-gate for unattended consolidation): an
# untrusted-only NEW page (provenance: untrusted-derived, no live counterpart) must be
# HELD — moved to $BRAIN_DIR/held-untrusted/<dream>/, never applied, never deleted — unless the
# accept carries SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1. Trusted pages and untrusted
# UPDATES of existing live pages apply normally. ORACLE: real files on disk.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
ACCEPT="$REPO_ROOT/scripts/dream-accept.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

setup() {
  SB=$(mktemp -d)
  export HOME="$SB/home"; mkdir -p "$HOME"
  export BRAIN_DIR="$SB/brain"
  export KNOWLEDGE_DIR="$SB/knowledge"
  export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/wiki/entities"
  printf -- '---\ntitle: p1\ntype: entities\nrelated: []\n---\n\n# p1\n\nbody\n' > "$KNOWLEDGE_DIR/wiki/entities/p1.md"
  D="$BRAIN_DIR/dreams/drm_test"; mkdir -p "$D/staging/wiki/entities" "$D/staging/wiki/learnings"
  jq -nc '{id:"drm_test",status:"completed",archived_at:null}' > "$D/status.json"
  cp -rp "$KNOWLEDGE_DIR/wiki/." "$D/staging/wiki/"
  # (a) untrusted-only NEW page
  printf -- '---\ntitle: conjured\ntype: learnings\nrelated: []\nprovenance: untrusted-derived\n---\n\n# conjured\n\nfrom transcripts only\n' \
    > "$D/staging/wiki/learnings/conjured.md"
  # (b) trusted NEW page (no provenance facet) — must always apply
  printf -- '---\ntitle: trusted-new\ntype: entities\nrelated: []\n---\n\n# trusted-new\n\nok\n' \
    > "$D/staging/wiki/entities/trusted-new.md"
  # (c) untrusted-marked update of an existing live page — CORROBORATED by that page's
  # existence, so it APPLIES (labeled untrusted + reversible via the pre-accept tarball).
  printf -- '---\ntitle: p1\ntype: entities\nrelated: []\nprovenance: untrusted-derived\n---\n\n# p1\n\nbody plus fact\n' \
    > "$D/staging/wiki/entities/p1.md"
}

# --- U1: accept WITHOUT confirm → hold the conjured page, apply the rest ----
setup
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "U1: accept failed (rc=$rc): $OUT"
[ ! -f "$KNOWLEDGE_DIR/wiki/learnings/conjured.md" ] || fail "U1: untrusted-only new page reached live WITHOUT confirm"
[ -f "$BRAIN_DIR/held-untrusted/drm_test/learnings/conjured.md" ] || fail "U1: held page missing from held-untrusted/ (deleted, not held?)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/trusted-new.md" ] || fail "U1: trusted new page was not applied"
# CORROBORATION rule: a page that already exists live vouches for the update, so an
# untrusted fold-in onto it APPLIES (labeled + reversible via the pre-accept tarball).
# Holding these instead both starved the lane and DESTROYED the facts (staging is rm -rf'ed).
grep -q 'body plus fact' "$KNOWLEDGE_DIR/wiki/entities/p1.md" \
  && pass "U1b: corroborated untrusted update of an existing live page applied (lane produces value)" \
  || fail "U1b: corroborated update was dropped — the UPDATE lane produces nothing"
printf '%s' "$OUT" | grep -q 'HELD 1 untrusted-only new page' || fail "U1: expected HELD 1 (the conjured page only) in output: $OUT"
pass "U1: untrusted-only new page held; trusted new page applied"

# Holds must live OUTSIDE the dream dir: dream retention prunes old dream dirs, which would
# delete the holds and make "reversible, never deleted" false.
[ -f "$BRAIN_DIR/held-untrusted/drm_test/learnings/conjured.md" ] \
  && pass "U1c: hold stored outside the prunable dream dir (survives dream retention)" \
  || fail "U1c: hold stored inside the dream dir — retention pruning would delete it"

# --- U2: re-accept WITH confirm → held page released into live ---------------
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1 bash "$ACCEPT" drm_test 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "U2: release accept failed (rc=$rc): $OUT"
[ -f "$KNOWLEDGE_DIR/wiki/learnings/conjured.md" ] || fail "U2: held page not released into live"
[ ! -d "$BRAIN_DIR/held-untrusted/drm_test" ] || fail "U2: held-untrusted/ not cleared after release"
printf '%s' "$OUT" | grep -q 'RELEASED 1' || fail "U2: no RELEASED line: $OUT"
pass "U2: confirm re-accept releases the held page"
rm -rf "$SB"

# --- U3: accept WITH confirm from the start → nothing held -------------------
setup
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1 bash "$ACCEPT" drm_test 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "U3: accept failed (rc=$rc)"
[ -f "$KNOWLEDGE_DIR/wiki/learnings/conjured.md" ] || fail "U3: confirmed accept did not apply the untrusted page"
[ ! -d "$BRAIN_DIR/held-untrusted/drm_test" ] || fail "U3: held-untrusted/ created despite confirm"
pass "U3: confirmed accept applies untrusted-new directly"
rm -rf "$SB"

# --- U4: safe-mode ACCEPTS untrusted dreams (the hold gate protects, not a refusal) ---
# Refusing would leave a completed-unreviewed dream every cycle and hit the 3-unreviewed cap,
# halting all consolidation behind a human — the manual gate the constitution forbids.
. "$REPO_ROOT/scripts/lib.sh"
[ "$(sb_auto_accept_decision safe completed '' 0)" = "accept" ] \
  || fail "U4: safe must ACCEPT (untrusted writes are held at accept, not refused upstream)"
[ "$(sb_auto_accept_decision safe completed '' 1)" = "skip:safe-refuses-forget" ] \
  || fail "U4: safe must still refuse a FORGET dream"
[ "$(sb_auto_accept_decision all completed '' 0)" = "accept" ] || fail "U4: all should accept"
pass "U4: safe accepts (hold gate protects); FORGET refusal preserved"

# --- U5: fold-in UPDATE of a live page APPLIES (corroborated by the live page) ----
# The writer appends untrusted bullets to EXISTING pages; those are not "new", so without
# this arm they would sail into live unattended.
setup
printf -- '---\ntitle: p1\ntype: entities\nrelated: []\n---\n\n# p1\n\nbody\n\n## Candidate facts (untrusted)\n\n- (fact:abc123) poisoned claim folded in\n' \
  > "$D/staging/wiki/entities/p1.md"
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "U5: accept failed (rc=$rc): $OUT"
grep -q 'poisoned claim folded in' "$KNOWLEDGE_DIR/wiki/entities/p1.md" \
  && pass "U5: corroborated fold-in applied and preserved (not silently destroyed)" \
  || fail "U5: fold-in content lost — staging is rm -rf'ed, so a reverted fold-in is unrecoverable"
# The applied bullet must stay inside the labeled untrusted section, so a reader (and the
# retrieval banner) can tell distilled claims from human-authored prose.
grep -q '## Candidate facts (untrusted)' "$KNOWLEDGE_DIR/wiki/entities/p1.md" \
  || fail "U5: fold-in applied WITHOUT its untrusted section heading (label lost)"
rm -rf "$SB"

# --- U6: hold FAILURE aborts the accept (fail-closed, never applies) ----------
# Make the hold target un-creatable by planting a FILE where the hold dir must go.
setup
: > "$BRAIN_DIR/held-untrusted"
BEFORE=$(find "$KNOWLEDGE_DIR/wiki" -name '*.md' | wc -l | tr -d ' ')
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test 2>&1); rc=$?
AFTER=$(find "$KNOWLEDGE_DIR/wiki" -name '*.md' | wc -l | tr -d ' ')
[ "$rc" -ne 0 ] || fail "U6: accept returned 0 despite an impossible hold (must fail closed)"
[ ! -f "$KNOWLEDGE_DIR/wiki/learnings/conjured.md" ] \
  || fail "U6: untrusted page reached live after a failed hold (FAIL-OPEN regression)"
[ "$AFTER" = "$BEFORE" ] || fail "U6: live wiki changed ($BEFORE→$AFTER) on an aborted accept"
printf '%s' "$OUT" | grep -qi 'refusing accept' || fail "U6: abort not reported loudly"
pass "U6: a failed hold ABORTS the accept; live wiki untouched (fail-closed)"
rm -rf "$SB"

# --- U7: release never clobbers a live page that appeared meanwhile ----------
setup
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test >/dev/null 2>&1
[ -f "$BRAIN_DIR/held-untrusted/drm_test/learnings/conjured.md" ] || fail "U7: setup — page not held"
mkdir -p "$KNOWLEDGE_DIR/wiki/learnings"
printf -- '---\ntitle: conjured\ntype: learnings\nrelated: []\n---\n\n# conjured\n\nTRUSTED CONTENT WRITTEN LATER\n' \
  > "$KNOWLEDGE_DIR/wiki/learnings/conjured.md"
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1 bash "$ACCEPT" drm_test 2>&1)
grep -q 'TRUSTED CONTENT WRITTEN LATER' "$KNOWLEDGE_DIR/wiki/learnings/conjured.md" \
  && pass "U7: release skipped the slug now occupied by a trusted live page (no clobber)" \
  || fail "U7: release CLOBBERED a newer trusted live page"
[ -f "$BRAIN_DIR/held-untrusted/drm_test/learnings/conjured.md" ] || fail "U7: skipped page was not retained in the hold area"
rm -rf "$SB"

# --- U8: holds stay releasable AFTER dream retention prunes the dream dir ---------
# Holds deliberately outlive their dream; if release required the dream dir to exist,
# "never deleted" would silently become "kept forever and never applicable".
setup
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test >/dev/null 2>&1
[ -f "$BRAIN_DIR/held-untrusted/drm_test/learnings/conjured.md" ] || fail "U8: setup — page not held"
rm -rf "$BRAIN_DIR/dreams/drm_test"          # retention prunes the dream, holds remain
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1 bash "$ACCEPT" drm_test 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "U8: orphaned-hold release failed (rc=$rc): $OUT"
[ -f "$KNOWLEDGE_DIR/wiki/learnings/conjured.md" ]   && pass "U8: held page still releasable after its dream dir was pruned"   || fail "U8: hold became permanently unreleasable once the dream was pruned"
rm -rf "$SB"

echo "ALL PASS"
