#!/bin/bash
# pins: SB_ARCHIVE_LOCK_WAIT_S — R2 shortens the held-quarantine-lock wait to 1 s: the skip-and-log, not the wait length, is under test
# pins: SB_EXTRACT_STUB — stubs the extractor so the deterministic-maintain path runs hermetically
# pins: SB_INTERACTIVE_OVERRIDE — forces the interactive-session gate to the non-interactive branch under test
# pins: SB_MAINTAIN_FORCE — forces the maintenance tick to run regardless of its normal due-time gate
# B2 (SP-B): the deterministic out-of-band consolidation — validate+backfill+reindex,
# NO LLM, NO creds, self-throttled — plus the extract-drain `auto_improve` gate.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MD="$ROOT/scripts/maintain-deterministic.sh"
DRAIN="$ROOT/scripts/extract-drain.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
# Run out-of-band: inside a Claude session CLAUDECODE=1 leaks in and the drainer
# (correctly) refuses, so the gate is never reached. Same as test-extract-drain.sh.
unset CLAUDECODE 2>/dev/null || true
HAS_NODE=0; command -v node >/dev/null 2>&1 && [ -f "$ROOT/mcp/dist/tools/knowledge-reindex.bundle.js" ] && HAS_NODE=1

# Content-free guard: must never shell out to an LLM.
grep -qE 'claude -p|sb_call_extractor|claude_-p' "$MD" && fail "maintain-deterministic invokes an LLM (must be content-free)" || pass "content-free (no LLM)"

# --- the script: marker + throttle ---
B=$(mktemp -d); export BRAIN_DIR="$B" KNOWLEDGE_DIR="$B/knowledge"
mkdir -p "$KNOWLEDGE_DIR/wiki/concepts"
printf -- '---\ntype: concepts\ntitle: X\n---\n# X\nbody body body\n' > "$KNOWLEDGE_DIR/wiki/concepts/x.md"

SB_MAINTAIN_FORCE=1 bash "$MD" >/dev/null 2>&1 || true
[ -f "$B/.last-maintain" ] && pass "forced run writes the .last-maintain marker" || fail "no marker after forced run"
if [ "$HAS_NODE" = 1 ]; then
  [ -f "$KNOWLEDGE_DIR/wiki/index.md" ] && pass "forced run reindexed (index.md built)" || fail "no index.md after forced run"
  rm -f "$KNOWLEDGE_DIR/wiki/index.md"
  bash "$MD" >/dev/null 2>&1 || true                    # no FORCE, marker fresh → throttled
  [ -f "$KNOWLEDGE_DIR/wiki/index.md" ] && fail "ran despite a fresh throttle marker" || pass "self-throttles when marker is fresh"
else
  echo "SKIP: node/reindex bundle absent — index.md assertions skipped"
fi

# --- the extract-drain `auto_improve` gate ---
mktx(){ mkdir -p "$1/transcripts"; : > "$1/transcripts/$2"; }
# auto OFF (EXPLICIT — 0.30.0 made absent default to ON) → maintain NOT run
G=$(mktemp -d); mktx "$G" "a_proj_2026-05-24.txt"; mkdir -p "$G/knowledge/wiki"
printf '{"auto_improve": false}\n' > "$G/config.json"
( export BRAIN_DIR="$G" KNOWLEDGE_DIR="$G/knowledge" SB_INTERACTIVE_OVERRIDE=inactive SB_EXTRACT_STUB=1
  bash "$DRAIN" >/dev/null 2>&1 ) || true
[ -f "$G/.last-maintain" ] && fail "deterministic maintain ran with auto_improve OFF" || pass "auto_improve off → no out-of-band maintain"
rm -f "$G/config.json"
# auto ON → maintain runs (marker appears)
printf '{"auto_improve": true}\n' > "$G/config.json"; mktx "$G" "b_proj_2026-05-24.txt"
( export BRAIN_DIR="$G" KNOWLEDGE_DIR="$G/knowledge" SB_INTERACTIVE_OVERRIDE=inactive SB_EXTRACT_STUB=1 SB_MAINTAIN_FORCE=1
  bash "$DRAIN" >/dev/null 2>&1 ) || true
[ -f "$G/.last-maintain" ] && pass "auto_improve on → out-of-band maintain runs" || fail "maintain did not run with auto_improve on"

# --- D128: KNOWLEDGE_DIR precedence must match sb_knowledge_dir() (plugin option
# FIRST, bare env var second) — a hand-rolled inverted chain here would reindex a
# DIFFERENT tree than extraction/the MCP server use ("two wikis" bug class).
if [ "$HAS_NODE" = 1 ]; then
  P=$(mktemp -d)
  mkdir -p "$P/A/wiki/learnings" "$P/B/wiki/learnings"
  for t in A B; do
    printf -- '---\ntitle: p\ndescription: d\ntype: learnings\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# p\n\nbody\n' > "$P/$t/wiki/learnings/p.md"
  done
  ( export BRAIN_DIR="$P/brain" KNOWLEDGE_DIR="$P/A" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$P/B" SB_MAINTAIN_FORCE=1
    bash "$MD" >/dev/null 2>&1 )
  if [ -f "$P/B/wiki/index.md" ] && [ ! -f "$P/A/wiki/index.md" ]; then
    pass "D128: plugin option (B) wins over bare KNOWLEDGE_DIR (A) — matches sb_knowledge_dir()"
  else
    fail "D128: precedence wrong (B/index.md exists=$([ -f "$P/B/wiki/index.md" ] && echo yes || echo no), A/index.md exists=$([ -f "$P/A/wiki/index.md" ] && echo yes || echo no))"
  fi
  rm -rf "$P"
else
  echo "SKIP: D128 precedence check — node/reindex bundle absent"
fi

# --- D5 (audit): the graph-quarantine replay rewrote edges-quarantine.jsonl with `mv keep QF`, so an
# edge merge-edges appended while the replay ran (after the read loop) was lost. A jq shim appends
# one such line exactly when the replay batch is built. ORACLE: the late line survives the rewrite,
# the resolvable edge leaves quarantine, the still-unresolvable one stays.
Q=$(mktemp -d); QF="$Q/knowledge/graph/edges-quarantine.jsonl"
mkdir -p "$Q/knowledge/wiki/concepts" "$Q/knowledge/graph" "$Q/brain" "$Q/jqshim"
for s in qa qb; do printf -- '---\ntitle: %s\n---\n# %s\n' "$s" "$s" > "$Q/knowledge/wiki/concepts/$s.md"; done
QNOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
qline() { printf '{"op":"assert","from":"%s","to":"%s","type":"relates","recorded_at":"%s","source":"extractor"}\n' "$1" "$2" "$QNOW"; }
{ qline qa qb; qline qx qy; } > "$QF"
qline late edge > "$Q/late.jsonl"
printf '#!%s\ncase "$*" in *"--slurpfile all "*) [ -e %q ] || { cat %q >> %q; : > %q; } ;; esac\nexec %q "$@"\n' \
  "$BASH" "$Q/late.done" "$Q/late.jsonl" "$QF" "$Q/late.done" "$(command -v jq)" > "$Q/jqshim/jq"
chmod +x "$Q/jqshim/jq"
( export BRAIN_DIR="$Q/brain" KNOWLEDGE_DIR="$Q/knowledge" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$Q/knowledge"
  PATH="$Q/jqshim:$PATH" SB_MAINTAIN_FORCE=1 bash "$MD" >/dev/null 2>&1 )
[ -e "$Q/late.done" ] || fail "D5: precondition — the jq shim never saw the replay batch"
grep -q '"from":"late"' "$QF" || fail "D5: an edge appended during the replay was lost by the quarantine rewrite"
grep -q '"from":"qx"' "$QF" || fail "D5: the still-unresolvable edge was dropped from quarantine"
grep -q '"from":"qa"' "$QF" && fail "D5: the resolvable edge was not replayed out of quarantine"
pass "D5: the quarantine rewrite keeps an edge appended during the replay"
rm -rf "$Q"

# --- Residual 2: the quarantine rewrite (tail-copy .. mv) holds .edges-quarantine.jsonl.lock, the lock
# merge-edges.sh takes around its quarantine append. A held lock (an append in flight) makes the
# rewrite wait (bounded), skip and fail loud: the file stays byte-identical, the lock untouched.
Q=$(mktemp -d); QF="$Q/knowledge/graph/edges-quarantine.jsonl"
mkdir -p "$Q/knowledge/wiki/concepts" "$Q/knowledge/graph" "$Q/brain"
for s in qa qb; do printf -- '---\ntitle: %s\n---\n# %s\n' "$s" "$s" > "$Q/knowledge/wiki/concepts/$s.md"; done
QNOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{ qline qa qb; qline qx qy; } > "$QF"
cp "$QF" "$Q/before.jsonl"
printf '%s\n' "$$.held" > "$Q/knowledge/graph/.edges-quarantine.jsonl.lock"
( export BRAIN_DIR="$Q/brain" KNOWLEDGE_DIR="$Q/knowledge" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$Q/knowledge"
  SB_ARCHIVE_LOCK_WAIT_S=1 SB_MAINTAIN_FORCE=1 bash "$MD" >/dev/null 2>&1 )
cmp -s "$QF" "$Q/before.jsonl" || fail "R2: the quarantine was rewritten while its lock was held"
grep -q 'still held' "$Q/brain/error-log.jsonl" 2>/dev/null || fail "R2: a busy quarantine lock left no error row"
[ -e "$Q/knowledge/graph/.edges-quarantine.jsonl.lock" ] || fail "R2: the rewrite removed a lock it does not hold"
rm -f "$Q/knowledge/graph/.edges-quarantine.jsonl.lock"
( export BRAIN_DIR="$Q/brain" KNOWLEDGE_DIR="$Q/knowledge" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$Q/knowledge"
  SB_MAINTAIN_FORCE=1 bash "$MD" >/dev/null 2>&1 )
grep -q '"from":"qa"' "$QF" && fail "R2: the replay did not clear the resolvable edge once the lock was free"
grep -q '"from":"qx"' "$QF" || fail "R2: the unresolvable edge was dropped"
[ ! -e "$Q/knowledge/graph/.edges-quarantine.jsonl.lock" ] || fail "R2: the rewrite left its lock behind"
pass "R2: the quarantine rewrite honours .edges-quarantine.jsonl.lock (skips + logs when busy, releases after)"
rm -rf "$Q"

rm -rf "$B" "$G"; echo; echo "ALL PASS"
