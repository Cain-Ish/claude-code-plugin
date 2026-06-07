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

# 2. legacy fallback (no CLAUDE_PROJECT_DIR): a VALID pin (project-root level) beats bare cwd
r=$(BRAIN_DIR="$SB" bash -c "source '$ROOT/scripts/lib.sh'; cd '$ROOT'; sb_resolve_slug")
[ "$r" = "cainish" ] || fail "legacy fallback: valid pin should beat cwd (got '$r', want cainish)"
pass "legacy fallback: valid pin beats bare cwd"

# 2b. but an INVALID pin (no matching PROJECT.md) falls through to the cwd basename
SB3="$TMP/.sb3"; mkdir -p "$SB3/projects/claude-code-plugin"; touch "$SB3/projects/claude-code-plugin/PROJECT.md"
printf 'no-such-project' > "$SB3/.active-session-slug"
r=$(BRAIN_DIR="$SB3" bash -c "source '$ROOT/scripts/lib.sh'; cd '$ROOT'; sb_resolve_slug")
[ "$r" = "claude-code-plugin" ] || fail "invalid pin should fall through to cwd (got '$r')"
pass "invalid pin falls through to cwd basename"

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

# 5. a degenerate CLAUDE_PROJECT_DIR (/) is skipped → falls through to the pin (TS/bash parity)
r=$(BRAIN_DIR="$SB" CLAUDE_PROJECT_DIR="/" bash -c "source '$ROOT/scripts/lib.sh'; sb_resolve_slug")
[ "$r" = "cainish" ] || fail "degenerate CLAUDE_PROJECT_DIR=/ should fall through to pin (got '$r')"
pass "degenerate CLAUDE_PROJECT_DIR falls through to the pin"

echo; echo "ALL PASS"
