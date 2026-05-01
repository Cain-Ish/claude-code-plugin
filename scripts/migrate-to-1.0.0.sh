#!/bin/bash
# 1.0.0 migration: wipe reflection runtime, reset learnings.md.
# Idempotent: no-op if .installed-version is already 1.0.0.
# Persona condensation (persona.md -> USER.md) is interactive and lives in
# the upgrade skill body, not here. This script does NOT update
# .installed-version — the upgrade skill's marker step does that.
# user-instruction-anchor: "1"
set -u
BRAIN="$HOME/.second-brain"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$BRAIN/.0.7.0-backup/$TS"

INSTALLED=$(cat "$BRAIN/.installed-version" 2>/dev/null || echo "0.0.0")
if [ "$INSTALLED" = "1.0.0" ]; then echo "already 1.0.0; no-op"; exit 0; fi

mkdir -p "$BACKUP"
for f in .pending-reflections.jsonl .learnings-hot.md .compact-count \
         friction-log.jsonl drift-log.jsonl error-log.jsonl \
         critic-log.jsonl doubt-history.jsonl; do
  [ -e "$BRAIN/$f" ] && mv "$BRAIN/$f" "$BACKUP/"
done
[ -d "$BRAIN/.reflection-context" ] && mv "$BRAIN/.reflection-context" "$BACKUP/"

[ -e "$BRAIN/learnings.md" ] && cp "$BRAIN/learnings.md" "$BACKUP/"

cat > "$BRAIN/learnings.md" <<'EOF'
# Learned Patterns

Strategic principles distilled from coding sessions. Read at session start.
Each entry captures what worked, what failed, and actionable guidance.
EOF

echo "Backup at: $BACKUP"
echo "Persona condensation runs in upgrade skill (interactive)."
echo "1.0.0 migration runtime steps complete."
