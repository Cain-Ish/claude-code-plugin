#!/bin/bash
# config-change-guard.sh — ConfigChange hook (audit-only).
#
# Closes G-HOOK-3 (wiki/security/plugin-hardening-gap-analysis-2026-05-28.md):
# previously mid-session edits to settings.json were not observed by the
# plugin. An adversarial skill could rewrite permissions or hook config and
# the session would proceed with the broader surface. This hook records
# every ConfigChange event to audit-log.jsonl so /second-brain:audit can
# surface them post-hoc.
#
# Scope: audit-only. Does NOT block.
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

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r' || true)
# Field-name fallback: Anthropic's ConfigChange JSON shape is documented at
# the matcher-category level but not the field-name level (as of 2026-05-28
# the only authoritative reference is the hook-output behavior). Try a few
# plausible names so an audit row still classifies correctly if the payload
# differs from the "source"/"file_path" guess used initially.
SOURCE=$(printf '%s' "$RAW" | jq -r '
  .source // .matcher // .category // .config_source // empty
' 2>/dev/null || true)
FILE_PATH=$(printf '%s' "$RAW" | jq -r '
  .file_path // .path // .config_file // .target // empty
' 2>/dev/null || true)

# extra payload: preserve the WHOLE raw event for forensics so a later
# Anthropic doc update can be cross-referenced against historical audit
# rows. Capped via the audit-log's own line-length defenses upstream.
EXTRA=$(printf '%s' "$RAW" | jq -c '.' 2>/dev/null || echo '{}')

REASON="ConfigChange observed: source=${SOURCE:-?} file=${FILE_PATH:-?}"
sb_log_audit "config-change-guard.sh" "flag" "config-change:${SOURCE:-unknown}" "${FILE_PATH:-}" "$REASON" "$SESSION_ID" "$EXTRA"

exit 0
