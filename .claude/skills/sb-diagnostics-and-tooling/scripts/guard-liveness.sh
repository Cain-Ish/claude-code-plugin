#!/bin/bash
# guard-liveness.sh — violation-injection liveness probe for the three PreToolUse guards.
#
# "No errors" has repeatedly meant "not running" in this repo (all three guards were
# inert on Windows for months, proven only by the 2026-07-02 deep audit; fixed 0.33.31).
# This script proves the guards are ARMED *right now* by feeding synthetic hook payloads
# on stdin — exactly what Claude Code's PreToolUse hook does — and asserting the JSON
# verdict, instead of trusting an absence of errors.
#
# Probes:
#   symlink-guard.sh      deny on credential-dir write (~/.ssh), allow on project file,
#                         plus a Windows-form (C:\) probe when cygpath exists (G-HOOK-2)
#   persona-tool-guard.sh rewrite (2>/dev/null strip), ask (force-push main, rm -rf,
#                         out-of-scope Edit), silent on harmless Bash
#   wiki-write-guard.sh   deny on frontmatter-less wiki-page Write, silent with frontmatter
#
# READ-ONLY / SIDE-EFFECT-FREE: every probe runs with HOME and BRAIN_DIR pointed at
# throwaway mktemp dirs, so verdict audit lines, tombstone restores, and prefix checks
# never touch real state. persona-tool-guard therefore evaluates the SHIPPED default
# rules (scripts/persona-rules.default.json), not any user ~/.second-brain/persona-rules.json
# — this probes the guard MECHANISM, not user rule content.
#
# Verdict semantics: empty stdout = no decision (silent allow);
# JSON with .hookSpecificOutput.permissionDecision = the guard fired.
#
# Usage (bash 3.2-safe, runnable from anywhere):
#   bash guard-liveness.sh [PLUGIN_ROOT]      # or export CLAUDE_PLUGIN_ROOT
# Exit: 0 = all three guards ARMED; 1 = any guard FAIL-OPEN, OVER-BLOCKING or DISABLED;
#       2 = prerequisites missing (jq / guard scripts not found).
set -u

# --- locate the plugin root -------------------------------------------------
ROOT=""
if [ -n "${1:-}" ]; then
  ROOT="$1"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/symlink-guard.sh" ]; then
  ROOT="$CLAUDE_PLUGIN_ROOT"
else
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    if [ -f "$d/scripts/symlink-guard.sh" ]; then ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi
if [ -z "$ROOT" ] || [ ! -f "$ROOT/scripts/symlink-guard.sh" ]; then
  echo "guard-liveness: cannot locate plugin root (pass it as \$1 or set CLAUDE_PLUGIN_ROOT)" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "guard-liveness: jq required" >&2; exit 2; }
for g in symlink-guard.sh persona-tool-guard.sh wiki-write-guard.sh; do
  [ -f "$ROOT/scripts/$g" ] || { echo "guard-liveness: missing $ROOT/scripts/$g" >&2; exit 2; }
done

# --- throwaway sandbox (all probe side effects land here) --------------------
TMPD=$(mktemp -d) || exit 2
trap 'rm -rf "$TMPD"' EXIT
SBHOME="$TMPD/home"; PBRAIN="$TMPD/brain"
mkdir -p "$SBHOME/.ssh" "$SBHOME/work/repo" "$PBRAIN"

TOTAL_FAIL=0

# Build the hook payload with printf, NOT `jq --arg` — on Windows git-bash, jq
# receives MSYS-converted C:\ argument paths, which breaks HOME-prefix checks
# (house rule, tests/test-symlink-guard.sh:28-29).
payload_file() {  # $1 tool  $2 file_path
  local et ep
  et=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ep=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"session_id":"guard-liveness-probe","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$et" "$ep"
}
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null; }

check() {  # $1 label  $2 expected(deny|ask|allow|silent)  $3 actual-output
  local label="$1" want="$2" out="$3" d
  d=$(decision "$out")
  case "$want" in
    silent)
      if [ -z "$out" ]; then echo "  ok:   $label -> silent allow"; return 0; fi
      echo "  FAIL: $label -> expected silent, got '${d:-non-decision output}'"; return 1 ;;
    *)
      if [ "$d" = "$want" ]; then echo "  ok:   $label -> $d"; return 0; fi
      echo "  FAIL: $label -> expected $want, got '${d:-SILENT (fail-open)}'"; return 1 ;;
  esac
}

# =============================== 1. symlink-guard ============================
echo "symlink-guard.sh (credential-dir write denial):"
G=0
if [ "${SB_SYMLINK_GUARD:-on}" = "off" ]; then
  echo "  DISABLED: SB_SYMLINK_GUARD=off is set in this environment — guard will not fire live"
  G=1
else
  run_sym() { payload_file "$1" "$2" | HOME="$SBHOME" BRAIN_DIR="$PBRAIN" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/symlink-guard.sh" 2>/dev/null; }
  OUT=$(run_sym Write "$SBHOME/.ssh/authorized_keys")
  check "Write \$HOME/.ssh/authorized_keys" deny "$OUT" || G=$((G+1))
  OUT=$(run_sym Write "$SBHOME/work/repo/main.py")
  check "Write project file (not over-blocking)" silent "$OUT" || G=$((G+1))
  # Windows-form probe — the exact fail-open class the guards had (inert on the dev
  # platform). Only meaningful where cygpath exists (git-bash/Cygwin).
  if command -v cygpath >/dev/null 2>&1; then
    WP=$(cygpath -w "$SBHOME/.ssh/id_probe" 2>/dev/null || true)
    if [ -n "$WP" ]; then
      OUT=$(run_sym Write "$WP")
      check "Write Windows-form C:\\ path into .ssh" deny "$OUT" || G=$((G+1))
    fi
  else
    echo "  skip: Windows-form probe (no cygpath; POSIX platform)"
  fi
fi
if [ "$G" -eq 0 ]; then echo "VERDICT symlink-guard: ARMED"; else echo "VERDICT symlink-guard: NOT LIVE ($G failing probe(s))"; TOTAL_FAIL=$((TOTAL_FAIL+1)); fi
echo

# ============================ 2. persona-tool-guard ==========================
echo "persona-tool-guard.sh (Layer-3 rules + resource scope, shipped defaults):"
G=0
if [ "${SB_PERSONA_GATE:-on}" = "off" ]; then
  echo "  DISABLED: SB_PERSONA_GATE=off is set in this environment — guard will not fire live"
  G=1
else
  run_ptg() { printf '%s' "$1" | HOME="$SBHOME" BRAIN_DIR="$PBRAIN" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/persona-tool-guard.sh" 2>/dev/null; }
  OUT=$(run_ptg '{"session_id":"guard-liveness-probe","tool_name":"Bash","tool_input":{"command":"ls foo 2>/dev/null"}}')
  check "Bash '... 2>/dev/null' (strip-silent-fallback)" allow "$OUT" || G=$((G+1))
  if [ -n "$OUT" ]; then
    if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.updatedInput.command | contains("2>/dev/null") | not' >/dev/null 2>&1; then
      echo "  ok:   rewrite removed 2>/dev/null from the command"
    else
      echo "  FAIL: rewrite did not strip 2>/dev/null"; G=$((G+1))
    fi
  fi
  OUT=$(run_ptg '{"session_id":"guard-liveness-probe","tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}')
  check "Bash force-push to main" ask "$OUT" || G=$((G+1))
  OUT=$(run_ptg '{"session_id":"guard-liveness-probe","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/guard-liveness-probe"}}')
  check "Bash rm -rf" ask "$OUT" || G=$((G+1))
  if [ "${SB_RESOURCE_SCOPE:-on}" = "off" ]; then
    echo "  skip: resource-scope probe (SB_RESOURCE_SCOPE=off in this environment)"
  else
    OUT=$(run_ptg '{"session_id":"guard-liveness-probe","tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj"}')
    check "Edit /etc/hosts outside resource scope" ask "$OUT" || G=$((G+1))
  fi
  OUT=$(run_ptg '{"session_id":"guard-liveness-probe","tool_name":"Bash","tool_input":{"command":"ls -la"}}')
  check "harmless Bash (not over-blocking)" silent "$OUT" || G=$((G+1))
  # Audit-channel wiring: verdicts above must have landed in the (sandboxed) audit log.
  if grep -q '"hook":"persona-tool-guard.sh"' "$PBRAIN/audit-log.jsonl" 2>/dev/null; then
    echo "  ok:   verdicts appended to audit-log.jsonl (sb_log_audit wiring live)"
  else
    echo "  FAIL: no persona-tool-guard entries in the probe audit log — sb_log_audit wiring broken"
    G=$((G+1))
  fi
fi
if [ "$G" -eq 0 ]; then echo "VERDICT persona-tool-guard: ARMED"; else echo "VERDICT persona-tool-guard: NOT LIVE ($G failing probe(s))"; TOTAL_FAIL=$((TOTAL_FAIL+1)); fi
echo

# ============================= 3. wiki-write-guard ===========================
echo "wiki-write-guard.sh (wiki frontmatter contract):"
G=0
if [ "${SB_PERSONA_GATE:-on}" = "off" ]; then
  echo "  DISABLED: SB_PERSONA_GATE=off is set in this environment (shared kill switch) — guard will not fire live"
  G=1
else
  # The guard matches on the literal '/knowledge/wiki/<category>/*.md' path segment,
  # so a sandbox path exercises it without touching the real wiki. BRAIN_DIR is
  # sandboxed so the tombstone auto-restore branch reads an empty archive log (no mv).
  WPAGE="$TMPD/knowledge/wiki/state/guard-liveness-probe.md"
  ep=$(printf '%s' "$WPAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  run_wwg() { printf '%s' "$1" | HOME="$SBHOME" BRAIN_DIR="$PBRAIN" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/wiki-write-guard.sh" 2>/dev/null; }
  OUT=$(run_wwg "{\"session_id\":\"guard-liveness-probe\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ep\",\"content\":\"# probe page without frontmatter\"}}")
  check "Write wiki page WITHOUT frontmatter" deny "$OUT" || G=$((G+1))
  OUT=$(run_wwg "{\"session_id\":\"guard-liveness-probe\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ep\",\"content\":\"---\\ntitle: probe\\ntype: state\\n---\\n\\n# probe\\n\"}}")
  check "Write wiki page WITH frontmatter (not over-blocking)" silent "$OUT" || G=$((G+1))
  np=$(printf '%s' "$TMPD/scratch/note.md" | sed 's/\\/\\\\/g; s/"/\\"/g')
  OUT=$(run_wwg "{\"session_id\":\"guard-liveness-probe\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$np\",\"content\":\"no frontmatter here\"}}")
  check "Write non-wiki .md (out of guard scope)" silent "$OUT" || G=$((G+1))
fi
if [ "$G" -eq 0 ]; then echo "VERDICT wiki-write-guard: ARMED"; else echo "VERDICT wiki-write-guard: NOT LIVE ($G failing probe(s))"; TOTAL_FAIL=$((TOTAL_FAIL+1)); fi
echo

# =================================== summary =================================
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "guard-liveness: ALL THREE GUARDS ARMED"
  exit 0
else
  echo "guard-liveness: $TOTAL_FAIL guard(s) NOT LIVE — a silent fail-open is exactly how the 0.33.31 incident class hid; investigate before trusting the safety layer"
  exit 1
fi
