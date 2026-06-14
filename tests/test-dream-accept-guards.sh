#!/usr/bin/env bash
# Premise-review fixes (0.25.0 autonomy): dream-accept must never let a broken/
# truncated dream destroy the LIVE wiki, and auto_accept=safe must truly forbid
# deletions. ORACLE: the real live-wiki page count on disk BEFORE vs AFTER a
# refused accept (a filesystem fact) — not a re-read of the script's own claim.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
ACCEPT="$REPO_ROOT/scripts/dream-accept.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

count(){ find "$1" -name '*.md' ! -name 'index.md' -type f 2>/dev/null | wc -l | tr -d ' '; }

# Build a sandbox: N live pages + a completed dream whose staging has M pages.
# Echoes the dream dir. $1=live_count $2=staging_pages(space-sep slugs or 'EMPTY' or 'SAME').
setup() {
  local live_n="$1" staging_spec="$2"
  SB=$(mktemp -d)
  export HOME="$SB/home"; mkdir -p "$HOME"
  export BRAIN_DIR="$SB/brain"
  export KNOWLEDGE_DIR="$SB/knowledge"
  export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/wiki/entities"
  local i; for i in $(seq 1 "$live_n"); do
    printf -- '---\ntitle: p%s\ntype: entities\nrelated: []\n---\n\n# p%s\n\nbody\n' "$i" "$i" > "$KNOWLEDGE_DIR/wiki/entities/p$i.md"
  done
  local D="$BRAIN_DIR/dreams/drm_test"; mkdir -p "$D/staging/wiki/entities"
  jq -nc '{id:"drm_test",status:"completed",archived_at:null}' > "$D/status.json"
  case "$staging_spec" in
    EMPTY) : ;;  # staging/wiki exists but no pages
    SAME)  cp -rp "$KNOWLEDGE_DIR/wiki/." "$D/staging/wiki/" ;;
    *)     for s in $staging_spec; do
             printf -- '---\ntitle: %s\ntype: entities\nrelated: []\n---\n\n# %s\n\nbody\n' "$s" "$s" > "$D/staging/wiki/entities/$s.md"
           done ;;
  esac
}

# --- F1a: EMPTY staging vs non-empty live → REFUSE, live untouched ----------
setup 3 EMPTY
BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
AFTER=$(count "$KNOWLEDGE_DIR/wiki")
[ "$rc" -ne 0 ] || fail "F1a: accepted an EMPTY staging (rc=0) — would wipe live"
[ "$AFTER" = "$BEFORE" ] && [ "$AFTER" = "3" ] && pass "F1a: empty staging REFUSED, live wiki intact ($AFTER pages)" || fail "F1a: live wiki changed $BEFORE→$AFTER on a refused accept"
rm -rf "$SB"

# --- F1b: tiny staging (1 page) vs 10 live → REFUSE (< 50%) -----------------
setup 10 "lonely"
BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
AFTER=$(count "$KNOWLEDGE_DIR/wiki")
[ "$rc" -ne 0 ] && [ "$AFTER" = "10" ] && pass "F1b: truncated staging (1 vs 10, <50%) REFUSED, live intact" || fail "F1b: truncated staging not refused (rc=$rc, live $BEFORE→$AFTER)"
rm -rf "$SB"

# --- F1c: full staging (== live) → ACCEPTS ----------------------------------
setup 4 SAME
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "F1c: a complete staging (== live) is accepted (rc=0)" || fail "F1c: a valid full consolidation was refused (rc=$rc)"
rm -rf "$SB"

# --- F3a: safe-mode (NO_DELETE) refuses a dream that drops a live page -------
setup 4 "p1 p2 p3"   # staging missing p4 → a deletion
BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
AFTER=$(count "$KNOWLEDGE_DIR/wiki")
[ "$rc" -ne 0 ] && [ "$AFTER" = "4" ] && pass "F3a: safe-mode refuses a deleting dream, all 4 live pages intact" || fail "F3a: safe-mode allowed a deletion (rc=$rc, live $BEFORE→$AFTER)"
rm -rf "$SB"

# --- F3b: safe-mode accepts an additive/modifying dream (no deletion) -------
setup 3 "p1 p2 p3 p4new"   # all live present + one new → no deletion
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "F3b: safe-mode accepts an additive dream (no live page removed)" || fail "F3b: safe-mode refused a non-deleting dream (rc=$rc)"
rm -rf "$SB"

# === 0.28.1: manual accept backs up live FIRST (reversibility), fail-closed ===
# ORACLE for B1 is a ROUND-TRIP: extract the backup tarball and assert it
# reproduces the PRE-accept live wiki (the snapshot BEFORE the merge), not the
# post-accept state — not merely "a file exists".

# --- B1: a manual accept tarballs live first; the tarball is the pre-accept snapshot
setup 3 "p1 p2 p3 p4new"   # additive: pre=3 pages, post=4 (p4new merged in)
PRE=$(cd "$KNOWLEDGE_DIR/wiki" && find . -name '*.md' ! -name 'index.md' -type f | sort)
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "B1: additive manual accept failed (rc=$rc)"
BK=$(ls "$BRAIN_DIR"/wiki-backup-pre-accept-*.tgz 2>/dev/null | head -1)
[ -n "$BK" ] || fail "B1: manual accept created NO pre-accept backup tarball"
EX=$(mktemp -d); tar xzf "$BK" -C "$EX" 2>/dev/null
BKSET=$(cd "$EX/wiki" && find . -name '*.md' ! -name 'index.md' -type f | sort)
[ "$BKSET" = "$PRE" ] || fail "B1: backup is not the pre-accept snapshot (got: $(echo "$BKSET" | tr '\n' ' '))"
[ "$(count "$KNOWLEDGE_DIR/wiki")" = "4" ] || fail "B1: accept didn't apply (live not 4 pages after)"
pass "B1: manual accept tarballs live FIRST; backup round-trips to the pre-accept wiki (no p4new)"
rm -rf "$SB" "$EX"

# --- B2: backup CANNOT be written → REFUSE (fail-closed), live untouched -----
setup 4 SAME
BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
chmod 555 "$BRAIN_DIR"     # tar czf "$BRAIN_DIR/…tgz" → EACCES (dir traversal still works for reads)
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
chmod 755 "$BRAIN_DIR"     # restore so cleanup can remove it
AFTER=$(count "$KNOWLEDGE_DIR/wiki")
[ "$rc" -ne 0 ] && [ "$AFTER" = "$BEFORE" ] && pass "B2: backup failure (unwritable BRAIN_DIR) → REFUSE, live untouched (fail-closed)" || fail "B2: not fail-closed (rc=$rc, live $BEFORE→$AFTER)"
rm -rf "$SB"

# --- B3: SB_DREAM_ACCEPT_SKIP_BACKUP=1 (auto path) → no duplicate tarball -----
setup 4 SAME
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_SKIP_BACKUP=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
BK=$(ls "$BRAIN_DIR"/wiki-backup-pre-accept-*.tgz 2>/dev/null | head -1)
[ "$rc" -eq 0 ] && [ -z "$BK" ] && pass "B3: skip flag → accept proceeds with NO dream-accept tarball (auto path already backed up)" || fail "B3: skip flag mishandled (rc=$rc, bk=${BK:-none})"
rm -rf "$SB"

echo "ALL PASS"
