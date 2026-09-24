#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  build_app.sh — packages launcher.py as a double-clickable
#  Mac Scripts Launcher.app and installs it to /Applications
# ─────────────────────────────────────────────────────────────
set -e

APP_NAME="Mac Scripts Launcher"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_PY="$SCRIPT_DIR/launcher.py"
BUILD_DIR="$SCRIPT_DIR/build_tmp"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨  Building $APP_NAME.app …"
echo ""

# ── 1. Find python3 ──────────────────────────────────────────
PYTHON=$(which python3 2>/dev/null || which python 2>/dev/null)
if [ -z "$PYTHON" ]; then
    echo "✗  python3 not found. Install it from https://python.org"
    exit 1
fi
echo "✓  Using Python: $PYTHON ($($PYTHON --version 2>&1))"

# ── 2. Create the .app bundle structure ──────────────────────
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# ── 3. Copy the Python script in ─────────────────────────────
cp "$LAUNCHER_PY" "$APP_BUNDLE/Contents/Resources/launcher.py"
cp "$(dirname "$0")/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# ── 4. Write the launcher shell script ───────────────────────
cat > "$APP_BUNDLE/Contents/MacOS/$APP_NAME" << 'LAUNCHER'
#!/bin/bash
# Launcher stub — runs inside the .app bundle
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../Resources/launcher.py"

# Prefer the python3 from common install locations
for PY in /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3 python3; do
    if command -v "$PY" &>/dev/null; then
        exec "$PY" "$SCRIPT"
    fi
done

osascript -e 'display alert "python3 not found" message "Install Python 3 from python.org to run Mac Scripts Launcher."'
LAUNCHER

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ── 5. Write Info.plist ──────────────────────────────────────
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>Mac Scripts Launcher</string>
    <key>CFBundleDisplayName</key>      <string>Mac Scripts Launcher</string>
    <key>CFBundleIdentifier</key>       <string>co.sarva.mac-scripts-launcher</string>
    <key>CFBundleVersion</key>          <string>1.0</string>
    <key>CFBundleExecutable</key>       <string>Mac Scripts Launcher</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>11.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSUIElement</key>              <false/>
</dict>
</plist>
PLIST

echo "✓  Bundle created at: $APP_BUNDLE"

# ── 6. Install to /Applications ──────────────────────────────
DEST="/Applications/$APP_NAME.app"
echo ""
echo "📦  Installing to $DEST …"

if [ -d "$DEST" ]; then
    echo "    (removing old version)"
    rm -rf "$DEST"
fi

cp -r "$APP_BUNDLE" "$DEST"
echo ""
echo "✅  Done!  \"$APP_NAME\" is now in your /Applications folder."
echo ""
echo "    You can:"
echo "    • Open it from Spotlight (⌘ Space → Mac Scripts)"
echo "    • Drag it to your Dock"
echo "    • Double-click it in Finder → Applications"
echo ""

# ── 7. Launch it right now ───────────────────────────────────
read -p "Launch it now? [Y/n] " yn
if [[ "$yn" != "n" && "$yn" != "N" ]]; then
    open "$DEST"
fi
