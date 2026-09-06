#!/usr/bin/env bash
# Tests for scripts/discover-installed.sh — the SessionStart hook that enumerates
# installed plugins/agents/skills into $BRAIN_DIR/.installed-catalog.json.
#
# WHY THIS FILE EXISTS (0.45.0): this hook had NO test at all, and it was
# silently broken in production. hooks/hooks.json declares a 10s timeout; the
# pre-0.45.0 implementation spawned 2 awk + 1 jq PER FILE, measured at 52.4s on a
# 964-skill / 320-agent install base. It was therefore killed at 10s every single
# SessionStart. Worse, the catalog is written at the very END of the script, so a
# killed run never refreshes the cache -> the plugins tree stays newer than the
# cache file -> the NEXT session takes the slow path and is killed again. A
# permanent starvation loop, triggered by any `/plugin update`, with no error
# surfaced anywhere. Reproduced end-to-end 2026-08-21:
#     fast path (cache fresh):                 1241ms  EXIT=0
#     after touching ~/.claude/plugins/cache: 12057ms  EXIT=124 (killed)
#     cache mtime after the killed run:        UNCHANGED
#
# The perf case below encodes the ACTUAL contract — "must finish inside the
# timeout hooks.json declares for it" — rather than a magic number, so it stays
# meaningful if that timeout is ever retuned.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/discover-installed.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/discover-installed.sh not found"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

# mkplugin <root> <name> <version> <n_agents> <n_skills> [crlf]
mkplugin() {
  local root="$1" name="$2" ver="$3" na="$4" ns="$5" crlf="${6:-}"
  local d="$root/$name"
  mkdir -p "$d/.claude-plugin" "$d/agents" "$d/skills"
  jq -nc --arg n "$name" --arg v "$ver" \
    '{name:$n, description:("desc for " + $n), version:$v}' > "$d/.claude-plugin/plugin.json"
  local i
  for (( i=1; i<=na; i++ )); do   # not `seq 1 "$na"`: BSD seq counts DOWN from 1 to 0 (issue #101)
    if [ -n "$crlf" ]; then
      printf -- '---\r\nname: %s-agent-%s\r\ndescription: agent %s of %s\r\n---\r\n\r\nbody\r\n' \
        "$name" "$i" "$i" "$name" > "$d/agents/a$i.md"
    else
      printf -- '---\nname: %s-agent-%s\ndescription: agent %s of %s\n---\n\nbody\n' \
        "$name" "$i" "$i" "$name" > "$d/agents/a$i.md"
    fi
  done
  for (( i=1; i<=ns; i++ )); do
    mkdir -p "$d/skills/s$i"
    printf -- '---\nname: %s-skill-%s\ndescription: skill %s of %s\n---\n\nbody\n' \
      "$name" "$i" "$i" "$name" > "$d/skills/s$i/SKILL.md"
  done
}

# --- Test 1: catalog shape + attribution -------------------------------------
P1="$TMP/plugins1"; B1="$TMP/b1"; mkdir -p "$P1" "$B1"
mkplugin "$P1" "alpha" "1.2.3" 2 3
mkplugin "$P1" "beta"  "0.1.0" 1 1
OUT=$(env BRAIN_DIR="$B1" bash "$SCRIPT" "$P1" 2>/dev/null) || fail "1: script exited non-zero"
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 || fail "1: output is not valid JSON"
[ "$(printf '%s' "$OUT" | jq -r '.plugins | length')" = "2" ] || fail "1: expected 2 plugins"
[ "$(printf '%s' "$OUT" | jq -r '.agents  | length')" = "3" ] || fail "1: expected 3 agents"
[ "$(printf '%s' "$OUT" | jq -r '.skills  | length')" = "4" ] || fail "1: expected 4 skills"
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.generated_at | type == "string"' >/dev/null || fail "1: missing generated_at"
[ "$(printf '%s' "$OUT" | jq -r '.plugins[] | select(.name=="alpha") | .version')" = "1.2.3" ] \
  || fail "1: plugin version not carried"
[ "$(printf '%s' "$OUT" | jq -r '.agents[] | select(.name=="alpha-agent-1") | .plugin')" = "alpha" ] \
  || fail "1: agent not attributed to its plugin"
[ "$(printf '%s' "$OUT" | jq -r '.skills[] | select(.name=="beta-skill-1") | .description')" = "skill 1 of beta" ] \
  || fail "1: skill description not extracted"
# every record must carry exactly the documented keys
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.agents[] | has("name") and has("description") and has("plugin")' >/dev/null \
  || fail "1: agent record shape changed"
pass "catalog shape, counts, attribution, version"

# --- Test 2: the catalog file is written, not just streamed -------------------
[ -f "$B1/.installed-catalog.json" ] || fail "2: .installed-catalog.json not written"
diff <(printf '%s\n' "$OUT") "$B1/.installed-catalog.json" >/dev/null 2>&1 \
  || fail "2: stdout and catalog file disagree"
pass "catalog file written and matches stdout"

# --- Test 3: CRLF frontmatter (Windows-authored .md) -------------------------
P3="$TMP/plugins3"; B3="$TMP/b3"; mkdir -p "$P3" "$B3"
mkplugin "$P3" "crlfplug" "1.0.0" 2 0 crlf
OUT3=$(env BRAIN_DIR="$B3" bash "$SCRIPT" "$P3" 2>/dev/null) || fail "3: script exited non-zero"
[ "$(printf '%s' "$OUT3" | jq -r '.agents | length')" = "2" ] || fail "3: CRLF frontmatter not parsed"
[ -n "$OUT3" ] && printf '%s' "$OUT3" | jq -e '.agents[] | select(.description | test("\r"))' >/dev/null 2>&1 \
  && fail "3: CR leaked into a description value"
pass "CRLF frontmatter parsed, no CR leakage"

# --- Test 4: nameless frontmatter is skipped ---------------------------------
P4="$TMP/plugins4"; B4="$TMP/b4"; mkdir -p "$P4" "$B4"
mkplugin "$P4" "gamma" "1.0.0" 1 0
printf -- '---\ndescription: no name here\n---\n\nbody\n' > "$P4/gamma/agents/noname.md"
OUT4=$(env BRAIN_DIR="$B4" bash "$SCRIPT" "$P4" 2>/dev/null)
[ "$(printf '%s' "$OUT4" | jq -r '.agents | length')" = "1" ] || fail "4: nameless agent was not skipped"
pass "frontmatter without name: skipped"

# --- Test 5: cache fast-path returns identical content ------------------------
OUT5=$(env BRAIN_DIR="$B1" bash "$SCRIPT" "$P1" 2>/dev/null) || fail "5: fast path exited non-zero"
[ "$OUT5" = "$OUT" ] || fail "5: fast-path output differs from the freshly built catalog"
pass "cache fast-path returns identical catalog"

# --- Test 6: PERF LOCK — must finish inside its own hooks.json timeout --------
# Read the declared budget rather than hardcoding it, so retuning hooks.json
# retunes this lock. Falls back to 10 (the 0.44.0 value) if the entry moves.
BUDGET=$(jq -r '
  [ .hooks.SessionStart[]?.hooks[]?
    | select(.command | test("discover-installed"))
    | .timeout ] | first // empty' "$ROOT/hooks/hooks.json" 2>/dev/null | tr -d '\r')
case "$BUDGET" in ''|*[!0-9]*) BUDGET=10 ;; esac

P6="$TMP/plugins6"; B6="$TMP/b6"; mkdir -p "$P6" "$B6"
# 200 agents + 200 skills across 2 plugins. The pre-0.45.0 implementation spent
# 3 process spawns per file (awk name, awk description, jq assemble) = ~1200
# spawns here, which blows the budget on any real machine.
mkplugin "$P6" "big1" "1.0.0" 100 100
mkplugin "$P6" "big2" "1.0.0" 100 100
T_START=$(date +%s)
OUT6=$(env BRAIN_DIR="$B6" bash "$SCRIPT" "$P6" 2>/dev/null) || fail "6: script exited non-zero"
T_ELAPSED=$(( $(date +%s) - T_START ))
[ "$(printf '%s' "$OUT6" | jq -r '.agents | length')" = "200" ] || fail "6: wrong agent count under load"
[ "$(printf '%s' "$OUT6" | jq -r '.skills | length')" = "200" ] || fail "6: wrong skill count under load"
if [ "$T_ELAPSED" -gt "$BUDGET" ]; then
  fail "6: PERF — 400 files took ${T_ELAPSED}s, over the ${BUDGET}s timeout hooks.json declares.
       A killed run never writes the catalog, so the cache stays stale and every
       later session re-enters the slow path. Do not spawn a process per file."
fi
pass "perf: 400 files discovered in ${T_ELAPSED}s (budget ${BUDGET}s)"

# --- Test 7: hostile / malformed frontmatter cannot corrupt the catalog -------
# The 0.45.0 implementation frames records with US (0x1f) between awk and jq, so a
# third-party plugin's SKILL.md is now UNTRUSTED INPUT to a parser. These cases lock
# the framing against forgery and the JSON against breakage. Verified equivalent to
# the pre-0.45.0 output on every case here EXCEPT the 0x1f one, where the old code
# passed the raw control character straight into the JSON value and this one strips
# it — a deliberate divergence, not a regression.
P7="$TMP/plugins7"; B7="$TMP/b7"; mkdir -p "$P7" "$B7"
mkplugin "$P7" "hostile" "1.0.0" 0 0
A7="$P7/hostile/agents"
printf -- '---\nname: quoteful\ndescription: has "quotes": and a \\ backslash and {"json":"bomb"}\n---\nbody\n' > "$A7/a1.md"
printf -- '---\nname: forger\ndescription: before\037FORGED\037PLUGIN\n---\nbody\n'                              > "$A7/a2.md"
printf -- 'just a body, no fences\n'                                                                            > "$A7/a3.md"
printf -- '---\nname: real\ndescription: real desc\n---\n\nbody\n\n---\nname: fake-from-body\n---\n'             > "$A7/a4.md"
printf -- '---\ndescription: nameless\n---\nbody\n'                                                             > "$A7/a5.md"
printf -- '---\nname: spaced\ndescription: file has spaces\n---\nbody\n'                                        > "$A7/a file with spaces.md"
printf -- '---\nname: "quoted-name"\ndescription: "quoted desc"\n---\nbody\n'                                    > "$A7/a7.md"

OUT7=$(env BRAIN_DIR="$B7" bash "$SCRIPT" "$P7" 2>/dev/null) || fail "7: script exited non-zero on hostile input"
[ -n "$OUT7" ] && printf '%s' "$OUT7" | jq -e . >/dev/null 2>&1 || fail "7: hostile frontmatter produced invalid JSON"
[ "$(printf '%s' "$OUT7" | jq -r '.agents | length')" = "5" ] \
  || fail "7: expected 5 agents (a3 no-frontmatter and a5 no-name are skipped)"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="quoteful") | .description')" \
  = 'has "quotes": and a \ backslash and {"json":"bomb"}' ] || fail "7: quotes/backslash/JSON payload mangled"
# Field forgery: the injected 0x1f bytes must be stripped, NOT treated as separators.
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="forger") | .description')" = "beforeFORGEDPLUGIN" ] \
  || fail "7: 0x1f in a description was not neutralised"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="forger") | .plugin')" = "hostile" ] \
  || fail "7: a description forged the plugin attribution field"
# A `---` rule in the BODY must not resurrect frontmatter parsing.
[ -z "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="fake-from-body") | .name')" ] \
  || fail "7: a --- rule in the body was parsed as frontmatter"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="spaced") | .description')" = "file has spaces" ] \
  || fail "7: filename containing spaces was dropped by the find -exec batch"
[ "$(printf '%s' "$OUT7" | jq -r '.agents[] | select(.name=="quoted-name") | .description')" = "quoted desc" ] \
  || fail "7: quoted frontmatter values not unquoted"
pass "hostile frontmatter: valid JSON, no field forgery, no body-fence bleed"

# --- Test 8: a hostile plugin.json `name` cannot FORGE catalog records ---------
# Found in review of the 0.45.0 rewrite, 2026-08-21. `name` is spliced into the
# 0x1f record stream as its third field, but unlike nm/ds it does NOT come from a
# line-oriented awk read -- it comes from a third-party plugin.json, so it can carry
# a literal NEWLINE. Before the fix, a name of the form
#     evil<NL>FAKE-NAME<US>FAKE-DESC<US>FAKE-PLUGIN
# appended a real extra line that `jq -Rc` parsed as a complete agent record backed
# by NO FILE AT ALL. Test 7 covers 0x1f inside .md frontmatter and did NOT catch
# this: the forgery vector is the newline, and only plugin.json can supply one.
# The fixture is built with printf escapes so no literal control byte lives in this
# source file (a stray 0x1f is invisible in review and easy to lose in an edit).
P8="$TMP/plugins8"; B8="$TMP/b8"; mkdir -p "$P8/evil/.claude-plugin" "$P8/evil/agents" "$B8"
printf -- '---\nname: real-agent\ndescription: legit\n---\nbody\n' > "$P8/evil/agents/real.md"
HOSTILE_NAME=$(printf 'evil\nFAKE-NAME\037FAKE-DESC\037FAKE-PLUGIN')
jq -nc --arg n "$HOSTILE_NAME" '{name:$n, description:"d", version:"1"}' \
  > "$P8/evil/.claude-plugin/plugin.json"
# Sanity-check the fixture itself: if the newline did not survive into the JSON
# string, this whole case would pass vacuously and lock nothing.
jq -e '.name | contains("\n")' "$P8/evil/.claude-plugin/plugin.json" >/dev/null 2>&1 \
  || fail "8: fixture lost the embedded newline in plugin.json name -- test would pass vacuously"

OUT8=$(env BRAIN_DIR="$B8" bash "$SCRIPT" "$P8" 2>/dev/null) || fail "8: script exited non-zero"
[ -n "$OUT8" ] && printf '%s' "$OUT8" | jq -e . >/dev/null 2>&1 || fail "8: forged-name fixture produced invalid JSON"
if [ -n "$OUT8" ] && printf '%s' "$OUT8" | jq -e '.agents[] | select(.name=="FAKE-NAME")' >/dev/null 2>&1; then
  fail "8: a hostile plugin.json name FORGED an agent record backed by no file"
fi
[ "$(printf '%s' "$OUT8" | jq -r '.agents | length')" = "1" ] \
  || fail "8: expected exactly the 1 real agent record"
[ "$(printf '%s' "$OUT8" | jq -r '.agents[0].name')" = "real-agent" ] \
  || fail "8: the legitimate agent record was lost"
pass "hostile plugin.json name cannot forge catalog records"

echo; echo "ALL PASS"
