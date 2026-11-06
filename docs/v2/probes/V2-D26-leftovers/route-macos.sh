launchctl bootout "gui/$(id -u)/sb-extract-drain"
rm -f ~/Library/LaunchAgents/sb-extract-drain.plist
rm -f ~/.second-brain/bin/buddy-statusline.sh ~/.second-brain/bin/sb-extract-drain.sh ~/.second-brain/.extract-timer-env
