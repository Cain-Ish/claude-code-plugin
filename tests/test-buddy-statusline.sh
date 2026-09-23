#!/bin/bash
# pins: SB_BUDDY — kill-switch test: asserts =off yields no output (renderer) and no state (producer)
# pins: SB_BUDDY_COLS — width fixture override (production reads COLUMNS; both paths asserted)
# pins: SB_BUDDY_SPRITE — telemetry-only mode asserted
# pins: SB_HOOK_PROFILE — minimal profile must stop the producer (lib.sh mapping) and the sprite (renderer shim)
# pins: SB_BUDDY_CHAIN — chained statusline arrives via env, never from a data file
# pins: SB_BUDDY_LOG_KEEP — a non-numeric value must not abort the producer (guards call it pre-decision)
# Buddy contract (docs/plans/2026-09-22-buddy-companion.md):
#  1. sb_buddy_event writes ONE atomic current-state file + an append-only log; a `gate` line holds
#     the CURRENT-STATE bubble for 60 s (the log always gets the row); nothing reaches stdout.
#  2. buddy-statusline.sh renders from state the hooks/server already keep (.injected memo/phase,
#     .buddy/<sid>.json, .buddy/_global.json) — goal, phase, ctx%, model, event line — and every
#     row fits the usable width at 60 / 80 / 120 columns; event text is never globbed or executed.
#  3. Kill switches and modes: SB_BUDDY=off, SB_BUDDY_SPRITE=off, minimal profile, mute, chain.
#  4. Hot path: no lib.sh, no node, ≤ 2 jq spawns, `set -f`, and a wall-clock ceiling.
#  5. Identity (no stats): pinned vector, merge-write, sprites for 18 species × hats fit, fallback seed.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo; echo "ALL PASS"; exit 0; }

# Width is measured in CHARACTERS (`wc -m`), which needs a UTF-8 locale; a bare CI runner may have
# none (LANG unset → C → bytes). Pick one that exists, else skip the width assertions loudly.
for _loc in "${LC_ALL:-}" "${LANG:-}" C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  [ -n "$_loc" ] || continue
  if [ "$(LC_ALL="$_loc" printf '…' | LC_ALL="$_loc" wc -m 2>/dev/null | tr -d ' ')" = "1" ]; then export LC_ALL="$_loc"; break; fi
done
WIDTH_OK=1; [ "$(printf '…' | wc -m | tr -d ' ')" = "1" ] || { WIDTH_OK=0; echo "  note: no UTF-8 locale on this host — width assertions skipped (content assertions still run)"; }
export HOME; HOME=$(mktemp -d); export USERPROFILE="$HOME"; export BRAIN_DIR="$HOME/.second-brain"
export CLAUDE_CONFIG_DIR="$HOME/.claude-cfg"; unset SB_BUDDY_CHAIN COLUMNS
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$BRAIN_DIR/.injected"
SID="sess-buddy-1"
printf '{"goal":"add buddy statusline renderer to the plugin","goal_kw":"buddy statusline"}' > "$BRAIN_DIR/.injected/$SID.json"
printf 'implement' > "$BRAIN_DIR/.injected/$SID.phase"
R="$ROOT/scripts/buddy-statusline.sh"
payload(){ printf '{"session_id":"%s","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":34.7}}' "$SID"; }
render(){ payload | NO_COLOR=1 bash "$R"; }   # callers set SB_BUDDY_COLS / COLUMNS

# --- 1. producer -----------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$ROOT/scripts/lib.sh"
out=$(sb_buddy_event "$SID" delivered focused "Hot tier delivered" session-load)
[ -z "$out" ] || fail "sb_buddy_event wrote to stdout (would corrupt a hook's JSON): $out"
[ -f "$BRAIN_DIR/.buddy/$SID.json" ] || fail "sb_buddy_event did not write the current-state file"
jq -e '.kind=="delivered" and .line=="Hot tier delivered" and (.ts|type=="number")' "$BRAIN_DIR/.buddy/$SID.json" >/dev/null || fail "current-state row malformed"
sb_buddy_event "$SID" gate alert "Plan gate fired" plan-first-nudge
sb_buddy_event "$SID" retrieved focused "2 wiki pages offered" persona-context
jq -e '.kind=="gate"' "$BRAIN_DIR/.buddy/$SID.json" >/dev/null || fail "a retrieval overwrote a fresh gate line (noise rule broken)"
n=$(wc -l < "$BRAIN_DIR/.buddy/$SID.log.jsonl" | tr -d ' ')
[ "$n" = "3" ] || fail "the log must keep every row even when the bubble is held (has $n, want 3)"
sb_buddy_event "$SID" gate alert "Verify gate fired" stop-verify-gate
jq -e '.line=="Verify gate fired"' "$BRAIN_DIR/.buddy/$SID.json" >/dev/null || fail "a newer gate must replace an older gate"
# hold expiry: a gate older than 60 s no longer holds
jq -c '.ts = (.ts - 61)' "$BRAIN_DIR/.buddy/$SID.json" > "$BRAIN_DIR/.buddy/x" && mv "$BRAIN_DIR/.buddy/x" "$BRAIN_DIR/.buddy/$SID.json"
sb_buddy_event "$SID" read focused "Read [[x]] from memory" mcp
jq -e '.kind=="read"' "$BRAIN_DIR/.buddy/$SID.json" >/dev/null || fail "an expired gate must not hold the bubble"
ls "$BRAIN_DIR/.buddy/" | grep -q 'tmp' && fail "temp file left behind (atomic write broken)"
sb_buddy_event "../evil" gate alert "x" t; [ -e "$BRAIN_DIR/.buddy/../evil.json" ] && fail "sid not sanitized"
sb_buddy_event unknown gate alert "x" t; sb_buddy_event default gate alert "x" t
ls "$BRAIN_DIR/.buddy/" | grep -Eq '^(unknown|default)\.' && fail "fallback session ids must not create state"
sb_buddy_event "$SID" read focused "$(printf 'esc\x1b[31mred\xc2\x9bcsi — ok')" t
jq -r .line "$BRAIN_DIR/.buddy/$SID.json" | grep -q $'\x1b' && fail "C0 control survived sanitisation"
jq -r .line "$BRAIN_DIR/.buddy/$SID.json" | grep -q $'\xc2\x9b' && fail "C1 control survived sanitisation"
jq -r .line "$BRAIN_DIR/.buddy/$SID.json" | grep -q '— ok' || fail "multibyte text damaged by sanitisation"
# A mistyped keep must not abort the caller: guards call this before emitting their decision.
( set -u; SB_BUDDY_LOG_KEEP=forty sb_buddy_event "$SID" read focused "keep typo survives" t ) 2>/dev/null \
  || fail "SB_BUDDY_LOG_KEEP=forty aborted sb_buddy_event under set -u (a guard would lose its deny)"
jq -r .line "$BRAIN_DIR/.buddy/$SID.json" | grep -q 'keep typo survives' || fail "event dropped under a mistyped SB_BUDDY_LOG_KEEP"
pass "producer: stdout-clean, atomic state, log keeps held rows, 60 s hold + expiry, sid sanitised, C0/C1 stripped"

# --- 2. renderer: content + width fixture (both width sources) -----------------------------
sb_buddy_event "$SID" gate alert "Verify gate fired" stop-verify-gate
for cols in 60 80 120; do
  out=$(SB_BUDDY_COLS=$cols render) || fail "renderer exited non-zero at $cols cols"
  usable=$(( cols - 14 ))
  while IFS= read -r row; do
    w=$(printf '%s' "$row" | wc -m | tr -d ' ')
    [ "$WIDTH_OK" = "0" ] || [ "$w" -le "$(( usable + 2 ))" ] || fail "row exceeds usable width at $cols cols ($w > $usable): $row"
  done <<< "$out"
  printf '%s' "$out" | grep -q 'add buddy statusline' || fail "goal missing at $cols cols"
  printf '%s' "$out" | grep -q 'implement'            || fail "phase missing at $cols cols"
  printf '%s' "$out" | grep -q 'ctx 34%'              || fail "context % missing at $cols cols"
  if [ "$cols" -ge 84 ]; then printf '%s' "$out" | grep -q 'Opus 5' || fail "model missing at $cols cols"
  else printf '%s' "$out" | grep -q 'Opus 5' && fail "model should be dropped at $cols cols to keep the goal readable"; fi
done
wide=$(SB_BUDDY_COLS=120 render)
printf '%s' "$wide" | grep -q 'Verify gate fired' || fail "event line not rendered in bubble"
[ "$(printf '%s\n' "$wide" | wc -l | tr -d ' ')" = "5" ] || fail "wide layout should be 5 rows, got: $wide"
narrow=$(SB_BUDDY_COLS=60 render)
[ "$(printf '%s\n' "$narrow" | wc -l | tr -d ' ')" -le 2 ] || fail "narrow layout must collapse"
printf '%s' "$narrow" | grep -q '╭' && fail "narrow layout must not draw the bubble"
viaCols=$(payload | COLUMNS=120 NO_COLOR=1 bash "$R")
[ "$viaCols" = "$wide" ] || fail "COLUMNS (what Claude Code exports) must drive the width like SB_BUDDY_COLS"
pass "renderer: goal/phase/ctx/model/event present; rows fit at 60/80/120; COLUMNS honoured; narrow collapses"

# --- 3. event text is data: no globbing, no execution; session gate beats newer global ------
jq -c '.ts = (.ts - 61)' "$BRAIN_DIR/.buddy/$SID.json" > "$BRAIN_DIR/.buddy/x" && mv "$BRAIN_DIR/.buddy/x" "$BRAIN_DIR/.buddy/$SID.json"   # release the gate hold
sb_buddy_event "$SID" read focused 'fixed *.sh and [a-z]* handling; $(touch PWNED) `id`' t
out=$(cd "$ROOT" && SB_BUDDY_COLS=120 render)
printf '%s' "$out" | grep -q 'fixed \*\.sh and \[a-z\]\*' || fail "event text was globbed or mangled: $out"
[ -e "$ROOT/PWNED" ] && { rm -f "$ROOT/PWNED"; fail "event text was executed"; }
grep -q '^set -f' "$R" || fail "renderer must set -f (event lines are transcript-derived)"
sb_buddy_event "$SID" gate alert "Plan gate holds" plan-first-nudge
sleep 1; sb_buddy_event _global read focused "Read [[later]] from memory" mcp
out=$(SB_BUDDY_COLS=120 render); printf '%s' "$out" | grep -q 'Plan gate holds' || fail "a fresh session gate must beat a newer _global read"
jq -c '.ts = (.ts - 61)' "$BRAIN_DIR/.buddy/$SID.json" > "$BRAIN_DIR/.buddy/x" && mv "$BRAIN_DIR/.buddy/x" "$BRAIN_DIR/.buddy/$SID.json"
out=$(SB_BUDDY_COLS=120 render); printf '%s' "$out" | grep -q 'Read \[\[later\]\]' || fail "after the hold, the newest live event (_global) must win"
printf '{"name":' > "$BRAIN_DIR/buddy.json"
out=$(SB_BUDDY_COLS=120 render); printf '%s' "$out" | grep -q 'add buddy statusline' || fail "a torn buddy.json must not blank the goal (per-file parse)"
pass "event text is inert (set -f, no exec); session gate > newer global; hold expiry hands over; torn file tolerated"

# --- 4. TTL, mute, sprite-off, chain-via-env, kill switches ----------------------------------
printf '{"name":"Ziutek","mute":false}' > "$BRAIN_DIR/buddy.json"
jq -c '.ts = 1' "$BRAIN_DIR/.buddy/_global.json" > "$BRAIN_DIR/.buddy/x" && mv "$BRAIN_DIR/.buddy/x" "$BRAIN_DIR/.buddy/_global.json"
SB_BUDDY_COLS=120 render | grep -q 'Read \[\[later\]\]' && fail "expired event (TTL) still rendered"
out=$(payload | SB_BUDDY_CHAIN='echo CHAINED-FIRST' SB_BUDDY_COLS=120 NO_COLOR=1 bash "$R")
[ "$(printf '%s\n' "$out" | head -1)" = "CHAINED-FIRST" ] || fail "chained statusline (env) must be line 1"
printf '%s' "$out" | grep -q 'Ziutek' || fail "configured name not rendered"
printf '{"name":"Ziutek","chain":"echo FROM-FILE"}' > "$BRAIN_DIR/buddy.json"
SB_BUDDY_COLS=120 render | grep -q 'FROM-FILE' && fail "a chain command in buddy.json must NEVER be executed"
out=$(SB_BUDDY_SPRITE=off SB_BUDDY_COLS=120 render); [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || fail "SB_BUDDY_SPRITE=off → telemetry only"
out=$(SB_HOOK_PROFILE=minimal SB_BUDDY_COLS=120 render); [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || fail "minimal profile → telemetry only"
printf '{"name":"Ziutek","mute":true}' > "$BRAIN_DIR/buddy.json"
out=$(SB_BUDDY_COLS=120 render); [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || fail "mute → telemetry only (no bubble at all)"
printf '{"name":"Ziutek"}' > "$BRAIN_DIR/buddy.json"
out=$(payload | SB_BUDDY=off bash "$R"); [ -z "$out" ] || fail "SB_BUDDY=off must print nothing"
rm -f "$BRAIN_DIR/.buddy/$SID.json"
SB_BUDDY=off sb_buddy_event "$SID" gate alert "should not land" t
[ -e "$BRAIN_DIR/.buddy/$SID.json" ] && fail "SB_BUDDY=off must stop the producer"
( SB_HOOK_PROFILE=minimal; source "$ROOT/scripts/lib.sh"; sb_buddy_event "$SID" gate alert "should not land" t )
[ -e "$BRAIN_DIR/.buddy/$SID.json" ] && fail "SB_HOOK_PROFILE=minimal must map to SB_BUDDY=off in lib.sh"
pass "TTL expiry, chain via env only, configured name, sprite off, minimal profile, mute, SB_BUDDY=off"

# --- 5. hot-path discipline ------------------------------------------------------------------
grep -q 'source .*lib.sh' "$R" && fail "renderer must not source lib.sh (hot path)"
grep -Eq '(^|[^a-z])node( |$)' "$R" && fail "renderer must not spawn node (hot path)"
# (-n, not -q: a quiet grep feeds the filters nothing, so this lock could never fire.) The one
# allowed spawn is the bash-3.2 `date +%s` fallback behind the printf '%(%s)T' builtin.
_sp=$(grep -En '(^|[^a-z_])(tput|stty|tr|awk|sed|date) ' "$R" | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -vF 'else now=$(date +%s); fi')
[ -z "$_sp" ] || fail "renderer must not spawn tput/stty/tr/awk/sed/date: $_sp"
jqn=$(grep -v '^\s*#' "$R" | grep -c '| jq \|(jq \|^  jq \|jq -rn')
[ "$jqn" -le 2 ] || fail "renderer should make at most 2 jq calls (found $jqn)"
sb_buddy_event "$SID" read focused "timing" t
t0=$(date +%s%N 2>/dev/null || echo 0)
if [ "$t0" != "0" ] && [[ "$t0" =~ ^[0-9]+$ ]]; then
  for i in 1 2 3 4 5; do SB_BUDDY_COLS=120 render >/dev/null; done
  t1=$(date +%s%N); ms=$(( (t1 - t0) / 5000000 ))
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) echo "  note: ${ms} ms/render on Windows git-bash (no ceiling asserted; fork/jq.exe cost dominates)" ;;
    *) [ "$ms" -le 150 ] || fail "renderer averaged ${ms} ms/run — over the hot-path ceiling (150 ms in CI, ~35 ms typical)"
       echo "  ${ms} ms/render" ;;
  esac
fi
pass "renderer: no lib.sh, no node, no tput/stty/tr/awk/sed, ≤ 2 jq, within the wall-clock ceiling"

# --- 6. identity (no stats): CLI + sprites ----------------------------------------------------
CLI="$ROOT/mcp/dist/tools/buddy-identity-cli.bundle.js"
if command -v node >/dev/null 2>&1 && [ -f "$CLI" ]; then
  out=$(node "$CLI" --user-id 0f7a2d9e-6c1b-4b3e-9a8d-1234567890ab --write 2>&1) || fail "buddy-identity-cli --write failed: $out"
  # Pinned vector: wyhash(Zig v4.2 == Bun.hash) → mulberry32 → uncommon dragon, @ eyes, tophat, default name Tofu.
  printf '%s' "$out" | grep -q '"species":"dragon"'   || fail "identity vector drifted (expected dragon): $out"
  printf '%s' "$out" | grep -q '"rarity":"uncommon"'  || fail "identity vector drifted (expected uncommon): $out"
  printf '%s' "$out" | grep -q '"default_name":"Tofu"' || fail "default name drifted: $out"
  printf '%s' "$out" | grep -q '"stats"' && fail "stats must not be part of the identity (re-scope 2026-09-23)"
  jq -e '.identity.species=="dragon" and .name=="Ziutek"' "$BRAIN_DIR/buddy.json" >/dev/null || fail "--write must merge identity without clobbering name"
  sb_buddy_event "$SID" gate alert "Verify gate fired" t
  out=$(SB_BUDDY_COLS=120 render)
  printf '%s' "$out" | grep -q '\[___\]'  || fail "tophat not rendered on the head row"
  printf '%s' "$out" | grep -q 'vvvv'      || fail "dragon body not rendered"
  printf '%s' "$out" | grep -q 'ò  ó'      || fail "alert mood should override the eyes"
  printf '%s' "$out" | grep -q 'Ziutek ★★' || fail "name row should carry rarity stars"
  rm -f "$BRAIN_DIR/.buddy/$SID.json" "$BRAIN_DIR/.buddy/_global.json"
  out=$(SB_BUDDY_COLS=120 render); printf '%s' "$out" | grep -q '@  @' || fail "focused mood should use the identity eye glyph"
  jq 'del(.name)' "$BRAIN_DIR/buddy.json" > "$BRAIN_DIR/b.tmp" && mv "$BRAIN_DIR/b.tmp" "$BRAIN_DIR/buddy.json"
  out=$(SB_BUDDY_COLS=120 render); printf '%s' "$out" | grep -q 'Tofu ★★' || fail "default_name must be used when no name is set"
  for sp in duck goose blob cat dragon octopus owl penguin turtle snail ghost axolotl capybara cactus robot rabbit mushroom chonk; do
    for hat in none crown wizard; do
      jq -c --arg s "$sp" --arg h "$hat" '.identity.species=$s | .identity.hat=$h' "$BRAIN_DIR/buddy.json" > "$BRAIN_DIR/b.tmp" && mv "$BRAIN_DIR/b.tmp" "$BRAIN_DIR/buddy.json"
      for cols in 90 120; do
        out=$(SB_BUDDY_COLS=$cols render) || fail "renderer failed for $sp/$hat at $cols"
        while IFS= read -r row; do
          w=$(printf '%s' "$row" | wc -m | tr -d ' ')
          [ "$WIDTH_OK" = "0" ] || [ "$w" -le "$(( cols - 14 + 2 ))" ] || fail "$sp/$hat row exceeds width at $cols cols ($w): $row"
        done <<< "$out"
      done
    done
  done
  out=$(node "$CLI" --rehatch 2>&1) || fail "fallback hatch failed: $out"   # HOME/USERPROFILE/CLAUDE_CONFIG_DIR are all sandboxed above
  printf '%s' "$out" | grep -q '"seed_source":"fallback"' || fail "expected fallback seed_source: $out"
  out=$(node "$ROOT/mcp/dist/cli/sb-entry.bundle.js" buddy 2>&1) || fail "sb buddy failed: $out"
  printf '%s' "$out" | grep -q '★' || fail "sb buddy card missing: $out"
  printf '%s' "$out" | grep -q 'DEBUGGING' && fail "sb buddy must not print a stat sheet"
  pass "identity: pinned vector (no stats), merge-write, hat/eyes/stars/mood, 18 species × hats fit, fallback seed, sb buddy"
else
  echo "SKIP: node or buddy-identity-cli bundle absent — identity subtests skipped"
fi

# --- 7. producers are wired ------------------------------------------------------------------
for s in plan-first-nudge persona-tool-guard stop-verify-gate session-load dream-autostage stop-extract persona-context flow-guard; do
  grep -q 'sb_buddy_event' "$ROOT/scripts/$s.sh" || fail "$s.sh no longer emits a buddy event"
done
grep -q 'buddyNote' "$ROOT/mcp/src/server.ts" || fail "server.ts no longer emits memory read/write events (buddyNote)"
grep -q '\.buddy' "$ROOT/scripts/ensure-dirs.sh" || fail "ensure-dirs.sh no longer GCs .buddy/"
grep -q 'buddy-identity-cli' "$ROOT/scripts/session-load.sh" && fail "session-load must not hatch (node in a hook for an opt-in feature) — hatch lives in sb buddy"
pass "producers wired: 8 hooks + MCP server; GC in ensure-dirs; no node in SessionStart"

# --- 8. the memory nudge: once per session, only deep in implement with nothing saved ----------
export KNOWLEDGE_DIR="$HOME/knowledge"; mkdir -p "$KNOWLEDGE_DIR/wiki"
NS="sess-nudge-1"
printf '{"goal":"implement the buddy nudge","goal_kw":"buddy nudge","prompts":8}' > "$BRAIN_DIR/.injected/$NS.json"
printf 'implement' > "$BRAIN_DIR/.injected/$NS.phase"
pc(){ printf '{"session_id":"%s","prompt":"now implement the next step of the buddy nudge please"}' "$1" | CLAUDE_PLUGIN_ROOT="$ROOT" timeout 60 bash "$ROOT/scripts/persona-context.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""'; }
out=$(pc "$NS"); printf '%s' "$out" | grep -q '^\[buddy\] 8 prompts' || fail "memory nudge did not fire at the threshold: $out"
[ "$(printf '%s' "$out" | grep -c '^\[buddy\]')" = "1" ] || fail "nudge must be exactly one line"
jq -e '.buddy_nudge=="1" and .prompts==9' "$BRAIN_DIR/.injected/$NS.json" >/dev/null || fail "memo must record the nudge and count prompts"
jq -e '.kind=="pending"' "$BRAIN_DIR/.buddy/$NS.json" >/dev/null || fail "nudge must also surface on the statusline as pending"
out=$(pc "$NS"); printf '%s' "$out" | grep -q '^\[buddy\]' && fail "nudge fired twice in one session"
NS2="sess-nudge-2"
printf '{"goal":"g","goal_kw":"g","prompts":9}' > "$BRAIN_DIR/.injected/$NS2.json"; printf 'implement' > "$BRAIN_DIR/.injected/$NS2.phase"
sleep 1; sb_buddy_event _global remembered pleased "Pinned to PROJECT.md decisions: x" mcp:pin_to_project
out=$(pc "$NS2"); printf '%s' "$out" | grep -q '^\[buddy\]' && fail "nudge fired although a save was recorded this session"
NS3="sess-nudge-3"
printf '{"goal":"g","goal_kw":"g","prompts":9}' > "$BRAIN_DIR/.injected/$NS3.json"; printf 'plan' > "$BRAIN_DIR/.injected/$NS3.phase"
rm -f "$BRAIN_DIR/.buddy/_global.log.jsonl"
out=$(pc "$NS3"); printf '%s' "$out" | grep -q '^\[buddy\]' && fail "nudge must not fire outside the implement phase"
# A save EARLIER in the session counts: "since" is the memo's t0, not its mtime (rewritten every
# prompt, so mtime meant "since the last prompt" and a prompt-3 save still nudged at prompt 8).
NS4="sess-nudge-4"; _n=$(date +%s)
printf '{"goal":"g","goal_kw":"g","prompts":9,"t0":%s}' $((_n - 300)) > "$BRAIN_DIR/.injected/$NS4.json"; printf 'implement' > "$BRAIN_DIR/.injected/$NS4.phase"
printf '{"ts":%s,"kind":"remembered","mood":"pleased","line":"Pinned to PROJECT.md decisions: y","source":"mcp:pin_to_project","ttl_s":900}\n' $((_n - 200)) >> "$BRAIN_DIR/.buddy/_global.log.jsonl"
out=$(pc "$NS4"); printf '%s' "$out" | grep -q '^\[buddy\]' && fail "nudge fired although a save landed earlier this session (since = memo mtime, not t0)"
# A quiet turn (everything deduped, only the frozen goal line) must still carry the nudge: the memo
# records buddy_nudge=1 either way, so dropping it there spends the once-per-session nudge unseen.
rm -f "$BRAIN_DIR/.buddy/_global.log.jsonl"
NS5="sess-nudge-5"; printf 'implement' > "$BRAIN_DIR/.injected/$NS5.phase"
printf '{"goal":"implement the buddy nudge","goal_kw":"buddy nudge","prompts":5}' > "$BRAIN_DIR/.injected/$NS5.json"
pc "$NS5" >/dev/null; pc "$NS5" >/dev/null   # second identical turn: everything deduped
jq -c '.prompts=8' "$BRAIN_DIR/.injected/$NS5.json" > "$BRAIN_DIR/.nq" && mv "$BRAIN_DIR/.nq" "$BRAIN_DIR/.injected/$NS5.json"
out=$(pc "$NS5"); printf '%s' "$out" | grep -q '^\[buddy\] 8 prompts' || fail "nudge recorded but not shown on a quiet turn: $out"
pass "memory nudge: fires once at the threshold in implement, mirrored as pending, silent after a save or in plan"

echo; echo "ALL PASS"
