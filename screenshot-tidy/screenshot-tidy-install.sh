#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  screenshot-tidy-install.sh                                              ║
# ║  Installs the LaunchAgent that runs screenshot-tidy.sh whenever          ║
# ║  ~/Desktop changes. Safe to re-run — it reinstalls cleanly.              ║
# ║                                                                          ║
# ║  Also installs com.amol.screenshot-clipboard — a LaunchAgent that        ║
# ║  ensures macOS always copies screenshots to the clipboard (so you can    ║
# ║  Ctrl-V immediately after any screenshot).                               ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TIDY_SCRIPT="$SCRIPT_DIR/screenshot-tidy.sh"
SETTINGS_SCRIPT="$SCRIPT_DIR/screenshot-settings.sh"
INSTALL_SCRIPT="$HOME/bin/screenshot-tidy.sh"
INSTALL_SETTINGS="$HOME/bin/screenshot-settings.sh"
LABEL="com.amol.screenshot-tidy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if [[ ! -f "$TIDY_SCRIPT" ]]; then
  echo "ERROR: $TIDY_SCRIPT not found"
  exit 1
fi
if [[ ! -f "$SETTINGS_SCRIPT" ]]; then
  echo "ERROR: $SETTINGS_SCRIPT not found"
  exit 1
fi

chmod +x "$TIDY_SCRIPT"
chmod +x "$SETTINGS_SCRIPT"
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$HOME/Desktop/Screenshots" "$HOME/bin"
install -m 755 "$TIDY_SCRIPT" "$INSTALL_SCRIPT"
install -m 755 "$SETTINGS_SCRIPT" "$INSTALL_SETTINGS"

"$INSTALL_SETTINGS"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_SCRIPT</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>$HOME/Desktop</string>
  </array>
  <key>StartInterval</key><integer>30</integer>
  <key>ThrottleInterval</key><integer>3</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/screenshot-tidy.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/screenshot-tidy.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo
echo "Installed $LABEL"
echo "  Script:  $INSTALL_SCRIPT"
echo "  Plist:   $PLIST"
echo "  Watches: $HOME/Desktop"
echo "  Target:  $HOME/Desktop/Screenshots"
echo "  Log:     $LOG_DIR/screenshot-tidy.log"
echo
echo "Take a screenshot (Cmd+Shift+3) to test. It should land in"
echo "~/Desktop/Screenshots."

# ─────────────────────────────────────────────────────────────────────────────
# 2.  Screenshot settings
#     Keeps screenshots landing in ~/Desktop/Screenshots and copying to the
#     clipboard automatically.
# ─────────────────────────────────────────────────────────────────────────────
CLIP_LABEL="com.amol.screenshot-clipboard"
CLIP_PLIST="$HOME/Library/LaunchAgents/$CLIP_LABEL.plist"

echo "Enabling screenshot location and clipboard settings..."

# Install a LaunchAgent so the setting is re-applied on every login
# (guards against macOS updates or other tooling resetting the preference)
cat > "$CLIP_PLIST" <<CLIP_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$CLIP_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_SETTINGS</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/screenshot-clipboard.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/screenshot-clipboard.err</string>
</dict>
</plist>
CLIP_PLIST

launchctl bootout "gui/$(id -u)" "$CLIP_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$CLIP_PLIST"
launchctl kickstart -k "gui/$(id -u)/$CLIP_LABEL"

echo
echo "Installed $CLIP_LABEL"
echo "  Plist:   $CLIP_PLIST"
echo "  Effect:  screenshots land in ~/Desktop/Screenshots and copy to clipboard on every login"
echo "  Tip:     take a screenshot (Cmd+Shift+3 or Cmd+Shift+4) then Ctrl-V to paste"
