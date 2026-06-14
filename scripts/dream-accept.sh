#!/bin/bash
# Accept a completed dream: copy staging wiki to live wiki, reindex, archive dream.
#
# Usage: dream-accept.sh <dream_id>
set -u
source "$(dirname "$0")/lib.sh"

DREAM_ID="${1:?usage: dream-accept.sh <dream_id>}"
DREAM_DIR="$BRAIN_DIR/dreams/$DREAM_ID"

if [ ! -f "$DREAM_DIR/status.json" ]; then
  echo "error: dream not found: $DREAM_ID" >&2
  exit 1
fi

STATUS=$(jq -r '.status' "$DREAM_DIR/status.json" 2>/dev/null)
if [ "$STATUS" != "completed" ]; then
  echo "error: dream $DREAM_ID is $STATUS, not completed" >&2
  exit 1
fi

ARCHIVED=$(jq -r '.archived_at // ""' "$DREAM_DIR/status.json" 2>/dev/null)
if [ -n "$ARCHIVED" ] && [ "$ARCHIVED" != "null" ]; then
  echo "error: dream $DREAM_ID already accepted/archived at $ARCHIVED" >&2
  exit 1
fi

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
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

# Apply: rsync staging over live wiki (preserves files not in staging). --safe-links drops any
# out-of-tree symlink as defense-in-depth behind the reject guard; the cp fallback is already
# covered by that guard (no out-of-tree symlink can reach it).
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --safe-links "$STAGING_WIKI/" "$LIVE_WIKI/"
else
  rm -rf "$LIVE_WIKI"
  cp -r "$STAGING_WIKI" "$LIVE_WIKI"
fi

# Reindex
sb_reindex_wiki "$KNOWLEDGE_DIR"

# Archive the dream
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg t "$NOW" '.archived_at = $t' "$DREAM_DIR/status.json" > "$tmp" && mv "$tmp" "$DREAM_DIR/status.json"

# Clean up staging to reclaim disk
rm -rf "$DREAM_DIR/staging" "$DREAM_DIR/transcripts"

ADDED=$(jq -r '.outputs.pages_added // 0' "$DREAM_DIR/status.json")
MODIFIED=$(jq -r '.outputs.pages_modified // 0' "$DREAM_DIR/status.json")
REMOVED=$(jq -r '.outputs.pages_removed // 0' "$DREAM_DIR/status.json")
echo "Dream $DREAM_ID accepted: +$ADDED ~$MODIFIED -$REMOVED pages applied to live wiki"
