#!/bin/bash
# Builds Backstage.app, installs it to ~/Applications, and (with --pkg) makes an installer.
#
#   ./build.sh          build + install to ~/Applications
#   ./build.sh --pkg    also build dist/Backstage-<version>.pkg for another Mac
#   ./build.sh --dmg    also build dist/Backstage-<version>.dmg + dist/latest.json (upload both to
#                       amolsarva.com/downloads/backstage/ — release.sh does it; running copies auto-update from latest.json)
#
# Build products go to ~/Library/Caches (NOT iCloud) so thousands of build files don't sync.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="1.4"
SCRATCH="$HOME/Library/Caches/backstage-build"
APP="${BACKSTAGE_APP_OVERRIDE:-$HOME/Applications/Backstage.app}"
# Build number = newest source mtime; the app compares it with the source folder / latest.json to self-update.
BUILD=$(stat -f %m Package.swift build.sh Sources/Backstage/*.swift | sort -n | tail -1)

echo "==> Compiling"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Backstage"

echo "==> Making the app icon"
swift ../supporting-files/icons/make-app-icon.swift "$SCRATCH/AppIcon.icns" terminal.fill "#6D5BD0" "#2B2254" gearshape.2.fill >/dev/null

echo "==> Assembling $APP"
rm -rf "$APP" 2>/dev/null || {
  echo "Could not remove $APP (probably owned by root from opening the .pkg installer)." >&2
  echo "Run this once, then retry: sudo chown -R \"\$(whoami)\":staff \"$APP\"" >&2
  exit 1
}
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
  <key>BackstageBuild</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
touch "$APP"
echo "Installed $APP"

if [[ " $* " == *" --pkg "* ]]; then
  echo "==> Building installer package"
  # A plain `pkgbuild --install-location /` package installs system-wide to /Applications when run
  # as admin, but Installer.app silently offers a no-password "install for me only" for a package
  # like this with no distribution.xml — and that lands in ~/Applications instead, owned by root
  # (installd always runs the payload copy as root). Two different Applications folders, and Finder's
  # "Applications" favorite only shows /Applications, so the app looks like it never installed.
  # Fix: a distribution.xml that *only* offers the current-user-home domain. Then there's one
  # possible destination (~/Applications, matching build.sh above and the self-updater), Installer
  # doesn't ask for a password, and the installed files are owned by the person running it, not root.
  STAGE="$SCRATCH/pkgroot"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/Backstage.app"
  mkdir -p dist
  pkgbuild --root "$STAGE" \
           --identifier co.sarva.backstage \
           --version "$VERSION" \
           --install-location "Applications" \
           "$SCRATCH/Backstage-component.pkg" >/dev/null
  cat > "$SCRATCH/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Backstage</title>
    <options customize="never" require-scripts="false" rootVolumeOnly="false"/>
    <domains enable_localSystem="false" enable_currentUserHome="true" enable_anywhere="false"/>
    <choices-outline>
        <line choice="co.sarva.backstage"/>
    </choices-outline>
    <choice id="co.sarva.backstage" visible="false">
        <pkg-ref id="co.sarva.backstage"/>
    </choice>
    <pkg-ref id="co.sarva.backstage" version="$VERSION" onConclusion="none">Backstage-component.pkg</pkg-ref>
</installer-gui-script>
XML
  productbuild --distribution "$SCRATCH/distribution.xml" \
               --package-path "$SCRATCH" \
               "dist/Backstage-$VERSION.pkg" >/dev/null
  echo "Built dist/Backstage-$VERSION.pkg — installs to ~/Applications only, no password, no root-owned files (unsigned: right-click → Open the first time)."
fi

if [[ " $* " == *" --dmg "* ]]; then
  echo "==> Building disk image"
  mkdir -p dist
  DMG="dist/Backstage-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname Backstage -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
  SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
  cat > dist/latest.json <<JSON
{"version": "$VERSION", "build": $BUILD, "dmg": "Backstage-$VERSION.dmg", "sha256": "$SHA"}
JSON
  echo "Built $DMG and dist/latest.json (supporting-files/publish/release.sh publishes them to amolsarva.com/downloads/backstage/)"
fi
