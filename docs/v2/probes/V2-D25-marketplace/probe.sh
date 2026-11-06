#!/usr/bin/env bash
# V2-D25's probe, one arm: a v1 install from a git stand-in for GitHub, then the stand-in's `main` moved to the arm's
# commit, then the CLI's updates. Usage: probe.sh <bare repo> <its URL> <fresh config dir> <arm commit>
# The commits must already be in the bare repo (git push <bare> <commit>:refs/arm).
set -u
bare=$1 url=$2 cfg=$3 arm=$4
here=$(cd "$(dirname "$0")" && pwd)
R() { CLAUDE_CONFIG_DIR=$cfg env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude "$@"; }
step() { echo "== $*"; }

git -C "$bare" update-ref refs/heads/main 9718ceeb4d12fc717a3c3fa498ce65e58c48032c # v1's release commit, 0.57.1
step add; R plugin marketplace add "$url" --json | tail -1; echo " exit ${PIPESTATUS[0]}"
step install v1; R plugin install second-brain@second-brain --scope user -y --json | tail -1; echo " exit ${PIPESTATUS[0]}"

git -C "$bare" update-ref refs/heads/main "$arm"
step main moved to "$(git -C "$bare" log --oneline -1 main)"
step marketplace update; R plugin marketplace update second-brain --json | tail -1; echo " exit ${PIPESTATUS[0]}"
step plugin update; R plugin update second-brain@second-brain --scope user -y --json | tail -1; echo " exit ${PIPESTATUS[0]}"

step marketplaces; R plugin marketplace list --json
step plugins; R plugin list --json
step known_marketplaces.json; cat "$cfg/plugins/known_marketplaces.json"
step installed_plugins.json; cat "$cfg/plugins/installed_plugins.json"
step cached copies and their product hash
for d in "$cfg"/plugins/cache/*/*/*/; do echo "$d $(node "$here/hash.mjs" "$d")"; done
