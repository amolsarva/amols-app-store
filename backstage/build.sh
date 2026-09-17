#!/bin/bash
# Builds Backstage.app, installs it to ~/Applications, and (with --pkg) makes an installer.
#
#   ./build.sh          build + install to ~/Applications
#   ./build.sh --pkg    also build dist/Backstage-<version>.pkg for another Mac
#
# Build products go to ~/Library/Caches (NOT iCloud) so thousands of build files don't sync.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="1.1"
SCRATCH="$HOME/Library/Caches/backstage-build"
APP="$HOME/Applications/Backstage.app"

echo "==> Compiling"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Backstage"

echo "==> Making the app icon"
ICONSET="$SCRATCH/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift tools/make-icon.swift "$SCRATCH/icon-1024.png" >/dev/null
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$SCRATCH/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$SCRATCH/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$SCRATCH/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Backstage"
cp "$SCRATCH/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Backstage</string>
  <key>CFBundleDisplayName</key><string>Backstage</string>
  <key>CFBundleIdentifier</key><string>co.sarva.backstage</string>
  <key>CFBundleExecutable</key><string>Backstage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
touch "$APP"
echo "Installed $APP"

if [ "${1:-}" = "--pkg" ]; then
  echo "==> Building installer package"
  STAGE="$SCRATCH/pkgroot"
  rm -rf "$STAGE"; mkdir -p "$STAGE/Applications"
  cp -R "$APP" "$STAGE/Applications/Backstage.app"
  mkdir -p dist
  pkgbuild --root "$STAGE" \
           --identifier co.sarva.backstage \
           --version "$VERSION" \
           --install-location / \
           "dist/Backstage-$VERSION.pkg"
  echo "Built dist/Backstage-$VERSION.pkg (unsigned: on a new Mac, right-click → Open, or allow it in System Settings ▸ Privacy & Security)"
fi
