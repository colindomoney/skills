#!/bin/bash
# Daily Hermes backup: keeps 3 zips on this Mac and 14 days on the NAS.
# Silent on success; a failure exits non-zero and shows in `hermes cron list`.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
D="$HOME/Backups/hermes"
R="nas-hermes:/share/ServerBackups/hermes-dev/$(hostname -s)"
mkdir -p "$D"

hermes backup -o "$D/hermes-backup-$(date +%F-%H%M%S).zip" -k 3 >/dev/null || exit 1
rclone copy "$D" "$R" --include 'hermes-backup-*.zip' || exit 1
rclone delete --min-age 14d "$R"
