#!/bin/bash
# R7 liveness/dormancy gate — "shipped" is not "running". Three independent
# audit findings (CR-001 cost-router never installed, MCP-INTEG-1 bridge
# consumer without producer, MCP-DEPS-1 dangling embeddings) were all ONE
# missing check: does each value artifact actually exist, match the shipped
# version, and show recent life on THIS box?
#
# Output: one line per probe — OK: / DRIFT: / DORMANT: / STALE: / MISSING:.
# Advisory by default (always exit 0); --strict exits 1 when any non-OK line
# fired (release-checklist / CI use). Read-only.
#
# Env (test seams): SB_LIVENESS_MARKETPLACE, SB_LIVENESS_INSTALLED, BRAIN_DIR.
# Bash 3.2 / BSD-safe: paired stat fallbacks, no date -d, no mapfile.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MP="${SB_LIVENESS_MARKETPLACE:-$PLUGIN_ROOT/.claude-plugin/marketplace.json}"
IPJ="${SB_LIVENESS_INSTALLED:-$HOME/.claude/plugins/installed_plugins.json}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

BAD=0
say() { printf '%s\n' "$1"; case "$1" in OK:*) : ;; *) BAD=1 ;; esac; }

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
NOW=$(date +%s)
WEEK=$((7 * 86400))

# ── 1. Deployment: every marketplace plugin installed at the shipped version ─
if [ -f "$MP" ] && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r P_NAME P_VER; do
    [ -n "$P_NAME" ] || continue
    if [ ! -f "$IPJ" ]; then
      say "MISSING: $IPJ not found — cannot verify $P_NAME deployment"
      continue
    fi
    INST_VER=$(jq -r --arg n "$P_NAME" \
      '[.plugins | to_entries[] | select(.key | startswith($n + "@")) | .value[].version] | sort | last // ""' \
      "$IPJ" 2>/dev/null | tr -d '\r')
    if [ -z "$INST_VER" ] || [ "$INST_VER" = "null" ]; then
      say "MISSING: $P_NAME shipped ($P_VER) but not deployed — not in installed_plugins.json"
    elif [ "$INST_VER" != "$P_VER" ]; then
      say "DRIFT: $P_NAME installed $INST_VER vs shipped $P_VER — update the plugin cache"
    else
      say "OK: $P_NAME deployed at $P_VER"
    fi
  done <<EOF_PLUGINS
$(jq -r '.plugins[] | [.name, .version] | @tsv' "$MP" 2>/dev/null | tr -d '\r')
EOF_PLUGINS
else
  say "MISSING: marketplace.json or jq unavailable — deployment probe skipped"
fi

# ── 2. Bridge: cost-router installed → its capture bridge must produce ──────
if [ -f "$IPJ" ] && jq -e '.plugins | keys[] | select(startswith("cost-router@"))' "$IPJ" >/dev/null 2>&1; then
  EV="$BRAIN_DIR/cost-router-events.jsonl"
  if [ ! -f "$EV" ]; then
    say "DORMANT: cost-router installed but $EV never produced (bridge dormant)"
  elif [ $((NOW - $(mtime_of "$EV"))) -gt "$WEEK" ]; then
    say "DORMANT: cost-router bridge stale — last event $(( (NOW - $(mtime_of "$EV")) / 86400 ))d ago"
  else
    say "OK: cost-router bridge producing (events fresh)"
  fi
fi

# ── 3. Episodic indexer keeps up with the transcript archive ────────────────
IDX="$BRAIN_DIR/episodic-index.json"
NEWEST_TX=""
if [ -d "$BRAIN_DIR/transcripts" ]; then
  NEWEST_TX=$(find "$BRAIN_DIR/transcripts" -maxdepth 1 -type f 2>/dev/null \
    | while IFS= read -r f; do printf '%s %s\n' "$(mtime_of "$f")" "$f"; done \
    | sort -rn | head -1 | cut -d' ' -f1)
fi
if [ -n "$NEWEST_TX" ]; then
  if [ ! -f "$IDX" ]; then
    say "STALE: transcripts exist but no episodic-index.json — indexer behind (never ran)"
  elif [ $((NEWEST_TX - $(mtime_of "$IDX"))) -gt $((2 * 86400)) ]; then
    say "STALE: episodic index behind — newest transcript is >2d newer than the index"
  else
    say "OK: episodic index keeping up"
  fi
fi

# ── 4. Embeddings deps: cache symlink must not dangle ───────────────────────
VD="$BRAIN_DIR/vector-deps/node_modules"
if [ -L "$VD" ] || [ -e "$VD" ]; then
  if [ -e "$VD" ]; then
    say "OK: vector-deps node_modules resolves"
  else
    say "MISSING: vector-deps node_modules is a dangling symlink — vector search degraded"
  fi
fi

[ "$STRICT" -eq 1 ] && [ "$BAD" -eq 1 ] && exit 1
exit 0
