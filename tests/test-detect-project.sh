#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi
}

TMP=$(mktemp -d)

# --- standalone git repo ---
mkdir -p "$TMP/standalone"; ( cd "$TMP/standalone" && git init -q )
OUT=$(cd "$TMP/standalone" && sb_detect_project "$PWD")
check "standalone slug"      "standalone" "$(printf '%s' "$OUT" | cut -f1)"
check "standalone parent"    ""           "$(printf '%s' "$OUT" | cut -f2)"
# M2: root_path must be non-empty and match the git toplevel.
# The function emits ${top:-$abs} where top = git rev-parse --show-toplevel.
# Capture what git actually emits (Windows or MSYS form) and compare directly.
STANDALONE_ROOT_GIT=$(cd "$TMP/standalone" && git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
check "standalone root_path (non-empty)" "1" "$([ -n "$(printf '%s' "$OUT" | cut -f3)" ] && echo 1 || echo 0)"
check "standalone root_path" "$STANDALONE_ROOT_GIT" "$(printf '%s' "$OUT" | cut -f3)"

# --- single-git monorepo (pnpm-workspace.yaml at root), working in packages/api ---
mkdir -p "$TMP/acme/packages/api"; ( cd "$TMP/acme" && git init -q )
printf 'packages:\n  - "packages/*"\n' > "$TMP/acme/pnpm-workspace.yaml"
OUT=$(cd "$TMP/acme/packages/api" && sb_detect_project "$PWD")
check "monorepo child slug"   "acme__api" "$(printf '%s' "$OUT" | cut -f1)"
check "monorepo child parent" "acme"      "$(printf '%s' "$OUT" | cut -f2)"

# --- working AT the monorepo root → treated as the root (bare slug, no parent) ---
OUT=$(cd "$TMP/acme" && sb_detect_project "$PWD")
check "monorepo root slug"   "acme" "$(printf '%s' "$OUT" | cut -f1)"
check "monorepo root parent" ""     "$(printf '%s' "$OUT" | cut -f2)"

# --- .sb-monorepo.json marker topology (condition 3: no git, no workspace manifest) ---
# The child dir must NOT be a git repo and NOT under a workspace manifest so
# conditions 1 and 2 fall through, leaving the marker branch (condition 3) to fire.
mkdir -p "$TMP/marker/sub"
printf '{"parent":"acme"}\n' > "$TMP/marker/.sb-monorepo.json"
OUT=$(cd "$TMP/marker/sub" && sb_detect_project "$PWD")
check "marker slug"   "acme__sub" "$(printf '%s' "$OUT" | cut -f1)"
check "marker parent" "acme"      "$(printf '%s' "$OUT" | cut -f2)"

# --- git submodule topology (condition 1) ---
# git 2.38+ blocks local-path submodule add by default (CVE-2022-39253).
# We use -c protocol.file.allow=always to permit it for this test only.
SUPER="$TMP/superproject"
INNER="$TMP/innerrepo"
mkdir -p "$SUPER" "$INNER"

# Seed the inner repo with one commit (empty repo cannot be added as submodule).
( cd "$INNER" \
  && git -c user.email=t@t -c user.name=t init -q \
  && git -c user.email=t@t -c user.name=t commit --no-gpg-sign --allow-empty -m "init" -q \
) 2>/dev/null

# Initialise the superproject.
( cd "$SUPER" \
  && git -c user.email=t@t -c user.name=t init -q \
  && git -c user.email=t@t -c user.name=t commit --no-gpg-sign --allow-empty -m "init" -q \
) 2>/dev/null

# Add the inner repo as a submodule called "mylib".
SUBMOD_ADD_ERR=$(
  cd "$SUPER" && \
  git -c protocol.file.allow=always \
      -c user.email=t@t -c user.name=t \
      submodule add --quiet "file://$INNER" mylib 2>&1
)

if [ -d "$SUPER/mylib/.git" ] || [ -f "$SUPER/mylib/.git" ]; then
  # Submodule was added successfully — run the detection test.
  OUT=$(cd "$SUPER/mylib" && sb_detect_project "$PWD")
  SUPER_LEAF=$(basename "$SUPER")
  check "submodule slug"   "${SUPER_LEAF}__mylib" "$(printf '%s' "$OUT" | cut -f1)"
  check "submodule parent" "$SUPER_LEAF"           "$(printf '%s' "$OUT" | cut -f2)"
else
  # git submodule add refused local paths even with protocol.file.allow=always.
  # This can happen with certain Git builds or security policies on Windows.
  # The submodule topology is exercised by the detection logic (condition 1:
  # `[ -n "$sup" ]`) but cannot be triggered via `git submodule add` in this
  # environment. Skipping rather than committing a flaky/failing test.
  # Error from git: $SUBMOD_ADD_ERR
  echo "SKIP: submodule topology — git submodule add refused local path: $SUBMOD_ADD_ERR"
fi

# --- SECURITY: a hostile .sb-monorepo.json parent must NOT traverse out of projects/ ---
# {"parent":"../../evil"} must be rejected (falls through to standalone), never become a slug
# (which would reach `mkdir -p projects/<slug>` in setup and traverse the tree).
mkdir -p "$TMP/evilmarker/sub"
printf '{"parent":"../../evil"}\n' > "$TMP/evilmarker/.sb-monorepo.json"
OUT=$(cd "$TMP/evilmarker/sub" && sb_detect_project "$PWD")
check "hostile marker parent rejected (slug is bare leaf, no traversal)" "sub" "$(printf '%s' "$OUT" | cut -f1)"
check "hostile marker parent rejected (parent empty)"                    ""    "$(printf '%s' "$OUT" | cut -f2)"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
