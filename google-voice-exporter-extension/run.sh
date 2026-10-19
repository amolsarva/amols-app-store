#!/bin/bash
# Chrome extension: opens chrome://extensions and this folder. Turn on Developer mode,
# click "Load unpacked", and pick this folder.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
open -a "Google Chrome" "chrome://extensions" 2>/dev/null || echo "Open chrome://extensions in Chrome"
open "$DIR"
echo "In Chrome: Developer mode → Load unpacked → $DIR"
