#!/bin/bash
# sb-health-snapshot.sh — one-screen, read-only health snapshot of a live second-brain.
#
# Prints: auth mode, drainer scheduler state, extractor health + backlog, error/audit
# log tails, wiki page counts (+ legacy-misroute check), embeddings state, dream states.
# Interpretation guide lives in the owning skill (sb-diagnostics-and-tooling/SKILL.md).
#
# STRICTLY READ-ONLY: never writes any state file (deliberately does NOT run verify.sh,
# which stamps .last-verify). External probes spawned: `claude auth status` (via the sb
# CLI bundle, 3s SIGKILL timeout) and the per-OS scheduler query (systemctl/launchctl/
# schtasks) inside sb_timer_health — both read-only.
#
# Usage (bash 3.2-safe, runnable from anywhere):
#   bash sb-health-snapshot.sh [PLUGIN_ROOT]     # or export CLAUDE_PLUGIN_ROOT
# Honors BRAIN_DIR / KNOWLEDGE_DIR / CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR overrides.
# Exit: 0 (informational; only exits 2 when the plugin root or lib.sh is unusable).
set -u

ROOT=""
if [ -n "${1:-}" ]; then
  ROOT="$1"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh" ]; then
  ROOT="$CLAUDE_PLUGIN_ROOT"
else
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    if [ -f "$d/scripts/lib.sh" ]; then ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/lib.sh" ] \
  || { echo "sb-health-snapshot: cannot locate plugin root (pass as \$1 or set CLAUDE_PLUGIN_ROOT)" >&2; exit 2; }
# lib.sh gives us BRAIN_DIR (MSYS-normalized), sb_timer_health, drain counters. Read-only to source.
source "$ROOT/scripts/lib.sh" 2>/dev/null \
  || { echo "sb-health-snapshot: failed to source $ROOT/scripts/lib.sh" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || echo "sb-health-snapshot: WARNING jq missing — most probes below will be blank" >&2

KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"; KD="${KD/#\~/$HOME}"
VER=$(jq -r '.version // "?"' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)

_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }  # GNU || BSD
_ago() {
  local s="$1" d
  d=$(( $(date +%s) - s )); [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 120 ];    then echo "${d}s ago"
  elif [ "$d" -lt 7200 ];   then echo "$((d/60))m ago"
  elif [ "$d" -lt 172800 ]; then echo "$((d/3600))h ago"
  else echo "$((d/86400))d ago"; fi
}

echo "== second-brain health snapshot ($(date -u +%Y-%m-%dT%H:%M:%SZ), read-only) =="
echo "plugin: $ROOT (v${VER:-?})   BRAIN_DIR: $BRAIN_DIR   KNOWLEDGE_DIR: $KD"

echo
echo "-- auth (extractor backend) --"
SB_BUNDLE="$ROOT/mcp/dist/cli/sb-entry.bundle.js"
if command -v node >/dev/null 2>&1 && [ -f "$SB_BUNDLE" ]; then
  node "$SB_BUNDLE" auth status 2>/dev/null | sed -n '1,3p' | sed 's/^/  /'
else
  echo '  (node or sb-entry bundle missing — probe skipped)'
  [ -n "${ANTHROPIC_API_KEY:-}" ] && echo '  fallback signal: ANTHROPIC_API_KEY is set (mode: api-key)' \
                                  || echo '  fallback signal: ANTHROPIC_API_KEY not set'
fi

echo
echo "-- drainer / extraction --"
echo "  scheduler timer: $(sb_timer_health)   (shim: $BRAIN_DIR/bin/sb-extract-drain.sh $( [ -f "$BRAIN_DIR/bin/sb-extract-drain.sh" ] && echo present || echo ABSENT ))"
HF="$BRAIN_DIR/.extractor-health.json"
if [ -f "$HF" ]; then
  echo "  extractor-health: $(jq -r '"status=\(.status) backend=\(.backend) checked_at=\(.checked_at) reason=\(.reason)"' "$HF" 2>/dev/null) ($(_ago "$(_mtime "$HF")"))"
else
  echo "  extractor-health: no marker yet (no extraction attempt recorded)"
fi
ST="$BRAIN_DIR/.extraction-state.jsonl"
if [ -s "$ST" ]; then
  echo "  last drained: $(tail -1 "$ST" | jq -r '"\(.ts)  outcome=\(.outcome)\(if .reason then " reason=" + .reason else "" end)  \(.basename)"' 2>/dev/null) ($(_ago "$(_mtime "$ST")"))"
else
  echo "  last drained: never (.extraction-state.jsonl absent/empty)"
fi
ARCH_N=$(ls -1 "$BRAIN_DIR"/transcripts/*.txt 2>/dev/null | wc -l | tr -d ' ')
# tr -d '\r': jq stdout is text-mode CRLF on Windows, so a CR rides on every basename and matches
# nothing in comm — backlog would falsely read as ALL archived. Strip at the source (same fix as
# scripts/wiki-forget-candidates.sh). project_jq_windows_crlf_stdout.
BACKLOG=$(comm -23 \
  <(ls -1 "$BRAIN_DIR"/transcripts/*.txt 2>/dev/null | sed 's|.*/||' | sort) \
  <(jq -r 'select(.outcome=="ok" or .outcome=="error") | .basename' "$ST" 2>/dev/null | tr -d '\r' | sort -u) \
  2>/dev/null | wc -l | tr -d ' ')
echo "  backlog: ${BACKLOG:-?} pending of ${ARCH_N:-0} archived transcripts (0 = fully drained)"
echo "  drain counters: timeouts(last 40 err-log lines)=$(sb_count_drain_timeouts 40)  dead-letters=$(sb_count_drain_dead_letters)"

echo
echo "-- logs --"
EL="$BRAIN_DIR/error-log.jsonl"
if [ -s "$EL" ]; then
  echo "  error-log: $(wc -l < "$EL" | tr -d ' ') lines, newest 3:"
  tail -3 "$EL" | jq -r '"    \(.timestamp)  [\(.script)] ec=\(.exit_code)  \(.message[0:110])"' 2>/dev/null
else
  echo "  error-log: empty/absent"
fi
AUD="$BRAIN_DIR/audit-log.jsonl"
if [ -s "$AUD" ]; then
  VT=$(jq -r 'select(.verdict != null) | .verdict' "$AUD" 2>/dev/null | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  # grep -c prints the count AND exits 1 on zero matches — never `|| echo 0` inside $() (double-print).
  LAT=$(grep -c '"kind":"latency"' "$AUD" 2>/dev/null); case "$LAT" in ''|*[!0-9]*) LAT=0 ;; esac
  BW=$(grep -c '"budget_warn":true' "$AUD" 2>/dev/null); case "$BW" in ''|*[!0-9]*) BW=0 ;; esac
  echo "  audit-log: verdicts: ${VT:-none}  latency rows: $LAT (budget_warn: $BW)"
else
  echo "  audit-log: empty/absent — SUSPICIOUS if guards are wired (fail-open signature)"
fi

echo
echo "-- wiki --"
if [ -d "$KD/wiki" ]; then
  WN=$(find "$KD/wiki" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')
  CN=$(find "$KD/wiki" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  [ -f "$KD/wiki/index.md" ] && IDX="present ($(_ago "$(_mtime "$KD/wiki/index.md")"))" || IDX="MISSING (run knowledge_reindex)"
  echo "  pages: $WN across $CN categories   index.md: $IDX"
else
  echo "  wiki: MISSING at $KD/wiki (run /second-brain:setup)"
fi
LEGACY=$(find "$BRAIN_DIR/wiki" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  legacy-misroute check ($BRAIN_DIR/wiki): ${LEGACY:-0} pages (expect 0 — anything here is invisible to search)"

echo
echo "-- embeddings --"
VD="${SB_VECTOR_DEPS_DIR:-$BRAIN_DIR/vector-deps}"
[ -f "$VD/node_modules/@huggingface/transformers/package.json" ] && SHARED="present" || SHARED="ABSENT"
[ -e "$ROOT/mcp/node_modules/@huggingface/transformers/package.json" ] && LINKED="linked" || LINKED="NOT linked"
echo "  vector deps: shared tree $SHARED at $VD; plugin junction $LINKED (heal: bash \"$ROOT/bin/install-vector-deps.sh\" --relink-only)"
EPI="$BRAIN_DIR/episodic-index.json"
if [ -f "$EPI" ]; then
  jq -r '(.exchanges|length) as $t
    | ([.exchanges[] | select((.embedding|length) > 0)] | length) as $e
    | if $t == 0 then "  episodic coverage: no exchanges indexed yet"
      else "  episodic coverage: \($e)/\($t) exchanges (\(($e*100/$t)|floor)%) — <100% = those match by text only" end' "$EPI" 2>/dev/null
else
  echo "  episodic coverage: no index yet ($EPI absent)"
fi
EMB_FAILS=$(jq -c 'select(.script=="embeddings")' "$EL" 2>/dev/null | wc -l | tr -d ' ')
EMB_LAST=$(jq -r 'select(.script=="embeddings") | .timestamp' "$EL" 2>/dev/null | tail -1)
echo "  embeddings load failures in error-log: ${EMB_FAILS:-0}${EMB_LAST:+ (newest: $EMB_LAST)}"

echo
echo "-- dreams --"
FOUND=0
for sf in "$BRAIN_DIR"/dreams/drm_*/status.json; do
  [ -f "$sf" ] || continue
  A=$(jq -r '.archived_at // ""' "$sf" 2>/dev/null | tr -d '\r')
  [ -n "$A" ] && [ "$A" != "null" ] && continue   # archived = reviewed, not shown
  FOUND=1
  jq -r '"  \(.id)  \(.status)  +\(.outputs.pages_added) ~\(.outputs.pages_modified) -\(.outputs.pages_removed)\(if .error then "  error=" + .error[0:60] else "" end)"' "$sf" 2>/dev/null
done
[ "$FOUND" -eq 0 ] && echo "  no unreviewed dreams"

echo
echo "== end snapshot (deep dives: guard-liveness.sh, scripts/verify.sh — note verify.sh WRITES .last-verify) =="
exit 0
