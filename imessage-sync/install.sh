#!/bin/bash
# Installs (or removes) the nightly iMessage Sync job on this Mac.
#
#   install.sh             build the helper app, write the LaunchAgent, make this Mac the primary
#   install.sh --uninstall remove the LaunchAgent (the archive and helper app are kept)
#
# The job fires hourly; the sync itself decides whether it's due (overnight window,
# catch-up after sleep, backoff after failures), so a missed night heals itself.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.amol.imessage-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/iMessage Sync.app"
BIN="$APP/Contents/MacOS/iMessageSync"
LOGDIR="$HOME/Library/Logs/imessage-sync"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed the nightly job. Archive and helper app left in place."
  exit 0
fi

# 1. Helper app: rebuilt only when its source changes, because every rebuild gets a new
#    code signature and macOS would silently drop the Full Disk Access grant.
# PLIST_REV bumps force a rebuild when only the Info.plist below changes.
PLIST_REV=3
SRC_HASH="$( (cat "$DIR/helper/main.swift" "$DIR/helper/AppIcon.icns"; echo "$PLIST_REV") | shasum | cut -c1-12)"
if [[ ! -x "$BIN" || "$(cat "$APP/Contents/Resources/source-hash" 2>/dev/null)" != "$SRC_HASH" ]]; then
  echo "==> Building $APP"
  BUILD="$HOME/Library/Caches/imessage-sync-build"
  mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -O -target "$(uname -m)-apple-macos13.0" "$DIR/helper/main.swift" -o "$BUILD/iMessageSync"
  cp "$BUILD/iMessageSync" "$BIN"
  cp "$DIR/helper/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>co.sarva.imessage-sync</string>
  <key>CFBundleName</key><string>iMessage Sync</string>
  <key>CFBundleExecutable</key><string>iMessageSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
  echo "$SRC_HASH" > "$APP/Contents/Resources/source-hash"
  codesign --force --sign - "$APP"
  NEW_BUILD=1
else
  echo "==> Helper app up to date ($APP)"
  NEW_BUILD=0
fi

# 2. Local copy of the job code (the job must start even before it may read ~/Documents)
JOBBIN="$HOME/Library/Application Support/imessage-sync/bin"
mkdir -p "$JOBBIN"
for f in imessage_sync.py run.sh ARCHIVE_README.md; do cp "$DIR/$f" "$JOBBIN/$f"; done
echo "$DIR" > "$JOBBIN/.repo"

# 3. LaunchAgent
mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string>
    <string>/bin/bash</string>
    <string>$JOBBIN/run.sh</string>
    <string>job</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>30</integer></dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOGDIR/job.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/job.log</string>
</dict></plist>
PL
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "==> Nightly job loaded: $LABEL (checks hourly, runs overnight 1–6am, catches up after sleep)"

# 4. Primary Mac (only one Mac should archive, or two would fight over the shared folder)
PRIMARY="$(python3 "$DIR/imessage_sync.py" status 2>/dev/null | sed -n 's/.*primary Mac: *\([^ ]*\).*/\1/p')"
if [[ "$PRIMARY" == "not" || -z "$PRIMARY" ]]; then
  python3 "$DIR/imessage_sync.py" take-over
fi

cat <<MSG

One manual step, only you can do it (macOS security):
  System Settings → Privacy & Security → Full Disk Access → + → choose
  $APP
  (Easiest: run  $DIR/run.sh grant  — it opens that pane and shows the app in Finder to drag in.)
  (If it's already listed but this was a rebuild, remove it with − and add it again.)
Then check everything with:   $DIR/run.sh doctor
MSG
if [[ "$NEW_BUILD" == "1" ]]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
  open -R "$APP" 2>/dev/null || true
fi
