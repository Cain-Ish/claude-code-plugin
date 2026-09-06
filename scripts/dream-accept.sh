#!/bin/bash
# Accept a completed dream: copy staging wiki to live wiki, reindex, archive dream.
#
# Usage: dream-accept.sh <dream_id>
set -u
source "$(dirname "$0")/lib.sh"

# Windows (git-bash): the MCP passes BRAIN_DIR/KNOWLEDGE_DIR in Windows form (C:\...). GNU tar and
# rsync parse a leading drive letter as a REMOTE host:path (`tar -f C:\...` → "Cannot connect to C:"),
# so the pre-accept backup AND the rsync apply both fail-closed on Windows. Normalize to MSYS form
# (/c/...) via cygpath, which exists only under git-bash/Cygwin; on POSIX cygpath is absent and this
# is a no-op (real Linux/macOS paths have no drive letter). dream-snapshot.sh is unaffected — it uses
# mkdir/cp, which the MSYS runtime path-translates; tar/rsync do not.
_to_msys() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi; }
BRAIN_DIR=$(_to_msys "$BRAIN_DIR")

DREAM_ID="${1:?usage: dream-accept.sh <dream_id>}"
DREAM_DIR="$BRAIN_DIR/dreams/$DREAM_ID"

# _release_holds <held_root>: apply previously-held untrusted pages to the live wiki after an
# explicit confirm. ONE implementation, two callers — the normal already-archived dream, and an
# ORPHANED hold whose dream dir was pruned by retention (holds deliberately outlive their dream,
# so they must stay releasable afterwards or "never deleted" degrades into "never applicable").
_release_holds() {
  local _HELD_ROOT="$1"
  RKD="$(sb_knowledge_dir)"; RKD=$(_to_msys "$RKD")
  # Same reversibility floor as every other apply path (0.28.1): tarball live FIRST and
  # fail CLOSED. An operator confirming a hold is not a reason to skip the undo trail.
  if [ "${SB_DREAM_ACCEPT_SKIP_BACKUP:-0}" != "1" ] && [ -d "$RKD/wiki" ]; then
    R_BK="$BRAIN_DIR/wiki-backup-pre-release-$(date -u +%Y%m%d%H%M%SZ).tgz"
    _RBK="wiki"; [ -d "$RKD/graph" ] && _RBK="wiki graph"
    # shellcheck disable=SC2086 -- deliberate word-split (two literal path args)
    if ! tar czf "$R_BK" -C "$RKD" $_RBK 2>/dev/null || [ ! -s "$R_BK" ]; then
      rm -f "$R_BK" 2>/dev/null
      echo "error: refusing to release held pages for $DREAM_ID — could not back up the live wiki first" >&2
      exit 1
    fi
  fi
  RN=0; RSKIP=0
  while IFS= read -r _hf; do
    [ -n "$_hf" ] || continue
    _rel=${_hf#"$_HELD_ROOT/"}
    _dest="$RKD/wiki/$_rel"
    # A live page may have appeared at this slug while the hold sat here (the drainer and
    # the maintainer keep writing). NEVER clobber it, and never write THROUGH a symlink.
    if [ -L "$_dest" ]; then
      echo "RELEASE: skipping '$_rel' — destination is a symlink (never written through)" >&2
      RSKIP=$((RSKIP + 1)); continue
    fi
    if [ -e "$_dest" ]; then
      echo "RELEASE: skipping '$_rel' — a live page now exists at that slug (held copy kept, not applied)" >&2
      RSKIP=$((RSKIP + 1)); continue
    fi
    if mkdir -p "$RKD/wiki/$(dirname "$_rel")" && cp -p "$_hf" "$_dest"; then
      rm -f "$_hf" 2>/dev/null; RN=$((RN + 1))
    else
      echo "RELEASE: FAILED to write '$_rel' (held copy kept)" >&2
      sb_log_error "dream-accept" "held-untrusted release failed for $_rel in $DREAM_ID (held copy retained)" 0
      RSKIP=$((RSKIP + 1))
    fi
  done < <(find "$_HELD_ROOT" -type f -name '*.md' 2>/dev/null)
  if [ "$RN" -gt 0 ] || [ "$RSKIP" -gt 0 ]; then
    # Only drop the hold area once nothing is left un-released; skipped pages stay held.
    [ "$RSKIP" -eq 0 ] && rm -rf "$_HELD_ROOT"
    [ "$RN" -gt 0 ] && sb_reindex_wiki "$RKD"
    echo "RELEASED $RN previously-held untrusted page(s) into the live wiki (confirmed); $RSKIP skipped/retained."
    return 0
  fi
  return 1   # nothing was held here — let the caller fall through to its normal error
}

if [ ! -f "$DREAM_DIR/status.json" ]; then
  # Holds OUTLIVE their dream on purpose (retention prunes dream dirs past keep-count), so a
  # release must still be possible after the dream itself is gone — otherwise "never deleted"
  # would mean "kept forever and never applicable", which is worse than deleting them.
  if [ "${SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED:-0}" = "1" ] && [ -d "$BRAIN_DIR/held-untrusted/$DREAM_ID" ]; then
    _release_holds "$BRAIN_DIR/held-untrusted/$DREAM_ID" && exit 0
    echo "error: no held pages to release for $DREAM_ID" >&2
    exit 1
  else
    echo "error: dream not found: $DREAM_ID" >&2
    exit 1
  fi
fi

STATUS=$(jq -r '.status' "$DREAM_DIR/status.json" 2>/dev/null | tr -d '\r')
if [ "$STATUS" != "completed" ]; then
  echo "error: dream $DREAM_ID is $STATUS, not completed" >&2
  exit 1
fi

ARCHIVED=$(jq -r '.archived_at // ""' "$DREAM_DIR/status.json" 2>/dev/null | tr -d '\r')
if [ -n "$ARCHIVED" ] && [ "$ARCHIVED" != "null" ]; then
  # Release path for the held-untrusted gate: an already-accepted dream whose held
  # pages are being confirmed after the fact. Applies ONLY the held pages (paths come
  # from our own filesystem walk, not user input), reindexes, and clears the hold.
  _HELD_ROOT="$BRAIN_DIR/held-untrusted/$DREAM_ID"
  # Legacy location (holds written before they moved out of the prunable dream dir).
  [ -d "$_HELD_ROOT" ] || _HELD_ROOT="$DREAM_DIR/held-untrusted"
  if [ "${SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED:-0}" = "1" ] && [ -d "$_HELD_ROOT" ]; then
    _release_holds "$_HELD_ROOT" && exit 0
  fi
  echo "error: dream $DREAM_ID already accepted/archived at $ARCHIVED" >&2
  exit 1
fi

KNOWLEDGE_DIR="$(sb_knowledge_dir)"
KNOWLEDGE_DIR=$(_to_msys "$KNOWLEDGE_DIR")   # MSYS-normalize (Windows): tar -C / rsync dest must not be C:\...
LIVE_WIKI="$KNOWLEDGE_DIR/wiki"
STAGING_WIKI="$DREAM_DIR/staging/wiki"

if [ ! -d "$STAGING_WIKI" ]; then
  echo "error: staging wiki not found" >&2
  exit 1
fi

# SECURITY (C/headless-maintainer hardening): staging is written by the consolidation agent —
# under the opt-in headless maintainer that agent is UNATTENDED and could be prompt-injected by
# captured wiki content. A symlink in staging that points OUTSIDE the wiki (e.g. → ~/.claude or
# ~/knowledge/graph) would, on the copy below, plant a write-through/read-through trapdoor into the
# LIVE wiki (a later unjailed write escapes; creds get read into a page). Refuse the accept if any
# staged symlink escapes the staging tree. In-tree relative aliases (e.g. security/latest.md ->
# 2026-06-06.md) are legitimate and preserved.
# Resolve BEFORE validate (the symlink-guard.sh doctrine): canonicalize the base too, else a
# symlinked ancestor (macOS /private/tmp, a symlinked ~/.second-brain) makes every legit in-tree
# alias resolve to a path that doesn't match the raw prefix → false-reject of a normal accept.
# Resolve targets with the PORTABLE sb_realpath (lib.sh), NOT bare `readlink -f`: stock
# macOS/BSD readlink has no -f, so `readlink -f` returned empty there → every staged symlink
# (incl. the legit security/latest.md alias) looked out-of-tree → every macOS accept was
# refused. sb_realpath canonicalizes the base too (resolve-before-validate).
# sb_realpath on an existing dir (verified above) only returns empty under a TOCTOU race (the dir
# vanishing mid-accept). This fallback is SECURITY-load-bearing, not cosmetic: an empty _SW makes
# the test `[[ "$_t" == "$_SW"/* ]]` degrade to `[[ "$_t" == /* ]]`, which matches EVERY absolute
# path — so every out-of-tree symlink would look in-tree and the escape guard would silently accept
# them all. Keep _SW non-empty so the prefix test stays meaningful.
_SW=$(sb_realpath "$STAGING_WIKI"); [ -n "$_SW" ] || _SW="$STAGING_WIKI"
OOT_LINKS=$(find "$STAGING_WIKI" -type l 2>/dev/null | while read -r _l; do
  _t=$(sb_realpath "$_l")
  # In-tree (resolves under the staging wiki root) -> ok; empty/anything else is an escape.
  # `[[ ]]` glob-match, NOT `case`: a `case` inside this $(...) command substitution is
  # mis-parsed by the bash 3.2 parser (macOS /bin/bash) -> the whole script fails to load.
  # `$_SW` is quoted so its own glob chars stay literal; only `/*` is the wildcard.
  # (both hazards guarded by tests/test-script-portability.sh check 8)
  [[ "$_t" == "$_SW"/* ]] || printf '%s\n' "$_l"
done)
if [ -n "$OOT_LINKS" ]; then
  echo "error: staging contains symlink(s) pointing outside the wiki — refusing accept (escape risk):" >&2
  # $OOT_LINKS is newline-delimited; read line-by-line so a path with spaces prints intact
  # (an unquoted `printf … $OOT_LINKS` would word-split it). Display-only. Here-string, not a pipe,
  # to avoid a needless subshell (`<<<` is bash 3.2 / macOS / Git-Bash safe).
  while IFS= read -r _oot; do printf '  %s\n' "$_oot" >&2; done <<< "$OOT_LINKS"
  exit 1
fi

# Node-shape convergence: run the SAME node-shaper the maintainer uses on the
# STAGING wiki BEFORE it touches live, so dream-authored pages arrive in
# canonical shape (valid β related:/tags:, patched required fields) rather than
# relying on the post-rsync reindex to clean them after the fact. Fail-open —
# a validator hiccup must never block an accepted dream from merging.
_DREAM_FIXED=$(sb_validate_wiki "$DREAM_DIR/staging" 2>/dev/null || echo 0)
[ "${_DREAM_FIXED:-0}" != "0" ] && echo "Normalized $_DREAM_FIXED staging page(s) to canonical shape before merge." >&2

# F1 (premise review): STAGING-VALIDITY FLOOR before the destructive rsync. The
# headless dream agent self-asserts status=completed; a timeout / prompt-injection
# / disk-full could leave staging EMPTY or truncated, and `rsync --delete` would
# then MIRROR that onto live — deleting every live page. A consolidation merges/
# archives a FEW pages; it never guts the wiki. Refuse if staging is empty, or
# has fewer than SB_DREAM_ACCEPT_MIN_RATIO% (default 50) of the live page count.
# Protects EVERY accept (manual + auto). Set the ratio to 0 to disable (not advised).
_count_pages() { find "$1" -name '*.md' ! -name 'index.md' -type f 2>/dev/null | wc -l | tr -d ' '; }
STAGING_PAGES=$(_count_pages "$STAGING_WIKI")
LIVE_PAGES=$(_count_pages "$LIVE_WIKI")
MIN_RATIO="${SB_DREAM_ACCEPT_MIN_RATIO:-50}"
case "$MIN_RATIO" in ''|*[!0-9]*) MIN_RATIO=50 ;; esac
if [ "$LIVE_PAGES" -gt 0 ] && [ "$MIN_RATIO" -gt 0 ]; then
  if [ "$STAGING_PAGES" -eq 0 ]; then
    echo "error: refusing accept of $DREAM_ID — staging wiki is EMPTY but live has $LIVE_PAGES page(s); a broken dream must not --delete the live wiki" >&2
    exit 1
  fi
  if [ $(( STAGING_PAGES * 100 )) -lt $(( LIVE_PAGES * MIN_RATIO )) ]; then
    echo "error: refusing accept of $DREAM_ID — staging has $STAGING_PAGES page(s) vs $LIVE_PAGES live (< ${MIN_RATIO}%); looks like a truncated/broken dream, not a consolidation" >&2
    exit 1
  fi
fi

# F3 (premise review): SB_DREAM_ACCEPT_NO_DELETE=1 (set by auto_accept=safe) makes
# "safe" mean what it says — refuse if the dream would remove ANY live page
# (dedup/summarize delete pages directly in staging, leaving no forget-manifest
# entry, so the manifest check alone is not a real no-deletions guarantee).
if [ "${SB_DREAM_ACCEPT_NO_DELETE:-0}" = "1" ]; then
  DELETED=$(comm -23 \
    <(cd "$LIVE_WIKI" 2>/dev/null && find . -name '*.md' ! -name 'index.md' -type f | sort || true) \
    <(cd "$STAGING_WIKI" 2>/dev/null && find . -name '*.md' ! -name 'index.md' -type f | sort || true) 2>/dev/null)
  if [ -n "$DELETED" ]; then
    echo "error: refusing accept of $DREAM_ID — auto_accept=safe but the dream removes live page(s): $(printf '%s' "$DELETED" | tr '\n' ' ' | head -c 300)" >&2
    exit 1
  fi
fi

# Universal backup safety net (0.28.1): tarball the LIVE wiki BEFORE the
# destructive rsync, so a MANUAL accept is reversible too. Previously only the
# AUTO-accept path (maintain-llm-drain's AA_BACKUP) backed up; the manual path's
# "your accept IS the confirmation" left it with no undo, so a bad consolidation
# accepted by hand overwrote live with no tarball. Fail CLOSED: if the backup
# can't be written, REFUSE rather than overwrite live unprotected (a disk-full /
# unwritable BRAIN_DIR is exactly when a wipe would be unrecoverable). The auto
# path already tarballs, so it passes SB_DREAM_ACCEPT_SKIP_BACKUP=1 to avoid a
# duplicate. Restore with: tar xzf <tgz> -C "$KNOWLEDGE_DIR".
if [ "${SB_DREAM_ACCEPT_SKIP_BACKUP:-0}" != "1" ] && [ -d "$LIVE_WIKI" ]; then
  ACCEPT_BK="$BRAIN_DIR/wiki-backup-pre-accept-$(date -u +%Y%m%d%H%M%SZ).tgz"
  # `wiki` AND `graph`: since Phase 3 the accept also APPENDS to graph/edges.jsonl, so a
  # wiki-only tarball no longer undoes the whole accept — the very claim it exists to back.
  _BKP="wiki"; [ -d "$KNOWLEDGE_DIR/graph" ] && _BKP="wiki graph"
  # shellcheck disable=SC2086 -- deliberate word-split (two literal path args)
  _bkerr=$(tar czf "$ACCEPT_BK" -C "$KNOWLEDGE_DIR" $_BKP 2>&1); _bkrc=$?
  if [ "$_bkrc" -eq 0 ] && [ -s "$ACCEPT_BK" ]; then
    echo "Backed up live wiki → $ACCEPT_BK before applying."
  else
    rm -f "$ACCEPT_BK" 2>/dev/null
    # Fail-loud with tar's ACTUAL error: a generic "disk full" guess hid a Windows tar host:path
    # bug (`tar -f C:\...` → "Cannot connect to C:") for a whole release. Never overwrite unprotected.
    echo "error: refusing accept of $DREAM_ID — could not back up the live wiki first; not overwriting live unprotected. tar (rc=$_bkrc): ${_bkerr:-<no stderr>}. If the wiki is genuinely fine, override with SB_DREAM_ACCEPT_SKIP_BACKUP=1." >&2
    exit 1
  fi
fi

# Held-untrusted confirm gate (P6 arm-gate). CORROBORATION is the dividing line:
#
#   NEW page, no live counterpart  → HELD. Conjured from nothing by transcript-derived
#     text; nothing in the wiki vouches for it. Moved to $BRAIN_DIR/held-untrusted/<dream>/
#     (OUTSIDE the dream dir — dream retention prunes old dream dirs, which would have
#     deleted the holds and made "never deleted" false), excluded from the apply.
#   FOLD-IN onto an existing live page → APPLIED. The live page's existence is the
#     corroboration (the original P6 T5 rule), the appended claims sit under an explicit
#     "## Candidate facts (untrusted)" heading, retrieval wraps them in the
#     untrusted-reference banner, and the pre-accept tarball makes the whole apply
#     reversible. Reverting these instead cost the UPDATE lane its entire output every
#     cycle AND destroyed it (staging is rm -rf'ed below, so a reverted fold-in was
#     unrecoverable) — a data-loss bug, not a safety win.
#
# Confirm with SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1 (auto_accept=all passes it) to apply
# held pages directly.
# FAIL-LOUD, FAIL-CLOSED: if a hold fails we ABORT the accept. Continuing would leave the
# unconfirmed page in staging and the apply below would merge it into live — the exact
# outcome this gate exists to prevent. (Nothing has been written to live at this point.)
HELD_N=0
HELD_ROOT="$BRAIN_DIR/held-untrusted/$DREAM_ID"
if [ "${SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED:-0}" != "1" ] && [ -d "$STAGING_WIKI" ]; then
  HELD_LIST=""
  while IFS= read -r _uf; do
    [ -n "$_uf" ] || continue
    _rel=${_uf#"$STAGING_WIKI/"}
    [ -f "$LIVE_WIKI/$_rel" ] && continue          # corroborated fold-in → applies normally
    if ! mkdir -p "$HELD_ROOT/$(dirname "$_rel")" || ! mv "$_uf" "$HELD_ROOT/$_rel"; then
      echo "error: refusing accept of $DREAM_ID — could not hold untrusted-only new page '$_rel'; aborting rather than applying it unconfirmed" >&2
      sb_log_error "dream-accept" "held-untrusted hold failed for $_rel in $DREAM_ID — accept ABORTED (fail-closed; the page stayed in staging and would otherwise have been applied)" 0
      exit 1
    fi
    HELD_N=$((HELD_N + 1)); HELD_LIST="$HELD_LIST $_rel"
  done < <(grep -rl '^provenance: untrusted-derived' "$STAGING_WIKI" 2>/dev/null)
  if [ "$HELD_N" -gt 0 ]; then
    echo "HELD $HELD_N untrusted-only new page(s) pending confirm:$HELD_LIST (release: bash scripts/dream-accept.sh $DREAM_ID with SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1)"
    # The stdout line above is swallowed by unattended callers, so ALSO record it where the
    # SessionStart banner and any operator can find it — an invisible hold is a silent drop.
    sb_log_error "dream-accept" "HELD $HELD_N untrusted-only new page(s) from $DREAM_ID in $HELD_ROOT — release with SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1" 0
  fi
fi

# Post-snapshot protection (flow/premise review): staging is a full-mirror
# SNAPSHOT taken at dream-create time (status.json .created_at). A completed
# dream can sit unreviewed for DAYS while the drainer / knowledge-maintainer /
# archive_to_wiki keep writing NEW pages to the LIVE wiki. Those pages are not
# in staging, so a bare `rsync --delete` silently deletes them (and an older
# staging copy would clobber a live page edited after the snapshot). The F1
# floor only catches >50% loss; diff.md — computed at runner-completion — never
# lists them. Protect every live page MODIFIED AFTER the snapshot: neither
# delete nor overwrite it (merge-only; the newer LIVE version wins). A reference
# file carries the snapshot mtime so `find -newer` (POSIX) stays portable — no
# ISO date-parsing differences across GNU/BSD.
PROTECT=""
PROTECT_OK=1     # 0 = snapshot time unusable → fail-SAFE: apply merge-only, never --delete
_snap_ref="$DREAM_DIR/.snap-ref.$$"
CREATED_AT=$(jq -r '.created_at // ""' "$DREAM_DIR/status.json" 2>/dev/null | tr -d '\r')
if [ -d "$LIVE_WIKI" ]; then
  _ref_ok=0
  if [ -n "$CREATED_AT" ] && [ "$CREATED_AT" != "null" ]; then
    if touch -d "$CREATED_AT" "$_snap_ref" 2>/dev/null; then _ref_ok=1        # GNU
    else
      _tt=$(printf '%s' "$CREATED_AT" | sed -E 's/[^0-9]//g')                  # 2026-07-01T12:00:00Z -> 20260701120000
      # TZ=UTC: created_at is UTC ('Z'), but POSIX `touch -t` reads LOCAL time —
      # without the override the protect boundary shifts by the UTC offset
      # (west-of-UTC leaves up to ~12h of post-snapshot writes unprotected).
      if   [ "${#_tt}" -ge 14 ]; then TZ=UTC touch -t "${_tt:0:12}.${_tt:12:2}" "$_snap_ref" 2>/dev/null && _ref_ok=1   # POSIX/BSD, with seconds
      elif [ "${#_tt}" -ge 12 ]; then TZ=UTC touch -t "${_tt:0:12}" "$_snap_ref" 2>/dev/null && _ref_ok=1              # seconds-less timestamp
      fi
    fi
  fi
  if [ "$_ref_ok" = "1" ]; then
    PROTECT=$(cd "$LIVE_WIKI" 2>/dev/null && find . -name '*.md' ! -name 'index.md' -type f -newer "$_snap_ref" 2>/dev/null | sed 's#^\./##')
  else
    # Fail-SAFE: with no trustworthy snapshot time we cannot tell which live
    # pages postdate the dream, so --delete must not run at all this accept.
    PROTECT_OK=0
    echo "warn: dream $DREAM_ID has no usable created_at ('${CREATED_AT:-<empty>}') — applying merge-only (dream deletions skipped) to protect post-snapshot live pages." >&2
  fi
  rm -f "$_snap_ref" 2>/dev/null
fi

# Apply: rsync staging over live. --delete removes live pages the dream dropped
# (dedup/forget) EXCEPT the post-snapshot pages protected above. --safe-links
# drops any out-of-tree symlink as defense-in-depth behind the reject guard.
# D084: none of these apply commands had their exit status checked — a partial
# failure (EACCES on one live subdir/file, ENOSPC, an rsync partial-transfer)
# fell straight through to the FORGET manifest, edge merge, reindex, archived_at
# stamp and `rm -rf staging/transcripts` below, so the dream's only copy of its
# output was destroyed and the accept was reported a success. Capture the exit
# status of every branch into APPLY_RC and check it before any of that runs.
APPLY_RC=0
APPLY_ERR=""
if command -v rsync >/dev/null 2>&1; then
  if [ "$PROTECT_OK" != "1" ]; then
    APPLY_ERR=$(rsync -a --safe-links "$STAGING_WIKI/" "$LIVE_WIKI/" 2>&1); APPLY_RC=$?    # merge-only (see warn above)
  elif [ -n "$PROTECT" ]; then
    _exf=$(mktemp)
    # while-read (never an unquoted expansion — a page path containing a space
    # must not word-split into broken patterns), each anchored to the transfer
    # root ('/'-prefixed) so rsync neither deletes nor overwrites it — the
    # newer live page is kept as-is.
    printf '%s\n' "$PROTECT" | while IFS= read -r _rel; do
      [ -n "$_rel" ] && printf '/%s\n' "$_rel"
    done > "$_exf"
    APPLY_ERR=$(rsync -a --delete --safe-links --exclude-from="$_exf" "$STAGING_WIKI/" "$LIVE_WIKI/" 2>&1); APPLY_RC=$?
    rm -f "$_exf"
    [ "$APPLY_RC" -eq 0 ] && echo "Preserved $(printf '%s\n' "$PROTECT" | grep -c .) live page(s) modified after the dream snapshot (merge-only; not deleted or overwritten)."
  else
    APPLY_ERR=$(rsync -a --delete --safe-links "$STAGING_WIKI/" "$LIVE_WIKI/" 2>&1); APPLY_RC=$?
  fi
else
  # No rsync — the NORMAL apply path on Windows git-bash (the primary dev
  # platform), not a rare fallback. MERGE staging into live WITHOUT `rm -rf`
  # (which would nuke every post-snapshot page). Post-snapshot EDITS must
  # survive too, not just new pages: stash every protected page, merge-copy
  # staging over live (namesakes overwritten), restore the stash — the newer
  # live version wins, the same contract as the rsync exclude above.
  _stash=""
  if [ -n "$PROTECT" ]; then
    _stash=$(mktemp -d)
    printf '%s\n' "$PROTECT" | while IFS= read -r _rel; do
      { [ -n "$_rel" ] && [ -f "$LIVE_WIKI/$_rel" ]; } || continue
      mkdir -p "$_stash/$(dirname "$_rel")" && cp -p "$LIVE_WIKI/$_rel" "$_stash/$_rel"
    done
  fi
  # First attempt's stderr is discarded on purpose — it commonly fails only
  # because $LIVE_WIKI doesn't exist yet, which the mkdir -p fallback fixes;
  # the SECOND attempt's exit status/stderr is the one that matters.
  cp -r "$STAGING_WIKI/." "$LIVE_WIKI/" 2>/dev/null
  APPLY_RC=$?
  if [ "$APPLY_RC" -ne 0 ]; then
    APPLY_ERR=$(mkdir -p "$LIVE_WIKI" && cp -r "$STAGING_WIKI/." "$LIVE_WIKI/" 2>&1); APPLY_RC=$?
  fi
  if [ "$APPLY_RC" -eq 0 ] && [ -n "$_stash" ]; then
    (cd "$_stash" 2>/dev/null && find . -type f 2>/dev/null | sed 's#^\./##') | while IFS= read -r _rel; do
      [ -n "$_rel" ] && cp -p "$_stash/$_rel" "$LIVE_WIKI/$_rel"
    done
    echo "Preserved $(printf '%s\n' "$PROTECT" | grep -c .) live page(s) modified after the dream snapshot (restored over staging copies)."
    rm -rf "$_stash"   # only cleared once its contents are safely restored onto live
  fi
  # D084 (review follow-up): $_stash is the ONLY copy of every post-snapshot
  # live page edit. The unconditional `rm -rf` that used to sit here deleted
  # it even when the cp -r apply above FAILED (APPLY_RC != 0) — destroying the
  # one thing that could have recovered those edits. Leave it on disk on
  # failure; the error block below names its path so it can be restored by hand.
  # Honest accounting (not silent): this path applies NO dream deletions —
  # FORGET/DEDUPLICATE removals stay in place until an rsync-equipped accept.
  [ "$APPLY_RC" -eq 0 ] && echo "note: rsync unavailable — staging merged over live; dream deletions were NOT applied."
fi

if [ "$APPLY_RC" -ne 0 ]; then
  _bk_msg="no local backup was taken for this accept (SB_DREAM_ACCEPT_SKIP_BACKUP was set) — restore from the caller's own pre-accept backup instead"
  [ -n "${ACCEPT_BK:-}" ] && [ -f "$ACCEPT_BK" ] && _bk_msg="restore the live wiki with: tar xzf \"$ACCEPT_BK\" -C \"$KNOWLEDGE_DIR\""
  _stash_msg=""
  [ -n "${_stash:-}" ] && [ -d "$_stash" ] && _stash_msg=" post-snapshot live page edits were stashed at $_stash and were NOT deleted — restore them manually;"
  echo "error: apply of dream $DREAM_ID FAILED partway (rc=$APPLY_RC: ${APPLY_ERR:-<no output>}) — staging KEPT (not deleted), archived_at NOT stamped so this can be retried;$_stash_msg $_bk_msg" >&2
  sb_log_error "dream-accept" "apply of $DREAM_ID failed (rc=$APPLY_RC): ${APPLY_ERR:-<no output>}; staging retained, archive skipped;$_stash_msg $_bk_msg" "$APPLY_RC"
  exit 1
fi

# FORGET manifest — the machine lock for what was previously dream-skill prose
# only (arm-gate from the P6 v2 decision): archive still-forgettable manifest
# pages from the POST-accept live wiki. Reversible move, never a delete —
# scripts/wiki-restore.sh undoes. Runs on EVERY accept path (skill, auto_accept,
# raw MCP dream_accept); before this, any non-skill accept silently dropped the
# manifest. auto_accept=safe never reaches here with a manifest present
# (sb_auto_accept_decision: safe-refuses-forget).
MANIFEST="$DREAM_DIR/forget-manifest.tsv"
FORGOT_N=0
if [ -f "$MANIFEST" ]; then
  ARC_DIR="$BRAIN_DIR/wiki-archive"; ARC_LOG="$BRAIN_DIR/wiki-archive-log.jsonl"
  # Re-score guard: the manifest was built BEFORE consolidation — re-validate
  # each slug against the post-accept wiki and keep any page the dream just
  # enriched (now linked / higher-scoring). Scorer failure = archive NOTHING
  # (fail-safe), keep the manifest for an attended pass, log loud.
  _ffl=$(mktemp)
  if bash "$(dirname "$0")/wiki-forget-score.sh" > "$_ffl" 2>/dev/null; then
    STILL=$(awk -F'\t' -v fl="${SB_FORGET_FLOOR:-0.15}" '($1+0)<fl && $5==""{print $2}' "$_ffl")
    mkdir -p "$ARC_DIR"
    while IFS=$'\t' read -r _slug _cat _rest; do
      _slug=${_slug%$'\r'}; _cat=${_cat%$'\r'}
      [ -n "$_slug" ] && [ -n "$_cat" ] || continue
      # The manifest is LLM-influenced DATA: validate both fields before they
      # touch a path (no separators, no dotfiles/.. — mirrors validateSlug).
      case "$_slug" in .*|*[!a-zA-Z0-9._-]*) echo "FORGET: skipping invalid slug '$_slug'" >&2; continue ;; esac
      case "$_cat"  in .*|*[!a-zA-Z0-9_-]*)  echo "FORGET: skipping invalid category '$_cat'" >&2; continue ;; esac
      printf '%s\n' "$STILL" | grep -qxF -- "$_slug" \
        || { echo "FORGET: keeping '$_slug' — no longer low-value after consolidation"; continue; }
      _srcp="$LIVE_WIKI/$_cat/$_slug.md"
      [ -f "$_srcp" ] || continue
      mkdir -p "$ARC_DIR/$_cat" && mv "$_srcp" "$ARC_DIR/$_cat/$_slug.md" || continue
      printf '{"event":"archived","slug":"%s","category":"%s","dream":"%s","date":"%s"}\n' \
        "$_slug" "$_cat" "$DREAM_ID" "$(date -u +%FT%TZ)" >> "$ARC_LOG"
      FORGOT_N=$((FORGOT_N + 1))
    done < "$MANIFEST"
    rm -f "$MANIFEST"
    [ "$FORGOT_N" -gt 0 ] && echo "FORGET: archived $FORGOT_N page(s) → $ARC_DIR (restore: scripts/wiki-restore.sh <slug>)"
  else
    sb_log_error "dream-accept" "wiki-forget-score.sh failed — archiving nothing from $DREAM_ID's forget manifest (manifest kept for attended review)" 0
  fi
  rm -f "$_ffl"
fi

# PROPOSED EDGES (Phase 3): Stage B resolved relation facts to slugs but did NOT write them —
# graph/edges.jsonl is an append-only LIVE log that is never snapshotted into a dream, so it can
# only be written on this side. merge-edges.sh re-validates BOTH endpoints against the live wiki
# (a held-untrusted page never resolves, so its edges quarantine instead of dangling), detects
# contradictions into conflicts.jsonl, and tags the cohort so one jq loop can invalidate this
# dream's edges wholesale. Fail-soft: a graph hiccup must not fail an applied accept.
_PE="$DREAM_DIR/staging/proposed-edges.json"
if [ -s "$_PE" ] && [ -f "$(dirname "$0")/merge-edges.sh" ]; then
  # ENFORCE THE rel LOCK HERE, at the boundary that actually feeds the graph. The schema
  # restricts what Stage A may emit, but proposed-edges.json is a FILE on disk: anything that
  # writes it (a future Stage B change, a tampered dream dir) could name `supersedes`, and
  # merge-edges.sh accepts all five edge types. A lock one hop upstream of the write is no lock.
  _ALLOWED=$(jq -r '.candidate_facts.relation_edge_types | join(" ")' "$(dirname "$0")/../kb-schema.json"  | tr -d '\r')
  [ -n "$_ALLOWED" ] || _ALLOWED="relates"
  _PEF="$DREAM_DIR/staging/.proposed-edges.filtered.json"
  jq -c --arg allowed "$_ALLOWED"     '{relations: [(.relations // [])[] | . as $r | select((($allowed | split(" ")) | index($r.type // "relates")) != null)]}'     "$_PE" > "$_PEF"  || printf '{"relations":[]}' > "$_PEF"
  _PE_N=$(jq -r '(.relations // []) | length' "$_PEF"  | tr -d '\r')
  _PE_RAW=$(jq -r '(.relations // []) | length' "$_PE"  | tr -d '\r')
  if [ "${_PE_RAW:-0}" -gt "${_PE_N:-0}" ]; then
    sb_log_error "dream-accept" "dropped $(( _PE_RAW - _PE_N )) proposed edge(s) from $DREAM_ID whose type is outside '$_ALLOWED' — the unattended lane may not create typed or supersedes edges" 0
  fi
  if [ "${_PE_N:-0}" -gt 0 ]; then
    # merge-edges.sh is a FAIL-SOFT boundary: it exits 0 even when it appends nothing (the same
    # dead-`||` class this repo documents for the code-map CLI), so its exit code proves nothing.
    # COUNT what actually landed instead of announcing success on faith.
    _EB=$(grep -c . "$KNOWLEDGE_DIR/graph/edges.jsonl"  || echo 0)
    bash "$(dirname "$0")/merge-edges.sh" --knowledge-dir "$KNOWLEDGE_DIR" --source "dream:$DREAM_ID" < "$_PEF" >/dev/null 2>&1       || sb_log_error "dream-accept" "merge-edges exited nonzero for $DREAM_ID (pages applied; graph may be unchanged)" 0
    _EA=$(grep -c . "$KNOWLEDGE_DIR/graph/edges.jsonl"  || echo 0)
    _APPLIED=$(( _EA - _EB ))
    if [ "$_APPLIED" -gt 0 ]; then
      echo "Applied $_APPLIED relation edge(s) from $DREAM_ID ($(( _PE_N - _APPLIED )) unresolvable -> quarantined)."
    else
      echo "Proposed $_PE_N relation edge(s) from $DREAM_ID; NONE applied (endpoints unresolvable -> quarantined)."
    fi
  fi
  rm -f "$_PEF" 
fi

# Reindex
sb_reindex_wiki "$KNOWLEDGE_DIR"

# Archive the dream
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg t "$NOW" '.archived_at = $t' "$DREAM_DIR/status.json" > "$tmp" && mv "$tmp" "$DREAM_DIR/status.json"

# A dream acceptance IS the consolidation the wiki-writes counter was counting toward — reset
# it, or the "N wiki writes since the last consolidation" banner nags forever (ledger F8:
# counter observed at 180 with dreams completing+archiving weekly; the only reset call sat in
# session-load's unreachable maintainer-reconcile branch). Scoped dream → that slug; unscoped
# (all-project) dream → every project's counter, since the consolidation covered them all.
DREAM_SLUG=$(jq -r '.inputs.project_slug // ""' "$DREAM_DIR/status.json" 2>/dev/null | tr -d '\r')
if [ -n "$DREAM_SLUG" ]; then
  sb_reset_wiki_writes "$DREAM_SLUG"
else
  for _wc in "$BRAIN_DIR"/projects/*/.wiki-writes; do
    [ -f "$_wc" ] || continue
    _ws="${_wc%/.wiki-writes}"; sb_reset_wiki_writes "${_ws##*/}"
  done
fi

# Clean up staging to reclaim disk
rm -rf "$DREAM_DIR/staging" "$DREAM_DIR/transcripts"

ADDED=$(jq -r '.outputs.pages_added // 0' "$DREAM_DIR/status.json" | tr -d '\r')
MODIFIED=$(jq -r '.outputs.pages_modified // 0' "$DREAM_DIR/status.json" | tr -d '\r')
REMOVED=$(jq -r '.outputs.pages_removed // 0' "$DREAM_DIR/status.json" | tr -d '\r')
echo "Dream $DREAM_ID accepted: +$ADDED ~$MODIFIED -$REMOVED pages applied to live wiki"

# Reversibility window: record what this accept did to the wiki. The pre-accept tarball can
# undo the WHOLE accept; this history can show and undo it page-by-page later. Fail-soft — a
# history failure must never turn a successful accept into an error.
[ -f "$(dirname "$0")/wiki-history.sh" ] && \
  bash "$(dirname "$0")/wiki-history.sh" snapshot "dream $DREAM_ID accepted (+$ADDED ~$MODIFIED -$REMOVED)" >/dev/null 2>&1 || true
