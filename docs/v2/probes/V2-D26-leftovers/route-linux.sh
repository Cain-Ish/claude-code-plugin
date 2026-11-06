systemctl --user disable --now sb-extract-drain.timer
rm -f ~/.config/systemd/user/sb-extract-drain.service ~/.config/systemd/user/sb-extract-drain.timer
systemctl --user daemon-reload
rm -f ~/.second-brain/bin/buddy-statusline.sh ~/.second-brain/bin/sb-extract-drain.sh ~/.second-brain/.extract-timer-env
