#!/usr/bin/env bash
# pins: SB_DREAM_ACCEPT_MIN_RATIO — opens the unrelated deletion-ratio gate to 0 to isolate the NO_DELETE/SKIP_BACKUP guards this file actually tests
# pins: SB_DREAM_ACCEPT_NO_DELETE — the flag itself is the subject of this subtest (dry-run no-delete mode)
# pins: SB_DREAM_ACCEPT_SKIP_BACKUP — the flag itself is the subject of subtest B3 (skip-backup auto path)
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
# supports_chmod_restrict: true only if chmod 555 on a dir actually blocks file creation inside it.
# On Windows/Git-Bash without elevated ACLs, chmod is advisory only and writes succeed regardless.
supports_chmod_restrict() {
  # Returns 0 (true) if chmod 555 actually prevents file creation; 1 (false) if not (Windows).
  local d; d=$(mktemp -d)
  chmod 555 "$d" 2>/dev/null
  touch "$d/probe" 2>/dev/null
  local touch_rc=$?
  chmod 755 "$d" 2>/dev/null
  # touch_rc=0 means touch SUCCEEDED → chmod did NOT restrict → return 1 (false)
  # touch_rc≠0 means touch FAILED  → chmod DID restrict     → return 0 (true)
  [ "$touch_rc" -ne 0 ]
}
if supports_chmod_restrict; then
  setup 4 SAME
  BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
  chmod 555 "$BRAIN_DIR"     # tar czf "$BRAIN_DIR/…tgz" → EACCES (dir traversal still works for reads)
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
  chmod 755 "$BRAIN_DIR"     # restore so cleanup can remove it
  AFTER=$(count "$KNOWLEDGE_DIR/wiki")
  [ "$rc" -ne 0 ] && [ "$AFTER" = "$BEFORE" ] && pass "B2: backup failure (unwritable BRAIN_DIR) → REFUSE, live untouched (fail-closed)" || fail "B2: not fail-closed (rc=$rc, live $BEFORE→$AFTER)"
  rm -rf "$SB"
else
  echo "SKIP: B2 — chmod 555 does not restrict writes on this filesystem (Windows without ACL support); fail-closed guard exercised on Unix/macOS/Linux"
  pass "B2: backup-failure fail-closed guard (skipped — chmod does not restrict here)"
fi

# --- B3: SB_DREAM_ACCEPT_SKIP_BACKUP=1 (auto path) → no duplicate tarball -----
setup 4 SAME
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_SKIP_BACKUP=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
BK=$(ls "$BRAIN_DIR"/wiki-backup-pre-accept-*.tgz 2>/dev/null | head -1)
[ "$rc" -eq 0 ] && [ -z "$BK" ] && pass "B3: skip flag → accept proceeds with NO dream-accept tarball (auto path already backed up)" || fail "B3: skip flag mishandled (rc=$rc, bk=${BK:-none})"
rm -rf "$SB"

# --- B4 (0.33.10): a Windows-form BRAIN_DIR (C:\...) is MSYS-normalized so tar/rsync don't host-parse `C:`
# GNU tar parses `tar -f C:\...` as a REMOTE host:path ("Cannot connect to C:"); the MCP passes BRAIN_DIR
# in Windows form on Windows, so EVERY dream_accept failed-closed there ("could not back up the live wiki")
# — a whole-release Windows regression the MSYS-only test sandboxes never reproduced. Behavioral oracle on
# the platform where the bug lives: feed a REAL Windows-form BRAIN_DIR and require the accept to SUCCEED and
# write the backup. cygpath + drive-letter paths exist only under git-bash/Cygwin → Linux/macOS skip.
if command -v cygpath >/dev/null 2>&1; then
  setup 4 SAME
  WINBRAIN=$(cygpath -w "$BRAIN_DIR")     # the real sandbox brain dir in Windows form (C:\...)
  BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
  BRAIN_DIR="$WINBRAIN" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
  AFTER=$(count "$KNOWLEDGE_DIR/wiki")
  BK=$(ls "$BRAIN_DIR"/wiki-backup-pre-accept-*.tgz 2>/dev/null | head -1)   # $BRAIN_DIR is still MSYS in test scope
  [ "$rc" -eq 0 ] && [ -n "$BK" ] && [ "$AFTER" = "4" ] \
    && pass "B4: Windows-form BRAIN_DIR normalized — accept succeeds + backup written (no tar host:path failure)" \
    || fail "B4: Windows-form BRAIN_DIR broke accept (rc=$rc, bk=${BK:-none}, live $BEFORE→$AFTER)"
  rm -rf "$SB"
else
  pass "B4: Windows-form path normalization (skipped — no cygpath; the tar host:path bug is Windows-only)"
fi

# === P1 (finding D): live pages written AFTER the snapshot survive the accept ===
# Staging is a full-mirror SNAPSHOT taken at status.json .created_at. A page the
# drainer/maintainer writes to LIVE after that (not in staging) must NOT be
# deleted by `rsync --delete`, while an OLD page the dream intentionally dropped
# must still be deleted. ORACLE: the two files on disk after a real accept.
setup 3 "p1 p2"     # live p1,p2,p3 ; staging p1,p2 (the dream drops p3)
# Stamp created_at in the PAST; the pre-snapshot pages get an OLDER mtime.
jq -nc '{id:"drm_test",status:"completed",archived_at:null,created_at:"2026-01-01T00:00:00Z"}' \
  > "$BRAIN_DIR/dreams/drm_test/status.json"
touch -t 202512010000 "$KNOWLEDGE_DIR/wiki/entities/p1.md" \
                      "$KNOWLEDGE_DIR/wiki/entities/p2.md" \
                      "$KNOWLEDGE_DIR/wiki/entities/p3.md" 2>/dev/null
# A POST-snapshot live page (mtime = now, newer than created_at), not in staging.
printf -- '---\ntitle: newpage\ntype: entities\nrelated: []\n---\n\n# newpage\n' \
  > "$KNOWLEDGE_DIR/wiki/entities/newpage.md"
touch "$KNOWLEDGE_DIR/wiki/entities/newpage.md"
# A POST-snapshot live EDIT to an existing page: p2 exists in staging (older
# copy) but the live copy was edited after the snapshot. The panel-confirmed
# hole: the no-rsync merge-cp path clobbered such edits with staging's older
# copy (and Windows git-bash — no rsync — is the PRIMARY apply path). Both
# paths must keep the newer live version (rsync: exclude; cp: stash+restore).
printf 'LIVE EDIT after snapshot\n' >> "$KNOWLEDGE_DIR/wiki/entities/p2.md"
touch "$KNOWLEDGE_DIR/wiki/entities/p2.md"
# MIN_RATIO=0 disables the F1 floor so this isolates the rsync protection.
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "P1: accept failed (rc=$rc)"
# THE fix (both apply paths): the post-snapshot live page must survive.
[ -f "$KNOWLEDGE_DIR/wiki/entities/newpage.md" ] \
  || fail "P1: POST-snapshot live page was silently DELETED on accept (finding D not fixed)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p1.md" ] || fail "P1: a kept page went missing"
grep -q 'LIVE EDIT after snapshot' "$KNOWLEDGE_DIR/wiki/entities/p2.md" \
  || fail "P1: POST-snapshot live EDIT was clobbered by the older staging copy (panel finding)"
if command -v rsync >/dev/null 2>&1; then
  # rsync path: --delete still removes the OLD page the dream intentionally dropped.
  [ ! -f "$KNOWLEDGE_DIR/wiki/entities/p3.md" ] \
    || fail "P1: an OLD dream-removed page survived — normal --delete broke (rsync path)"
  pass "P1: post-snapshot new page + live edit preserved; old dream-removed page still deleted (rsync, finding D)"
else
  # cp fallback (no rsync): merge-only by design — never deletes, so p3 is
  # retained. Safe-by-default (no data loss) over deletion-completeness. The
  # key properties (post-snapshot page + edit preserved) are what finding D is about.
  echo "SKIP: P1 deletion-completeness — no rsync; cp fallback is merge-only (post-snapshot preservation still asserted)"
  pass "P1: post-snapshot new page + live edit preserved on the cp-fallback path (finding D)"
fi
rm -rf "$SB"

# === P2: missing/unusable created_at → FAIL-SAFE (no deletions this accept) ===
# With no trustworthy snapshot time the accept cannot tell which live pages
# postdate the dream, so `rsync --delete` must not run at all: dream-dropped
# pages survive (deletions skipped), everything live survives. Panel finding:
# the previous behavior fell through to an UNPROTECTED --delete.
setup 3 "p1 p2"     # live p1,p2,p3 ; staging p1,p2 (the dream drops p3)
jq -nc '{id:"drm_test",status:"completed",archived_at:null}' \
  > "$BRAIN_DIR/dreams/drm_test/status.json"     # NO created_at at all
printf -- '---\ntitle: newpage\ntype: entities\nrelated: []\n---\n\n# newpage\n' \
  > "$KNOWLEDGE_DIR/wiki/entities/newpage.md"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "P2: accept failed (rc=$rc)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/newpage.md" ] \
  || fail "P2: live-only page deleted despite unusable created_at (fail-safe broken)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p3.md" ] \
  || fail "P2: dream deletion applied WITHOUT a snapshot time — unprotected --delete ran (not fail-safe)"
pass "P2: missing created_at → merge-only accept (no deletions, nothing lost)"
rm -rf "$SB"

# === F5: FORGET manifest handled by the ACCEPT SCRIPT (machine lock) =========
# Previously the archive loop lived only in dream-skill prose, so auto_accept
# and raw MCP dream_accept silently dropped the manifest (P6 arm-gate).

# --- F5a: still-forgettable manifest page → archived, logged, manifest gone --
setup 4 SAME
D="$BRAIN_DIR/dreams/drm_test"
printf 'p1\tentities\n' > "$D/forget-manifest.tsv"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_FORGET_MIN_AGE_DAYS=0 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "F5a: accept failed (rc=$rc)"
[ ! -f "$KNOWLEDGE_DIR/wiki/entities/p1.md" ] || fail "F5a: manifest page still live — FORGET not applied by the accept script"
[ -f "$BRAIN_DIR/wiki-archive/entities/p1.md" ] || fail "F5a: archived page missing from wiki-archive (deleted, not moved?)"
grep -q '"slug":"p1"' "$BRAIN_DIR/wiki-archive-log.jsonl" 2>/dev/null || fail "F5a: no archive-log entry for p1"
[ ! -f "$D/forget-manifest.tsv" ] || fail "F5a: manifest not consumed after accept"
pass "F5a: accept-script FORGET — page archived (reversible), logged, manifest consumed"
rm -rf "$SB"

# --- F5b: LLM-influenced manifest fields are DATA — traversal rejected ------
setup 4 SAME
D="$BRAIN_DIR/dreams/drm_test"
printf -- '../evil\tentities\np2\t../../escape\n' > "$D/forget-manifest.tsv"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_FORGET_MIN_AGE_DAYS=0 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "F5b: accept failed (rc=$rc)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p2.md" ] || fail "F5b: page moved despite invalid category (traversal guard broken)"
[ -z "$(find "$BRAIN_DIR/wiki-archive" -name '*.md' -type f 2>/dev/null)" ] || fail "F5b: something was archived from an all-invalid manifest"
pass "F5b: invalid slug/category manifest lines rejected, nothing moved"
rm -rf "$SB"

# --- F5c: enrichment race — page linked during the dream is KEPT ------------
setup 4 SAME
D="$BRAIN_DIR/dreams/drm_test"
printf -- '---\ntitle: linker\ntype: entities\nrelated: []\n---\n\n# linker\n\nsee [[p3]] and [[p3]] again\n' \
  > "$D/staging/wiki/entities/linker.md"
printf 'p3\tentities\n' > "$D/forget-manifest.tsv"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 SB_FORGET_MIN_AGE_DAYS=0 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "F5c: accept failed (rc=$rc)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p3.md" ] || fail "F5c: post-consolidation-linked page was archived (re-score guard broken)"
[ ! -f "$D/forget-manifest.tsv" ] || fail "F5c: manifest not consumed"
pass "F5c: re-score guard keeps a page the dream just linked (enrichment race)"
rm -rf "$SB"

# === D084: a partial apply failure must ABORT loud, not silently "succeed" ===
# None of the rsync/cp apply commands had their exit status checked; a partial
# failure (EACCES on one live file) fell through to archived_at + rm -rf
# staging, destroying the dream's only copy of its output while reporting
# "accepted". ORACLE: archived_at stays unset, staging survives, rc != 0, and
# the error names a backup tarball to restore from.
supports_chmod_file_restrict() {
  local f; f=$(mktemp)
  chmod 444 "$f" 2>/dev/null
  printf x > "$f" 2>/dev/null
  local write_rc=$?
  chmod 644 "$f" 2>/dev/null; rm -f "$f"
  [ "$write_rc" -ne 0 ]
}
if supports_chmod_file_restrict; then
  setup 3 SAME
  D="$BRAIN_DIR/dreams/drm_test"
  # Staging modifies p1 so the apply actually attempts to overwrite the live file.
  printf -- '---\ntitle: p1\ntype: entities\nrelated: []\n---\n\n# p1\n\nCONSOLIDATED\n' > "$D/staging/wiki/entities/p1.md"
  chmod 444 "$KNOWLEDGE_DIR/wiki/entities/p1.md"
  # rsync (Linux/macOS CI) replaces files via temp-file+rename, so a read-only FILE does
  # not fail it — only an unwritable DIRECTORY does. Restrict both: the cp fallback trips
  # on the file (Windows, where dir modes are inert), rsync trips on the dir.
  chmod 555 "$KNOWLEDGE_DIR/wiki/entities" 2>/dev/null
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>/dev/null; rc=$?
  chmod 755 "$KNOWLEDGE_DIR/wiki/entities" 2>/dev/null
  chmod 644 "$KNOWLEDGE_DIR/wiki/entities/p1.md" 2>/dev/null
  AFTER_ARCHIVED=$(jq -r '.archived_at // ""' "$D/status.json" 2>/dev/null | tr -d '\r')
  [ "$rc" -ne 0 ] || fail "D084: a partial apply failure returned rc=0"
  { [ -z "$AFTER_ARCHIVED" ] || [ "$AFTER_ARCHIVED" = "null" ]; } || fail "D084: archived_at was stamped despite a failed apply"
  [ -d "$D/staging" ] || fail "D084: staging was deleted despite a failed apply"
  BK=$(ls "$BRAIN_DIR"/wiki-backup-pre-accept-*.tgz 2>/dev/null | head -1)
  [ -n "$BK" ] || fail "D084: no backup tarball left to restore from"
  pass "D084: partial apply failure aborts loud — no archived_at, staging kept, backup ($BK) named"
  rm -rf "$SB"
else
  echo "SKIP: D084 — chmod 444 does not restrict file overwrite on this filesystem (Windows without ACL support)"
  pass "D084: apply-failure guard (skipped — chmod does not restrict here)"
  rm -rf "$SB"
fi

# === D084 (review follow-up): the cp-fallback (no-rsync) apply path must not
# `rm -rf $_stash` on a FAILED apply — $_stash holds the only copy of every
# post-snapshot live page edit (protected pages, stashed before the merge-copy
# so the newer live version can be restored after). Deleting it unconditionally
# destroyed those edits with no way back; the fix keeps it and names its path
# in the failure message. This is the primary Windows git-bash apply path (no
# rsync), so it is exercised directly rather than only via a stub.
if command -v rsync >/dev/null 2>&1; then
  echo "SKIP: D084 follow-up — rsync present on this host; the no-rsync \$_stash path is not exercised"
  pass "D084 follow-up: \$_stash-on-failure guard (skipped — rsync present, different apply path)"
elif supports_chmod_file_restrict; then
  setup 3 "p1 p2 p3"
  D="$BRAIN_DIR/dreams/drm_test"
  # created_at in the past so p2's live edit below is POST-snapshot (-> PROTECT -> stashed).
  jq -nc '{id:"drm_test",status:"completed",archived_at:null,created_at:"2026-01-01T00:00:00Z"}' > "$D/status.json"
  touch -t 202512010000 "$KNOWLEDGE_DIR/wiki/entities/p1.md" \
                        "$KNOWLEDGE_DIR/wiki/entities/p2.md" \
                        "$KNOWLEDGE_DIR/wiki/entities/p3.md" 2>/dev/null
  printf 'LIVE EDIT after snapshot\n' >> "$KNOWLEDGE_DIR/wiki/entities/p2.md"
  touch "$KNOWLEDGE_DIR/wiki/entities/p2.md"
  # Staging modifies p1 so the merge-copy actually attempts to overwrite it; chmod 444
  # forces THAT overwrite to fail (p2's protection/stashing is what we're checking survives).
  printf -- '---\ntitle: p1\ntype: entities\nrelated: []\n---\n\n# p1\n\nCONSOLIDATED\n' > "$D/staging/wiki/entities/p1.md"
  chmod 444 "$KNOWLEDGE_DIR/wiki/entities/p1.md"
  ERR=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test 2>&1 1>/dev/null); rc=$?
  chmod 644 "$KNOWLEDGE_DIR/wiki/entities/p1.md" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "D084 follow-up: cp-fallback apply failure returned rc=0"
  STASH_PATH=$(printf '%s' "$ERR" | grep -oE 'stashed at [^ ]+' | sed 's/^stashed at //')
  [ -n "$STASH_PATH" ] || fail "D084 follow-up: failure message did not name the stash path (got: $ERR)"
  [ -d "$STASH_PATH" ] || fail "D084 follow-up: stash dir $STASH_PATH was deleted despite the failed apply"
  grep -q 'LIVE EDIT after snapshot' "$STASH_PATH/entities/p2.md" 2>/dev/null \
    || fail "D084 follow-up: stash did not retain the post-snapshot live edit to p2"
  pass "D084 follow-up: failed cp-fallback apply keeps \$_stash ($STASH_PATH) instead of deleting it"
  rm -rf "$STASH_PATH" "$SB"
else
  echo "SKIP: D084 follow-up — chmod 444 does not restrict file overwrite on this filesystem"
  pass "D084 follow-up: \$_stash-on-failure guard (skipped — chmod does not restrict here)"
  rm -rf "$SB"
fi

# === D212: the shipped 30-day FORGET age floor is a REAL gate, not just
# something every test pins to 0. A page younger than SB_FORGET_MIN_AGE_DAYS
# (default 30) named in the manifest must be PROTECT:age'd and survive.
setup 4 SAME
D="$BRAIN_DIR/dreams/drm_test"
touch "$KNOWLEDGE_DIR/wiki/entities/p1.md"     # fresh mtime — age 0 days
printf 'p1\tentities\n' > "$D/forget-manifest.tsv"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?   # SB_FORGET_MIN_AGE_DAYS unset -> shipped default (30)
[ "$rc" -eq 0 ] || fail "D212: accept failed (rc=$rc)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p1.md" ] || fail "D212: a page younger than the 30-day floor was archived — the reversibility floor is not enforced at the shipped default"
[ ! -f "$BRAIN_DIR/wiki-archive/entities/p1.md" ] || fail "D212: young page landed in wiki-archive despite the age floor"
pass "D212: at the shipped 30-day default, a freshly-written manifest page is PROTECT:age'd and kept live"
rm -rf "$SB"

echo "ALL PASS"
