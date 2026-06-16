#!/usr/bin/env bash
# Install (or remove) the WHOOP background engine + menu-bar app at login.
#   ./scripts/install-login-item.sh         install + start now
#   ./scripts/install-login-item.sh remove  stop + uninstall
#
# Installs a LaunchAgent that runs the headless engine (`serve`: the local API + auto-sync),
# and registers the native "WHOOP Widget.app" (which owns the menu bar) as a login item.
set -euo pipefail

LABEL="com.lawrencetang.whoop"
APP_NAME="WHOOP Widget"
APP_PATH="/Applications/$APP_NAME.app"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$PROJECT_DIR/.venv/bin/python"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-install}" == "remove" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  osascript -e "tell application \"System Events\" to delete login item \"$APP_NAME\"" 2>/dev/null || true
  echo "Removed $LABEL and the $APP_NAME login item."
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
        <string>-m</string>
        <string>whoop_dashboard</string>
        <string>serve</string>
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

# Register the native menu-bar app as a login item (and launch it now) if it's installed.
if [[ -d "$APP_PATH" ]]; then
  osascript -e "tell application \"System Events\" to if not (exists login item \"$APP_NAME\") then make new login item at end with properties {path:\"$APP_PATH\", hidden:true}" 2>/dev/null || true
  open "$APP_PATH" 2>/dev/null || true
  echo "Registered $APP_NAME as a login item (and launched it)."
else
  echo "Note: $APP_PATH not found — build/copy the native app there so the menu bar appears at login."
fi

echo "Installed $LABEL — the headless WHOOP engine will start at login (and just started now)."
echo "Logs: /tmp/whoop-dashboard.{out,err}.log"
echo "To remove: ./scripts/install-login-item.sh remove"
