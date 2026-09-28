#!/bin/bash
# Avinstallerar raw-backup. Rör inte USB-minnet eller dina inställningar.
set -uo pipefail
LABEL="se.westruplabs.raw-backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
rm -f "$PLIST" "$HOME/Library/Scripts/raw-backup.sh"
echo "✓ raw-backup avinstallerat."
echo "  Inställningar och loggar ligger kvar: ~/.config/raw-backup.conf, ~/Library/Logs/raw-backup*.log"
