#!/usr/bin/env bash
# pins: SB_DREAM_ACCEPT_MIN_RATIO — opens the unrelated deletion-ratio gate to 0 to isolate the NO_DELETE/SKIP_BACKUP guards this file actually tests
# pins: SB_DREAM_ACCEPT_NO_DELETE — the flag itself is the subject of this subtest (dry-run no-delete mode)
# pins: SB_DREAM_ACCEPT_SKIP_BACKUP — the flag itself is the subject of subtest B3 (skip-backup auto path)
# run-all-timeout: 240   (~31 dream-accept.sh runs; measured alone on MSYS 2026-10-07 after R3-B's
#   C1/F3c cases and the first real run of the D084 follow-up: 79 s jq 1.8.1 / 83 s jq 1.7.1,
#   15.1 GB free, 377 processes; the 120 s default was under 2x that. 2026-10-08 after R3-C's P-C4
#   case, alone: 75 s jq 1.8.1 / 88 s jq 1.7.1)
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

# --- F3a: safe-mode (NO_DELETE) refuses a dream that drops a PRE-snapshot live page ------
# Only an apply that can delete is refused: rsync --delete with a usable created_at. Without
# either the apply is merge-only and deletes nothing, so there is nothing to refuse (K1, F3c).
# The pre-K1 F3a ran with no created_at, so it asserted a refusal that guarded nothing. A host
# without rsync gets a stub on PATH: the refusal comes before the apply, so the stub never runs
# there (gate-only), and where it does run (F3d) the case asserts the gate's verdict only.
RSYNC_STUB=""
if ! command -v rsync >/dev/null 2>&1; then
  RSYNC_STUB=$(mktemp -d); printf '#!/bin/bash\nexit 0\n' > "$RSYNC_STUB/rsync"; chmod +x "$RSYNC_STUB/rsync"
fi
with_rsync() { if [ -n "$RSYNC_STUB" ]; then PATH="$RSYNC_STUB:$PATH" "$@"; else "$@"; fi; }
# old_snapshot: created_at in the past, every live page older than it (all pre-snapshot).
old_snapshot() {
  jq -nc '{id:"drm_test",status:"completed",archived_at:null,created_at:"2026-01-01T00:00:00Z"}' \
    > "$BRAIN_DIR/dreams/drm_test/status.json"
  find "$KNOWLEDGE_DIR/wiki" -name '*.md' -type f -exec touch -t 202512010000 {} +
}
setup 4 "p1 p2 p3"   # staging missing p4 → a deletion
old_snapshot
BEFORE=$(count "$KNOWLEDGE_DIR/wiki")
with_rsync env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
AFTER=$(count "$KNOWLEDGE_DIR/wiki")
[ "$rc" -ne 0 ] && [ "$AFTER" = "4" ] && pass "F3a: safe-mode refuses a dream that drops a pre-snapshot page, all 4 live pages intact" || fail "F3a: safe-mode allowed a deletion (rc=$rc, live $BEFORE→$AFTER)"
rm -rf "$SB"

# --- F3c (K1): no usable created_at → merge-only apply → the deletion check is skipped, logged ---
# A refused auto-accept stays completed and unarchived, and the lane's no-stacking check then
# stops every later run, so refusing an apply that cannot delete was a permanent stall.
# The skip is routine (every safe accept on a host without rsync takes it), so its row is a gate=
# trace in the audit-log, not an error-log line (R3-B S12). The created_at arm runs under
# with_rsync, so a host without rsync exercises it too instead of passing on the rsync arm (Q-L5);
# the rsync arm is asserted where rsync is really absent.
f3c_row() {  # $1 = log file: the NO_DELETE skip row(s), compact
  jq -c 'select(.script == "dream-accept" and ((.message // "") | test("NO_DELETE check skipped")))' "$1" 2>/dev/null | tr -d '\r'
}
setup 4 "p1 p2 p3"   # staging missing p4, but NO created_at: the apply cannot delete it
with_rsync env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
SKIPROW=$(f3c_row "$BRAIN_DIR/audit-log.jsonl")
[ "$rc" -eq 0 ] && [ -f "$KNOWLEDGE_DIR/wiki/entities/p4.md" ] && [ "$(count "$KNOWLEDGE_DIR/wiki")" = "4" ] \
  && printf '%s' "$SKIPROW" | grep -q '"message":"gate=no-delete-check [^"]*created_at '"'"'<empty>'"'"' unusable' \
  && [ -z "$(f3c_row "$BRAIN_DIR/error-log.jsonl")" ] \
  && pass "F3c: no usable created_at → merge-only safe accept goes through, deletes nothing, logs the skip (created_at reason) as an audit trace" \
  || fail "F3c: merge-only safe accept (rc=$rc, p4=$([ -f "$KNOWLEDGE_DIR/wiki/entities/p4.md" ] && echo kept || echo GONE), audit row=${SKIPROW:-none}, error-log row=$(f3c_row "$BRAIN_DIR/error-log.jsonl"))"
rm -rf "$SB"
if [ -n "$RSYNC_STUB" ]; then   # rsync really absent: the other arm, with a usable created_at
  setup 4 "p1 p2 p3"; old_snapshot
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
  SKIPROW=$(f3c_row "$BRAIN_DIR/audit-log.jsonl")
  [ "$rc" -eq 0 ] && [ -f "$KNOWLEDGE_DIR/wiki/entities/p4.md" ] && printf '%s' "$SKIPROW" | grep -q 'rsync not installed' \
    && pass "F3c: no rsync → merge-only safe accept goes through and logs the skip (rsync reason)" \
    || fail "F3c: no-rsync safe accept (rc=$rc, audit row=${SKIPROW:-none})"
  rm -rf "$SB"
fi

# --- F3d (K1): a page created LIVE after the snapshot is not a deletion ----------------------
# Staging mirrors the wiki at created_at; a live page newer than that is protected by the apply
# (never deleted, never overwritten). The deletion check ran before that protection was computed,
# so safe mode refused every dream that sat while the drainer wrote a page.
k1_fixture() {
  setup 3 SAME          # staging == live p1..p3
  old_snapshot          # p1..p3 predate created_at
  printf -- '---\ntitle: p4\ntype: entities\nrelated: []\n---\n\n# p4\n\nlive after the snapshot\n' \
    > "$KNOWLEDGE_DIR/wiki/entities/p4.md"   # mtime now > created_at, absent from staging
}
k1_fixture
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$KNOWLEDGE_DIR/wiki/entities/p4.md" ] \
  && pass "F3d: a post-snapshot live page is not counted as a deletion (rc=0, p4 kept; this host's apply path)" \
  || fail "F3d: safe mode refused over a page created after the snapshot (rc=$rc)"
rm -rf "$SB"
if [ -n "$RSYNC_STUB" ]; then
  k1_fixture
  PATH="$RSYNC_STUB:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_NO_DELETE=1 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] \
    && pass "F3d: with rsync on PATH the deletion check subtracts the protected page (gate-only: stub rsync)" \
    || fail "F3d: with rsync on PATH, safe mode refused over a post-snapshot page (rc=$rc)"
  rm -rf "$SB"
fi

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
# supports_chmod_file_restrict: true only if chmod 444 on a FILE actually blocks overwriting it
# (Git-Bash maps it to the read-only attribute, so it does there; root on Linux ignores it). The
# D084 follow-up below called this without a definition, so "command not found" sent every host
# to its SKIP branch (R3-B).
supports_chmod_file_restrict() {
  local d rc; d=$(mktemp -d)
  printf 'a\n' > "$d/probe"; chmod 444 "$d/probe" 2>/dev/null
  ( printf 'b\n' > "$d/probe" ) 2>/dev/null; rc=$?
  chmod 644 "$d/probe" 2>/dev/null; rm -f "$d/probe"; rmdir "$d" 2>/dev/null
  [ "$rc" -ne 0 ]
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
# A live edit to a page staging also holds: with no snapshot time nothing tells it apart from a
# pre-snapshot page, so the merge overwrites it with the staging copy. The warn must say THAT
# (R3-B S12b: it claimed to "protect post-snapshot live pages", which only holds for deletions).
printf 'LIVE EDIT after snapshot\n' >> "$KNOWLEDGE_DIR/wiki/entities/p1.md"
ERR=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_DREAM_ACCEPT_MIN_RATIO=0 bash "$ACCEPT" drm_test 2>&1 1>/dev/null); rc=$?
[ "$rc" -eq 0 ] || fail "P2: accept failed (rc=$rc)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/newpage.md" ] \
  || fail "P2: live-only page deleted despite unusable created_at (fail-safe broken)"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p3.md" ] \
  || fail "P2: dream deletion applied WITHOUT a snapshot time — unprotected --delete ran (not fail-safe)"
pass "P2: missing created_at → merge-only accept (no deletions, nothing lost)"
if grep -q 'LIVE EDIT after snapshot' "$KNOWLEDGE_DIR/wiki/entities/p1.md"; then
  fail "P2: the merge kept the live edit to p1 — the S12b warn below no longer describes this path"
fi
printf '%s' "$ERR" | grep -q 'overwritten by its staging copy' && ! printf '%s' "$ERR" | grep -q 'to protect post-snapshot live pages' \
  && pass "P2: the merge-only warn says a post-snapshot live edit is overwritten (and the backup has it)" \
  || fail "P2: the merge-only warn misdescribes the merge (stderr: $ERR)"
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
# Failure injection that trips EVERY apply path on every OS: a read-only file does not
# stop rsync (temp-file + rename) and a 555 directory is re-chmodded by `rsync -a`, but
# neither rsync nor `cp -r` can replace a NON-EMPTY DIRECTORY with a regular file
# (ENOTDIR / "cannot delete non-empty directory") — and Windows dir modes are inert
# anyway. So: staging ships p1.md as a file, live holds p1.md as a directory with content.
{
  setup 3 SAME
  D="$BRAIN_DIR/dreams/drm_test"
  # Staging modifies p1 so the apply actually attempts to overwrite the live entry.
  printf -- '---\ntitle: p1\ntype: entities\nrelated: []\n---\n\n# p1\n\nCONSOLIDATED\n' > "$D/staging/wiki/entities/p1.md"
  rm -f "$KNOWLEDGE_DIR/wiki/entities/p1.md"
  mkdir -p "$KNOWLEDGE_DIR/wiki/entities/p1.md" && printf 'keep\n' > "$KNOWLEDGE_DIR/wiki/entities/p1.md/keep.txt"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>/dev/null; rc=$?
  AFTER_ARCHIVED=$(jq -r '.archived_at // ""' "$D/status.json" 2>/dev/null | tr -d '\r')
  [ "$rc" -ne 0 ] || fail "D084: a partial apply failure returned rc=0"
  { [ -z "$AFTER_ARCHIVED" ] || [ "$AFTER_ARCHIVED" = "null" ]; } || fail "D084: archived_at was stamped despite a failed apply"
  [ -d "$D/staging" ] || fail "D084: staging was deleted despite a failed apply"
  BK=$(ls "$BRAIN_DIR"/wiki-backup-pre-accept-*.tgz 2>/dev/null | head -1)
  [ -n "$BK" ] || fail "D084: no backup tarball left to restore from"
  pass "D084: partial apply failure aborts loud — no archived_at, staging kept, backup ($BK) named"
  rm -rf "$SB"
}

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

# === K10: the archived_at stamp (`jq > tmp && mv`) had no exit check, so a failed stamp fell
# through to `rm -rf staging` and left a dream that was neither archived nor re-acceptable
# ("staging wiki not found"). The shim fails ONLY the stamping jq call; every other jq call
# reaches the real binary (captured BEFORE the shim goes on PATH).
setup 3 "p1 p2 p3 p9"   # additive: p9 is new
D="$BRAIN_DIR/dreams/drm_test"
REAL_JQ=$(command -v jq)
JQSHIM="$SB/jqshim"; mkdir -p "$JQSHIM"
cat > "$JQSHIM/jq" <<EOF
#!/bin/bash
case "\$*" in *'.archived_at = \$t'*) echo "jq: simulated write failure" >&2; exit 2 ;; esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$JQSHIM/jq"
ERR=$(PATH="$JQSHIM:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test 2>&1 1>/dev/null); rc=$?
[ "$rc" -ne 0 ] || fail "K10: a failed archived_at stamp returned rc=0"
[ -d "$D/staging/wiki" ] || fail "K10: staging was deleted after the archived_at stamp failed (the dream can no longer be re-accepted)"
A=$(jq -r '.archived_at // ""' "$D/status.json" 2>/dev/null | tr -d '\r')
{ [ -z "$A" ] || [ "$A" = "null" ]; } || fail "K10: archived_at is '$A' after a failed stamp"
jq -c 'select(.script == "dream-accept" and .exit_code != 0 and ((.message // "") | test("archived_at")))' \
  "$BRAIN_DIR/error-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q . \
  || fail "K10: a failed archived_at stamp left no error-log row (stderr: $ERR)"
pass "K10: a failed archived_at stamp exits 1, keeps staging and logs the failure"
# The pages are already applied; a re-accept must finish the job (it only stamps and cleans up, C1).
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
A=$(jq -r '.archived_at // ""' "$D/status.json" 2>/dev/null | tr -d '\r')
[ "$rc" -eq 0 ] && [ -n "$A" ] && [ "$A" != "null" ] && [ ! -d "$D/staging" ] \
  && [ -f "$KNOWLEDGE_DIR/wiki/entities/p9.md" ] \
  && pass "K10: the re-accept after a failed stamp archives the dream (rc=0, archived_at=$A, staging cleaned, p9 live)" \
  || fail "K10: re-accept after a failed stamp did not finish (rc=$rc archived_at='$A' staging=$([ -d "$D/staging" ] && echo kept || echo gone))"
rm -rf "$SB"


# === C1 (R3-B): that re-accept must not apply the dream a second time. The first run's FORGET
# moved p1 to wiki-archive and consumed the manifest, and merge-edges appended the proposed edge;
# staging still holds p1 and proposed-edges.json, so re-applying brought p1 back to live (live AND
# archive) and appended the edge again. The `.applied` marker, written once the apply, FORGET and
# edge merge are done, makes the re-accept only reindex, stamp and clean up.
setup 4 "p1 p2 p3 p4 p9"   # p9 is new; p1 is in the forget manifest
D="$BRAIN_DIR/dreams/drm_test"
printf 'p1\tentities\n' > "$D/forget-manifest.tsv"
printf '{"relations":[{"from":"p2","type":"relates","to":"p3"}]}\n' > "$D/staging/proposed-edges.json"
JQSHIM="$SB/jqshim"; mkdir -p "$JQSHIM"
printf '#!%s\ncase "$*" in *".archived_at = \\$t"*) echo "jq: simulated write failure" >&2; exit 2 ;; esac\nexec %q "$@"\n' \
  "$BASH" "$REAL_JQ" > "$JQSHIM/jq"; chmod +x "$JQSHIM/jq"
PATH="$JQSHIM:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_FORGET_MIN_AGE_DAYS=0 bash "$ACCEPT" drm_test >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || fail "C1: precondition — the shimmed stamp did not fail (rc=$rc)"
{ [ -f "$BRAIN_DIR/wiki-archive/entities/p1.md" ] && [ ! -f "$KNOWLEDGE_DIR/wiki/entities/p1.md" ]; } \
  || fail "C1: precondition — the first run did not archive p1"
E1=$(grep -c . "$KNOWLEDGE_DIR/graph/edges.jsonl" 2>/dev/null); E1=${E1:-0}
[ "$E1" -ge 1 ] || fail "C1: precondition — the first run landed no edge (edges.jsonl has $E1 lines)"
# The applied marker lives beside the dream dir, outside what the dream-runner may write (P-C4). Its
# presence is read now (the re-accept removes it) and asserted LAST (R3-C P-Q4): the behaviour
# checks come first, so a build without the marker fails on what the user would see.
C1_MARK="$BRAIN_DIR/dreams/.applied-drm_test"
C1_MARKED=0; [ -f "$C1_MARK" ] && C1_MARKED=1
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SB_FORGET_MIN_AGE_DAYS=0 bash "$ACCEPT" drm_test 2>&1); rc=$?
A=$(jq -r '.archived_at // ""' "$D/status.json" 2>/dev/null | tr -d '\r')
{ [ "$rc" -eq 0 ] && [ -n "$A" ] && [ "$A" != "null" ] && [ ! -d "$D/staging" ]; } \
  || fail "C1: the re-accept did not finish (rc=$rc archived_at='$A' staging=$([ -d "$D/staging" ] && echo kept || echo gone)): $OUT"
[ ! -f "$KNOWLEDGE_DIR/wiki/entities/p1.md" ] || fail "C1: the re-accept brought archived p1 back to the live wiki"
[ -f "$KNOWLEDGE_DIR/wiki/entities/p9.md" ] || fail "C1: p9 (applied by the first run) is not live"
P1ROWS=$(grep -c '"slug":"p1"' "$BRAIN_DIR/wiki-archive-log.jsonl" 2>/dev/null); P1ROWS=${P1ROWS:-0}
[ "$P1ROWS" = 1 ] || fail "C1: wiki-archive-log has $P1ROWS p1 rows (want 1)"
E2=$(grep -c . "$KNOWLEDGE_DIR/graph/edges.jsonl" 2>/dev/null); E2=${E2:-0}
[ "$E2" = "$E1" ] || fail "C1: the re-accept appended edges again ($E1 -> $E2 lines)"
[ "$C1_MARKED" = 1 ] || fail "C1: the applied-but-unstamped dream carried no marker at $C1_MARK"
[ ! -e "$C1_MARK" ] || fail "C1: the finished re-accept left its marker at $C1_MARK"
pass "C1: the re-accept after a failed stamp only finishes (p1 stays archived, 1 archive row, edges $E1 -> $E2, marker cleaned)"
rm -rf "$SB"

# === P-C4 (R3-C): the applied marker sat INSIDE the dream dir ($D/.applied), which the dream-runner
# may write (K12 confines its Write/Edit to that dir). An injected runner that planted one made
# dream_accept skip the apply, stamp archived_at, delete staging and print a success built from its
# own status.json: the dream's output was lost under a success message. The marker now lives at
# $BRAIN_DIR/dreams/.applied-<id> (pg_dream_confine denies the runner there; tests/test-protocol-guard.sh
# locks that); a .applied found inside the dream dir is ignored, with one error row.
setup 4 "p1 p2 p3 p4 p9"   # p9 is new
D="$BRAIN_DIR/dreams/drm_test"
jq -nc '{id:"drm_test",status:"completed",archived_at:null,outputs:{pages_added:7,pages_modified:0,pages_removed:0}}' > "$D/status.json"
printf '2026-10-08T00:00:00Z\n' > "$D/.applied"   # planted by the runner
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$ACCEPT" drm_test 2>&1); rc=$?
A=$(jq -r '.archived_at // ""' "$D/status.json" 2>/dev/null | tr -d '\r')
[ -f "$KNOWLEDGE_DIR/wiki/entities/p9.md" ] \
  || fail "P-C4: a .applied planted in the dream dir skipped the apply: p9 is not live (rc=$rc): $OUT"
{ [ "$rc" -eq 0 ] && [ -n "$A" ] && [ "$A" != "null" ] && [ ! -d "$D/staging" ]; } \
  || fail "P-C4: the accept with a planted .applied did not finish (rc=$rc archived_at='$A'): $OUT"
jq -c 'select(.script == "dream-accept" and .exit_code == 1 and ((.message // "") | test("\\.applied")))' \
  "$BRAIN_DIR/error-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q . \
  || fail "P-C4: the planted .applied left no error row (error-log: $(tail -1 "$BRAIN_DIR/error-log.jsonl" 2>/dev/null))"
[ ! -e "$BRAIN_DIR/dreams/.applied-drm_test" ] || fail "P-C4: the finished accept left its own marker behind"
pass "P-C4: a .applied planted in the dream dir does not short-circuit the accept (p9 applied, archived, one error row)"
rm -rf "$SB"

echo "ALL PASS"
