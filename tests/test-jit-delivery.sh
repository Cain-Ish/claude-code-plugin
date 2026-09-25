#!/bin/bash
# tests/test-jit-delivery.sh — Slice 2 (repo-brain) path-triggered repo memory.
# pins: SB_JIT — kill-switch test: asserts =off suppresses delivery + the Stop rebuild
# pins: SB_JIT_MAX_ITEMS — cap test: asserts the per-delivery item cap
# pins: SB_EXTRACT — set =off on the stop-rebuild subtest calls: this file only exercises the
#   new JIT freshness-rebuild block, not stop-extract.sh's LLM extraction path (which the
#   test's fixture transcript has no tool_use for anyway; =off just skips it deterministically)
# Exercises the whole class (b)(c)(d)(f)(g) delivery path: the jit-index-cli.bundle.js
# builder against a real git fixture repo, protocol-guard.sh's pg_jit at the PreToolUse hot
# path (delivery, once-per-session+item, Windows path form, jq spawn budget), and
# stop-extract.sh's freshness rebuild. Sandboxed HOME/BRAIN_DIR/KNOWLEDGE_DIR throughout
# (this file mentions stop-extract.sh, so test-real-kb-isolation.sh requires the sandbox).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PG="$REPO/scripts/protocol-guard.sh"
SE="$REPO/scripts/stop-extract.sh"
CLI_BUNDLE="$REPO/mcp/dist/tools/jit-index-cli.bundle.js"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export BRAIN_DIR="$TMP/brain"; mkdir -p "$BRAIN_DIR/.injected"
export KNOWLEDGE_DIR="$TMP/knowledge"; mkdir -p "$KNOWLEDGE_DIR/wiki"

# =============================================================================
# 1. Builder/CLI — end-to-end against a real git-fixture repo.
# =============================================================================
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node unavailable — builder/CLI subtest skipped"
elif [ ! -f "$CLI_BUNDLE" ]; then
  echo "SKIP: $CLI_BUNDLE not built — run 'npm run bundle' in mcp/ first"
else
  REPO_FIX="$TMP/fixture-repo"
  mkdir -p "$REPO_FIX/scripts" "$REPO_FIX/mcp/src/tools"
  echo 'x' > "$REPO_FIX/scripts/lib.sh"
  echo 'y' > "$REPO_FIX/mcp/src/tools/a.ts"
  git -C "$REPO_FIX" init -q
  git -C "$REPO_FIX" add -A
  git -C "$REPO_FIX" -c user.email=a@b.co -c user.name=t commit -qm fixture

  mkdir -p "$BRAIN_DIR/projects/demo" "$KNOWLEDGE_DIR/wiki/issues" "$KNOWLEDGE_DIR/wiki/learnings"
  cat > "$BRAIN_DIR/projects/demo/PROJECT.md" <<'EOF'
# PROJECT: demo
## Conventions
EOF
  cat > "$KNOWLEDGE_DIR/wiki/issues/crlf-bug.md" <<'EOF'
---
title: crlf bug
description: x
type: issues
created: 2026-01-01
updated: 2026-01-01
tags: []
related: []
project: demo
---
<!-- ai:begin (authored) -->
symptom: CRLF breaks scripts/lib.sh readers
fix: tr -d r after jq
status: open
<!-- ai:end -->
EOF
  cat > "$KNOWLEDGE_DIR/wiki/learnings/brain-paths.md" <<'EOF'
---
title: brain paths
description: x
type: learnings
created: 2026-01-01
updated: 2026-01-01
tags: []
related: []
project: demo
---
<!-- ai:begin (authored) -->
claim: mcp/src/tools/ CLIs must use brain-paths
action: import resolveBrainDir
<!-- ai:end -->
EOF
  cat > "$KNOWLEDGE_DIR/wiki/learnings/no-repo-path.md" <<'EOF'
---
title: no repo path
description: x
type: learnings
created: 2026-01-01
updated: 2026-01-01
tags: []
related: []
project: demo
---
<!-- ai:begin (authored) -->
claim: only docs/nope.md is named here
action: nothing in the repo
<!-- ai:end -->
EOF

  node "$CLI_BUNDLE" demo "$REPO_FIX"
  RC=$?
  [ "$RC" -eq 0 ] || fail "CLI exited $RC against a real git fixture repo"
  IDX="$BRAIN_DIR/projects/demo/jit-index.json"
  [ -s "$IDX" ] || fail "CLI did not write jit-index.json"
  jq -e '.schema == 1' "$IDX" >/dev/null 2>&1 || fail "jit-index.json .schema != 1"
  N=$(jq '.items | length' "$IDX" 2>/dev/null)
  [ "${N:-0}" -ge 2 ] || fail "expected >=2 items, got $N"
  jq -e '.items[] | select(.id=="crlf-bug") | .globs == ["scripts/lib.sh"]' "$IDX" >/dev/null 2>&1 \
    || fail "crlf-bug item's globs are not exactly [scripts/lib.sh]"
  jq -e '.items[] | select(.id=="brain-paths") | .globs == ["mcp/src/tools/*"]' "$IDX" >/dev/null 2>&1 \
    || fail "brain-paths item's globs are not exactly [mcp/src/tools/*]"
  jq -e '[.items[].id] | index("no-repo-path") | not' "$IDX" >/dev/null 2>&1 \
    || fail "a page naming only a non-repo path (docs/nope.md) was not dropped"
  pass "builder/CLI: real git fixture -> jit-index.json with correct globs, non-repo-path page dropped"

  # non-git repoRoot
  NOGIT="$TMP/nogit-dir"; mkdir -p "$NOGIT"
  rm -f "$IDX"
  node "$CLI_BUNDLE" demo "$NOGIT"; RC2=$?
  [ "$RC2" -eq 0 ] || fail "CLI exited $RC2 for a non-git repoRoot"
  jq -e '.git_rev == "nogit"' "$IDX" >/dev/null 2>&1 || fail "non-git repoRoot: .git_rev != nogit"
  jq -e '.items == []' "$IDX" >/dev/null 2>&1 || fail "non-git repoRoot: .items != []"
  pass "builder/CLI: non-git repoRoot exits 0, git_rev=nogit, items=[]"
fi

# =============================================================================
# 2. Delivery via protocol-guard.sh pre mode — fixture jit-index.json, no CLI/node needed.
# =============================================================================
DBRAIN="$TMP/dbrain"; mkdir -p "$DBRAIN/.injected" "$DBRAIN/projects/demo"
DREPO="$TMP/drepo"; mkdir -p "$DREPO/scripts" "$DREPO/mcp/src/tools" "$DREPO/tests"
printf 'demo' > "$DBRAIN/.injected/s1.slug"     # NOTE: no trailing newline — matches production
cat > "$DBRAIN/projects/demo/jit-index.json" <<'EOF'
{"schema":1,"slug":"demo","generated_at":"2026-01-01T00:00:00Z","git_rev":"abc",
 "items":[
   {"id":"p1","kind":"lesson","globs":["scripts/lib.sh"],"line":"CRLF breaks scripts/lib.sh readers -> tr -d r after jq"},
   {"id":"p2","kind":"lesson","globs":["mcp/src/tools/*"],"line":"CLIs must use brain-paths"},
   {"id":"conv:1","kind":"convention","globs":["tests/*"],"line":"Tests under tests/ declare # pins:"}
 ]}
EOF

pg_pre() {  # $1 = JSON payload
  printf '%s' "$1" | BRAIN_DIR="$DBRAIN" HOME="$HOME" CLAUDE_PROJECT_DIR="$DREPO" bash "$PG" pre
}

READ_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"s1","cwd":"'"$DREPO"'","tool_input":{"file_path":"'"$DREPO"'/scripts/lib.sh"}}'
OUT=$(pg_pre "$READ_PAYLOAD")
printf '%s' "$OUT" | grep -qF 'Repo memory for scripts/lib.sh' || fail "delivery: missing 'Repo memory for scripts/lib.sh' (got: $OUT)"
printf '%s' "$OUT" | grep -qF '[[p1]]' || fail "delivery: missing [[p1]] wiki-id marker"
printf '%s' "$OUT" | grep -qF 'knowledge_fetch' || fail "delivery: missing knowledge_fetch pointer"
printf '%s' "$OUT" | grep -qF 'untrusted reference' || fail "delivery: missing untrusted-reference DATA banner open"
printf '%s' "$OUT" | grep -qF 'End untrusted reference' || fail "delivery: missing untrusted-reference DATA banner close"
grep -qF '{"kind":"jit","id":"p1"}' "$DBRAIN/.injected-manifest-s1.jsonl" 2>/dev/null \
  || fail "delivery: manifest missing {\"kind\":\"jit\",\"id\":\"p1\"}"
grep -qE 'gate=jit tool=Read path=scripts/lib\.sh items=1 ids=p1 .*sid=s1' "$DBRAIN/audit-log.jsonl" 2>/dev/null \
  || fail "delivery: audit-log row shape wrong (got: $(cat "$DBRAIN/audit-log.jsonl" 2>/dev/null))"
grep -qF 'p1' "$DBRAIN/.injected/s1.jit.seen" 2>/dev/null || fail "delivery: .jit.seen missing p1"
pass "delivery: PreToolUse Read delivers the DATA-banner block, manifest, audit row, seen-marker"

# once per session+item: same Read again -> no output, no new audit row.
AUDIT_BEFORE=$(wc -l < "$DBRAIN/audit-log.jsonl" 2>/dev/null || echo 0)
OUT2=$(pg_pre "$READ_PAYLOAD")
[ -z "$OUT2" ] || fail "repeat Read of the same path delivered again (got: $OUT2)"
AUDIT_AFTER=$(wc -l < "$DBRAIN/audit-log.jsonl" 2>/dev/null || echo 0)
[ "$AUDIT_BEFORE" = "$AUDIT_AFTER" ] || fail "repeat Read wrote a new audit-log row"
pass "once per session+item: a repeat Read of the same path is silent, no new row"

# Edit of a different matching path -> delivers p2 only.
EDIT_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Edit","session_id":"s1","cwd":"'"$DREPO"'","tool_input":{"file_path":"'"$DREPO"'/mcp/src/tools/x.ts"}}'
OUT3=$(pg_pre "$EDIT_PAYLOAD")
printf '%s' "$OUT3" | grep -qF '[[p2]]' || fail "Edit of mcp/src/tools/x.ts did not deliver [[p2]] (got: $OUT3)"
printf '%s' "$OUT3" | grep -qF '[[p1]]' && fail "Edit of mcp/src/tools/x.ts unexpectedly also delivered [[p1]]"
pass "Edit of a different matching path delivers p2 only"

# Write of a new path matching the convention -> delivers the convention line, no [[ ]], no manifest entry.
WRITE_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"'"$DREPO"'","tool_input":{"file_path":"'"$DREPO"'/tests/new.sh"}}'
OUT4=$(pg_pre "$WRITE_PAYLOAD")
printf '%s' "$OUT4" | grep -qF 'Tests under tests/ declare # pins:' || fail "Write of tests/new.sh did not deliver the convention line (got: $OUT4)"
printf '%s' "$OUT4" | grep -qF '[[' && fail "a convention delivery must never carry a [[ ]] wiki-id marker (got: $OUT4)"
grep -qF 'conv:1' "$DBRAIN/.injected-manifest-s1.jsonl" 2>/dev/null \
  && fail "a convention id (conv:1) must never reach the manifest"
pass "Write of a new path delivers the convention line (no [[ ]]), manifest gains no conv: entry"

# Windows path form: backslash file_path + backslash cwd, no CLAUDE_PROJECT_DIR.
WIN_CWD='C:\winrepo'
WIN_FP='C:\winrepo\scripts\lib.sh'
WBRAIN="$TMP/wbrain"; mkdir -p "$WBRAIN/.injected" "$WBRAIN/projects/demo"
printf 'demo' > "$WBRAIN/.injected/s1.slug"
cat > "$WBRAIN/projects/demo/jit-index.json" <<'EOF'
{"schema":1,"slug":"demo","generated_at":"2026-01-01T00:00:00Z","git_rev":"abc",
 "items":[{"id":"p1","kind":"lesson","globs":["scripts/lib.sh"],"line":"CRLF breaks scripts/lib.sh readers"}]}
EOF
WIN_PAYLOAD=$(jq -nc --arg cwd "$WIN_CWD" --arg fp "$WIN_FP" \
  '{hook_event_name:"PreToolUse",tool_name:"Read",session_id:"s1",cwd:$cwd,tool_input:{file_path:$fp}}')
OUTW=$(printf '%s' "$WIN_PAYLOAD" | BRAIN_DIR="$WBRAIN" HOME="$HOME" bash "$PG" pre)
printf '%s' "$OUTW" | grep -qF 'Repo memory for scripts/lib.sh' \
  || fail "Windows path form did not resolve to rel=scripts/lib.sh (got: $OUTW)"
pass "Windows path form (backslash file_path + cwd, no CLAUDE_PROJECT_DIR) delivers the same as POSIX"

# SB_JIT_MAX_ITEMS caps items per delivery (default 3; garbage falls back to 3).
CBRAIN="$TMP/cbrain"; mkdir -p "$CBRAIN/.injected" "$CBRAIN/projects/demo"
CREPO="$TMP/crepo"; mkdir -p "$CREPO/scripts"
printf 'demo' > "$CBRAIN/.injected/s1.slug"
cat > "$CBRAIN/projects/demo/jit-index.json" <<'EOF'
{"schema":1,"slug":"demo","generated_at":"2026-01-01T00:00:00Z","git_rev":"abc",
 "items":[
   {"id":"c1","kind":"lesson","globs":["scripts/lib.sh"],"line":"one"},
   {"id":"c2","kind":"lesson","globs":["scripts/lib.sh"],"line":"two"},
   {"id":"c3","kind":"lesson","globs":["scripts/lib.sh"],"line":"three"},
   {"id":"c4","kind":"lesson","globs":["scripts/lib.sh"],"line":"four"}
 ]}
EOF
CPAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"s1","cwd":"'"$CREPO"'","tool_input":{"file_path":"'"$CREPO"'/scripts/lib.sh"}}'
OUTC=$(printf '%s' "$CPAYLOAD" | BRAIN_DIR="$CBRAIN" HOME="$HOME" CLAUDE_PROJECT_DIR="$CREPO" bash "$PG" pre)
CCOUNT=$(printf '%s' "$OUTC" | grep -o '\[\[c[0-9]*\]\]' | wc -l | tr -d ' ')
[ "$CCOUNT" = "3" ] || fail "default SB_JIT_MAX_ITEMS should deliver 3 items, got $CCOUNT (out: $OUTC)"
pass "SB_JIT_MAX_ITEMS default caps a delivery at 3 items"

rm -f "$CBRAIN/.injected/s1.jit.tsv" "$CBRAIN/.injected/s1.jit.seen"
OUTC2=$(printf '%s' "$CPAYLOAD" | SB_JIT_MAX_ITEMS=1 BRAIN_DIR="$CBRAIN" HOME="$HOME" CLAUDE_PROJECT_DIR="$CREPO" bash "$PG" pre)
CCOUNT2=$(printf '%s' "$OUTC2" | grep -o '\[\[c[0-9]*\]\]' | wc -l | tr -d ' ')
[ "$CCOUNT2" = "1" ] || fail "SB_JIT_MAX_ITEMS=1 should deliver exactly 1 item, got $CCOUNT2 (out: $OUTC2)"
pass "SB_JIT_MAX_ITEMS=1 caps a delivery at 1 item"

# =============================================================================
# 3. Spawn budget: a jq PATH shim counts invocations.
# =============================================================================
SBRAIN="$TMP/sbrain"; mkdir -p "$SBRAIN/.injected" "$SBRAIN/projects/demo"
SREPO="$TMP/srepo"; mkdir -p "$SREPO/scripts" "$SREPO/other"
printf 'demo' > "$SBRAIN/.injected/s1.slug"
cat > "$SBRAIN/projects/demo/jit-index.json" <<'EOF'
{"schema":1,"slug":"demo","generated_at":"2026-01-01T00:00:00Z","git_rev":"abc",
 "items":[{"id":"p1","kind":"lesson","globs":["scripts/lib.sh"],"line":"CRLF breaks scripts/lib.sh readers"}]}
EOF
REALJQ=$(command -v jq) || fail "jq not on PATH — cannot build the counting shim"
SHIMDIR="$TMP/shim"; mkdir -p "$SHIMDIR"
JQCALLS="$TMP/jqcalls.log"; : > "$JQCALLS"
cat > "$SHIMDIR/jq" <<EOF
#!/bin/bash
printf 'x\n' >> "$JQCALLS"
exec "$REALJQ" "\$@"
EOF
chmod +x "$SHIMDIR/jq"

NOMATCH_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"s1","cwd":"'"$SREPO"'","tool_input":{"file_path":"'"$SREPO"'/other/unrelated.txt"}}'

: > "$JQCALLS"
OUT5=$(printf '%s' "$NOMATCH_PAYLOAD" | PATH="$SHIMDIR:$PATH" BRAIN_DIR="$SBRAIN" HOME="$HOME" CLAUDE_PROJECT_DIR="$SREPO" bash "$PG" pre)
[ -z "$OUT5" ] || fail "spawn budget: a no-match Read unexpectedly delivered (got: $OUT5)"
FIRST_CALLS=$(wc -l < "$JQCALLS" | tr -d ' ')
[ "$FIRST_CALLS" = "2" ] || fail "spawn budget: first call of the session (cache absent) should log 2 jq calls, got $FIRST_CALLS"
pass "spawn budget: first no-match call of a session = 2 jq calls (field read + cache build)"

: > "$JQCALLS"
OUT6=$(printf '%s' "$NOMATCH_PAYLOAD" | PATH="$SHIMDIR:$PATH" BRAIN_DIR="$SBRAIN" HOME="$HOME" CLAUDE_PROJECT_DIR="$SREPO" bash "$PG" pre)
[ -z "$OUT6" ] || fail "spawn budget: a no-match Read unexpectedly delivered on the second call (got: $OUT6)"
SECOND_CALLS=$(wc -l < "$JQCALLS" | tr -d ' ')
[ "$SECOND_CALLS" = "1" ] || fail "spawn budget: a no-match Read once the .jit.tsv cache exists should log exactly 1 jq call, got $SECOND_CALLS"
pass "spawn budget: a no-match Read with the cache already built logs exactly 1 jq call"

: > "$JQCALLS"
OUT7=$(printf '%s' "$READ_PAYLOAD" | PATH="$SHIMDIR:$PATH" BRAIN_DIR="$DBRAIN" HOME="$HOME" SB_JIT=off CLAUDE_PROJECT_DIR="$DREPO" bash "$PG" pre)
[ -z "$OUT7" ] || fail "SB_JIT=off unexpectedly delivered (got: $OUT7)"
OFF_CALLS=$(wc -l < "$JQCALLS" | tr -d ' ')
[ "$OFF_CALLS" = "1" ] || fail "SB_JIT=off should log exactly 1 jq call (the field read), got $OFF_CALLS"
pass "SB_JIT=off: exactly 1 jq call (the field read), no output"

# =============================================================================
# 4. Stop rebuild — a stub node records its argv.
# =============================================================================
RBRAIN="$TMP/rbrain"; mkdir -p "$RBRAIN/.injected" "$RBRAIN/projects/demo"
RREPO="$TMP/rrepo"; mkdir -p "$RREPO"
RKNOW="$TMP/rknowledge"; mkdir -p "$RKNOW/wiki/issues"
# NOTE: WITH a trailing newline here (unlike the pg_jit fixtures above), working around a
# pre-existing bug in lib.sh's sb_session_slug (scaffold-owned, outside Slice 2's files):
# `IFS= read -r s < "$f" || s=""` clobbers a successfully-read value whenever the memo has NO
# trailing newline (read returns 1 on EOF-without-delimiter even though it populated $s) —
# exactly how session-load.sh actually WRITES the memo (`printf '%s'`, no \n). Flagged as a
# deviation in the slice report; fixing it is out of scope (not an S2-owned file).
printf 'demo\n' > "$RBRAIN/.injected/S9.slug"
cat > "$RBRAIN/projects/demo/PROJECT.md" <<'EOF'
# PROJECT: demo
## Goal
x
EOF
: > "$RBRAIN/projects/demo/jit-index.json"   # present but STALE (older than the wiki page below)
touch -t 202001010000 "$RBRAIN/projects/demo/jit-index.json"
cat > "$RKNOW/wiki/issues/newer-page.md" <<'EOF'
---
title: x
description: x
type: issues
created: 2026-01-01
updated: 2026-01-01
tags: []
related: []
project: demo
---
body
EOF

NODEDIR="$TMP/nodebin"; mkdir -p "$NODEDIR"
NODEARGV="$TMP/node-argv.log"
cat > "$NODEDIR/node" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$NODEARGV"
exit 0
EOF
chmod +x "$NODEDIR/node"
mkdir -p "$REPO/mcp/dist/tools"   # ensure the CLI path exists so stop-extract.sh's -f check passes
[ -f "$CLI_BUNDLE" ] || : > "$CLI_BUNDLE"

TRANSCRIPT="$TMP/transcript.jsonl"
printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$TRANSCRIPT"
STOP_PAYLOAD=$(jq -nc --arg t "$TRANSCRIPT" --arg c "$RREPO" '{transcript_path:$t,cwd:$c,session_id:"S9"}')

: > "$NODEARGV"
printf '%s' "$STOP_PAYLOAD" \
  | PATH="$NODEDIR:$PATH" BRAIN_DIR="$RBRAIN" HOME="$HOME" KNOWLEDGE_DIR="$RKNOW" CLAUDE_PROJECT_DIR="$RREPO" \
    SB_EXTRACT=off bash "$SE" >/dev/null 2>&1
grep -qF "jit-index-cli.bundle.js demo $RREPO" "$NODEARGV" 2>/dev/null \
  || fail "stale jit-index (wiki page newer) did not invoke jit-index-cli.bundle.js demo $RREPO (argv: $(cat "$NODEARGV" 2>/dev/null))"
pass "stop rebuild: a stale jit-index (page newer) invokes jit-index-cli.bundle.js"

: > "$NODEARGV"
printf '%s' "$STOP_PAYLOAD" \
  | PATH="$NODEDIR:$PATH" BRAIN_DIR="$RBRAIN" HOME="$HOME" KNOWLEDGE_DIR="$RKNOW" CLAUDE_PROJECT_DIR="$RREPO" \
    SB_EXTRACT=off SB_JIT=off bash "$SE" >/dev/null 2>&1
[ -s "$NODEARGV" ] && fail "SB_JIT=off must not invoke the rebuild (argv: $(cat "$NODEARGV" 2>/dev/null))"
pass "stop rebuild: SB_JIT=off does not invoke jit-index-cli.bundle.js"

# fresh index (newer than every page and PROJECT.md) -> not rebuilt.
touch "$RBRAIN/projects/demo/jit-index.json"
: > "$NODEARGV"
printf '%s' "$STOP_PAYLOAD" \
  | PATH="$NODEDIR:$PATH" BRAIN_DIR="$RBRAIN" HOME="$HOME" KNOWLEDGE_DIR="$RKNOW" CLAUDE_PROJECT_DIR="$RREPO" \
    SB_EXTRACT=off bash "$SE" >/dev/null 2>&1
[ -s "$NODEARGV" ] && fail "a fresh jit-index was rebuilt unnecessarily (argv: $(cat "$NODEARGV" 2>/dev/null))"
pass "stop rebuild: a fresh jit-index (newer than pages + PROJECT.md) is not rebuilt"

# =============================================================================
# 5. Value-loop lock (documentation-only — Slice 0's wiki_hit already counts every
#    non-anchor manifest kind, so a "jit" kind needs no special-casing anywhere).
# =============================================================================
grep -qE '\.kind\s*==\s*"jit"' "$SE" \
  && fail "stop-extract.sh must not special-case kind==\"jit\" — the generic kind!=\"anchor\" fold already counts it"
pass "value-loop lock: stop-extract.sh counts jit ids the same as every other non-anchor manifest kind"

echo; echo "ALL PASS"
