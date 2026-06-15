#!/usr/bin/env bash
# Install (or remove) a LaunchAgent so the WHOOP menu-bar app starts at login.
#   ./scripts/install-login-item.sh         install + start now
#   ./scripts/install-login-item.sh remove  stop + uninstall
set -euo pipefail

LABEL="com.lawrencetang.whoop"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$PROJECT_DIR/.venv/bin/python"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-install}" == "remove" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

if [[ ! -x "$PY" ]]; then
  echo "Virtualenv python not found at $PY — run the install steps in README.md first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$PROJECT_DIR/run.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/whoop-dashboard.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/whoop-dashboard.err.log</string>
</dict>
</plist>
PLIST

# Reload cleanly (bootout first if it's already registered), then start.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installed $LABEL — the WHOOP menu-bar app will start at login (and just started now)."
echo "Logs: /tmp/whoop-dashboard.{out,err}.log"
echo "To remove: ./scripts/install-login-item.sh remove"
