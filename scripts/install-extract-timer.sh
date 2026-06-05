#!/bin/bash
# install-extract-timer.sh — install/print/uninstall the systemd user timer
# that runs extract-drain.sh out-of-band.
#
#   (no flag)     print the rendered units + commands; touch nothing.
#   --apply       write units, daemon-reload, enable+start the timer.
#   --uninstall   disable+stop the timer and remove the unit files.
#
# Linger (loginctl enable-linger) is printed for the user to run, never run
# silently — it is a host-state change.
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

render_service() {
  if [ "$VARIANT_SVC" = "sb-extract-drain-oauth.service" ]; then
    echo "# NOTE: --oauth grants this background service read/write of ~/.claude (your OAuth credentials)." >&2
  fi
  sed "s#@EXEC@#bash $DRAINER#g" "$TPL_DIR/$VARIANT_SVC"
}

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
