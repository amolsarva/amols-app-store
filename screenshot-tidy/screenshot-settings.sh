#!/bin/bash
# Keep macOS screenshot preferences pointed at the tidy screenshots folder.
set -uo pipefail

TARGET="$HOME/Desktop/Screenshots"

mkdir -p "$TARGET"
/usr/bin/defaults write com.apple.screencapture location "$TARGET"

# Keep the floating thumbnail preview in the corner of the screen.
# NOTE: copy-to-clipboard=true suppresses the thumbnail (the capture goes to the
# clipboard instead of being written to a file). Explicitly turn it off.
/usr/bin/defaults write com.apple.screencapture copy-to-clipboard -bool false
/usr/bin/defaults write com.apple.screencapture show-thumbnail -bool true

/usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
/usr/bin/killall ScreenshotAgent >/dev/null 2>&1 || true
/usr/bin/killall com.apple.screencaptureui >/dev/null 2>&1 || true
