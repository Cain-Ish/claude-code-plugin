#!/bin/bash
# Validate plugin files after modifications.
# Exit 0 = all valid, exit 1 = errors found.
# Outputs issues to stdout for the caller to read.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ERRORS=0

# Validate hooks.json
HOOKS="$PLUGIN_ROOT/hooks/hooks.json"
if [ -f "$HOOKS" ]; then
  if ! jq empty "$HOOKS" 2>/dev/null; then
    echo "FAIL: hooks.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  else
    # Iterate via while-read with --arg to safely handle event names that
    # contain whitespace or shell metacharacters (a malicious self-PR could
    # insert one). Several lifecycle events ignore matchers per the Claude
    # Code spec — for those, a matcher is not required, and declaring one
    # is misleading (silently ignored at runtime), so we WARN instead.
    NO_MATCHER_EVENTS="UserPromptSubmit Notification SessionEnd Stop PostToolBatch TeammateIdle TaskCreated TaskCompleted WorktreeCreate WorktreeRemove CwdChanged"
    SESSION_START_MATCHERS="startup|resume|clear|compact"

    while IFS= read -r event; do
      event="${event%$'\r'}"  # jq on Windows (Git Bash) emits CRLF — strip the CR
      [ -z "$event" ] && continue
      count=$(jq -r --arg e "$event" '.hooks[$e] | length' "$HOOKS" 2>/dev/null | tr -d '\r')
      if [ -z "$count" ] || [ "$count" = "null" ]; then
        continue
      fi
      for i in $(seq 0 $((count - 1))); do
        case " $NO_MATCHER_EVENTS " in
          *" $event "*)
            # Matcher optional — but warn if present, since it's a no-op
            if jq -e --arg e "$event" --argjson i "$i" '.hooks[$e][$i].matcher' "$HOOKS" >/dev/null 2>&1; then
              echo "WARN: hooks.json $event[$i] declares a 'matcher' but $event ignores matchers — remove it"
            fi
            ;;
          *)
            if ! jq -e --arg e "$event" --argjson i "$i" '.hooks[$e][$i].matcher' "$HOOKS" >/dev/null 2>&1; then
              echo "FAIL: hooks.json $event[$i] missing 'matcher'"
              ERRORS=$((ERRORS + 1))
            elif [ "$event" = "SessionStart" ]; then
              matcher=$(jq -r --arg e "$event" --argjson i "$i" '.hooks[$e][$i].matcher // ""' "$HOOKS" 2>/dev/null | tr -d '\r')
              if [ -n "$matcher" ] && ! echo "$matcher" | grep -Eq "^($SESSION_START_MATCHERS)(\|($SESSION_START_MATCHERS))*$"; then
                echo "WARN: hooks.json SessionStart[$i] matcher '$matcher' is not in the documented set ($SESSION_START_MATCHERS)"
              fi
            fi
            ;;
        esac

        if ! jq -e --arg e "$event" --argjson i "$i" '.hooks[$e][$i].hooks | length > 0' "$HOOKS" >/dev/null 2>&1; then
          echo "FAIL: hooks.json $event[$i] has empty 'hooks' array"
          ERRORS=$((ERRORS + 1))
          continue
        fi

        hcount=$(jq -r --arg e "$event" --argjson i "$i" '.hooks[$e][$i].hooks | length' "$HOOKS" 2>/dev/null | tr -d '\r')
        for j in $(seq 0 $((hcount - 1))); do
          if ! jq -e --arg e "$event" --argjson i "$i" --argjson j "$j" '.hooks[$e][$i].hooks[$j].command' "$HOOKS" >/dev/null 2>&1; then
            echo "FAIL: hooks.json $event[$i].hooks[$j] missing 'command'"
            ERRORS=$((ERRORS + 1))
          fi
        done
      done
    done < <(jq -r '.hooks | keys[]' "$HOOKS" 2>/dev/null)
  fi
fi

# Validate plugin.json
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ]; then
  if ! jq empty "$PLUGIN_JSON" 2>/dev/null; then
    echo "FAIL: plugin.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Version-sync check. Anthropic's community marketplace pins
# plugins to a specific commit SHA; if plugin.json and marketplace.json drift,
# the next submission rejects. Fail the validation when they disagree so the
# bump script can't ship a mismatched pair.
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
if [ -f "$MARKETPLACE_JSON" ]; then
  # Iterate EVERY marketplace entry, not .plugins[0], so any future additional
  # entry's drift is checked too. Each entry's `source` dir must carry
  # .claude-plugin/plugin.json with a matching version.
  # Fail CLOSED on schema surprises: tostring keeps @tsv alive on a non-string
  # source (object/remote forms), and a parse failure must surface as an
  # error, not silently skip every drift check.
  # tr -d '\r': the Windows (Git-Bash) jq build emits CRLF in -r output even when the input is
  # clean LF, so the LAST @tsv field of each record (.source) keeps a trailing \r — `${P_SRC#./}`
  # then becomes "\r" and the built manifest path "…/\r/.claude-plugin/plugin.json" doesn't exist
  # → a spurious drift FAIL on every non-last entry. Normalize jq's output, not the data.
  DRIFT_TSV=$(jq -r '.plugins[] | [.name, (.version // ""), (.source | tostring)] | @tsv' "$MARKETPLACE_JSON" 2>/dev/null | tr -d '\r')
  if [ -z "$DRIFT_TSV" ]; then
    echo "FAIL: could not parse .plugins[] from marketplace.json for the drift check"
    ERRORS=$((ERRORS + 1))
  fi
  while IFS=$'\t' read -r P_NAME P_VER P_SRC; do
    [ -n "$P_NAME" ] || continue
    case "$P_SRC" in
      ./*|.) : ;;  # local relative source — checkable below
      *)
        echo "WARN: marketplace plugin '$P_NAME' has non-local source '$P_SRC' — drift not checkable here"
        continue ;;
    esac
    SRC_MANIFEST="$PLUGIN_ROOT/${P_SRC#./}/.claude-plugin/plugin.json"
    SRC_MANIFEST=$(printf '%s' "$SRC_MANIFEST" | sed 's|//*|/|g')
    if [ ! -f "$SRC_MANIFEST" ]; then
      echo "FAIL: marketplace plugin '$P_NAME' source '$P_SRC' has no .claude-plugin/plugin.json"
      ERRORS=$((ERRORS + 1))
      continue
    fi
    SRC_VER=$(jq -r '.version // ""' "$SRC_MANIFEST" 2>/dev/null | tr -d '\r')   # Windows jq CRLF: keep the version comparison clean
    if [ -n "$SRC_VER" ] && [ -n "$P_VER" ] && [ "$SRC_VER" != "$P_VER" ]; then
      echo "FAIL: version drift — $P_NAME plugin.json=$SRC_VER but marketplace.json=$P_VER. Sync both on release."
      ERRORS=$((ERRORS + 1))
    fi
  done <<EOF_DRIFT
$DRIFT_TSV
EOF_DRIFT
fi

# claude plugin validate (P2c). Anthropic runs this on every community
# submission; running it locally surfaces issues before the SHA pin. Skip
# silently if the claude CLI isn't installed (e.g. in CI).
#
# --strict (CC v2.1.x+) treats warnings as errors, so manifest gaps the plain
# validate only warns about (e.g. a missing marketplace description) become hard
# release-gate failures. We probe --strict support first: older CLIs that don't
# know the flag exit non-zero on the --help probe, and we fall back to plain
# validate so the gate still runs (offline/old-CLI graceful degradation).
if command -v claude >/dev/null 2>&1 && claude plugin --help >/dev/null 2>&1; then
  PV_STRICT=""
  if claude plugin validate --help 2>/dev/null | grep -q -- '--strict'; then
    PV_STRICT="--strict"
  fi
  if ! claude plugin validate $PV_STRICT "$PLUGIN_ROOT" >/dev/null 2>&1; then
    # Re-run capturing output so the user sees what failed.
    PV_OUT=$(claude plugin validate $PV_STRICT "$PLUGIN_ROOT" 2>&1 || true)
    echo "FAIL: \`claude plugin validate $PV_STRICT\` reported issues:"
    printf '%s\n' "$PV_OUT" | sed 's/^/  /' | head -20
    ERRORS=$((ERRORS + 1))
  fi
fi

# Validate all shell scripts
while IFS= read -r script; do
  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: $script has syntax errors"
    ERRORS=$((ERRORS + 1))
  fi
done < <(find "$PLUGIN_ROOT/scripts" -name "*.sh" -type f 2>/dev/null)

# Validate all SKILL.md frontmatter
while IFS= read -r skill_file; do
  if head -1 "$skill_file" | grep -q "^---"; then
    # Lines after the first '---' and before the next '---'. awk stops at the
    # first closing delimiter; a sed start/end range would restart on a
    # body-level '---' thematic break and leak body lines into the frontmatter.
    frontmatter=$(awk '/^---$/{n++; next} n==1' "$skill_file")

    # user-invocable + disable-model-invocation must be EXPLICIT —
    # implicit defaults made the dispatch surface unauditable (a side-effectful
    # skill silently model-invocable is the failure class).
    for field in name description allowed-tools user-invocable disable-model-invocation; do
      if ! echo "$frontmatter" | grep -q "^$field:"; then
        echo "FAIL: $(basename "$(dirname "$skill_file")")/SKILL.md missing '$field' in frontmatter"
        ERRORS=$((ERRORS + 1))
      fi
    done
  else
    echo "FAIL: $(basename "$(dirname "$skill_file")")/SKILL.md missing YAML frontmatter"
    ERRORS=$((ERRORS + 1))
  fi
done < <(find "$PLUGIN_ROOT/skills" -name "SKILL.md" -type f 2>/dev/null)

# Validate agent definitions
while IFS= read -r agent_file; do
  if head -1 "$agent_file" | grep -q "^---"; then
    frontmatter=$(awk '/^---$/{n++; next} n==1' "$agent_file")
    if ! echo "$frontmatter" | grep -q "^name:"; then
      echo "FAIL: $(basename "$agent_file") missing 'name' in frontmatter"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(find "$PLUGIN_ROOT/agents" -name "*.md" -type f 2>/dev/null)

# R8 surface budget: live counts must not EXCEED .claude-plugin/surface-budget.json —
# growth without a same-commit baseline bump fails (deliberate, git-blameable
# growth only). Shrinking is always fine (ratchet the baseline down when seen).
BUDGET_JSON="$PLUGIN_ROOT/.claude-plugin/surface-budget.json"
if [ -f "$BUDGET_JSON" ]; then
  LIVE_SKILLS=$(find "$PLUGIN_ROOT/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  LIVE_AGENTS=$(find "$PLUGIN_ROOT/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  LIVE_SCRIPTS=$(find "$PLUGIN_ROOT/scripts" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')
  LIVE_TESTS=$(find "$PLUGIN_ROOT/tests" -maxdepth 1 -name 'test-*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')
  for pair in "skills:$LIVE_SKILLS" "agents:$LIVE_AGENTS" "scripts:$LIVE_SCRIPTS" "tests:$LIVE_TESTS"; do
    key="${pair%%:*}"; live="${pair#*:}"
    cap=$(jq -r --arg k "$key" '.[$k] // empty' "$BUDGET_JSON" 2>/dev/null | tr -d '\r')
    case "$cap" in ''|*[!0-9]*) continue ;; esac
    if [ "$live" -gt "$cap" ]; then
      echo "FAIL: surface budget exceeded — $key=$live > budget $cap (bump .claude-plugin/surface-budget.json in the same commit to grow deliberately)"
      ERRORS=$((ERRORS + 1))
    fi
  done
  # Lean-runner cap — enforced here as the SKILL.md Notes promise.
  UPG_CAP=$(jq -r '.upgrade_skill_max_bytes // 8192' "$BUDGET_JSON" 2>/dev/null | tr -d '\r')
  UPG_BYTES=$(wc -c < "$PLUGIN_ROOT/skills/upgrade/SKILL.md" 2>/dev/null | tr -d ' ')
  case "$UPG_BYTES" in *[!0-9]*|'') UPG_BYTES=0 ;; esac
  if [ "$UPG_BYTES" -gt "$UPG_CAP" ]; then
    echo "FAIL: skills/upgrade/SKILL.md is ${UPG_BYTES}B (cap $UPG_CAP) — narrative goes to the release commit body, actions to migrations/<version>.md"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "FAIL: .claude-plugin/surface-budget.json missing (R8 surface budget baseline)"
  ERRORS=$((ERRORS + 1))
fi

# Verify runtime-referenced files exist. These are not skills or agents but are
# loaded by other scripts/skills at runtime; if they go missing, parts of the
# plugin break silently. The MCP manifest lives at .claude-plugin/mcp.json
# (referenced from plugin.json's mcpServers), NOT at the repo root — see the
# root-.mcp.json guard below for why.
for ref in \
  ".claude-plugin/mcp.json" \
  "mcp/package.json"; do
  if [ ! -f "$PLUGIN_ROOT/$ref" ]; then
    echo "FAIL: required file missing: $ref"
    ERRORS=$((ERRORS + 1))
  fi
done

# JSON-validate the MCP manifests so a corrupt one is caught here, not at runtime
for json_ref in ".claude-plugin/mcp.json" "mcp/package.json"; do
  if [ -f "$PLUGIN_ROOT/$json_ref" ] && ! jq empty "$PLUGIN_ROOT/$json_ref" 2>/dev/null; then
    echo "FAIL: $json_ref is not valid JSON"
    ERRORS=$((ERRORS + 1))
  fi
done

# MCP path-anchor guard — REQUIRES the bare ${CLAUDE_PLUGIN_ROOT}/ anchor on bundle paths.
# Claude Code substitutes ONLY the bare ${CLAUDE_PLUGIN_ROOT} token to an absolute
# path. The ${VAR:-default} shell form is NOT applied, and a bare relative path
# resolves against the user's cwd — either way the server starts only inside the
# plugin's own directory and fails everywhere else (the P0 that broke every installed
# user). So any bundled *.bundle.js arg MUST be anchored by a bare ${CLAUDE_PLUGIN_ROOT}/
# prefix — never ${CLAUDE_PLUGIN_ROOT:-...}, never a bare relative path. (A var-less
# server such as an npx command has no .bundle.js path and is unaffected.)
MCP_MANIFEST="$PLUGIN_ROOT/.claude-plugin/mcp.json"
if [ -f "$MCP_MANIFEST" ] && grep -qE '\.bundle\.js' "$MCP_MANIFEST" \
   && ! grep -qE '\$\{CLAUDE_PLUGIN_ROOT\}/[^"]*\.bundle\.js' "$MCP_MANIFEST"; then
  echo 'FAIL: .claude-plugin/mcp.json bundle path is not anchored by ${CLAUDE_PLUGIN_ROOT}/ (found a ${CLAUDE_PLUGIN_ROOT:-...} default or a bare relative path) — Claude Code resolves it against the user cwd, so the server fails to start outside the plugin dir. Use ${CLAUDE_PLUGIN_ROOT}/mcp/dist/server.bundle.js.'
  ERRORS=$((ERRORS + 1))
fi

# A root .mcp.json is read a SECOND time as a project-scoped MCP config when the repo
# is opened as a project (CLAUDE_PLUGIN_ROOT unset there → "missing env var" + a dead
# server). Keep the manifest only at .claude-plugin/mcp.json, wired via plugin.json.
if [ -f "$PLUGIN_ROOT/.mcp.json" ]; then
  echo 'FAIL: root .mcp.json present — it is double-read as a project MCP config (var unset → broken). Move it to .claude-plugin/mcp.json and reference it from plugin.json mcpServers.'
  ERRORS=$((ERRORS + 1))
fi

# plugin.json must wire the relocated manifest via "mcpServers" — unlike a root
# .mcp.json it is not auto-discovered, so without the reference the server never loads.
# ($PLUGIN_JSON is set near the top, next to the version-drift check.)
if [ -f "$PLUGIN_JSON" ] && ! jq -e '.mcpServers' "$PLUGIN_JSON" >/dev/null 2>&1; then
  echo 'FAIL: plugin.json has no "mcpServers" — the relocated .claude-plugin/mcp.json will not be loaded. Add "mcpServers": "./.claude-plugin/mcp.json".'
  ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -eq 0 ]; then
  echo "OK: all plugin files valid"
  exit 0
else
  echo "TOTAL: $ERRORS error(s) found"
  exit 1
fi
