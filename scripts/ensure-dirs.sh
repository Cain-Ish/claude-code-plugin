#!/bin/bash
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
source "$(dirname "$0")/lib.sh"
KNOWLEDGE_DIR="$(sb_knowledge_dir)"

mkdir -p "$BRAIN_DIR/projects"
mkdir -p "$BRAIN_DIR/transcripts"
mkdir -p "$BRAIN_DIR/dreams"
mkdir -p "$BRAIN_DIR/wiki-archive"
# Wiki content-category dirs from the KB source of truth (kb-schema.json, via lib.sh -> kb-schema.sh).
# Creates ALL content categories.
for _c in ${SB_CONTENT_CATEGORIES:-learnings decisions entities issues concepts security state sources}; do
  mkdir -p "$KNOWLEDGE_DIR/wiki/$_c"
done
test -f "$BRAIN_DIR/projects.jsonl" || : > "$BRAIN_DIR/projects.jsonl"
# Seed a self-documenting config.json. Automation is ON by default — this is an
# automation plugin, so a fresh install self-maintains without the user remembering to opt in.
#   auto_improve : true  — free + offline: validate + reindex the wiki on the drainer timer.
#   auto_maintain: true  — runs the headless `claude -p` maintainer on its cadence. NOTE: this
#                          reads your Claude OAuth + spends tokens. Disable with auto_maintain:false
#                          for a fully-offline/zero-spend box. D097: SB_MAINTAINER_AUTO=off does
#                          NOT do this — it only silences session-load.sh's in-session "wiki
#                          maintenance suggested" banner; the actual token-spending maintainer
#                          (maintain-llm-drain.sh, brain-os-run.sh) reads only this config key.
#   auto_accept  : "safe" — auto-accept only LOW-RISK dream changes; "off" = always manual review,
#                          "all" = accept everything (not the default — too aggressive).
#   brain_os     : true  — the OFFLINE ENGINE seam: one entry point for every out-of-band pass
#                          that processes already-captured knowledge (prune, deterministic
#                          upkeep, embedding warm pass, consolidation lane, code-map). false =
#                          no offline processing at all; capture + retrieval keep working and
#                          consolidation stays on the in-session /second-brain:maintain path.
#   auto_embed   : true  — free + offline: precompute wiki embeddings on the drainer timer so
#                          the first search of a session isn't paying to embed changed pages.
#   wiki_git     : true  — REVERSIBILITY WINDOW: snapshot the wiki into a git history after every
#                          unattended write, so any consolidation can be inspected and undone
#                          (scripts/wiki-history.sh list|show|restore). The repo lives in
#                          ~/.second-brain/wiki-history.git — NO .git is created in your
#                          knowledge dir, so Obsidian/cloud-sync are unaffected.
# Idempotent: never clobbers an existing config, so machines that already chose values keep them.
# wiki_archive_ttl_days:0 = NEVER (the irreversible store stays off).
test -f "$BRAIN_DIR/config.json" || cat > "$BRAIN_DIR/config.json" <<'JSON'
{
  "auto_improve": true,
  "auto_maintain": true,
  "auto_accept": "safe",
  "brain_os": true,
  "auto_embed": true,
  "wiki_git": true,
  "retention": {
    "dream_keep_count": 5,
    "bak_ttl_days": 14,
    "embeddings_cache_gc": true,
    "wiki_archive_ttl_days": 0
  }
}
JSON

# GC stale per-session injection memos. persona-context.sh writes one file per
# session-id under .injected/ and never deletes them — observed 189 files
# accumulated (one per Claude Code session in the last 30 days). 7-day TTL is
# generous: any session older than a week has no useful dedup signal anyway.
if [ -d "$BRAIN_DIR/.injected" ]; then
  # *.phase rides the same TTL: the intent-spine phase file is per-session state
  # with the exact lifetime of its sibling memo.
  find "$BRAIN_DIR/.injected" -maxdepth 1 \( -name '*.json' -o -name '*.phase' \) -type f -mtime +7 -delete 2>/dev/null || true
fi

# GC stale ghost projects. session-load.sh used to accept any $PWD basename as
# a project slug, so mktemp dirs like tmp.xK3p9q became permanent project
# directories with empty PROJECT.md. The session-load.sh slug guard prevents
# new ones; this prunes the existing 33+ ghosts. Only deletes dirs matching
# tmp.* whose PROJECT.md is empty or unmodified beyond scaffold (<200 bytes).
if [ -d "$BRAIN_DIR/projects" ]; then
  for d in "$BRAIN_DIR/projects"/tmp.*; do
    [ -d "$d" ] || continue
    pf="$d/PROJECT.md"
    if [ ! -f "$pf" ]; then
      rm -rf "$d" 2>/dev/null
      continue
    fi
    sz=$(wc -c < "$pf" 2>/dev/null | tr -d ' ')
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    if [ "$sz" -lt 250 ]; then
      rm -rf "$d" 2>/dev/null
    fi
  done
fi

# D118: ONE-TIME migration cleanup — a projects.jsonl row registered before the
# sb_registration_refused_reason guard existed (session-load.sh) may have root_path=$HOME
# or a bare temp root. brain-os-run.sh's registry root-picker treats the most-recently-
# active row as the code-map target, so a leftover row like this would still trigger a
# whole-home-directory codemap crawl even after the guard stops NEW rows like it from
# ever being written. Sweep once (marker-gated, not every ensure-dirs run) and NEVER
# delete silently: purged rows are appended to a dated sidecar first.
_D118_MARK="$BRAIN_DIR/.ensure-dirs-d118-purge-done"
if [ ! -f "$_D118_MARK" ] && [ -s "$BRAIN_DIR/projects.jsonl" ] && command -v jq >/dev/null 2>&1; then
  _D118_PURGED=$(mktemp); _D118_KEPT=$(mktemp)
  : > "$_D118_PURGED"; : > "$_D118_KEPT"
  while IFS= read -r _row; do
    [ -z "$_row" ] && continue
    _rp=$(printf '%s' "$_row" | jq -r '.root_path // empty' 2>/dev/null | tr -d '\r')
    if [ -n "$_rp" ] && [ -n "$(sb_registration_refused_reason "$_rp")" ]; then
      printf '%s\n' "$_row" >> "$_D118_PURGED"
    else
      printf '%s\n' "$_row" >> "$_D118_KEPT"
    fi
  done < <(tr -d '\r' < "$BRAIN_DIR/projects.jsonl")
  if [ -s "$_D118_PURGED" ]; then
    _D118_DEST="$BRAIN_DIR/projects.jsonl.purged-$(date -u +%Y%m%d)"
    cat "$_D118_PURGED" >> "$_D118_DEST"
    mv "$_D118_KEPT" "$BRAIN_DIR/projects.jsonl"
    _D118_N=$(grep -c . "$_D118_PURGED" 2>/dev/null || echo 0)
    sb_log_error "ensure-dirs.sh" "gate=registration-purge removed $_D118_N HOME/temp-root registry row(s) -> $_D118_DEST" 0
  else
    rm -f "$_D118_KEPT"
  fi
  rm -f "$_D118_PURGED"
  : > "$_D118_MARK"
fi

WIKI_INDEX="$KNOWLEDGE_DIR/wiki/index.md"
# Build the index on a fresh wiki, else validate+autofix an existing one. Delegated to the
# canonical lib.sh helpers (dynamic-import + error-logging) — NOT an inline `node -e`, which had
# carried a duplicate of the static-import-from-env SyntaxError bug that silently never ran.
if [ ! -f "$WIKI_INDEX" ]; then
  sb_reindex_wiki "$KNOWLEDGE_DIR"
else
  # Throttle the full-wiki validate+autofix to once per 24h. It is a SYNCHRONOUS
  # node spawn that ran on EVERY SessionStart (startup|resume|clear) — pure
  # latency for a wiki that rarely drifts between sessions. Stamp mtime is the
  # clock, the same >86400s age idiom as session-load.sh's stale-index reindex
  # (855-865). First run (no stamp) always validates; the fresh-wiki reindex
  # path above is untouched. Fail-soft: the count on stdout is dropped so it
  # never leaks into SessionStart context.
  _EV_STAMP="$BRAIN_DIR/.last-ensure-validate"
  _EV_AGE=$(( $(date +%s) - $(sb_mtime "$_EV_STAMP") ))
  if [ ! -f "$_EV_STAMP" ] || [ "$_EV_AGE" -gt 86400 ]; then
    # D096: this autofix DELETES empty pages and rewrites frontmatter (knowledge-validate.ts
    # fs.unlink) at SessionStart, unattended — exactly the kind of write config.json's own
    # wiki_git comment (above) promises a reversibility snapshot for. wiki-history.sh checks
    # the wiki_git flag itself and fails soft (exit 0, no-op) when the feature is off — a
    # NONZERO exit therefore only ever means "wiki_git is on but the snapshot itself failed"
    # (e.g. a pre-commit hook rejecting the commit). The undo point the autofix's own comment
    # promises would not exist, so — while wiki_git is on — a failed snapshot must SKIP the
    # deleting autofix, not silently run it anyway (the old `2>/dev/null` swallowed this).
    _SNAP_RC=0
    if [ -f "$(dirname "$0")/wiki-history.sh" ]; then
      bash "$(dirname "$0")/wiki-history.sh" snapshot "pre-autofix safety snapshot (ensure-dirs)" >/dev/null 2>&1 || _SNAP_RC=$?
    fi
    if [ "$_SNAP_RC" -ne 0 ]; then
      sb_log_error "ensure-dirs.sh" "pre-autofix wiki-history snapshot failed (rc=$_SNAP_RC) — autofix skipped this run, no undo point" 1
    else
      sb_validate_wiki "$KNOWLEDGE_DIR" >/dev/null 2>&1
    fi
    : > "$_EV_STAMP"   # stamp AFTER the run so the next 24h window starts here
  fi
fi

exit 0
