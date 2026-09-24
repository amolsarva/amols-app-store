#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${SUNLIGHT_BUILD_DIR:-$HOME/Library/Caches/sunlight-build}"
swift build --package-path "$DIR" -c release --scratch-path "$BUILD"
BIN="$(swift build --package-path "$DIR" -c release --scratch-path "$BUILD" --show-bin-path)/Sunlight"
APP="$BUILD/Sunlight.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sunlight"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$DIR/Resources/Sunlight.icns" ]; then
  cp "$DIR/Resources/Sunlight.icns" "$APP/Contents/Resources/Sunlight.icns"
fi
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --sign - "$APP"
mkdir -p "$DIR/dist"
if [ -d "$DIR/dist/Sunlight.app" ] && [ ! -L "$DIR/dist/Sunlight.app" ]; then
  mv "$DIR/dist/Sunlight.app" "$DIR/dist/Sunlight-previous-$(date +%s).app"
fi
ln -sfn "$APP" "$DIR/dist/Sunlight.app"
printf 'Built %s\n' "$APP"
