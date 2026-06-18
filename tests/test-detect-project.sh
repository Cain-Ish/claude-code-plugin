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
check "standalone slug"   "standalone" "$(printf '%s' "$OUT" | cut -f1)"
check "standalone parent" ""           "$(printf '%s' "$OUT" | cut -f2)"

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

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
