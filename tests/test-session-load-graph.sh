#!/bin/bash
# Tests that session-load.sh injects the active project's current typed
# dependency neighbourhood from the relational graph (edges.jsonl) into the
# hot tier. No-op when the graph CLI or edges.jsonl is absent (back-compat).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

GRAPH_CLI="$ROOT/mcp/dist/tools/graph-neighbors-cli.bundle.js"
[ -f "$GRAPH_CLI" ] || fail "build mcp first: cd mcp && npm run build (missing $GRAPH_CLI)"

# Minimal fake env: a project whose Cross-references name a slug that has a
# current edge in the graph.
export BRAIN_DIR="$TMP/.second-brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$TMP/knowledge"
export CLAUDE_PLUGIN_ROOT="$ROOT"
KDIR="$TMP/knowledge"
mkdir -p "$BRAIN_DIR/projects" "$KDIR/wiki/entities" "$KDIR/graph"

# The session slug is basename($PWD); run the hook from a dir named "demo".
WORKDIR="$TMP/demo"; mkdir -p "$WORKDIR"
mkdir -p "$BRAIN_DIR/projects/demo"
cat > "$BRAIN_DIR/projects/demo/PROJECT.md" <<'EOF'
# PROJECT: demo

## Goal
wg-tunnel recovery work

## State

## Conventions

## Recent decisions

## Open blockers

## Cross-references
- [[wg-tunnel]]

<!-- last_updated: 2026-05-29T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF

printf '%s\n' '---' 'title: wg-tunnel' 'type: entities' '---' '# wg-tunnel' > "$KDIR/wiki/entities/wg-tunnel.md"
printf '%s\n' '---' 'title: vps-ufw-depinned' 'type: entities' '---' '# vps' > "$KDIR/wiki/entities/vps-ufw-depinned.md"
printf '%s\n' '{"op":"assert","from":"wg-tunnel","to":"vps-ufw-depinned","type":"requires","valid_from":"2026-05-29","recorded_at":"2026-05-29T00:00:00Z"}' > "$KDIR/graph/edges.jsonl"

# --- Test 1: neighbourhood injected when edges exist ---
OUT=$(cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
echo "$OUT" | grep -q 'vps-ufw-depinned' || fail "active-project neighbourhood not injected (expected vps-ufw-depinned)"
pass "session-load injects current dependency neighbourhood"

# --- Test 2: no graph dir → no crash, no graph block (back-compat) ---
rm -rf "$KDIR/graph"
OUT2=$(cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
RC=$?
[ "$RC" -eq 0 ] || fail "session-load returned non-zero without graph dir"
echo "$OUT2" | grep -q 'Dependency graph' && fail "graph block emitted with no edges.jsonl"
pass "no graph dir → clean no-op (back-compat)"

echo; echo "ALL PASS"
