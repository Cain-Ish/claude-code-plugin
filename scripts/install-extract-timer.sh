#!/bin/bash
# install-extract-timer.sh — install/print/uninstall the per-OS scheduler that runs
# extract-drain.sh out-of-band: systemd timer (Linux) / launchd LaunchAgent (macOS) /
# Task Scheduler (Windows Git-Bash). OS is auto-detected (override SB_INSTALL_OS_OVERRIDE).
#
#   (no flag)     print the rendered unit + commands; touch nothing.
#   --apply       install + enable the scheduler.
#   --uninstall   disable + remove it.
#   --oauth       (Linux/systemd only) the creds-granting hardened variant. Off Linux
#                 there is no portable sandbox, so the job runs unsandboxed as you and
#                 --oauth is a no-op (printed).
#
# Linger (loginctl enable-linger) is printed for the user to run, never run
# silently — it is a host-state change. macOS has no linger equivalent.
set -u

SDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SDIR/.." && pwd)"
DRAINER="$SDIR/extract-drain.sh"
TPL_DIR="$REPO/systemd"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SVC="sb-extract-drain.service"
TIMER="sb-extract-drain.timer"

# Default = hardened local-only unit; --oauth opts into the creds-granting one.
# Action + variant are parsed from anywhere in the args so `--apply --oauth`,
# `--oauth --apply`, and bare `--oauth` (print) all work.
VARIANT_SVC="$SVC"; ACTION=print
for a in "$@"; do
  case "$a" in
    --oauth)     VARIANT_SVC="sb-extract-drain-oauth.service" ;;
    --apply)     ACTION=apply ;;
    --uninstall) ACTION=uninstall ;;
  esac
done

# The knowledge dir the out-of-band drainer must read/write. In-session (where --apply is
# normally run) Claude Code sets CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR for a custom dir; the
# scheduled job has no such injection, so we capture it at install time. Empty ⇒ default.
INSTALL_KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-}}"

render_service() {
  if [ "$VARIANT_SVC" = "sb-extract-drain-oauth.service" ]; then
    echo "# NOTE: --oauth grants this background service read/write of ~/.claude (your OAuth credentials)." >&2
  fi
  # A custom knowledge dir must be BOTH forwarded (Environment=) and granted in the
  # sandbox (the default unit only grants %h/knowledge) — else the out-of-band extraction
  # AND consolidation operate on the wrong tree / are blocked by ProtectHome.
  if [ -n "$INSTALL_KD" ] && [ "$INSTALL_KD" != "$HOME/knowledge" ]; then
    sed -e "s#@EXEC@#bash $DRAINER#g" \
        -e "s#^ReadWritePaths=.*#&  $INSTALL_KD#" \
        -e "/^Environment=PATH=/a Environment=CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR=$INSTALL_KD" \
        "$TPL_DIR/$VARIANT_SVC"
  else
    sed "s#@EXEC@#bash $DRAINER#g" "$TPL_DIR/$VARIANT_SVC"
  fi
}

# --- OS detection (overridable for tests via SB_INSTALL_OS_OVERRIDE) ----------
OS="${SB_INSTALL_OS_OVERRIDE:-}"
if [ -z "$OS" ]; then
  case "$(uname -s)" in
    Linux)               OS=systemd ;;
    Darwin)              OS=launchd ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)                   OS=unsupported ;;
  esac
fi

# Scheduled jobs (launchd / Task Scheduler) get a MINIMAL env — snapshot the engine
# knobs the user set in their shell so the out-of-band job actually sees them.
env_snapshot() {
  local v val
  # Include the knowledge dir (+ BRAIN_DIR) so the out-of-band consolidation/extraction
  # target the user's actual wiki, not the default ~/knowledge (launchd/windows have no
  # sandbox, so forwarding the var is sufficient there).
  for v in SB_EXTRACTOR_LOCAL_URL SB_EXTRACTOR_LOCAL_MODEL SB_EXTRACTOR_ENGINE ANTHROPIC_BASE_URL ANTHROPIC_API_KEY CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR KNOWLEDGE_DIR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && printf '%s=%s\n' "$v" "$val"
  done
}

LA_LABEL="sb-extract-drain"
LA_PLIST="$HOME/Library/LaunchAgents/$LA_LABEL.plist"
# XML-escape a value going into a plist <string> (a `&` in e.g. ANTHROPIC_BASE_URL's
# query string, or `<`/`>` in a path, would otherwise make the plist invalid XML).
xml_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
la_render() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0"><dict>\n'
  printf '  <key>Label</key><string>%s</string>\n' "$LA_LABEL"
  printf '  <key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array>\n' "$(xml_esc "$DRAINER")"
  printf '  <key>StartInterval</key><integer>1800</integer>\n'
  printf '  <key>RunAtLoad</key><true/>\n'
  printf '  <key>EnvironmentVariables</key><dict>\n'
  printf '    <key>HOME</key><string>%s</string>\n' "$(xml_esc "$HOME")"
  printf '    <key>PATH</key><string>%s</string>\n' "$(xml_esc "${PATH:-/usr/local/bin:/usr/bin:/bin}")"
  env_snapshot | while IFS='=' read -r _k _v; do printf '    <key>%s</key><string>%s</string>\n' "$_k" "$(xml_esc "$_v")"; done
  printf '  </dict>\n</dict></plist>\n'
}
la_note() {
  echo "# macOS: a LaunchAgent runs ONLY while you are logged in (no per-user linger equivalent);"
  echo "#        RunAtLoad gives a catch-up drain at next login."
  echo "# No sandbox off Linux — the job runs unsandboxed as you (so --oauth is a no-op here:"
  echo "#        the job can read ~/.claude regardless)."
}

# Non-Linux schedulers run as a branch before the systemd path (which is unchanged).
if [ "$OS" != "systemd" ]; then
  case "$OS" in
    launchd)
      case "$ACTION" in
        apply)
          mkdir -p "$HOME/Library/LaunchAgents"; la_render > "$LA_PLIST"
          launchctl bootout "gui/$(id -u)/$LA_LABEL" 2>/dev/null || true
          launchctl bootstrap "gui/$(id -u)" "$LA_PLIST" 2>/dev/null || launchctl load -w "$LA_PLIST"
          echo "applied: launchd agent $LA_LABEL installed."; la_note ;;
        uninstall)
          launchctl bootout "gui/$(id -u)/$LA_LABEL" 2>/dev/null || launchctl unload -w "$LA_PLIST" 2>/dev/null || true
          rm -f "$LA_PLIST"; echo "uninstalled: removed $LA_LABEL" ;;
        *)
          echo "# === launchd LaunchAgent (would be written to $LA_PLIST) ==="
          la_render; echo
          echo "# To install:  bash $0 --apply    |    To remove:  bash $0 --uninstall"
          la_note ;;
      esac ;;
    windows)
      WIN_TASK="sb-extract-drain"
      BASH_W=$(cygpath -w "$(command -v bash 2>/dev/null)" 2>/dev/null || echo "bash.exe")
      WIN_TR="\"$BASH_W\" -lc 'exec \"$DRAINER\"'"
      case "$ACTION" in
        apply)
          schtasks /Create /TN "$WIN_TASK" /SC MINUTE /MO 30 /F /TR "$WIN_TR"
          echo "applied: Scheduled Task $WIN_TASK (every 30 min)."
          echo "# No sandbox on Windows — the task runs unsandboxed as you (--oauth no-op)." ;;
        uninstall)
          schtasks /Delete /TN "$WIN_TASK" /F 2>/dev/null || true
          echo "uninstalled: removed task $WIN_TASK" ;;
        *)
          echo "# === Windows Scheduled Task ($WIN_TASK) ==="
          echo "schtasks /Create /TN $WIN_TASK /SC MINUTE /MO 30 /F /TR $WIN_TR"
          echo "# To install:  bash $0 --apply    |    To remove:  bash $0 --uninstall"
          echo "# No sandbox on Windows — the task runs unsandboxed as you." ;;
      esac ;;
    *)
      echo "# Unsupported OS ($(uname -s)) — no out-of-band drainer scheduler available."
      echo "# Frictionless fallback (any OS): export ANTHROPIC_API_KEY=sk-ant-... for in-session capture,"
      echo "# or run '$DRAINER' yourself from cron / a scheduler." ;;
  esac
  exit 0
fi

case "$ACTION" in
  uninstall)
    systemctl --user disable --now "$TIMER" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SVC" "$UNIT_DIR/$TIMER"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "uninstalled: removed $SVC + $TIMER"
    ;;
  apply)
    mkdir -p "$UNIT_DIR"
    render_service > "$UNIT_DIR/$SVC"
    cp "$TPL_DIR/$TIMER" "$UNIT_DIR/$TIMER"
    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER"
    echo "applied: $SVC + $TIMER installed and timer enabled."
    echo "Run this yourself to keep the timer alive without an active login:"
    echo "    loginctl enable-linger \"$USER\""
    ;;
  *)
    echo "# === $SVC (would be written to $UNIT_DIR) ==="
    render_service
    echo
    echo "# === $TIMER ==="
    cat "$TPL_DIR/$TIMER"
    echo
    echo "# To install:   bash $0 --apply"
    echo "# Then run:     loginctl enable-linger \"$USER\""
    echo "# To remove:    bash $0 --uninstall"
    ;;
esac
