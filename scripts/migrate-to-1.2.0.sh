#!/bin/bash
# 1.2.0 migration: ensure ## Intent section is present in USER.md.
# Idempotent: no-op if .installed-version is already 1.2.0 OR if USER.md
# already contains a `## Intent` heading. Does NOT update
# .installed-version — the upgrade skill's marker step does that.
# user-instruction-anchor: "intent-injection"
set -u
BRAIN="$HOME/.second-brain"
USER_FILE="$BRAIN/USER.md"

INSTALLED=$(cat "$BRAIN/.installed-version" 2>/dev/null || echo "0.0.0")
if [ "$INSTALLED" = "1.2.0" ]; then echo "already 1.2.0; no-op"; exit 0; fi

if [ ! -f "$USER_FILE" ]; then
  echo "USER.md missing at $USER_FILE — run the setup skill first; nothing to migrate"
  exit 0
fi

if grep -q '^## Intent$' "$USER_FILE"; then
  echo "USER.md already contains ## Intent section; no-op"
  exit 0
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$BRAIN/.1.2.0-backup/$TS"
mkdir -p "$BACKUP_DIR"
cp "$USER_FILE" "$BACKUP_DIR/USER.md"

# Append the Intent block. Leading newline guards against a USER.md that
# does not end with one.
{
  printf '\n## Intent\n'
  printf 'For substantive requests (anything beyond a one-verb-on-one-noun edit), before answering:\n'
  printf '1. Extract 3-5 keywords from the request (domain, action, surface).\n'
  printf '2. Run the `second-brain:query` skill on those keywords. Read top 1-2 hits in full. Look for prior decisions, design plans, conventions, blockers, and restrictions the user has not restated.\n'
  printf '3. Generate the followups a senior colleague would ask — adapted to this specific request — e.g., "is there an existing implementation? what tech stack and version? does anything similar already exist? what scope/auth/pagination is implied?".\n'
  printf '4. Answer the followups yourself from retrieved context where possible. Surface only the ones that remain genuinely ambiguous AND costly to guess wrong, as one focused clarifying question.\n'
  printf '5. If the wiki had nothing relevant, say so explicitly so the user knows you checked. Then proceed with your best interpretation.\n'
} >> "$USER_FILE"

echo "Backup at: $BACKUP_DIR"
echo "Appended ## Intent section to $USER_FILE"
echo "1.2.0 migration complete."
