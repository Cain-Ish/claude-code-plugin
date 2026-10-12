#!/bin/bash
# run-all-timeout: 240   (green ~15 s; Tests 4/5 each carry a 90 s hang watchdog, so a regression must fail on its own assertion, not the runner's kill)
# pins: SB_SESSION_LOAD_SOFT_S — Tests 7/8 lift the soft time budget: on a loaded box a new project's first start passes 9 s before the graph spawn and skips the very block they measure
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

# --- Test 1b: a [[cat/slug#heading|alias]] cross-reference seeds the graph with its bare slug ---
sed 's/^- \[\[wg-tunnel\]\]$/- [[entities\/wg-tunnel#Setup|the tunnel]]/' "$BRAIN_DIR/projects/demo/PROJECT.md" > "$TMP/p1b" \
  && mv "$TMP/p1b" "$BRAIN_DIR/projects/demo/PROJECT.md"
grep -qF '[[entities/wg-tunnel#Setup|the tunnel]]' "$BRAIN_DIR/projects/demo/PROJECT.md" || fail "1b: fixture rewrite failed"
OUT1B=$(cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
echo "$OUT1B" | grep -q 'vps-ufw-depinned' || fail "1b: [[entities/wg-tunnel#Setup|alias]] did not seed wg-tunnel's neighbourhood"
pass "a [[cat/slug#h|alias]] cross-reference seeds the graph with its bare slug"

# --- Test 2: no graph dir → no crash, no graph block (back-compat) ---
rm -rf "$KDIR/graph"
OUT2=$(cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
RC=$?
[ "$RC" -eq 0 ] || fail "session-load returned non-zero without graph dir"
echo "$OUT2" | grep -q 'Dependency graph' && fail "graph block emitted with no edges.jsonl"
pass "no graph dir → clean no-op (back-compat)"

# --- Test 3: project-first seeding — the project slug itself (no edges of its own,
# EMPTY Cross-references) resolves through graph/project-registry.jsonl to its anchor
# entity, and the anchor's neighbourhood lands in the session brief. This is the
# headline path: bash → graph-neighbors-cli → knowledgeNeighbors registry resolver.
mkdir -p "$KDIR/graph"
cat > "$BRAIN_DIR/projects/demo/PROJECT.md" <<'EOF'
# PROJECT: demo

## Goal
project-first seeding

## State

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-29T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF
printf '%s\n' '{"op":"assert","from":"hub-learning","to":"demo-anchor","type":"part_of","valid_from":"2026-05-29","recorded_at":"2026-05-29T00:00:00Z"}' > "$KDIR/graph/edges.jsonl"
printf '%s\n' '{"anchor":"demo-anchor","project":"demo"}' > "$KDIR/graph/project-registry.jsonl"
OUT3=$(cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
echo "$OUT3" | grep -q 'hub-learning' \
  || fail "project-first seed: anchor neighbourhood not injected (expected hub-learning via demo→demo-anchor registry row; got: $(echo "$OUT3" | grep -A2 'Dependency graph' || echo 'no graph block'))"
echo "$OUT3" | grep -q -- '- demo:' \
  || fail "project-first seed: brief line not labeled with the project slug"
pass "project slug with no own edges seeds the graph brief via the registry anchor"

# wd_run SECS OUT DIR IN CMD...: portable watchdog (no `timeout` on stock macOS). Runs CMD in DIR
# with stdin from IN and stdout/stderr to OUT/OUT.err in the background, polls up to SECS s.
# The job gets its own process group (set -m) and an overrun kills the whole GROUP: the hang can
# sit in a forked $(...) child of the hook, and killing only the parent orphaned that child,
# blocked for good (seen while writing these tests). TERM, then KILL, return 124, and never
# `wait` — a Git-Bash process blocked writing a here-string pipe ignores TERM.
wd_run() {
  local secs="$1" out="$2" dir="$3" in="$4"; shift 4
  set -m
  ( cd "$dir" || exit 1
    if declare -F "$1" >/dev/null; then "$@"; else exec "$@"; fi ) < "$in" > "$out" 2> "$out.err" &
  local pid=$! i=0
  set +m
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$secs" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- -"$pid" 2>/dev/null; sleep 1; kill -KILL -- -"$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

# --- Test 4 (da #9/#10/#13/#14): a hub anchor whose graph-neighbors-cli output
# lands in the MSYS here-string hang window must not hang SessionStart. e2b943b
# swapped the bounded `node cli | head -12 | awk` for `sl_graph_fmt "$nbr"`, whose
# `done <<< "$1"` fed the CLI's FULL, uncapped edge list through a here-string:
# at 65,537..~65,650 bytes (text + newline) Git-Bash blocks for good, the hook
# dies at its 15 s timeout and the whole SessionStart context is lost — every
# start, until the graph changes. Short `to` slugs keep the 12 rendered entries
# far under the block's 600 B cap (so a dropped block cannot pass this
# vacuously); the byte window is reached by edge COUNT and asserted before the
# run. RED reproduces on MSYS only; on Linux/macOS this still checks the format.
awk 'BEGIN { for (i = 1; i <= 2262; i++)
  printf "{\"op\":\"assert\",\"from\":\"demo-anchor\",\"to\":\"n%05d\",\"type\":\"relates\",\"valid_from\":\"2026-05-29\",\"recorded_at\":\"2026-05-29T00:00:00Z\"}\n", i }' \
  > "$KDIR/graph/edges.jsonl"
HUB_BYTES=$(( $(KNOWLEDGE_DIR="$KDIR" node "$GRAPH_CLI" demo 1 both | tr -d '\r' | wc -c) ))
[ "$HUB_BYTES" -ge 65540 ] && [ "$HUB_BYTES" -le 65640 ] \
  || fail "4: fixture drifted — the hub's CLI output is $HUB_BYTES B, outside the 65,540..65,640 B here-string hang window it must exercise"
echo '{"hook_event_name":"SessionStart","source":"startup"}' > "$TMP/start.json"
wd_run 90 "$TMP/out4" "$WORKDIR" "$TMP/start.json" bash "$ROOT/scripts/session-load.sh"; RC4=$?
[ "$RC4" -ne 124 ] || fail "4: session-load hung on a ${HUB_BYTES}-byte hub edge list (MSYS here-string window) — killed after 90 s"
[ "$RC4" -eq 0 ] || fail "4: session-load exited $RC4: $(head -c 300 "$TMP/out4.err")"
GLINE4=$(tr -d '\r' < "$TMP/out4" | grep -- '^- demo: ')
[ -n "$GLINE4" ] || fail "4: no '- demo:' graph line for the hub anchor (block dropped?): $(grep -A2 'Dependency graph' "$TMP/out4" || echo 'no graph block')"
N4=$(printf '%s\n' "$GLINE4" | grep -o 'demo-anchor relates n[0-9]*; ' | wc -l | tr -d ' ')
[ "$N4" -eq 12 ] || fail "4: expected exactly 12 'from type to;' entries for the hub, got $N4: $GLINE4"
pass "hub anchor with a ${HUB_BYTES}-byte edge list: no hang, 12 formatted entries"

# --- Test 5: sl_graph_fmt itself across the whole window, sweep under the
# watchdog (the window's upper edge moved between probes, ~65,650..65,690),
# plus one 70,000-byte line. The function is lifted verbatim from
# session-load.sh; the oracle is the pre-e2b943b pipeline
# (`head -12 | awk -F'\t'`) run on the same text.
SLG_SRC=$(awk '/^  sl_graph_fmt\(\) \{/ { f = 1 } f { print } f && /^  \}$/ { exit }' "$ROOT/scripts/session-load.sh")
[ -n "$SLG_SRC" ] || fail "5: could not lift sl_graph_fmt from session-load.sh"
eval "$SLG_SRC"
slg_sweep() {
  local n x want
  for n in 65530 65535 65536 65540 65560 65584 65600 65616 65632 65648 65664 65690 65700 70000; do
    x=$(awk -v n="$n" 'BEGIN { l = "relates\tdemo-anchor\tn00000\t1"; s = "";
      while (length(s) + length(l) + 1 < n) s = s l "\n";
      pad = n - length(s); t = ""; for (i = 0; i < pad; i++) t = t "z"; printf "%s%s", s, t }')
    [ "${#x}" -eq "$n" ] || { echo "size $n built ${#x}"; return 1; }
    sl_graph_fmt "$x"
    want=$(printf '%s\n' "$x" | head -12 | awk -F'\t' '{ printf "%s %s %s; ", $2, $1, $3 }')
    [ "$SL_NBR" = "$want" ] || { echo "size $n: got [$SL_NBR] want [$want]"; return 1; }
  done
  # One oversized edge line (loadEdges never length-checks a slug): a 12-LINE cap alone would
  # still feed all 70,000 bytes to the loop; the byte cap keeps the rendered entry bounded.
  x=$(head -c 70000 /dev/zero | tr '\0' a)
  sl_graph_fmt "$x"
  [ "${#SL_NBR}" -le 8200 ] || { echo "one 70,000-byte line rendered ${#SL_NBR} bytes (no byte cap)"; return 1; }
  echo done
}
wd_run 90 "$TMP/sweep5" "$TMP" /dev/null slg_sweep; RC5=$?
[ "$RC5" -ne 124 ] || fail "5: sl_graph_fmt did not return within 90 s for a 65,530..70,000-byte edge list (MSYS here-string hang)"
[ "$(tr -d '\r' < "$TMP/sweep5")" = done ] || fail "5: sl_graph_fmt formatted the wrong 12 entries: $(cat "$TMP/sweep5")"
pass "sl_graph_fmt returns and formats exactly the first 12 edges across the 65,530..70,000-byte window; one 70,000-byte line stays byte-capped"

# --- Test 6 (re-audit H6-1): an anchor with 12 edges of long slugs renders > 600 B; sb_append keeps
# whole lines only, so the seed line was dropped and the block shipped as a bare header (while the
# manifest still recorded the seed as injected). The seed line is now capped while it is built.
awk 'BEGIN { for (i = 1; i <= 12; i++)
  printf "{\"op\":\"assert\",\"from\":\"demo-anchor\",\"to\":\"long-neighbour-slug-number-%02d-padding\",\"type\":\"relates\",\"valid_from\":\"2026-05-29\",\"recorded_at\":\"2026-05-29T00:00:00Z\"}\n", i }' \
  > "$KDIR/graph/edges.jsonl"
wd_run 90 "$TMP/out6" "$WORKDIR" "$TMP/start.json" bash "$ROOT/scripts/session-load.sh"; RC6=$?
[ "$RC6" -eq 0 ] || fail "6: session-load exited $RC6"
GLINE6=$(tr -d '\r' < "$TMP/out6" | grep -- '^- demo: ')
[ -n "$GLINE6" ] || fail "6: a 12-edge anchor shipped a bare graph header, no '- demo:' line ($(grep -A2 'Dependency graph' "$TMP/out6" || echo 'no graph block'))"
printf '%s\n' "$GLINE6" | grep -q 'long-neighbour-slug-number-01' || fail "6: the first edge is missing from the capped line: $GLINE6"
pass "a 12-edge long-slug anchor still ships a (capped) neighbourhood line, never a bare header"

# 12 edges from demo-anchor whose rendered entries are 66 B each ("demo-anchor relates <44 B>; ").
awk 'BEGIN { for (i = 1; i <= 12; i++) { t = sprintf("nbr-%02d-", i); while (length(t) < 44) t = t "q"
  printf "{\"op\":\"assert\",\"from\":\"demo-anchor\",\"to\":\"%s\",\"type\":\"relates\",\"valid_from\":\"2026-05-29\",\"recorded_at\":\"2026-05-29T00:00:00Z\"}\n", t } }' \
  > "$KDIR/graph/edges.jsonl"

# --- Test 7 (re-audit T3/B3): the seed line's cap counts the seed and the header. A 100-byte project
# slug plus the old 400 B entry cap made a 607 B block: sb_append dropped the line, a bare header
# shipped, and the anchor was still recorded as injected.
SLUG7="long-project-slug-$(printf '%082d' 7 | tr 0 x)"
[ "${#SLUG7}" -eq 100 ] || fail "7: fixture slug is ${#SLUG7} bytes, not 100"
mkdir -p "$TMP/$SLUG7" "$BRAIN_DIR/projects/$SLUG7"
sed "s/^# PROJECT: demo$/# PROJECT: $SLUG7/" "$BRAIN_DIR/projects/demo/PROJECT.md" > "$BRAIN_DIR/projects/$SLUG7/PROJECT.md"
printf '{"anchor":"demo-anchor","project":"%s"}\n' "$SLUG7" > "$KDIR/graph/project-registry.jsonl"
echo '{"hook_event_name":"SessionStart","source":"startup","session_id":"graph-t7"}' > "$TMP/start7.json"
wd_run 90 "$TMP/out7" "$TMP/$SLUG7" "$TMP/start7.json" env SB_SESSION_LOAD_SOFT_S=60 bash "$ROOT/scripts/session-load.sh"; RC7=$?
[ "$RC7" -eq 0 ] || fail "7: session-load exited $RC7"
GLINE7=$(tr -d '\r' < "$TMP/out7" | grep -F -- "- $SLUG7: ")
grep -qF "{\"kind\":\"anchor\",\"id\":\"$SLUG7\"}" "$BRAIN_DIR/.injected-manifest-graph-t7.jsonl" 2>/dev/null && [ -z "$GLINE7" ] \
  && fail "7/B3: the anchor was recorded as injected although its line was dropped"
[ -n "$GLINE7" ] || fail "7/T3: a 100-byte project slug shipped a bare graph header ($(grep -A2 'Dependency graph' "$TMP/out7" || echo 'no graph block'))"
grep -qF "{\"kind\":\"anchor\",\"id\":\"$SLUG7\"}" "$BRAIN_DIR/.injected-manifest-graph-t7.jsonl" \
  || fail "7: the shipped anchor line was not recorded in the manifest"
pass "a 100-byte project slug still ships its capped seed line, and only a shipped anchor is recorded"

# --- Test 8 (re-audit B3): two seed lines over the 600 B cap: sb_append keeps whole lines, and the
# dropped seed must not be recorded as injected (the manifest reads what sb_append kept).
printf '%s\n' '{"anchor":"demo-anchor","project":"demo"}' > "$KDIR/graph/project-registry.jsonl"
awk 'BEGIN { for (i = 1; i <= 3; i++) { t = sprintf("wg-dep-%02d-", i); while (length(t) < 44) t = t "q"
  printf "{\"op\":\"assert\",\"from\":\"wg-tunnel\",\"to\":\"%s\",\"type\":\"requires\",\"valid_from\":\"2026-05-29\",\"recorded_at\":\"2026-05-29T00:00:00Z\"}\n", t } }' \
  >> "$KDIR/graph/edges.jsonl"
printf '# PROJECT: demo\n\n## Goal\ntwo seeds\n\n## Cross-references\n- [[wg-tunnel]]\n' > "$BRAIN_DIR/projects/demo/PROJECT.md"
echo '{"hook_event_name":"SessionStart","source":"startup","session_id":"graph-t8"}' > "$TMP/start8.json"
wd_run 90 "$TMP/out8" "$WORKDIR" "$TMP/start8.json" env SB_SESSION_LOAD_SOFT_S=60 bash "$ROOT/scripts/session-load.sh"; RC8=$?
[ "$RC8" -eq 0 ] || fail "8: session-load exited $RC8"
tr -d '\r' < "$TMP/out8" | grep -q -- '^- demo: ' || fail "8: precondition — the anchor line did not ship"
tr -d '\r' < "$TMP/out8" | grep -q -- '^- wg-tunnel: ' && fail "8: precondition — the second seed line fit; the fixture no longer exceeds 600 B"
grep -qF '{"kind":"graph","id":"wg-tunnel"}' "$BRAIN_DIR/.injected-manifest-graph-t8.jsonl" 2>/dev/null \
  && fail "8: the dropped wg-tunnel seed was recorded as injected"
grep -qF '{"kind":"anchor","id":"demo"}' "$BRAIN_DIR/.injected-manifest-graph-t8.jsonl" 2>/dev/null \
  || fail "8: the shipped anchor line was not recorded"
pass "a seed line dropped by the 600 B cap is not recorded in the injection manifest"

echo; echo "ALL PASS"
