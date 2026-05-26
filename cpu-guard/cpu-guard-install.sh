#!/bin/bash
# Install cpu-guard as a per-user LaunchAgent that starts at login.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
GUARD_SCRIPT="$SCRIPT_DIR/cpu_guard.py"
INSTALL_SCRIPT="$HOME/bin/cpu_guard.py"
LABEL="com.amol.cpu-guard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if [[ ! -f "$GUARD_SCRIPT" ]]; then
  echo "ERROR: $GUARD_SCRIPT not found"
  exit 1
fi

PYTHON_BIN="$(command -v python3)"
if ! "$PYTHON_BIN" -c 'import psutil' >/dev/null 2>&1; then
  echo "ERROR: psutil is not installed for $PYTHON_BIN"
  echo "Install it with: $PYTHON_BIN -m pip install --user psutil"
  exit 1
fi

chmod +x "$GUARD_SCRIPT"
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$HOME/bin"
install -m 755 "$GUARD_SCRIPT" "$INSTALL_SCRIPT"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON_BIN</string>
    <string>$INSTALL_SCRIPT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CPU_GUARD_ACTION</key><string>${CPU_GUARD_ACTION:-kill}</string>
    <key>CPU_GUARD_NOTIFY_EVENTS</key><string>${CPU_GUARD_NOTIFY_EVENTS:-action,error}</string>
    <key>CPU_GUARD_CPU_LIMIT</key><string>${CPU_GUARD_CPU_LIMIT:-80}</string>
    <key>CPU_GUARD_DURATION</key><string>${CPU_GUARD_DURATION:-30}</string>
    <key>CPU_GUARD_INTERVAL</key><string>${CPU_GUARD_INTERVAL:-5}</string>
    <key>CPU_GUARD_ACTION_COOLDOWN</key><string>${CPU_GUARD_ACTION_COOLDOWN:-1800}</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG_DIR/cpu-guard.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/cpu-guard.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo
echo "Installed $LABEL"
echo "  Script: $INSTALL_SCRIPT"
echo "  Plist:  $PLIST"
echo "  Logs:   $LOG_DIR/cpu-guard.out and $LOG_DIR/cpu-guard.err"
echo "  Mode:   ${CPU_GUARD_ACTION:-kill}; notifications: ${CPU_GUARD_NOTIFY_EVENTS:-action,error}"
