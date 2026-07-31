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

if [ ! -f "$DREAM_DIR/status.json" ]; then
  echo "error: dream not found: $DREAM_ID" >&2
  exit 1
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
  if [ "${SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED:-0}" = "1" ] && [ -d "$DREAM_DIR/held-untrusted" ]; then
    RKD="$(sb_knowledge_dir)"; RKD=$(_to_msys "$RKD")
    # Same reversibility floor as every other apply path (0.28.1): tarball live FIRST and
    # fail CLOSED. An operator confirming a hold is not a reason to skip the undo trail.
    if [ "${SB_DREAM_ACCEPT_SKIP_BACKUP:-0}" != "1" ] && [ -d "$RKD/wiki" ]; then
      R_BK="$BRAIN_DIR/wiki-backup-pre-release-$(date -u +%Y%m%d%H%M%SZ).tgz"
      if ! tar czf "$R_BK" -C "$RKD" wiki 2>/dev/null || [ ! -s "$R_BK" ]; then
        rm -f "$R_BK" 2>/dev/null
        echo "error: refusing to release held pages for $DREAM_ID — could not back up the live wiki first" >&2
        exit 1
      fi
    fi
    RN=0; RSKIP=0
    while IFS= read -r _hf; do
      [ -n "$_hf" ] || continue
      _rel=${_hf#"$DREAM_DIR/held-untrusted/"}
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
    done < <(find "$DREAM_DIR/held-untrusted" -type f -name '*.md' 2>/dev/null)
    if [ "$RN" -gt 0 ] || [ "$RSKIP" -gt 0 ]; then
      # Only drop the hold area once nothing is left un-released; skipped pages stay held.
      [ "$RSKIP" -eq 0 ] && rm -rf "$DREAM_DIR/held-untrusted"
      [ "$RN" -gt 0 ] && sb_reindex_wiki "$RKD"
      echo "RELEASED $RN previously-held untrusted page(s) into the live wiki (confirmed); $RSKIP skipped/retained."
      exit 0
    fi
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
  _bkerr=$(tar czf "$ACCEPT_BK" -C "$KNOWLEDGE_DIR" wiki 2>&1); _bkrc=$?
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

# Held-untrusted confirm gate (P6 arm-gate): a NEW page that exists only because the
# quarantined summarizer distilled it from transcripts (provenance: untrusted-derived,
# no live counterpart) is exactly what a poisoned transcript could conjure from nothing.
# Without explicit confirmation, HOLD it — a reversible move to $DREAM_DIR/held-untrusted/
# (never deleted, excluded from the apply below) — and apply the rest of the dream.
# Confirm with SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1 (auto_accept=all passes it; safe-mode
# auto-accept refuses upstream via sb_auto_accept_decision). A page that UPDATES a live
# page is corroborated by that page's existence and applies normally.
# Two shapes of untrusted write, both handled here:
#   NEW page  (provenance: untrusted-derived, no live counterpart) → MOVED to held-untrusted/
#   FOLD-IN   (untrusted bullets appended to an existing live page) → staging copy REVERTED to
#             the live bytes, so the apply below is a no-op for that page.
# Without the fold-in arm the gate would be trivially bypassable: the writer's UPDATE lane
# appends transcript-derived claims to pages that already exist live, which are not "new"
# and so would sail through unattended.
# FAIL-LOUD, FAIL-CLOSED: if any hold/revert step fails we ABORT the accept. Continuing would
# leave the unconfirmed page in staging and the apply below would merge it into live — the
# exact outcome this gate exists to prevent. (Nothing has been written to live at this point.)
HELD_N=0
if [ "${SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED:-0}" != "1" ] && [ -d "$STAGING_WIKI" ]; then
  HELD_LIST=""
  while IFS= read -r _uf; do
    [ -n "$_uf" ] || continue
    _rel=${_uf#"$STAGING_WIKI/"}
    if [ -f "$LIVE_WIKI/$_rel" ]; then
      # Fold-in: restore the live bytes over the staging copy (revert the untrusted append).
      if ! cp -p "$LIVE_WIKI/$_rel" "$_uf"; then
        echo "error: refusing accept of $DREAM_ID — could not revert untrusted fold-in on '$_rel'; aborting rather than applying unconfirmed untrusted content" >&2
        sb_log_error "dream-accept" "untrusted fold-in revert failed for $_rel in $DREAM_ID — accept ABORTED (fail-closed)" 0
        exit 1
      fi
      HELD_N=$((HELD_N + 1)); HELD_LIST="$HELD_LIST $_rel(fold-in reverted)"
      continue
    fi
    if ! mkdir -p "$DREAM_DIR/held-untrusted/$(dirname "$_rel")" || ! mv "$_uf" "$DREAM_DIR/held-untrusted/$_rel"; then
      echo "error: refusing accept of $DREAM_ID — could not hold untrusted-only new page '$_rel'; aborting rather than applying it unconfirmed" >&2
      sb_log_error "dream-accept" "held-untrusted hold failed for $_rel in $DREAM_ID — accept ABORTED (fail-closed; the page stayed in staging and would otherwise have been applied)" 0
      exit 1
    fi
    HELD_N=$((HELD_N + 1)); HELD_LIST="$HELD_LIST $_rel"
  done < <(grep -rlE '^provenance: untrusted-derived|^## Candidate facts \(untrusted\)' "$STAGING_WIKI" 2>/dev/null)
  if [ "$HELD_N" -gt 0 ]; then
    echo "HELD $HELD_N untrusted write(s) pending confirm:$HELD_LIST (release: re-accept with SB_DREAM_ACCEPT_CONFIRM_UNTRUSTED=1)"
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
if command -v rsync >/dev/null 2>&1; then
  if [ "$PROTECT_OK" != "1" ]; then
    rsync -a --safe-links "$STAGING_WIKI/" "$LIVE_WIKI/"    # merge-only (see warn above)
  elif [ -n "$PROTECT" ]; then
    _exf=$(mktemp)
    # while-read (never an unquoted expansion — a page path containing a space
    # must not word-split into broken patterns), each anchored to the transfer
    # root ('/'-prefixed) so rsync neither deletes nor overwrites it — the
    # newer live page is kept as-is.
    printf '%s\n' "$PROTECT" | while IFS= read -r _rel; do
      [ -n "$_rel" ] && printf '/%s\n' "$_rel"
    done > "$_exf"
    rsync -a --delete --safe-links --exclude-from="$_exf" "$STAGING_WIKI/" "$LIVE_WIKI/"
    rm -f "$_exf"
    echo "Preserved $(printf '%s\n' "$PROTECT" | grep -c .) live page(s) modified after the dream snapshot (merge-only; not deleted or overwritten)."
  else
    rsync -a --delete --safe-links "$STAGING_WIKI/" "$LIVE_WIKI/"
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
  cp -r "$STAGING_WIKI/." "$LIVE_WIKI/" 2>/dev/null || { mkdir -p "$LIVE_WIKI" && cp -r "$STAGING_WIKI/." "$LIVE_WIKI/"; }
  if [ -n "$_stash" ]; then
    (cd "$_stash" 2>/dev/null && find . -type f 2>/dev/null | sed 's#^\./##') | while IFS= read -r _rel; do
      [ -n "$_rel" ] && cp -p "$_stash/$_rel" "$LIVE_WIKI/$_rel"
    done
    rm -rf "$_stash"
    echo "Preserved $(printf '%s\n' "$PROTECT" | grep -c .) live page(s) modified after the dream snapshot (restored over staging copies)."
  fi
  # Honest accounting (not silent): this path applies NO dream deletions —
  # FORGET/DEDUPLICATE removals stay in place until an rsync-equipped accept.
  echo "note: rsync unavailable — staging merged over live; dream deletions were NOT applied."
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

# Reindex
sb_reindex_wiki "$KNOWLEDGE_DIR"

# Archive the dream
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg t "$NOW" '.archived_at = $t' "$DREAM_DIR/status.json" > "$tmp" && mv "$tmp" "$DREAM_DIR/status.json"

# Clean up staging to reclaim disk
rm -rf "$DREAM_DIR/staging" "$DREAM_DIR/transcripts"

ADDED=$(jq -r '.outputs.pages_added // 0' "$DREAM_DIR/status.json" | tr -d '\r')
MODIFIED=$(jq -r '.outputs.pages_modified // 0' "$DREAM_DIR/status.json" | tr -d '\r')
REMOVED=$(jq -r '.outputs.pages_removed // 0' "$DREAM_DIR/status.json" | tr -d '\r')
echo "Dream $DREAM_ID accepted: +$ADDED ~$MODIFIED -$REMOVED pages applied to live wiki"
