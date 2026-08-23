#!/bin/bash
# discover-installed.sh — enumerate installed plugins/agents/skills under a plugins root.
# Usage: discover-installed.sh [plugins-root]
# Defaults: plugins-root=${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache}
# Writes JSON catalog to ${BRAIN_DIR:-~/.second-brain}/.installed-catalog.json and stdout.
#
# PERFORMANCE IS A CORRECTNESS PROPERTY HERE (0.45.0). hooks/hooks.json gives this
# hook a 10s SessionStart budget. The previous implementation spawned three
# processes PER FILE (awk for `name`, awk for `description`, jq to assemble) and
# measured 52.4s against a 964-skill / 320-agent install base — killed at 10s every
# session. Because the catalog is written only at the END, a killed run never
# refreshes the cache, so the plugins tree stays newer than the cache file and the
# NEXT session re-enters the slow path and is killed again: a permanent starvation
# loop, tripped by any `/plugin update`, surfacing no error anywhere.
# This version spawns a BOUNDED number of processes per PLUGIN — not per file — via
# one `find -exec awk … {} +` batch per kind. The exact count is deliberately not
# written down here: an earlier draft said "2 jq + 2 find + 2 awk" and was already
# wrong (it omitted the `tr` sanitizer and the dirname/basename pair), and a hard
# number in a comment drifts silently the moment the loop changes (PR #91 review).
# What matters is the ORDER: per-plugin, never per-file. The machine-checked version
# of this claim is tests/test-discover-installed.sh test 6, which fails the build if
# 400 files no longer fit inside the timeout hooks.json declares.
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

PLUGINS_ROOT="${1:-${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache}}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
OUT_FILE="$BRAIN_DIR/.installed-catalog.json"

mkdir -p "$BRAIN_DIR"

# Fast-path: reuse cached catalog if nothing under plugins dir has changed.
# We compare against ANY file in the tree, not just $PLUGINS_ROOT itself —
# directory mtime only bumps when entries at the immediate level change, so
# a plugin update inside a subdirectory leaves a root-only check stale
# indefinitely. `head -n1` closes the pipe on the first hit, short-circuiting find
# portably — `-quit` is a GNU-only primary that BSD/macOS find rejects (its swallowed
# error empties the capture and the script then re-discovers on every single run).
if [ -f "$OUT_FILE" ] && [ -d "$PLUGINS_ROOT" ]; then
  NEWER=$(find "$PLUGINS_ROOT" -newer "$OUT_FILE" -print 2>/dev/null | head -n1)
  if [ -z "$NEWER" ]; then
    cat "$OUT_FILE"
    exit 0
  fi
fi

TMP_PLUGINS=$(mktemp)
TMP_AGENTS_RAW=$(mktemp)
TMP_SKILLS_RAW=$(mktemp)
TMP_AGENTS=$(mktemp)
TMP_SKILLS=$(mktemp)
trap 'rm -f "$TMP_PLUGINS" "$TMP_AGENTS_RAW" "$TMP_SKILLS_RAW" "$TMP_AGENTS" "$TMP_SKILLS"' EXIT

# Frontmatter reader, batched over MANY .md files in one awk process.
# Emits one US(\037)-separated record per file: name \037 description \037 plugin.
# Records with an empty name are dropped in emit() below (`if (nm != "")`), matching
# the previous `[ -z "$aname" ] && continue`. The jq stage re-checks the same
# condition — belt and braces, since jq is what turns a line into a catalog record and
# should not depend on an upstream guarantee it cannot see (PR #91 review: the earlier
# wording credited jq alone and obscured where the filtering actually happens).
#   - The fence regex keeps `[ \t\r]*` because a CRLF-authored .md fence is `---\r`;
#     a strict /^---$/ would never toggle and the whole block would be invisible.
#   - Only the FIRST frontmatter block is read (fence==1), so a `---` rule inside
#     the body cannot resurrect parsing. The old per-key `exit` made that moot;
#     batching means we must be explicit.
#   - \037 is stripped from values so a hostile description cannot forge a field.
FM_AWK=$(cat <<'AWKEOF'
function clean(v) {
  gsub(/\r/, "", v)
  gsub(/\037/, "", v)
  gsub(/^["'[:space:]]+/, "", v)
  gsub(/["'[:space:]]+$/, "", v)
  return v
}
function emit() {
  if (nm != "") printf "%s\037%s\037%s\n", nm, ds, PLUG
  nm = ""; ds = ""; fence = 0
}
FNR == 1 { emit() }
/^---[ \t\r]*$/ { fence++; next }
fence == 1 {
  if (nm == "" && $0 ~ /^name:/) {
    v = $0; sub(/^name:[ \t]*/, "", v); nm = clean(v)
  } else if (ds == "" && $0 ~ /^description:/) {
    v = $0; sub(/^description:[ \t]*/, "", v); ds = clean(v)
  }
}
END { emit() }
AWKEOF
)

if [ -d "$PLUGINS_ROOT" ]; then
  while IFS= read -r pj; do
    [ -f "$pj" ] || continue
    # One jq builds the plugin record (was three `jq -r` reads plus a `jq -nc`
    # assemble). gsub("\r";"") replaces the old `tr -d '\r'` without a second process.
    prec=$(jq -c 'select((.name // "") != "")
                  | {name: .name,
                     description: ((.description // "") | gsub("\r"; "")),
                     version:     ((.version     // "") | gsub("\r"; ""))}' "$pj" 2>/dev/null)
    [ -n "$prec" ] || continue
    printf '%s\n' "$prec" >> "$TMP_PLUGINS"
    # Sanitize the SAME characters clean() strips inside FM_AWK. $name is spliced
    # into the 0x1f record stream as the third field, so it is untrusted framing
    # input exactly like a description is — but it arrives from a THIRD-PARTY
    # plugin.json, not from a line-oriented awk read, so it can carry a literal
    # NEWLINE. Without \n and \037 stripping, a hostile plugin.json name of the form
    #   "evil\nFAKE-NAME\037FAKE-DESC\037FAKE-PLUGIN"
    # appends a genuine extra line to the stream, which `jq -Rc` then parses as a
    # fully FORGED agent/skill record backed by no file at all (reproduced 2026-08-21
    # during review of this rewrite; the header's anti-forgery claim covered only
    # nm/ds and silently did not hold for PLUG). Locked by test 8.
    name=$(jq -r '.name // empty' "$pj" 2>/dev/null | tr -d '\r\n\037')
    [ -n "$name" ] || continue

    # Resolve the plugin's root dir. plugin.json may live at <root>/plugin.json
    # or <root>/.claude-plugin/plugin.json.
    # Builtins, not $(dirname)/$(basename): this loop runs once per installed plugin on EVERY
    # SessionStart, and each spawn is ~30-60ms on MSYS (3 spawns x N plugins per start).
    plugin_dir="${pj%/*}"
    if [ "${plugin_dir##*/}" = ".claude-plugin" ]; then
      plugin_dir="${plugin_dir%/*}"
    fi

    # `-exec … {} +` batches every matching file into ONE awk invocation (a handful
    # for very large trees), instead of one process per file. POSIX; BSD/macOS-safe.
    # No match => awk is never invoked at all.
    [ -d "$plugin_dir/agents" ] && find "$plugin_dir/agents" -maxdepth 1 -name '*.md' -type f \
      -exec awk -v PLUG="$name" "$FM_AWK" {} + >> "$TMP_AGENTS_RAW" 2>/dev/null
    [ -d "$plugin_dir/skills" ] && find "$plugin_dir/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -type f \
      -exec awk -v PLUG="$name" "$FM_AWK" {} + >> "$TMP_SKILLS_RAW" 2>/dev/null
  done < <(find "$PLUGINS_ROOT" -name 'plugin.json' -type f 2>/dev/null | head -200)
fi

# One jq per kind converts the whole US-separated stream to JSONL. `-R` reads raw
# lines, so no shell quoting can corrupt a description.
us2json() {
  jq -Rc 'select(length > 0)
          | split(([31] | implode))   # US (0x1f); built from its code point so no
                                       # backslash escape can be mangled by an editor or sed
          | select(length >= 3)
          | select(.[0] != "")
          | {name: .[0], description: .[1], plugin: .[2]}'
}
# FAIL LOUD on a truncated category. A jq failure here would silently yield an
# EMPTY agents/skills list and a structurally valid catalog — the same
# silently-truncated-catalog failure this rewrite exists to end. This is a
# SessionStart hook, so it must not block: breadcrumb and continue with what we
# have, rather than swallow. Only fires when raw input existed but conversion
# produced nothing, so an install base with genuinely zero agents stays quiet.
convert_or_log() {
  local raw="$1" out="$2" kind="$3" rc=0
  us2json < "$raw" > "$out" 2>/dev/null || rc=$?
  # Gate on the EXIT CODE first, not just on an empty result. Checking only
  # `-s "$out"` misses the partial-truncation case this breadcrumb exists for: jq
  # emitting some records and then failing still leaves a non-empty file, so the
  # "fail loud" path stayed silent on the very failure mode it was added to catch
  # (PR #91 review). Record counts go in the message so a partial loss is
  # diagnosable from the log alone.
  local rawn outn
  rawn=$(grep -c . "$raw" 2>/dev/null | tr -d ' '); rawn=${rawn:-0}
  outn=$(grep -c . "$out" 2>/dev/null | tr -d ' '); outn=${outn:-0}
  if [ "$rc" -ne 0 ] || { [ -s "$raw" ] && [ ! -s "$out" ]; }; then
    printf '{"timestamp":"%s","script":"discover-installed.sh","message":"catalog %s conversion failed (jq rc=%s): %s input record(s) -> %s output record(s) — catalog is truncated","exit_code":1}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$rc" "$rawn" "$outn" \
      >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
  fi
}
convert_or_log "$TMP_AGENTS_RAW" "$TMP_AGENTS" agents
convert_or_log "$TMP_SKILLS_RAW" "$TMP_SKILLS" skills

# Slurp the JSONL streams into a single catalog object.
CATALOG=$(jq -ns \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile p "$TMP_PLUGINS" \
  --slurpfile a "$TMP_AGENTS" \
  --slurpfile s "$TMP_SKILLS" \
  '{generated_at:$ts, plugins:$p, agents:$a, skills:$s}')

echo "$CATALOG" > "$OUT_FILE"
echo "$CATALOG"
