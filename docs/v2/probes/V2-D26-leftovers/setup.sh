#!/usr/bin/env bash
# V2-D26's probe, before the route (an ephemeral CI runner; it changes the real home): v1's statusline and timer,
# installed by v1's own code from a cached copy, then D25's move, then the data snapshot.
# Usage: setup.sh <v1 checkout at v1-final> <v2 plugin dir> <snapshot file>
set -eu
v1=$1 v2=$2 snap=$3
here=$(cd "$(dirname "$0")" && pwd)
w() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }   # a path Node on Windows can open
cfg="$HOME/.claude"
cache="$cfg/plugins/cache/second-brain/second-brain"
brain="$HOME/.second-brain"
fail() { echo "PROBE FAIL: $*"; exit 1; }

mkdir -p "$cache" "$brain/wiki" "$HOME/knowledge"
cp -R "$v1/plugin" "$cache/0.57.1"
printf '{\n  "statusLine": { "type": "command", "command": "echo before" }\n}\n' > "$cfg/settings.json"
echo 'a decision v1 kept' > "$brain/wiki/sample.md"
echo 'a note in the knowledge folder' > "$HOME/knowledge/sample.md"

echo "== v1: sb buddy install"
CLAUDE_PLUGIN_ROOT=$(w "$cache/0.57.1") bash "$cache/0.57.1/bin/sb" buddy install
echo "== v1: install-extract-timer.sh --apply"
bash "$cache/0.57.1/scripts/install-extract-timer.sh" --apply

echo "== installed by v1"
cmd=$(node -e 'console.log(require(process.argv[1]).statusLine.command)' "$(w "$cfg/settings.json")")
echo "statusLine: $cmd"
case "$cmd" in *"SB_BUDDY_CHAIN='echo before'"*buddy-statusline.sh*) ;; *) fail "v1's statusLine is not in place" ;; esac
for f in "$brain/bin/buddy-statusline.sh" "$brain/bin/sb-extract-drain.sh" "$brain/.extract-timer-env"; do
  [ -f "$f" ] || fail "missing $f"
done
case "$(uname -s)" in
  Linux) systemctl --user is-enabled sb-extract-drain.timer || fail "no systemd timer" ;;
  Darwin) launchctl print "gui/$(id -u)/sb-extract-drain" > /dev/null || fail "no LaunchAgent" ;;
  *) MSYS_NO_PATHCONV=1 schtasks /Query /TN sb-extract-drain || fail "no scheduled task"
     [ -f "$brain/bin/sb-extract-drain-hidden.vbs" ] || fail "missing the .vbs launcher" ;;
esac

echo "== D25's move: v1's cached copy goes, a v2 copy arrives"
rm -rf "$cache/0.57.1"
cp -R "$v2" "$cache/2.0.0-alpha.5"
out=$(echo '{}' | bash -c "$cmd" 2>&1 || true)
echo "statusline prints: $out"
case "$out" in *"no second-brain renderer found"*) ;; *) fail "the user's case is not reproduced" ;; esac

sleep 30   # let a scheduler run started at install time finish before the snapshot
node "$here/datahash.mjs" "$(w "$brain")" "$(w "$HOME/knowledge")" > "$snap"
echo "== data before the route: $(head -1 "$snap")"
echo "PROBE SETUP OK"
