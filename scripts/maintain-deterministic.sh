#!/bin/bash
# maintain-deterministic.sh (SP-B) — the CONTENT-FREE half of consolidation, safe to run
# out-of-band with NO LLM and NO credentials: validate(+autofix) → project-backfill →
# reindex. It NEVER authors prose or makes dedup/supersede judgements — those need a
# Claude session via /second-brain:maintain. Called by extract-drain.sh at the end of a
# drain cycle WHEN config.json `auto_improve` is on (the call site gates it), so it
# inherits the drainer's CLAUDECODE-refuse / interactive-defer / single-flight guards and
# needs no second timer. Also runnable standalone. Fail-soft — always exits 0.
set -u
SDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SDIR/lib.sh"

# Self-throttle so a 30-min drain cadence doesn't reindex every cycle. The marker also
# serves as the "last consolidated" timestamp. SB_MAINTAIN_FORCE=1 bypasses (tests).
MARK="$BRAIN_DIR/.last-maintain"
INT="${SB_MAINTAIN_INTERVAL:-3600}"; case "$INT" in ''|*[!0-9]*) INT=3600 ;; esac
if [ "${SB_MAINTAIN_FORCE:-0}" != "1" ]; then
  mt=$(sb_mtime "$MARK")
  [ "$(( $(date +%s) - ${mt:-0} ))" -ge "$INT" ] || exit 0
fi
: > "$MARK"

# D128: resolve the knowledge dir via the SINGLE shared resolver (lib.sh, already sourced
# above), not a hand-rolled precedence chain. The inline form here had the precedence
# INVERTED (bare KNOWLEDGE_DIR before the plugin option) vs sb_knowledge_dir() and every
# other resolver in this repo (brain-paths.ts, the embed warm pass, sb_extract_transcript,
# sb_floor_transcript, sb-prune-archives) — the exact "two wikis" bug class brain-os-run.sh
# documents by name: a user with both set gets validate/reindex/graph-requarantine running
# against a DIFFERENT tree than extraction writes and the MCP server reads.
KDIR="$(sb_knowledge_dir)"

# 1. validate + autofix (frontmatter, empty pages, broken links) — deterministic
sb_validate_wiki "$KDIR" >/dev/null 2>&1 || true
# 2. project-backfill (project: facet via part_of fixpoint — additive, reversible)
[ -f "$SDIR/kb-project-backfill.sh" ] && bash "$SDIR/kb-project-backfill.sh" >/dev/null 2>&1 || true
# 3. reindex (index.md + project/theme MOCs + projects' related:/Dependencies)
sb_reindex_wiki "$KDIR" >/dev/null 2>&1 || true
# 4. retention prune (SP-D) — regenerable/dead-only GC (embeddings-cache, *.bak/*.tgz);
# deterministic + content-free + zero-credential, like the steps above. Never live knowledge.
[ -f "$SDIR/sb-prune-archives.sh" ] && bash "$SDIR/sb-prune-archives.sh" >/dev/null 2>&1 || true

# 5. GRAPH QUARANTINE RE-DRAIN — deterministic, content-free, no LLM.
# merge-edges.sh quarantines any edge whose endpoints do not resolve to live pages. Until now
# NOTHING read that file back (verified: one writer, zero readers), so a legitimate edge whose
# target page merely arrived later rotted there forever. That matters more since the engine
# proposes dream edges: a page HELD by the untrusted gate is exactly the "not yet, maybe later"
# case. Replay entries whose endpoints now resolve, keep the rest, and TTL-drop the ones that
# have never resolved so the file cannot grow without bound.
QF="$KDIR/graph/edges-quarantine.jsonl"
if [ -s "$QF" ] && [ -f "$SDIR/merge-edges.sh" ] && command -v jq >/dev/null 2>&1; then
  _q_resolves() { find "$KDIR/wiki" -name "$1.md" -type f ! -name 'index.md'  | grep -q .; }
  QTTL="${SB_EDGE_QUARANTINE_TTL_DAYS:-30}"; case "$QTTL" in ''|*[!0-9]*) QTTL=30 ;; esac
  _q_cut=$(date -u -d "-${QTTL} days" +%Y-%m-%dT%H:%M:%SZ          || date -u -v-"${QTTL}"d +%Y-%m-%dT%H:%M:%SZ  || echo "")
  _q_keep=$(mktemp); _q_ship=$(mktemp)
  while IFS= read -r _qline; do
    [ -n "$_qline" ] || continue
    _qf=$(printf '%s' "$_qline" | jq -r '.from // empty'  | tr -d '')
    _qt=$(printf '%s' "$_qline" | jq -r '.to // empty'  | tr -d '')
    if [ -n "$_qf" ] && [ -n "$_qt" ] && _q_resolves "$_qf" && _q_resolves "$_qt"; then
      printf '%s
' "$_qline" >> "$_q_ship"; continue          # both endpoints exist now → replay
    fi
    # Still unresolvable: keep it unless it has sat past the TTL (never-resolving junk).
    _qr=$(printf '%s' "$_qline" | jq -r '.recorded_at // empty'  | tr -d '')
    if [ -n "$_q_cut" ] && [ -n "$_qr" ] && [ "$_qr" \< "$_q_cut" ]; then continue; fi
    printf '%s
' "$_qline" >> "$_q_keep"
  done < "$QF"
  if [ -s "$_q_ship" ]; then
    # One merge-edges call per SOURCE cohort so replayed edges keep their original attribution
    # (cohort tags are what make a bad batch bulk-invalidatable).
    for _src in $(jq -r '.source // "extractor"' "$_q_ship"  | sort -u); do
      jq -c --arg s "$_src" -n --slurpfile all "$_q_ship"         '{relations: [$all[] | select((.source // "extractor") == $s) | {from,to,type,confidence}]}'          | bash "$SDIR/merge-edges.sh" --knowledge-dir "$KDIR" --source "$_src" >/dev/null 2>&1 || true
    done
    sb_log_error "maintain-deterministic" "graph quarantine: replayed $(grep -c . "$_q_ship") edge(s) whose endpoints now resolve" 0
  fi
  # Atomic rewrite (tmp+mv): a torn quarantine file would lose edges outright.
  if ! cmp -s "$_q_keep" "$QF"; then
    mv "$_q_keep" "$QF"  || rm -f "$_q_keep" 
  else
    rm -f "$_q_keep" 
  fi
  rm -f "$_q_ship" 
fi
exit 0
