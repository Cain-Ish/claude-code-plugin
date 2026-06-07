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
mkdir -p "$SB/projects/claude-code-plugin"; touch "$SB/projects/claude-code-plugin/PROJECT.md"
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; unset CLAUDE_PROJECT_DIR; cd '$ROOT'; sb_resolve_slug")
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

echo; echo "ALL PASS"
