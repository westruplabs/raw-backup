#!/bin/bash
# Installerar raw-backup som en LaunchAgent som startar när en volym monteras.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="se.westruplabs.raw-backup"
SCRIPT_DIR="$HOME/Library/Scripts"
SCRIPT="$SCRIPT_DIR/raw-backup.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF="$HOME/.config/raw-backup.conf"

[ "$(uname)" = "Darwin" ] || { echo "Det här fungerar bara på macOS."; exit 1; }

mkdir -p "$SCRIPT_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.config"
install -m 755 raw-backup.sh "$SCRIPT"
echo "✓ Skript installerat: $SCRIPT"

if [ ! -f "$CONF" ]; then
    cp raw-backup.conf.example "$CONF"
    echo "✓ Inställningar skapade: $CONF"
else
    echo "• Behåller befintliga inställningar: $CONF"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
    </array>
    <key>StartOnMount</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/raw-backup.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/raw-backup.launchd.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ LaunchAgent aktiv: $LABEL"
echo
echo "Klart. Sätt i USB-minnet så startar backupen. Logg: ~/Library/Logs/raw-backup.log"
echo "Testa manuellt:  $SCRIPT --dry-run"
