#!/bin/bash
# Install cpu-guard as a per-user LaunchAgent that starts at login.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
GUARD_SCRIPT="$SCRIPT_DIR/cpu_guard.py"
INSTALL_SCRIPT="$HOME/bin/cpu_guard.py"
LABEL="com.amol.cpu-guard"
OLD_LABEL="com.user.cpuguard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if [[ ! -f "$GUARD_SCRIPT" ]]; then
  echo "ERROR: $GUARD_SCRIPT not found"
  exit 1
fi

# Python comes from python-guard: a private venv OUTSIDE iCloud
# (~/Library/Application Support/python-guard/venvs/cpu-guard). python-guard rebuilds it whenever
# Homebrew moves to a new Python and then restarts this agent, so it never points at a dead Python.
# (Until 2026-10-17 the venv lived in iCloud next to this script; evictions and upgrades broke it.)
GUARD="$SCRIPT_DIR/../python-guard/pyenv.sh"
PYTHON_BIN="$(/bin/bash "$GUARD" venv cpu-guard --pkg psutil --restart "$LABEL")" || {
  echo "ERROR: could not build cpu-guard's Python environment. See: $SCRIPT_DIR/../python-guard/run.sh doctor"; exit 1; }
if ! "$PYTHON_BIN" -c 'import psutil; psutil.cpu_percent()' >/dev/null 2>&1; then
  echo "ERROR: psutil does not import from $PYTHON_BIN. See ~/Library/Logs/python-guard.log"; exit 1
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
    <key>CPU_GUARD_ACTION</key><string>${CPU_GUARD_ACTION:-notify}</string>
    <key>CPU_GUARD_NOTIFY_EVENTS</key><string>${CPU_GUARD_NOTIFY_EVENTS:-action,error}</string>
    <key>CPU_GUARD_CPU_LIMIT</key><string>${CPU_GUARD_CPU_LIMIT:-100}</string>
    <key>CPU_GUARD_DURATION</key><string>${CPU_GUARD_DURATION:-7200}</string>
    <key>CPU_GUARD_INTERVAL</key><string>${CPU_GUARD_INTERVAL:-5}</string>
    <key>CPU_GUARD_ACTION_COOLDOWN</key><string>${CPU_GUARD_ACTION_COOLDOWN:-21600}</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG_DIR/cpu-guard.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/cpu-guard.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

# This script exists to replace the old, broken com.user.cpuguard agent (it
# points at paths that moved in the 2026-09-17 reorg). Now that the new one
# is confirmed running, retire the old one instead of leaving it to keep
# failing and restarting forever in the background.
if [[ -f "$OLD_PLIST" ]]; then
  launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || true
  rm -f "$OLD_PLIST"
  echo "Removed old broken agent: $OLD_LABEL"
fi

# The pre-2026-10-17 venv lived in iCloud next to this script; nothing uses it any more.
if [[ -d "$SCRIPT_DIR/.venv" ]]; then
  mv "$SCRIPT_DIR/.venv" "$HOME/.Trash/cpu-guard-old-icloud-venv-$(date +%s)" 2>/dev/null && echo "Moved the old in-iCloud venv to the Trash"
fi

echo
echo "Installed $LABEL"
echo "  Script: $INSTALL_SCRIPT"
echo "  Plist:  $PLIST"
echo "  Logs:   $LOG_DIR/cpu-guard.out and $LOG_DIR/cpu-guard.err"
echo "  Mode:   ${CPU_GUARD_ACTION:-notify} (flags a process after ${CPU_GUARD_CPU_LIMIT:-100}% of one core for ${CPU_GUARD_DURATION:-7200}s); notifications: ${CPU_GUARD_NOTIFY_EVENTS:-action,error}"
echo "  Report + Notify/Kill toggle: cpu-guard-report.sh (also pops up by itself every 50th notification)"
echo "  A mode chosen in that popup is saved in ~/.config/cpu-guard/config.json and wins over these defaults."
