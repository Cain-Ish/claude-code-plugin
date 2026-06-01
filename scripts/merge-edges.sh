#!/bin/bash
# Append extractor-proposed relationship edges to ~/knowledge/graph/edges.jsonl.
# Pure-bash deterministic write path (no node dependency) so the graph accrues
# even when the LLM extractor / MCP layer is unavailable. The LLM only proposes
# the `relations` array; this script validates endpoints + type and either
# appends an op:assert line or quarantines the edge. JSONL line format is the
# contract shared with mcp/src/tools/graph-store.ts.
#
# Usage: echo '<delta-json>' | bash merge-edges.sh --knowledge-dir <dir>
set -u
source "$(dirname "$0")/lib.sh"

KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    *) echo "merge-edges: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI="$KNOWLEDGE_DIR/wiki"
GRAPH_DIR="$KNOWLEDGE_DIR/graph"
LOG="$GRAPH_DIR/edges.jsonl"
QLOG="$GRAPH_DIR/edges-quarantine.jsonl"
VALID_TYPES="requires affects relates part_of supersedes"
CONFLICTS="$GRAPH_DIR/conflicts.jsonl"
SNAP=$(mktemp); trap 'rm -f "$SNAP"' EXIT

RAW=$(cat)
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0   # not JSON → no-op
COUNT=$(echo "$RAW" | jq '(.relations // []) | length' 2>/dev/null || echo 0)
[ "${COUNT:-0}" -eq 0 ] && exit 0

# A slug resolves if a matching page exists anywhere under wiki/ (excluding index.md).
resolves() {
  local slug="$1"
  [ -n "$slug" ] || return 1
  find "$WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | grep -q .
}

# Structural conflict detector (pure jq over the running snapshot $SNAP). On a hit,
# prints "<kind>\t<against-json>" and returns 0; else returns 1.
# Spec: docs/specs/2026-06-01-write-time-contradiction-flag-design.md §2.
detect_conflict() {
  local F="$1" T="$2" O="$3" against opp
  # R1 reintroduce: latest record for (F,T,O) is closed (op:invalidate or valid_to set).
  against=$(jq -c --arg f "$F" --arg t "$T" --arg o "$O" \
    '(map(select(.from==$f and .type==$t and .to==$o)) | .[0])
     | select(. != null and (.op=="invalidate" or (.valid_to != null)))
     | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
  [ -n "$against" ] && { printf 'reintroduce\t%s\n' "$against"; return 0; }
  # R2 opposing (supersedes-anchored): circular supersede, or supersede<->requires on the pair.
  against=""
  if [ "$T" = supersedes ]; then
    against=$(jq -c --arg f "$F" --arg o "$O" \
      '(map(select(.from==$o and .type=="supersedes" and .to==$f and .valid_to==null)) | .[0] // empty)
       | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
  fi
  if [ -z "$against" ] && { [ "$T" = requires ] || [ "$T" = supersedes ]; }; then
    [ "$T" = requires ] && opp=supersedes || opp=requires
    against=$(jq -c --arg f "$F" --arg o "$O" --arg op "$opp" \
      '(map(select(.from==$f and .type==$op and .to==$o and .valid_to==null)) | .[0] // empty)
       | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
  fi
  [ -n "$against" ] && { printf 'opposing\t%s\n' "$against"; return 0; }
  # R3 multi_parent (opt-in): a second live parent under the single-parent assumption.
  if [ "${SB_CONFLICT_MULTIPARENT:-off}" = on ] && [ "$T" = part_of ]; then
    against=$(jq -c --arg f "$F" --arg o "$O" \
      '(map(select(.from==$f and .type=="part_of" and .to!=$o and .valid_to==null)) | .[0] // empty)
       | {from,type,to,valid_to}' "$SNAP" 2>/dev/null)
    [ -n "$against" ] && { printf 'multi_parent\t%s\n' "$against"; return 0; }
  fi
  return 1
}

# True iff conflict identity (from,type,to,kind) currently folds to status:open.
already_open() {
  # Per-line tolerant fold (skip torn lines) so a partial last line can't mask an open conflict.
  [ -s "$CONFLICTS" ] && jq -e --arg f "$1" --arg t "$2" --arg o "$3" --arg k "$4" \
    -nR '[inputs|fromjson?] | group_by([.from,.type,.to,.kind]) | map(last)
        | any(.from==$f and .type==$t and .to==$o and .kind==$k and .status=="open")' \
    "$CONFLICTS" >/dev/null 2>&1
}

mkdir -p "$GRAPH_DIR"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- write-time contradiction detection (pure-bash, offline; spec 2026-06-01) ---
# Computed ONCE pre-batch; updated per appended edge so within-delta collisions are caught.
DETECT=0
[ "${SB_CONFLICT_DETECT:-on}" != off ] && DETECT=1
# Build the pre-batch snapshot only when a prior log exists (within-batch collisions on
# a fresh graph are still caught via the per-edge fold below). Fail-open to [] on a
# torn/corrupt log. recorded_at normalized to seconds, ties broken by file order (later
# line wins) so a same-second ms-stamped invalidate beats an earlier-line assert.
if [ "$DETECT" = 1 ] && [ -s "$LOG" ]; then
  jq -s '[ to_entries[] | .value + {recorded_at: (.value.recorded_at|.[0:19]), _i: .key} ]
         | group_by([.from,.type,.to]) | map(max_by([.recorded_at, ._i]))' \
     "$LOG" > "$SNAP" 2>/dev/null || echo '[]' > "$SNAP"
else
  echo '[]' > "$SNAP"
fi

echo "$RAW" | jq -c '.relations[]?' 2>/dev/null | while IFS= read -r rel; do
  from=$(echo "$rel" | jq -r '.from // empty')
  to=$(echo "$rel"   | jq -r '.to // empty')
  type=$(echo "$rel" | jq -r '.type // "relates"')
  vf=$(echo "$rel"   | jq -r '.valid_from // empty')
  conf=$(echo "$rel" | jq -r '.confidence // "medium"')

  # sanitize slugs (kebab/url-safe) — reuse lib.sh helper; reject on failure
  sfrom=$(sb_sanitize_slug "$from") || continue
  sto=$(sb_sanitize_slug "$to") || continue

  # validate edge type
  case " $VALID_TYPES " in *" $type "*) : ;; *) continue ;; esac

  # build the record (valid_from optional)
  if [ -n "$vf" ]; then
    rec=$(jq -nc --arg f "$sfrom" --arg t "$sto" --arg ty "$type" --arg vf "$vf" --arg now "$NOW" --arg c "$conf" \
      '{op:"assert",from:$f,to:$t,type:$ty,valid_from:$vf,valid_to:null,recorded_at:$now,source:"extractor",confidence:$c}')
  else
    rec=$(jq -nc --arg f "$sfrom" --arg t "$sto" --arg ty "$type" --arg now "$NOW" --arg c "$conf" \
      '{op:"assert",from:$f,to:$t,type:$ty,valid_to:null,recorded_at:$now,source:"extractor",confidence:$c}')
  fi

  # endpoint guard: both must resolve to real pages, else quarantine
  if resolves "$sfrom" && resolves "$sto"; then
    # detect BEFORE appending, against the running pre-batch snapshot (R1 needs this)
    if [ "$DETECT" = 1 ]; then
      if hit=$(detect_conflict "$sfrom" "$type" "$sto"); then
        kind="${hit%%$'\t'*}"; against="${hit#*$'\t'}"
        if ! already_open "$sfrom" "$type" "$sto" "$kind"; then
          jq -nc --arg f "$sfrom" --arg t "$type" --arg o "$sto" --arg k "$kind" \
            --arg now "$NOW" --argjson ag "$against" \
            '{detected_at:$now,from:$f,type:$t,to:$o,kind:$k,against:$ag,source:"merge-edges",status:"open"}' \
            >> "$CONFLICTS"
        fi
      fi
    fi
    printf '%s\n' "$rec" >> "$LOG"
    # fold the just-appended edge into the running snapshot
    if [ "$DETECT" = 1 ]; then
      upd=$(jq --argjson new "$rec" \
        '($new | .recorded_at |= .[0:19]) as $n
         | (map(select([.from,.type,.to] != [$n.from,$n.type,$n.to]))) + [$n]' "$SNAP" 2>/dev/null) \
        && printf '%s' "$upd" > "$SNAP"
    fi
  else
    printf '%s\n' "$rec" >> "$QLOG"
  fi
done

exit 0
