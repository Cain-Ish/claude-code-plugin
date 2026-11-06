#!/usr/bin/env bash
# V2-D26's pass conditions, after the route. Usage: verify.sh <route file> <README.md> <snapshot file>
set -u
route=$1 readme=$2 snap=$3
here=$(cd "$(dirname "$0")" && pwd)
w() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
brain="$HOME/.second-brain"
bad=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; bad=1; fi; }

cmd=$(node -e 'console.log(require(process.argv[1]).statusLine?.command ?? "(none)")' "$(w "$HOME/.claude/settings.json")")
check "statusLine is back to 'echo before' (now: $cmd)" '[ "$cmd" = "echo before" ]'
case "$(uname -s)" in
  Linux)
    check "no systemd unit" '! systemctl --user cat sb-extract-drain.timer >/dev/null 2>&1 && ! systemctl --user cat sb-extract-drain.service >/dev/null 2>&1'
    check "no unit files" '[ ! -e ~/.config/systemd/user/sb-extract-drain.timer ] && [ ! -e ~/.config/systemd/user/sb-extract-drain.service ]' ;;
  Darwin)
    check "no LaunchAgent loaded" '! launchctl print "gui/$(id -u)/sb-extract-drain" >/dev/null 2>&1'
    check "no plist" '[ ! -e ~/Library/LaunchAgents/sb-extract-drain.plist ]' ;;
  *)
    check "no scheduled task" '! MSYS_NO_PATHCONV=1 schtasks /Query /TN sb-extract-drain >/dev/null 2>&1'
    check "no .vbs launcher" '[ ! -e "$brain/bin/sb-extract-drain-hidden.vbs" ]' ;;
esac
check "no shims or env file" '[ ! -e "$brain/bin/buddy-statusline.sh" ] && [ ! -e "$brain/bin/sb-extract-drain.sh" ] && [ ! -e "$brain/.extract-timer-env" ]'
after=$(node "$here/datahash.mjs" "$(w "$brain")" "$(w "$HOME/knowledge")")
check "data unchanged ($(cat "$snap") -> $after)" '[ "$after" = "$(cat "$snap")" ]'
check "data not empty" '! grep -q "(0 files)" "$snap"'
while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  check "README holds: $line" 'grep -qF -- "$line" "$readme"'
done < "$route"
[ "$bad" = 0 ] && echo "PROBE PASS" || { echo "PROBE FAIL"; exit 1; }
