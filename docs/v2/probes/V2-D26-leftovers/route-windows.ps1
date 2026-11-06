schtasks /Delete /TN sb-extract-drain /F
Remove-Item "$HOME\.second-brain\bin\buddy-statusline.sh", "$HOME\.second-brain\bin\sb-extract-drain.sh", "$HOME\.second-brain\bin\sb-extract-drain-hidden.vbs", "$HOME\.second-brain\.extract-timer-env" -ErrorAction SilentlyContinue
