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
  # D159: log loudly (not just skip) when BOTH files exist but one is unparseable — a
  # torn/truncated write, not the ordinary "no index/cache yet" case — so a corrupt
  # episodic-index.json is visible in error-log.jsonl instead of reading identically to
  # "nothing to prune this run".
  if [ -f "$CACHE" ] && [ -f "$IDX" ] && { ! jq -e . "$CACHE" >/dev/null 2>&1 || ! jq -e . "$IDX" >/dev/null 2>&1; }; then
    sb_log_error "sb-prune-archives.sh" "embeddings-cache GC skipped: $CACHE or $IDX is present but unparseable (torn/truncated write) — cache left untouched" 0
  fi
  if [ -f "$CACHE" ] && [ -f "$IDX" ] && jq -e . "$CACHE" >/dev/null 2>&1 && jq -e . "$IDX" >/dev/null 2>&1; then
    # SAFETY: skip when the index has 0 live exchanges. The index is legitimately empty/
    # partial mid-rebuild (the degraded-embeddings banner tells users to remove + re-index
    # it); GC'ing against an empty live-set would drop the ENTIRE cache → a needless, slow
    # full re-embed. An empty index = "unknown liveness", so leave the cache alone.
    LIVE_N=$(jq -r '(.exchanges // []) | length' "$IDX" 2>/dev/null); case "$LIVE_N" in ''|*[!0-9]*) LIVE_N=0 ;; esac
    if [ "$LIVE_N" -gt 0 ]; then
      _tmp=$(mktemp)
      # D159: `--slurpfile` re-reads $IDX here (a second read after the `jq -e .` gate
      # above) — a concurrent rewrite of episodic-index.json in that TOCTOU gap can make
      # THIS read fail even though the gate passed. A silent failure here already skips
      # the GC (safe — nothing gets deleted), but silently: log it loudly so a torn index
      # is visible instead of indistinguishable from "nothing to prune this run".
      if jq --slurpfile idx "$IDX" '
            ($idx[0].exchanges // [] | map({key: ("episodic:" + .id), value: true}) | from_entries) as $live
            | .entries |= with_entries(select((.key | startswith("episodic:") | not) or ($live[.key] == true)))
          ' "$CACHE" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
        mv "$_tmp" "$CACHE"
      else
        rm -f "$_tmp"
        sb_log_error "sb-prune-archives.sh" "embeddings-cache GC skipped: --slurpfile could not read $IDX (torn/concurrent rewrite?) — cache left untouched" 0
      fi
    fi
  fi
fi

# (b) abandoned backup snapshots past a TTL. Recent backups (< TTL) survive, so the newest copy of a
# just-made backup is always kept; only genuinely-stale one-shot artifacts are reclaimed. ttl 0 = off.
BAK_TTL="$(sb_config_get .retention.bak_ttl_days 14)"; case "$BAK_TTL" in ''|*[!0-9]*) BAK_TTL=14 ;; esac
if [ "$BAK_TTL" -gt 0 ] && [ -d "$BRAIN_DIR" ]; then
  # *.bak.* covers the stamped registry backups sb_harden_projects_jsonl writes
  # (projects.jsonl.bak.<UTC-stamp>) — otherwise every hardening leaves a permanent copy.
  find "$BRAIN_DIR" -maxdepth 1 -type f \
    \( -name '*.bak' -o -name '*.bak-*' -o -name '*.bak.*' -o -name '*.broken.bak' -o -name '*.pre-rebuild-*' -o -name '*.tgz' \) \
    -mtime "+$BAK_TTL" -delete 2>/dev/null || true
fi

# (c) wiki embeddings-cache eviction — the wiki BM25/vector cache
# (<knowledge_dir>/wiki/.embeddings-cache.json) keys each entry by the .md file's
# absolute path; a page that was forgotten/renamed/merged leaves a dead vector entry
# forever. Drop entries whose key path no longer exists on disk. Lossless: a survivor
# keeps its exact {hash,vector}; a missed vector is simply re-embedded on next search.
# Atomic tmp+mv. Gated on the same embeddings_cache_gc knob as (a).
if [ "$(sb_config_bool .retention.embeddings_cache_gc on)" = "on" ]; then
  WIKI_CACHE="$(sb_knowledge_dir)/wiki/.embeddings-cache.json"
  if [ -f "$WIKI_CACHE" ] && jq -e '(.entries | type) == "object"' "$WIKI_CACHE" >/dev/null 2>&1; then
    # ONE jq in, ONE jq out. The previous loop spawned jq once PER CACHE KEY to append to KEEP
    # (486 keys = 486 spawns, and KEEP re-serialized each time = O(N^2)): measured 37s on the
    # dev box to delete nothing — and this runs on EVERY drainer tick via maintain-deterministic,
    # so it alone made a NO_LLM tick ~70s and test-extract-drain (31 ticks) un-runnable in 120s.
    # Existence is checked in bash (builtin -f); survivors are collected as newline-delimited
    # text and handed to jq once as a set.
    _keep_tmp="$WIKI_CACHE.keep.$$"; : > "$_keep_tmp"
    while IFS= read -r _k; do
      [ -n "$_k" ] && [ -f "$_k" ] && printf '%s\n' "$_k" >> "$_keep_tmp"
    done < <(jq -r '.entries | keys[]' "$WIKI_CACHE" 2>/dev/null | tr -d '\r')
    _wtmp="$WIKI_CACHE.tmp.$$"
    if jq -c --rawfile keeptxt "$_keep_tmp" \
         '($keeptxt | split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries) as $keep
          | .entries |= with_entries(select($keep[.key] == true))' \
         "$WIKI_CACHE" > "$_wtmp" 2>/dev/null && [ -s "$_wtmp" ]; then
      rm -f "$_keep_tmp" 2>/dev/null
      mv "$_wtmp" "$WIKI_CACHE" 2>/dev/null || rm -f "$_wtmp" 2>/dev/null
    else
      rm -f "$_wtmp" "$_keep_tmp" 2>/dev/null
    fi
  fi
fi

exit 0
