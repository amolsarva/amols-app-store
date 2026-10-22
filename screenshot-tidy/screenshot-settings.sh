#!/bin/bash
# Keep macOS screenshot preferences pointed at the tidy screenshots folder.
# The folder is resolved at run time (see screenshot-paths.sh) so this works on
# any Mac, whether or not "Desktop & Documents Folders" iCloud sync is on.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=screenshot-paths.sh
source "$HERE/screenshot-paths.sh"

TARGET="$(shot_target)"
mkdir -p "$TARGET"

# Screenshot Mover owns the capture location while it is installed (it saves to
# its own inbox, copies to the clipboard, then files into the same folder).
# Don't fight it.
if /bin/launchctl print "gui/$(id -u)/com.amol.screenshot-mover" >/dev/null 2>&1; then
  echo "Screenshot Mover is running — leaving com.apple.screencapture location alone."
  echo "Screenshots folder: $TARGET"
  exit 0
fi

/usr/bin/defaults write com.apple.screencapture location "$TARGET"

# Keep the floating thumbnail preview in the corner of the screen.
# NOTE: copy-to-clipboard=true suppresses the thumbnail (the capture goes to the
# clipboard instead of being written to a file). Explicitly turn it off.
/usr/bin/defaults write com.apple.screencapture copy-to-clipboard -bool false
/usr/bin/defaults write com.apple.screencapture show-thumbnail -bool true

/usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
/usr/bin/killall ScreenshotAgent >/dev/null 2>&1 || true
/usr/bin/killall com.apple.screencaptureui >/dev/null 2>&1 || true

echo "Screenshots folder: $TARGET"
