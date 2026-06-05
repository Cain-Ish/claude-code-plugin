#!/bin/bash
# sb-prune-archives.sh (SP-D) — deterministic, content-free, ZERO-credential retention GC for
# REGENERABLE / dead artifacts ONLY. Runs as step 4 of maintain-deterministic.sh, so it rides the
# auto_improve out-of-band cadence + the drainer's CLAUDECODE-refuse/defer/single-flight guards —
# no new timer. It NEVER deletes live or unprocessed knowledge. It touches only:
#   (a) embeddings-cache entries with no live episodic exchange — rebuilt from transcripts, lossless;
#   (b) abandoned *.bak / *.tgz / rebuild snapshots past a TTL — one-shot dead weight.
# It deliberately does NOT touch: transcripts (the re-extraction + episodic source), the wiki-archive
# (the IRREVERSIBLE sole copy of forgotten pages + the auto-restore source — deferred, off by default),
# or the episodic-index (a single rebuildable file with no per-row terminal state). Fail-soft — exit 0.
set -u
SDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SDIR/lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

# (a) embeddings-cache GC — drop `episodic:<id>` entries with no live exchange (id ∉ episodic-index).
# Cache key format is `episodic:${id}` (episodic-search.ts); live ids are episodic-index.exchanges[].id.
# Keeps every non-episodic key (the transient concept-*) + every live episodic key. Lossless: a missed
# vector is simply re-embedded from the transcript on next search.
if [ "$(sb_config_bool .retention.embeddings_cache_gc on)" = "on" ]; then
  CACHE="$BRAIN_DIR/transcripts/.embeddings-cache.json"
  IDX="$BRAIN_DIR/episodic-index.json"
  if [ -f "$CACHE" ] && [ -f "$IDX" ] && jq -e . "$CACHE" >/dev/null 2>&1 && jq -e . "$IDX" >/dev/null 2>&1; then
    _tmp=$(mktemp)
    if jq --slurpfile idx "$IDX" '
          ($idx[0].exchanges // [] | map({key: ("episodic:" + .id), value: true}) | from_entries) as $live
          | .entries |= with_entries(select((.key | startswith("episodic:") | not) or ($live[.key] == true)))
        ' "$CACHE" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
      mv "$_tmp" "$CACHE"
    else
      rm -f "$_tmp"
    fi
  fi
fi

# (b) abandoned backup snapshots past a TTL. Recent backups (< TTL) survive, so the newest copy of a
# just-made backup is always kept; only genuinely-stale one-shot artifacts are reclaimed. ttl 0 = off.
BAK_TTL="$(sb_config_get .retention.bak_ttl_days 14)"; case "$BAK_TTL" in ''|*[!0-9]*) BAK_TTL=14 ;; esac
if [ "$BAK_TTL" -gt 0 ] && [ -d "$BRAIN_DIR" ]; then
  find "$BRAIN_DIR" -maxdepth 1 -type f \
    \( -name '*.bak' -o -name '*.bak-*' -o -name '*.broken.bak' -o -name '*.pre-rebuild-*' -o -name '*.tgz' \) \
    -mtime "+$BAK_TTL" -delete 2>/dev/null || true
fi

exit 0
