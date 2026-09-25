#!/bin/bash
# pins: SB_RULES_LAYERS — the layering feature's own kill switch; the whole point of this file
# pins: SB_SEARCH_FIRST — pg_search's kill switch, exercised directly
# pins: SB_REPO_KEY_COMMON_DIR — sb_repo_key's kill switch, exercised directly
# pins: SB_RESOURCE_SCOPE — off, so the resource-scope guard never asks first and masks the
#   rules-layer verdict being asserted (same idiom test-persona-tool-guard.sh already uses)
# pins: SB_PROTOCOL_GUARD — set =off is asserted as a no-op guard elsewhere; not toggled here,
#   listed because protocol-guard.sh is driven directly
#
# Slice 3 (docs/plans/2026-09-24-repo-brain.md) — layered plugin/user/repo rules, the learning
# loop closing per repo, search-before-create, and one brain per git-worktree family.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
GUARD="$ROOT/scripts/persona-tool-guard.sh"
PGUARD="$ROOT/scripts/protocol-guard.sh"
MERGESIG="$ROOT/scripts/merge-persona-signals.sh"

fail_n=0
fail() { echo "FAIL: $1"; fail_n=$((fail_n + 1)); }
pass() { echo "PASS: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A PATH-shim jq that counts every invocation (real work still happens via $REAL_JQ) — used to
# prove "zero jq spawns from sb_rules_effective on an unchanged, cache-warm second call".
SHIMDIR="$TMP/shim"; mkdir -p "$SHIMDIR"
REAL_JQ=$(command -v jq)
cat > "$SHIMDIR/jq" <<SHIM
#!/bin/bash
echo 1 >> "\$JQ_COUNT_FILE"
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$SHIMDIR/jq"
jq_count() { # <count-file> <cmd...>  -> prints the spawn count for that one invocation
  local cf="$1"; shift
  : > "$cf"
  JQ_COUNT_FILE="$cf" PATH="$SHIMDIR:$PATH" "$@" >/dev/null 2>&1
  wc -l < "$cf" | tr -d ' '
}

# --------------------------------------------------------------------------
# 1. Layering: P (real defaults) + U (loosen-attempt + a repo-only rule) + R
#    (deny override + disable-attempt on a locked default).
# --------------------------------------------------------------------------
B1="$TMP/b1"; mkdir -p "$B1/projects/demo" "$B1/.injected"
printf 'demo' > "$B1/.injected/s1.slug"
cat > "$B1/persona-rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"warn-rm-rf","action":"warn"},{"name":"repo-only","tool":"Bash","match_command":"make deploy","action":"warn","reason":"u"}]}
EOF
cat > "$B1/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"repo-only","action":"deny","reason":"r"},{"name":"warn-force-push-main","enabled":false}]}
EOF
run1() { printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"%s"}}' "$B1" "$1" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B1" bash "$GUARD"; }

out=$(run1 "make deploy")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "layering: make deploy should deny (repo-only overrides U's warn) — got: $out"
out=$(run1 "rm -rf /tmp/x")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "layering: rm -rf should ask (warn-rm-rf stays locked at ask) — got: $out"

EFF1="$B1/projects/demo/.rules-effective.json"
[ -s "$EFF1" ] || fail "layering: no .rules-effective.json cache was written"
jq -e '.violations|length == 2' "$EFF1" >/dev/null \
  || fail "layering: expected exactly 2 violations, got: $(jq -c '.violations' "$EFF1" 2>/dev/null)"
jq -e '.rules[]|select(.name=="warn-force-push-main")|.name=="warn-force-push-main"' "$EFF1" >/dev/null \
  || fail "layering: warn-force-push-main (locked) should still be present (disable rejected)"
[ "$(grep -c '"rule":"rules-lock-violation"' "$B1/audit-log.jsonl" 2>/dev/null)" = "2" ] \
  || fail "layering: expected 2 rules-lock-violation flag rows in audit-log"
grep -q 'gate=rules-effective.*violations=2' "$B1/audit-log.jsonl" \
  || fail "layering: expected one gate=rules-effective row with violations=2"
pass "layering: P+U+R merge, lock enforcement, violations logged, correct verdicts"

# --------------------------------------------------------------------------
# 2. Repo lock ignored: R cannot set lock, even on a brand-new rule name.
# --------------------------------------------------------------------------
B2="$TMP/b2"; mkdir -p "$B2/projects/demo" "$B2/.injected"
printf 'demo' > "$B2/.injected/s1.slug"
cat > "$B2/persona-rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"x","enabled":false}]}
EOF
cat > "$B2/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"x","tool":"Bash","match_command":"foo","action":"warn","lock":true}]}
EOF
run1_b2() { printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"echo hi"}}' "$B2" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B2" bash "$GUARD" >/dev/null 2>&1; }
run1_b2   # trigger a rebuild/read so the cache exists
EFF2="$B2/projects/demo/.rules-effective.json"
jq -e '(.rules|map(select(.name=="x"))|length) == 0' "$EFF2" >/dev/null \
  || fail "repo lock ignored: effective set should have no rule 'x' (repo cannot set lock)"
grep -q '"rule":"rules-lock-violation".*"reason":"repo attempted lock"' "$B2/audit-log.jsonl" \
  || fail "repo lock ignored: expected a 'repo attempted lock' violation row"
pass "repo lock ignored: a repo-authored lock:true is stripped and logged, not honoured"

# --------------------------------------------------------------------------
# 3. Cache: a warm second call spawns the SAME total jq count as the first warm
#    call (zero additional spawns from sb_rules_effective); touching R rebuilds.
# --------------------------------------------------------------------------
B3="$TMP/b3"; mkdir -p "$B3/projects/demo" "$B3/.injected"
printf 'demo' > "$B3/.injected/s1.slug"
cat > "$B3/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"repo-only3","tool":"Bash","match_command":"make deploy","action":"warn","reason":"r1"}]}
EOF
payload3() { printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"make deploy"}}' "$B3"; }
# prime the cache (first call may rebuild)
payload3 | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3" bash "$GUARD" >/dev/null 2>&1
n_warm1=$(jq_count "$TMP/jc1" bash -c "payload3() { printf '{\"tool_name\":\"Bash\",\"session_id\":\"s1\",\"cwd\":\"$B3\",\"tool_input\":{\"command\":\"make deploy\"}}'; }; payload3 | SB_RESOURCE_SCOPE=off BRAIN_DIR=\"$B3\" bash \"$GUARD\"")
n_warm2=$(jq_count "$TMP/jc2" bash -c "payload3() { printf '{\"tool_name\":\"Bash\",\"session_id\":\"s1\",\"cwd\":\"$B3\",\"tool_input\":{\"command\":\"make deploy\"}}'; }; payload3 | SB_RESOURCE_SCOPE=off BRAIN_DIR=\"$B3\" bash \"$GUARD\"")
[ "$n_warm1" = "$n_warm2" ] || fail "cache: warm-call jq spawn count changed between two unchanged calls ($n_warm1 vs $n_warm2) — sb_rules_effective is re-spawning on a fresh cache"
pass "cache: two consecutive warm calls spawn the identical jq count ($n_warm1)"

sleep 1
cat > "$B3/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"repo-only3","tool":"Bash","match_command":"make deploy","action":"deny","reason":"r2"}]}
EOF
out=$(payload3 | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "cache: touching R and changing the action should rebuild and the new verdict should apply — got: $out"
pass "cache: touching R triggers a rebuild and the new verdict is honoured"

# --------------------------------------------------------------------------
# 4. Broken repo layer: invalid JSON in R never denies — P+U keep working.
#    No usable layer at all -> the existing D154 fail-safe deny.
# --------------------------------------------------------------------------
B4="$TMP/b4"; mkdir -p "$B4/projects/demo" "$B4/.injected"
printf 'demo' > "$B4/.injected/s1.slug"
printf '{not json' > "$B4/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf /tmp/x"}}' "$B4" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B4" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "broken repo layer: verdict should still be ask via P (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision != "deny"' >/dev/null \
  || fail "broken repo layer: a broken layer must never deny"
grep -q 'rules-layer repo unreadable' "$B4/error-log.jsonl" 2>/dev/null \
  || fail "broken repo layer: expected an error-log line naming the repo layer unreadable"
pass "broken repo layer: invalid R is skipped+logged, guard still works from P+U, never denies"

B4b="$TMP/b4b"; mkdir -p "$B4b/.injected"
printf 'nolayers' > "$B4b/.injected/s1.slug"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf /tmp/x"}}' "$B4b" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B4b" CLAUDE_PLUGIN_ROOT="$TMP/no-such-plugin-root" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "no usable layer: should hit the D154 fail-safe deny (got: $out)"
pass "no usable layer at all: falls through to the existing D154 fail-safe deny"

# --------------------------------------------------------------------------
# 5. Kill switch: SB_RULES_LAYERS=off restores today's U/P precedence exactly —
#    R's deny is never consulted, and no cache file is written.
# --------------------------------------------------------------------------
B5="$TMP/b5"; mkdir -p "$B5/projects/demo" "$B5/.injected"
printf 'demo' > "$B5/.injected/s1.slug"
cat > "$B5/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"kswitch","tool":"Bash","match_command":"make deploy","action":"deny","reason":"should never apply"}]}
EOF
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"make deploy"}}' "$B5" \
  | SB_RESOURCE_SCOPE=off SB_RULES_LAYERS=off BRAIN_DIR="$B5" bash "$GUARD")
# No U file exists in this fixture and R's "kswitch" rule is repo-only, so with layering off
# (today's U-then-P precedence, R never consulted) the correct result is SILENCE — a real
# "deny leaked through" bug would show up as a non-empty deny payload, not empty output.
[ -z "$out" ] || { [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision != "deny"' >/dev/null \
  || fail "kill switch: SB_RULES_LAYERS=off must not apply R's deny (got: $out)"; }
[ ! -e "$B5/projects/demo/.rules-effective.json" ] \
  || fail "kill switch: SB_RULES_LAYERS=off must never write a .rules-effective.json cache"
pass "kill switch: SB_RULES_LAYERS=off restores today's U/P precedence, no cache, repo ignored"

# --------------------------------------------------------------------------
# 6. Candidates per repo: merge-persona-signals.sh --slug arms into the REPO
#    layer, never the user file; without --slug the user file still receives it.
# --------------------------------------------------------------------------
B6="$TMP/b6"; mkdir -p "$B6"
PAYLOAD6='{"persona_signals":[],"rule_candidates":[{"event":"bash","pattern":"npm run migrate","message":"always confirm before migrating"}]}'
for i in 1 2 3; do printf '%s' "$PAYLOAD6" | BRAIN_DIR="$B6" bash "$MERGESIG" --slug demo >/dev/null 2>&1; done
[ "$(jq -r '.learned[0].pattern' "$B6/projects/demo/rules.json" 2>/dev/null)" = "npm run migrate" ] \
  || fail "candidates per repo: repo rules.json .learned[0].pattern should be the armed candidate"
[ "$(jq -r '.learned[0].action' "$B6/projects/demo/rules.json" 2>/dev/null)" = "warn" ] \
  || fail "candidates per repo: armed candidate action should be warn"
[ ! -e "$B6/persona-rules.json" ] \
  || fail "candidates per repo: --slug must NOT arm into the user persona-rules.json"

mkdir -p "$B6/.injected"; printf 'demo' > "$B6/.injected/s1.slug"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"npm run migrate"}}' "$B6" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B6" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("confirm before migrating")' >/dev/null \
  || fail "candidates per repo: a session pinned to demo should warn on the armed learned pattern (got: $out)"

printf 'other' > "$B6/.injected/s2.slug"
out2=$(printf '{"tool_name":"Bash","session_id":"s2","cwd":"%s","tool_input":{"command":"npm run migrate"}}' "$B6" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B6" bash "$GUARD")
[ -z "$out2" ] \
  || fail "candidates per repo: a session pinned to a DIFFERENT repo must not see demo's learned rule (got: $out2)"

B6u="$TMP/b6u"; mkdir -p "$B6u"
for i in 1 2 3; do printf '%s' "$PAYLOAD6" | BRAIN_DIR="$B6u" bash "$MERGESIG" >/dev/null 2>&1; done
[ "$(jq -r '.learned[0].pattern' "$B6u/persona-rules.json" 2>/dev/null)" = "npm run migrate" ] \
  || fail "candidates per repo: WITHOUT --slug, the user file should still receive the armed candidate"
pass "candidates per repo: --slug arms the repo layer only, is session-scoped, and the no-slug path is unchanged"

# --------------------------------------------------------------------------
# 7. Self-edit ask for the repo rules layer (Write + Edit) — regression-locked
#    in more depth in test-persona-tool-guard.sh; one direct check here too.
# --------------------------------------------------------------------------
B7="$TMP/b7"; mkdir -p "$B7"
out=$(printf '{"tool_name":"Write","session_id":"s1","tool_input":{"file_path":"%s/projects/demo/rules.json","content":"{}"}}' "$B7" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B7" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "self-edit ask: Write to repo rules.json should ask (got: $out)"
grep -q '"rule":"warn-self-edit-repo-rules"' "$B7/audit-log.jsonl" \
  || fail "self-edit ask: expected rule warn-self-edit-repo-rules in the audit row"
pass "self-edit ask: Write to a repo rules.json asks via warn-self-edit-repo-rules"

# --------------------------------------------------------------------------
# 8. Search-first: a Write of a path whose basename already exists elsewhere
#    in the repo warns once; an existing path and a no-namesake path stay silent.
# --------------------------------------------------------------------------
B8="$TMP/b8"; mkdir -p "$B8/.injected"
R8="$TMP/repo8"; mkdir -p "$R8/lib"
( cd "$R8" && git init -q && git config user.email a@b.c && git config user.name a
  printf 'export {}' > lib/util.ts && git add -A && git commit -q -m init )
printf 'demo8' > "$B8/.injected/s1.slug"
pgpre() { printf '{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$R8" "$1" \
  | BRAIN_DIR="$B8" bash "$PGUARD" pre; }

out=$(pgpre "$R8/src/new/util.ts")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | (test("lib/util.ts") and test("Search before creating"))' >/dev/null \
  || fail "search-first: a namesake write should warn with the existing path named (got: $out)"
grep -q 'gate=search-first tool=Write path=src/new/util.ts matches=1 hits=lib/util.ts verdict=warn' "$B8/audit-log.jsonl" \
  || fail "search-first: expected the exact gate=search-first warn row"

out=$(pgpre "$R8/lib/util.ts")
[ -z "$out" ] || fail "search-first: a Write to an EXISTING path must produce no output (got: $out)"

out=$(pgpre "$R8/src/brand-new.ts")
[ -z "$out" ] || fail "search-first: a namesake-free new path must produce no output (got: $out)"
grep -q 'gate=search-first tool=Write path=src/brand-new.ts matches=0 hits=none verdict=ok' "$B8/audit-log.jsonl" \
  || fail "search-first: expected a verdict=ok row for the no-namesake path"

out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$R8" "$R8/src/another/util.ts" \
  | SB_SEARCH_FIRST=off BRAIN_DIR="$B8" bash "$PGUARD" pre)
[ -z "$out" ] || fail "search-first: SB_SEARCH_FIRST=off must suppress everything (got: $out)"

GITSHIMDIR="$TMP/gitshim"; mkdir -p "$GITSHIMDIR"
REAL_GIT=$(command -v git)
cat > "$GITSHIMDIR/git" <<SHIM
#!/bin/bash
echo 1 >> "\$GIT_COUNT_FILE"
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$GITSHIMDIR/git"
: > "$TMP/gitcount"
GIT_COUNT_FILE="$TMP/gitcount" PATH="$GITSHIMDIR:$PATH" bash -c \
  "printf '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"session_id\":\"s1\",\"cwd\":\"$R8\",\"tool_input\":{\"file_path\":\"$R8/src/yet-another.ts\"}}' | BRAIN_DIR='$B8' bash '$PGUARD' pre" >/dev/null 2>&1
[ "$(wc -l < "$TMP/gitcount" | tr -d ' ')" = "0" ] \
  || fail "search-first: the per-session lsfiles cache should already be warm — expected zero git spawns on a later call"
pass "search-first: warns on a namesake, silent on existing/no-namesake paths, kill switch honoured, ls-files cached once"

# --------------------------------------------------------------------------
# 9. Repo key (bash): a linked worktree shares its main repo's slug; a plain
#    repo is unchanged; the kill switch restores the worktree's own basename.
# --------------------------------------------------------------------------
source "$ROOT/scripts/lib.sh"
WK="$TMP/wk"; mkdir -p "$WK/main-repo"
( cd "$WK/main-repo" && git init -q && git config user.email a@b.c && git config user.name a \
  && git commit -q --allow-empty -m init && git worktree add -q "$WK/wt" -b wtb ) 2>/dev/null
out=$(cd "$WK/wt" && sb_detect_project "$PWD" | cut -f1)
[ "$out" = "main-repo" ] || fail "repo key (bash): sb_detect_project on a linked worktree should print main-repo's slug (got: $out)"
out=$(CLAUDE_PROJECT_DIR="$WK/wt" bash -c "source '$ROOT/scripts/lib.sh'; sb_resolve_slug")
[ "$out" = "main-repo" ] || fail "repo key (bash): sb_resolve_slug(CLAUDE_PROJECT_DIR=<worktree>) should print main-repo (got: $out)"

mkdir -p "$WK/solo"; ( cd "$WK/solo" && git init -q )
out=$(cd "$WK/solo" && sb_detect_project "$PWD" | cut -f1)
[ "$out" = "solo" ] || fail "repo key (bash): a plain non-worktree repo should still print its own basename (got: $out)"

out=$(cd "$WK/wt" && SB_REPO_KEY_COMMON_DIR=off sb_detect_project "$PWD" | cut -f1)
[ "$out" = "wt" ] || fail "repo key (bash): SB_REPO_KEY_COMMON_DIR=off should restore the worktree's own basename (got: $out)"
pass "repo key (bash): worktree shares the main repo's slug; plain repos and the kill switch are unaffected"

# --------------------------------------------------------------------------
# 10. Skill rename: skills/rules exists with the right shape, skills/audit gone.
# --------------------------------------------------------------------------
[ -f "$ROOT/skills/rules/SKILL.md" ] || fail "skill rename: skills/rules/SKILL.md is missing"
[ ! -d "$ROOT/skills/audit" ] || fail "skill rename: skills/audit/ should no longer exist"
grep -q '^name: rules$' "$ROOT/skills/rules/SKILL.md" 2>/dev/null || fail "skill rename: SKILL.md frontmatter name: is not 'rules'"
for heading in show audit distill promote demote; do
  grep -qi "^## \`\?$heading" "$ROOT/skills/rules/SKILL.md" 2>/dev/null \
    || fail "skill rename: missing the '$heading' subcommand heading"
done
grep -qi 'lock' "$ROOT/skills/rules/SKILL.md" || fail "skill rename: SKILL.md never mentions 'lock'"
grep -qi 'layer' "$ROOT/skills/rules/SKILL.md" || fail "skill rename: SKILL.md never mentions 'layer'"
pass "skill rename: skills/rules/SKILL.md has the right shape, skills/audit is gone"

# --------------------------------------------------------------------------
# 11. Protocol lock holds: pg_search never writes to .claude/rules, CLAUDE.md or
#     MEMORY.md, and its output only ever carries additionalContext (warn), never
#     a permissionDecision — mirrors what tests/test-protocol-guard.sh's source
#     scan (Slice 1) checks; that file does not exist yet in this worktree
#     (Slice 1 has not landed here), so this is a direct behavioral proof of the
#     same invariant limited to Slice 3's own pg_search body.
# --------------------------------------------------------------------------
PG_BODY=$(awk '/^pg_search\(\) \{/,/^# --- end pg_search ---/' "$PGUARD")
echo "$PG_BODY" | grep -qE '\.claude/rules|CLAUDE\.md|MEMORY\.md' \
  && fail "protocol lock: pg_search body references a forbidden write target" \
  || pass "protocol lock: pg_search never references .claude/rules, CLAUDE.md or MEMORY.md"
echo "$PG_BODY" | grep -q 'permissionDecision' \
  && fail "protocol lock: pg_search body must never construct a permissionDecision" \
  || pass "protocol lock: pg_search never emits a permissionDecision (warn-only, via pg_ctx_add)"

if [ "$fail_n" -eq 0 ]; then
  echo; echo "ALL PASS"
else
  echo; echo "$fail_n FAILURE(S)"
  exit 1
fi
