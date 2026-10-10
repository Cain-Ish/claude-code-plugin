#!/bin/bash
# Guard: an agent whose body invokes `node` or a `bash "$CLAUDE_PLUGIN_ROOT/…"` script must
# DECLARE the matching grant in its `tools:` frontmatter, else the call prompts/denies mid-run.
# This is the same missing-grant class that hid the maintainer's missing Bash(node *) for ~10
# releases (skills are guarded by test-skill-allowed-tools.sh; agents had no guard until now).
# Body-scan matches invocation patterns (node + quote/$, bash + ${CLAUDE_PLUGIN_ROOT}) to avoid
# matching prose mentions. Known (currently-unused) blind spots, by design, to keep it
# false-positive-free: a script exec'd directly without a leading `bash ` prefix, and `node`
# captured via `$(…)`. No agent uses either today; widen the patterns if one ever does.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; A="$ROOT/agents"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -d "$A" ] || fail "agents/ dir missing"

checked=0
for f in "$A"/*.md; do
  name=$(basename "$f" .md)
  tools=$(grep -m1 '^tools:' "$f" || true)
  # node invocation: `node "` or `node '` or `node $`
  if grep -qE 'node ["'\''$]' "$f"; then
    printf '%s' "$tools" | grep -qE 'Bash\(node ' \
      || fail "$name: body invokes node but tools: lacks Bash(node *)"
  fi
  # bash-script invocation: `bash "$CLAUDE_PLUGIN_ROOT` or `bash "${CLAUDE_PLUGIN_ROOT`
  if grep -qE 'bash "\$\{?CLAUDE_PLUGIN_ROOT' "$f"; then
    printf '%s' "$tools" | grep -qE 'Bash\(bash ' \
      || fail "$name: body invokes a plugin bash script but tools: lacks Bash(bash *)"
  fi
  checked=$((checked + 1))
done
pass "all $checked agents declare the tools their bodies invoke (node / bash scripts)"

# R3-B X1: the dream-runner's Bash grants are the commands its documented steps run. Only its
# Write/Edit/MultiEdit are path-confined (protocol-guard.sh pg_dream_confine), so a grant that can
# write or execute anywhere undoes that: find (-exec/-delete), sed (-i, e), awk (system(),
# print >), cp, touch, mkdir, sort (-o), uniq (output file), and `bash` on ANY plugin script
# (dream-accept.sh would self-accept the dream). mv and rm stay (status/heartbeat, renames,
# removing a merged page) and are the residual its Constraints state.
# R3-C P-Q10: an ALLOWLIST. The denylist this replaced missed the `Bash(find:*)` spelling and every
# grant nobody had thought to list (Bash(curl *), a bare Bash, WebFetch, a pinned dream-accept.sh).
# Every tools: entry must be one of the entries below; a new grant fails here until it is reviewed
# and added. Write/Edit/MultiEdit are allowed because pg_dream_confine path-confines them.
DR_ALLOW_TOOLS=" Read Write Edit MultiEdit Glob Grep "
DR_ALLOW_BASH=" jq grep diff cat head tail wc date test ls basename dirname stat mktemp mv rm "
DR_ALLOW_SCRIPTS=" wiki-redundancy.sh graph-cluster.sh wiki-forget-candidates.sh dream-diff.sh "
# dr_grants <tools: value>: one grant per line, split on the commas outside parentheses.
dr_grants() {
  local s="$1" g="" d=0 c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      "(") d=$((d + 1)) ;;
      ")") d=$((d - 1)) ;;
      ",") [ "$d" -eq 0 ] && { printf '%s\n' "$g"; g=""; continue; } ;;
    esac
    g="$g$c"
  done
  printf '%s\n' "$g"
}
# dr_allowed <grant>: 0 when the (trimmed) grant is on the allowlist. A Bash grant is one bare
# command word followed by ` *`, or a pinned `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh*`.
dr_allowed() {
  local g="$1" in w
  case "$g" in
    'Bash('*')')
      in="${g#Bash(}"; in="${in%)}"
      case "$in" in
        'bash ${CLAUDE_PLUGIN_ROOT}/scripts/'*'.sh*')
          w="${in#'bash ${CLAUDE_PLUGIN_ROOT}/scripts/'}"; w="${w%\*}"
          case "$w" in *[!a-z0-9.-]*) return 1 ;; esac
          case "$DR_ALLOW_SCRIPTS" in *" $w "*) return 0 ;; esac ;;
        *' *')
          w="${in% \*}"
          case "$w" in ''|*[!a-z0-9]*) return 1 ;; esac
          case "$DR_ALLOW_BASH" in *" $w "*) return 0 ;; esac ;;
      esac
      return 1 ;;
    ''|*[!A-Za-z]*) return 1 ;;
  esac
  case "$DR_ALLOW_TOOLS" in *" $g "*) return 0 ;; esac
  return 1
}
# dr_bad_grants <tools: line>: the grants outside the allowlist, space-separated.
dr_bad_grants() {
  local g out=""
  while IFS= read -r g; do
    g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
    [ -n "$g" ] || continue
    dr_allowed "$g" || out="$out$g "
  done < <(dr_grants "${1#tools:}")
  printf '%s' "$out"
}
# Poison self-test: the checker must flag each of these, or a pass below proves nothing.
for poison in 'Bash(find:*)' 'Bash(find *)' 'Bash(curl *)' 'Bash' 'Bash(*)' 'WebFetch' 'Bash(sed -i *)' \
              'Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/dream-accept.sh*)' 'Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)' \
              'Bash(bash *)' 'Read Write' 'mcp__plugin_second-brain_knowledge-base__dream_accept'; do
  [ -n "$(dr_bad_grants "tools: Read, $poison, Bash(jq *)")" ] \
    || fail "allowlist self-test: the checker let '$poison' through"
done
[ -z "$(dr_bad_grants 'tools: Read, Write, Bash(jq *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/dream-diff.sh*)')" ] \
  || fail "allowlist self-test: the checker flagged an allowed line ($(dr_bad_grants 'tools: Read, Write, Bash(jq *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/dream-diff.sh*)'))"
DR="$A/dream-runner.md"
DRT=$(grep -m1 '^tools:' "$DR" | tr -d '\r' || true)
[ -n "$DRT" ] || fail "dream-runner: no tools: line (the allowlist check would pass on nothing)"
DR_BAD=$(dr_bad_grants "$DRT")
[ -z "$DR_BAD" ] || fail "dream-runner: tools: grant(s) outside the allowlist: $DR_BAD(review each one, then add it to DR_ALLOW_* here)"
DR_N=0
for s in $(grep -oE 'bash "\$\{?CLAUDE_PLUGIN_ROOT\}?/scripts/[a-z0-9-]+\.sh' "$DR" | sed 's#.*/scripts/##' | sort -u); do
  printf '%s' "$DRT" | grep -qF "Bash(bash \${CLAUDE_PLUGIN_ROOT}/scripts/$s" \
    || fail "dream-runner: the body runs scripts/$s but tools: has no pinned Bash(bash \${CLAUDE_PLUGIN_ROOT}/scripts/$s…) grant"
  DR_N=$((DR_N + 1))
done
[ "$DR_N" -ge 4 ] || fail "dream-runner: expected >=4 plugin scripts in the body, found $DR_N (the scan broke?)"
grep -q 'not path-confined' "$DR" || fail "dream-runner: Constraints do not state the Bash residual (\"not path-confined\")"
pass "dream-runner: every tools: grant is on the allowlist (no write/exec-capable Bash grant beyond mv/rm); each of its $DR_N plugin scripts has a pinned grant; the residual is stated"
echo; echo "ALL PASS"
