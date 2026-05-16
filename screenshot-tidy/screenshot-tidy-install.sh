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
LABEL="com.amol.screenshot-tidy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if [[ ! -f "$TIDY_SCRIPT" ]]; then
  echo "ERROR: $TIDY_SCRIPT not found"
  exit 1
fi

chmod +x "$TIDY_SCRIPT"
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$HOME/Desktop/Screenshots"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-l</string>
    <string>$TIDY_SCRIPT</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>$HOME/Desktop</string>
  </array>
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
echo "  Script:  $TIDY_SCRIPT"
echo "  Plist:   $PLIST"
echo "  Watches: $HOME/Desktop"
echo "  Target:  $HOME/Desktop/Screenshots"
echo "  Log:     $LOG_DIR/screenshot-tidy.log"
echo
echo "Take a screenshot (Cmd+Shift+3) to test. It should move into"
echo "~/Desktop/Screenshots within a few seconds."

# ─────────────────────────────────────────────────────────────────────────────
# 2.  Screenshot → Clipboard setting
#     Sets macOS to copy every screenshot to the clipboard automatically,
#     so you can Ctrl-V immediately after taking one.
# ─────────────────────────────────────────────────────────────────────────────
CLIP_LABEL="com.amol.screenshot-clipboard"
CLIP_PLIST="$HOME/Library/LaunchAgents/$CLIP_LABEL.plist"

echo "Enabling 'copy screenshot to clipboard'..."

# Apply immediately
defaults write com.apple.screencapture copy-to-clipboard -bool true
killall SystemUIServer 2>/dev/null || true

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
    <string>/usr/bin/defaults</string>
    <string>write</string>
    <string>com.apple.screencapture</string>
    <string>copy-to-clipboard</string>
    <string>-bool</string>
    <string>true</string>
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
echo "  Effect:  screenshots are now copied to clipboard on every login"
echo "  Tip:     take a screenshot (Cmd+Shift+3 or Cmd+Shift+4) then Ctrl-V to paste"
