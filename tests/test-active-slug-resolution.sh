#!/bin/bash
# Guard: the active project slug is resolved from the PER-SESSION project dir
# (CLAUDE_PROJECT_DIR, else the caller's cwd), NOT from the global, shared
# .active-session-slug pin — which a CONCURRENT session can clobber. A stale pin
# must never override the session's real project. (sb_resolve_slug / sb_slug_from_dir)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SB="$TMP/.sb"; mkdir -p "$SB/projects/cainish" "$SB/projects/claude-code-plugin"
touch "$SB/projects/cainish/PROJECT.md" "$SB/projects/claude-code-plugin/PROJECT.md"
printf 'cainish' > "$SB/.active-session-slug"   # STALE pin from a concurrent session

run() { # args: CLAUDE_PROJECT_DIR cwd  -> prints resolved slug
  BRAIN_DIR="$SB" CLAUDE_PROJECT_DIR="$1" bash -c "source '$ROOT/scripts/lib.sh'; cd '$2' 2>/dev/null; sb_resolve_slug"
}

# 1. CLAUDE_PROJECT_DIR wins over the stale pin (the concurrent-session bug)
r=$(run "/home/u/Projects/claude-code-plugin" "$TMP")
[ "$r" = "claude-code-plugin" ] || fail "stale pin overrode CLAUDE_PROJECT_DIR (got '$r', want claude-code-plugin)"
pass "CLAUDE_PROJECT_DIR beats the stale pin"

# 2. THE live bug: no CLAUDE_PROJECT_DIR, cwd IS the known project, pin clobbered to cainish.
#    The per-process cwd (a registered project) must beat the stale shared pin.
#    Use a CONTROLLED cwd whose basename names the registered project — NOT $ROOT, whose
#    basename is the checkout/cache dir name (e.g. "0.24.33" when this runs from the plugin
#    cache, or any CI/worktree dir). Keying the cwd off $ROOT made this subtest pass only when
#    run from a directory literally named "claude-code-plugin".
KP="$TMP/wd/claude-code-plugin"; mkdir -p "$KP"   # cwd basename = a registered project, location-independent
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd '$KP'; sb_resolve_slug")
[ "$r" = "claude-code-plugin" ] || fail "cwd (known project) should beat the stale pin (got '$r', want claude-code-plugin)"
pass "cwd that names a known project beats the stale pin (no CLAUDE_PROJECT_DIR)"

# 2b. a SUBDIR cwd (basename not a registered project) falls to the pin (subdir survival)
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd '$ROOT/scripts'; sb_resolve_slug")
[ "$r" = "cainish" ] || fail "subdir cwd should fall to the pin (got '$r', want cainish)"
pass "subdir cwd (not a known project) falls to the pin"

# 3. tmp→scratch normalization is shared (sb_slug_from_dir)
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; sb_slug_from_dir /tmp/tmp.aB3xq")
[ "$r" = "scratch" ] || fail "tmp dir not normalized to scratch (got '$r')"
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; sb_slug_from_dir /x/tmpfs")
[ "$r" = "scratch" ] || fail "tmpfs not normalized to scratch (got '$r')"
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; sb_slug_from_dir /home/u/Projects/my-app")
[ "$r" = "my-app" ] || fail "real project basename mangled (got '$r')"
pass "sb_slug_from_dir normalizes tmp-like dirs, preserves real names"

# 3b. 0.30.0 cross-OS: a CRLF-tainted CLAUDE_PROJECT_DIR must NOT leak a trailing \r into the
# slug (else a ghost project dir + split-brain vs the clean-slug pins/markers, and divergence
# from the MCP slugFromProjectDir which also CR-strips). printf %b to inject a real CR.
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; sb_slug_from_dir \"\$(printf '%b' '/home/u/Projects/my-app\r')\"")
[ "$r" = "my-app" ] || fail "sb_slug_from_dir leaked a CR into the slug (got $(printf '%q' "$r"))"
pass "sb_slug_from_dir strips a trailing CR (no ghost 'my-app\\r' project on Windows)"

# 4. session-load.sh writes the pin from the project dir (not a stale value)
SB2="$TMP/.sb2"; mkdir -p "$SB2/projects"
printf 'cainish' > "$SB2/.active-session-slug"
CLAUDE_PROJECT_DIR="/home/u/Projects/claude-code-plugin" BRAIN_DIR="$SB2" KNOWLEDGE_DIR="$TMP/kd" \
  bash "$ROOT/scripts/session-load.sh" >/dev/null 2>&1 || true
r=$(cat "$SB2/.active-session-slug")
[ "$r" = "claude-code-plugin" ] || fail "session-load did not refresh the pin to the project dir (got '$r')"
pass "session-load refreshes the pin from CLAUDE_PROJECT_DIR"

# 5. a degenerate CLAUDE_PROJECT_DIR (/) is skipped; from a non-project cwd it reaches the pin
mkdir -p "$TMP/plain"
r=$(BRAIN_DIR="$SB" CLAUDE_PROJECT_DIR="/" bash -c "source '$ROOT/scripts/lib.sh'; cd '$TMP/plain'; sb_resolve_slug")
[ "$r" = "cainish" ] || fail "degenerate CLAUDE_PROJECT_DIR=/ + non-project cwd should reach the pin (got '$r')"
pass "degenerate CLAUDE_PROJECT_DIR is skipped, non-project cwd reaches the pin"

# 6. tier-4 parity: a non-project cwd with NO valid pin → the cwd basename (brand-new project)
SB4="$TMP/.sb4"; mkdir -p "$SB4/projects"   # no pin, no registered projects
r=$(BRAIN_DIR="$SB4" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd '$TMP/plain'; sb_resolve_slug")
[ "$r" = "plain" ] || fail "tier-4 new project should be the cwd basename (got '$r', want plain)"
pass "tier-4: non-project cwd with no pin resolves to the cwd basename"

# 6b. tier-4 parity: a DEGENERATE cwd with no pin → empty (matches the TS resolver's undefined)
r=$(BRAIN_DIR="$SB4" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd /; sb_resolve_slug")
[ -z "$r" ] || fail "degenerate cwd with no pin should resolve to empty, not a '/' slug (got '$r')"
pass "tier-4: degenerate cwd with no pin → empty (TS parity, no '/' slug leak)"

# 7. remote identity: a re-clone under a NEW folder name (`name-2` of registered repo `name`)
#    resolves the registered slug in BOTH funnels — sb_resolve_slug (query/capture callers
#    here) AND sb_detect_project (registration) — on both sb_resolve_slug branches.
SB7="$TMP/.sb7"; mkdir -p "$SB7/projects/name"
touch "$SB7/projects/name/PROJECT.md"
printf '%s\n' \
  '{"slug":"name","name":"name","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"https://github.com/example/name.git"}' \
  > "$SB7/projects.jsonl"
RC="$TMP/wd/name-2"; mkdir -p "$RC"
( cd "$RC" && git init -q && git remote add origin "https://github.com/example/name.git" )

# 7a. CLAUDE_PROJECT_DIR branch: remote identity beats the basename
r=$(BRAIN_DIR="$SB7" CLAUDE_PROJECT_DIR="$RC" bash -c "source '$ROOT/scripts/lib.sh'; cd '$TMP'; sb_resolve_slug")
[ "$r" = "name" ] || fail "re-clone via CLAUDE_PROJECT_DIR should resolve registered slug (got '$r', want name)"
pass "re-clone: CLAUDE_PROJECT_DIR branch resolves the registered slug via remote identity"

# 7b. cwd branch (no CLAUDE_PROJECT_DIR): same override
r=$(BRAIN_DIR="$SB7" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd '$RC'; sb_resolve_slug")
[ "$r" = "name" ] || fail "re-clone via cwd should resolve registered slug (got '$r', want name)"
pass "re-clone: cwd branch resolves the registered slug via remote identity"

# 7c. the capture/registration funnel agrees: sb_detect_project on the same sandbox → no split-brain
r=$(BRAIN_DIR="$SB7" bash -c "source '$ROOT/scripts/lib.sh'; sb_detect_project '$RC'" | cut -f1)
[ "$r" = "name" ] || fail "sb_detect_project disagrees with sb_resolve_slug on the re-clone (got '$r', want name)"
pass "re-clone: sb_detect_project and sb_resolve_slug agree (no capture/query split-brain)"

# 7d. the override is LOUD: audit-logged, never silent (.git/config is attacker-writable)
grep -q 'remote-identity-override' "$SB7/audit-log.jsonl" \
  || fail "remote-identity override was not audit-logged (want remote-identity-override in audit-log.jsonl)"
pass "remote-identity override is audit-logged"

# 7e. a remote-less dir keeps its basename (identity enhancement, not a guard)
RL="$TMP/wd/name-9"; mkdir -p "$RL"
( cd "$RL" && git init -q )
r=$(BRAIN_DIR="$SB7" CLAUDE_PROJECT_DIR="$RL" bash -c "source '$ROOT/scripts/lib.sh'; cd '$TMP'; sb_resolve_slug")
[ "$r" = "name-9" ] || fail "remote-less dir should keep its basename (got '$r', want name-9)"
pass "remote-less dir keeps its basename"

# 7f. pin precedence preserved: a non-project, remote-less cwd still falls to the pin
printf 'name' > "$SB7/.active-session-slug"
mkdir -p "$TMP/wd/plain7"
r=$(BRAIN_DIR="$SB7" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd '$TMP/wd/plain7'; sb_resolve_slug")
[ "$r" = "name" ] || fail "non-project cwd should still fall to the pin (got '$r', want name)"
pass "pin still wins for a non-project, remote-less cwd (precedence preserved)"

echo; echo "ALL PASS"
