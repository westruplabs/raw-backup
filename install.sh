#!/bin/bash
# Installs raw-backup as a LaunchAgent that runs whenever a drive is mounted.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="se.westruplabs.raw-backup"
SCRIPT_DIR="$HOME/Library/Scripts"
SCRIPT="$SCRIPT_DIR/raw-backup.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF="$HOME/.config/raw-backup.conf"

[ "$(uname)" = "Darwin" ] || { echo "This only works on macOS."; exit 1; }

mkdir -p "$SCRIPT_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.config"
install -m 755 raw-backup.sh "$SCRIPT"
echo "✓ Script installed: $SCRIPT"

# ---- Config: ask for the first job if there is no config yet
write_conf() {  # $1 = job line
    awk -v job="$1" -v q="'" '
        index($0, "JOBS=" q) == 1 { print; print job; skip = 1; next }
        skip && substr($0, 1, 1) == q { skip = 0 }
        skip && /^#/ { print; next }
        skip { next }
        { print }' raw-backup.conf.example > "$CONF"
}

if [ -f "$CONF" ]; then
    echo "• Keeping existing config: $CONF"
elif [ -t 0 ]; then
    echo
    echo "Set up your first backup job (you can add more later in $CONF)."
    read -r -p "Folder to back up [~/Pictures]: " src
    src="${src:-~/Pictures}"
    echo "Drives currently connected:"
    ls /Volumes | grep -v '^Macintosh HD' | sed 's/^/    /' || true
    read -r -p "Drive name (as shown in Finder): " vol
    while [ -z "$vol" ]; do read -r -p "Drive name: " vol; done
    src_expanded="${src/#\~/$HOME}"
    read -r -p "Folder on the drive [$(basename "$src_expanded")]: " dir
    dir="${dir:-$(basename "$src_expanded")}"
    write_conf "$src | $vol | $dir"
    echo "✓ Config created: $CONF"
else
    cp raw-backup.conf.example "$CONF"
    echo "✓ Config created from example: $CONF  (edit JOBS before use)"
fi

# ---- LaunchAgent
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
echo "✓ LaunchAgent active: $LABEL"
echo
bash "$SCRIPT" --list || true
echo
echo "Done. Plug in a drive and its jobs start automatically. Log: ~/Library/Logs/raw-backup.log"
echo "Try it first without copying anything:  bash $SCRIPT --dry-run"
echo
echo "IMPORTANT: give /bin/bash Full Disk Access, or macOS will block the background run."
echo "System Settings > Privacy & Security > Full Disk Access > + > Cmd+Shift+G > /bin/bash"
