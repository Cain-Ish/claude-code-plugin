#!/bin/bash
# config-change-guard.sh — ConfigChange hook (audit-only, v0.21.0).
#
# Closes G-HOOK-3 (wiki/security/plugin-hardening-gap-analysis-2026-05-28.md):
# previously mid-session edits to settings.json were not observed by the
# plugin. An adversarial skill could rewrite permissions or hook config and
# the session would proceed with the broader surface. This hook records
# every ConfigChange event to audit-log.jsonl so /second-brain:audit can
# surface them post-hoc.
#
# Scope (v0.21.0): audit-only. Does NOT block. Future iteration may add
# a deny path for high-risk diffs (e.g. broadening permission rules) once
# we have empirical data on which changes legitimately fire mid-session.
#
# Matcher categories Anthropic emits:
#   user_settings, project_settings, local_settings, policy_settings, skills
#
# Input JSON (typical fields seen in hook docs):
#   { session_id, source (one of the matcher categories), file_path,
#     hook_event_name: "ConfigChange", ... }
#
# Kill switch: SB_CONFIG_CHANGE_AUDIT=off
# Always exits 0. No stdout (audit-only).
set -u

[ "${SB_CONFIG_CHANGE_AUDIT:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0
printf '%s' "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  # Fail-soft no-op: if lib.sh can't be sourced, we can't audit but we
  # must not block the user. Exit silently.
  exit 0
fi

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null || true)
SOURCE=$(printf '%s'    "$RAW" | jq -r '.source      // empty' 2>/dev/null || true)
FILE_PATH=$(printf '%s' "$RAW" | jq -r '.file_path   // empty' 2>/dev/null || true)

# extra payload: keep the raw event JSON for forensics, capped so a runaway
# diff doesn't bloat the audit-log line. jq -c keeps it on one line.
EXTRA=$(printf '%s' "$RAW" | jq -c '{source, file_path, hook_event_name}' 2>/dev/null || echo '{}')

REASON="ConfigChange observed: source=${SOURCE:-?} file=${FILE_PATH:-?}"
sb_log_audit "config-change-guard.sh" "flag" "config-change:${SOURCE:-unknown}" "${FILE_PATH:-}" "$REASON" "$SESSION_ID" "$EXTRA"

exit 0
