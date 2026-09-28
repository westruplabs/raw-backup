#!/bin/bash
# Uninstalls raw-backup. Leaves your drives, config and logs untouched.
set -uo pipefail
LABEL="se.westruplabs.raw-backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
rm -f "$PLIST" "$HOME/Library/Scripts/raw-backup.sh"
echo "✓ raw-backup uninstalled."
echo "  Config and logs are kept: ~/.config/raw-backup.conf, ~/Library/Logs/raw-backup*.log"
