#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  build_app.sh — packages the Mac Scripts launcher as a double-clickable
#  "Mac Scripts Launcher.app" (in /Applications, or ~/Applications if that isn't writable).
#
#  One launcher, one source: the app runs ../supporting-files/launcher.py straight from this
#  repo (so it is never stale), with a bundled copy only as a fallback when the repo is missing.
#  Python comes from ../python-guard (a python3 with Tk; installs python-tk after Homebrew upgrades).
#
#    ./build_app.sh               build + install, then offer to launch it
#    ./build_app.sh --no-launch   build + install only (what the release pipeline uses)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="Mac Scripts Launcher"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LAUNCHER_PY="$REPO/supporting-files/launcher.py"
BUILD_DIR="$HOME/Library/Caches/mac-scripts-launcher-build"   # not iCloud
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
NO_LAUNCH=0; [[ " $* " == *" --no-launch "* || -n "${MAC_SCRIPTS_NONINTERACTIVE:-}" || ! -t 0 ]] && NO_LAUNCH=1

echo "🔨  Building $APP_NAME.app …"
/bin/bash "$REPO/python-guard/pyenv.sh" find --tk >/dev/null || echo "⚠️  no python3 with Tk yet; the app will offer the fix when opened"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/fallback/supporting-files/catalog"
cp "$LAUNCHER_PY" "$APP_BUNDLE/Contents/Resources/fallback/supporting-files/launcher.py"
cp "$REPO/supporting-files/catalog/launcher.json" "$APP_BUNDLE/Contents/Resources/fallback/supporting-files/catalog/" 2>/dev/null || true
cp "$REPO/python-guard/pyenv.sh" "$APP_BUNDLE/Contents/Resources/pyenv.sh"
cp "$HERE/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
printf '%s\n' "$REPO" > "$APP_BUNDLE/Contents/Resources/repo-path"

cat > "$APP_BUNDLE/Contents/MacOS/$APP_NAME" << 'STUB'
#!/bin/bash
# Mac Scripts Launcher.app stub: run the live launcher from the repo; fall back to the bundled copy.
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
REPO="$(cat "$RES/repo-path" 2>/dev/null)"
for cand in "$REPO" "$HOME/Documents/root/mac-scripts"; do
  [ -f "$cand/supporting-files/launcher.py" ] && { REPO="$cand"; break; }
done
if [ -f "$REPO/supporting-files/launcher.py" ]; then
  export MAC_SCRIPTS_DIR="$REPO"; SCRIPT="$REPO/supporting-files/launcher.py"
  GUARD="$REPO/python-guard/pyenv.sh"; [ -f "$GUARD" ] || GUARD="$RES/pyenv.sh"
else
  export MAC_SCRIPTS_DIR="$RES/fallback"; SCRIPT="$RES/fallback/supporting-files/launcher.py"; GUARD="$RES/pyenv.sh"
fi
exec /bin/bash "$GUARD" exec --tk -- "$SCRIPT"
STUB
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>Mac Scripts Launcher</string>
    <key>CFBundleDisplayName</key>      <string>Mac Scripts Launcher</string>
    <key>CFBundleIdentifier</key>       <string>co.sarva.mac-scripts-launcher</string>
    <key>CFBundleVersion</key>          <string>2.0</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleExecutable</key>       <string>Mac Scripts Launcher</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>11.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

DEST_DIR="/Applications"; [ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"; DEST="$DEST_DIR/$APP_NAME.app"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"
/usr/bin/xattr -cr "$DEST" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
echo "✅  Installed $DEST (runs the launcher straight from $REPO)"

if [[ $NO_LAUNCH -eq 0 ]]; then
  read -r -p "Launch it now? [Y/n] " yn
  [[ "$yn" != "n" && "$yn" != "N" ]] && open "$DEST"
fi
