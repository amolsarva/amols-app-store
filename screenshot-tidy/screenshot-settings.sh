#!/bin/bash
# Keep macOS screenshot preferences pointed at the tidy screenshots folder.
set -uo pipefail

TARGET="$HOME/Desktop/Screenshots"

mkdir -p "$TARGET"
/usr/bin/defaults write com.apple.screencapture location "$TARGET"
/usr/bin/defaults write com.apple.screencapture copy-to-clipboard -bool true
/usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
