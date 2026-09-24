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
VENV_DIR="$SCRIPT_DIR/.venv"

if [[ ! -f "$GUARD_SCRIPT" ]]; then
  echo "ERROR: $GUARD_SCRIPT not found"
  exit 1
fi

# Homebrew's python3 is an externally-managed environment (PEP 668) — a bare
# `pip install --user psutil` against it always fails. Use a private venv next
# to this script instead, so this step is self-contained and actually installs
# rather than just printing instructions.
SYSTEM_PYTHON="$(command -v python3)"
if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
  echo "Creating venv at $VENV_DIR ..."
  "$SYSTEM_PYTHON" -m venv "$VENV_DIR"
fi

if ! "$VENV_DIR/bin/python3" -c 'import psutil, psutil.cpu_percent' >/dev/null 2>&1; then
  echo "Installing psutil into $VENV_DIR ..."
  "$VENV_DIR/bin/python3" -m pip install --quiet --upgrade pip psutil
fi

# Verify the install actually works. A stale/corrupted venv (e.g. an evicted
# iCloud placeholder — 0 bytes on disk despite reporting a real size) can look
# installed but fail to import; rebuild once from scratch before giving up.
if ! "$VENV_DIR/bin/python3" -c 'import psutil; psutil.cpu_percent()' >/dev/null 2>&1; then
  echo "psutil install looks broken (corrupt venv?) — rebuilding venv from scratch ..."
  rm -rf "$VENV_DIR"
  "$SYSTEM_PYTHON" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python3" -m pip install --quiet --upgrade pip psutil
fi

if ! "$VENV_DIR/bin/python3" -c 'import psutil; psutil.cpu_percent()' >/dev/null 2>&1; then
  echo "ERROR: psutil still doesn't import cleanly from $VENV_DIR after a rebuild."
  echo "Run manually to see the real error: $VENV_DIR/bin/python3 -m pip install --upgrade psutil"
  exit 1
fi

PYTHON_BIN="$VENV_DIR/bin/python3"

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

# This script exists to replace the old, broken com.user.cpuguard agent (it
# points at paths that moved in the 2026-09-17 reorg). Now that the new one
# is confirmed running, retire the old one instead of leaving it to keep
# failing and restarting forever in the background.
if [[ -f "$OLD_PLIST" ]]; then
  launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || true
  rm -f "$OLD_PLIST"
  echo "Removed old broken agent: $OLD_LABEL"
fi

echo
echo "Installed $LABEL"
echo "  Script: $INSTALL_SCRIPT"
echo "  Plist:  $PLIST"
echo "  Logs:   $LOG_DIR/cpu-guard.out and $LOG_DIR/cpu-guard.err"
echo "  Mode:   ${CPU_GUARD_ACTION:-kill}; notifications: ${CPU_GUARD_NOTIFY_EVENTS:-action,error}"
