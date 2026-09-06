#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi
}

TMP=$(mktemp -d)
# Hermetic: sb_detect_project's standalone case consults $BRAIN_DIR/projects.jsonl for
# remote-identity resolution — point it at a sandbox so the user's real registry can
# never leak slugs into (or absorb noise from) these fixtures.
BRAIN_DIR="$TMP/brain"; mkdir -p "$BRAIN_DIR"

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

# --- remote-URL normalization: the shared fixture locks the bash + jq + TS twins together ---
# Every row is asserted against BOTH bash-side implementations (sb_normalize_remote and the
# $SB_JQ_REMOTE_ID jq def); the vitest suite asserts normalizeRemote against the same file.
FIX="$HERE/tests/fixtures/remote-normalization.tsv"
if [ -f "$FIX" ]; then
  rows=0
  while IFS=$'\t' read -r raw want; do
    raw=$(printf '%s' "$raw" | tr -d '\r'); want=$(printf '%s' "$want" | tr -d '\r')
    [ -n "$raw" ] || continue   # blank fixture line = the empty-line handling case (skipped)
    check "normalize [$raw]"         "$want" "$(sb_normalize_remote "$raw")"
    # MSYS_NO_PATHCONV: the bare-path fixture row would otherwise be rewritten to a
    # Windows path by Git-Bash before jq sees it (same reason sb_slug_from_remote sets it).
    check "jq-twin normalize [$raw]" "$want" "$(MSYS_NO_PATHCONV=1 jq -nr --arg u "$raw" "$SB_JQ_REMOTE_ID"'$u | nrm')"
    rows=$((rows+1))
  done < "$FIX"
  check "fixture exercised (>=8 rows)" "1" "$([ "$rows" -ge 8 ] && echo 1 || echo 0)"
else
  echo "FAIL: shared fixture missing: $FIX"; fail=1
fi
check "normalize empty -> empty" "" "$(sb_normalize_remote "")"

# --- remote identity: a re-clone under a new folder name resolves to the registered slug ---
printf '%s\n' \
  '{"slug":"name","name":"name","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"https://github.com/example/name.git"}' \
  > "$BRAIN_DIR/projects.jsonl"
mkdir -p "$TMP/name-2"
( cd "$TMP/name-2" && git init -q && git remote add origin "https://github.com/example/name.git" )
OUT=$(cd "$TMP/name-2" && sb_detect_project "$PWD")
check "re-clone (name-2) resolves registered slug" "name" "$(printf '%s' "$OUT" | cut -f1)"
check "re-clone keeps its own root_path"           "1"    "$([ -n "$(printf '%s' "$OUT" | cut -f3)" ] && echo 1 || echo 0)"

# ssh/scp form of the SAME repo matches the https-registered remote (normalized identity)
mkdir -p "$TMP/name-3"
( cd "$TMP/name-3" && git init -q && git remote add origin "git@github.com:Example/Name.git" )
OUT=$(cd "$TMP/name-3" && sb_detect_project "$PWD")
check "ssh-form re-clone matches https-registered remote" "name" "$(printf '%s' "$OUT" | cut -f1)"

# remote-less dir keeps its basename (identity enhancement, not a guard)
mkdir -p "$TMP/name-4"
( cd "$TMP/name-4" && git init -q )
OUT=$(cd "$TMP/name-4" && sb_detect_project "$PWD")
check "remote-less dir keeps basename" "name-4" "$(printf '%s' "$OUT" | cut -f1)"

# unregistered remote falls open to the basename
mkdir -p "$TMP/other"
( cd "$TMP/other" && git init -q && git remote add origin "https://github.com/example/other.git" )
OUT=$(cd "$TMP/other" && sb_detect_project "$PWD")
check "unregistered remote falls back to basename" "other" "$(printf '%s' "$OUT" | cut -f1)"

# bare-path (local filesystem) remote: the leading-slash jq arg must survive Git-Bash
# path mangling inside sb_slug_from_remote, so the registry lookup still matches.
printf '%s\n' \
  '{"slug":"name5","name":"name5","last_session_iso":"2026-01-01T00:00:00Z","git_remote":"/srv/git/name5.git"}' \
  >> "$BRAIN_DIR/projects.jsonl"
check "bare-path remote registry lookup" "name5" \
  "$(sb_slug_from_remote "$BRAIN_DIR/projects.jsonl" "/srv/git/name5.git")"

# --- D118: sb_registration_refused_reason refuses $HOME and bare temp roots
# (which brain-os-run.sh's registry root-picker would otherwise code-map as a
# whole-home-directory project), but lets a REAL project living there through.
OLD_HOME="$HOME"

# $HOME itself, no .git/manifest → refused
export HOME="$TMP/home-plain"; mkdir -p "$HOME"
check "D118: bare \$HOME refused" "home" "$(sb_registration_refused_reason "$HOME")"

# $HOME itself, but it's a REAL git repo (e.g. a dotfiles repo) → let through
export HOME="$TMP/home-dotfiles"; mkdir -p "$HOME"; ( cd "$HOME" && git init -q )
check "D118: \$HOME with its own .git is NOT refused" "" "$(sb_registration_refused_reason "$HOME")"
export HOME="$OLD_HOME"

# A bare temp root by env var, no .git/manifest → refused
FAKE_TMPDIR="$TMP/tmproot"; mkdir -p "$FAKE_TMPDIR"
check "D118: \$TMPDIR root refused" "temp-root" \
  "$(TMPDIR="$FAKE_TMPDIR" sb_registration_refused_reason "$FAKE_TMPDIR")"

# A bare mktemp-style basename, case-insensitively (Windows AppData\Local\Temp
# basename is "Temp", not "tmp") → refused
WIN_TEMP="$TMP/winhome/AppData/Local/Temp"; mkdir -p "$WIN_TEMP"
check "D118: Windows-form 'Temp' basename refused" "temp-root" "$(sb_registration_refused_reason "$WIN_TEMP")"

# An ORDINARY project nested several levels under a temp root (e.g. a test
# fixture, or a repo cloned for review) is NOT the bare root itself → not refused
NESTED="$TMP/tmproot2/some/real/project"; mkdir -p "$NESTED"; ( cd "$NESTED" && git init -q )
check "D118: a real project several levels under a temp root is not refused" "" \
  "$(sb_registration_refused_reason "$NESTED")"

# An ordinary non-temp, non-home directory with no .git/manifest is NOT refused —
# this guard only fires for HOME/temp-root candidates, never ordinary projects.
ORDINARY="$TMP/just-a-folder"; mkdir -p "$ORDINARY"
check "D118: an ordinary non-git folder elsewhere is not refused" "" "$(sb_registration_refused_reason "$ORDINARY")"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
