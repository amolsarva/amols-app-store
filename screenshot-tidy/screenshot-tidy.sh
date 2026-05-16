#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  screenshot-tidy.sh                                                      ║
# ║  Moves macOS screenshots that land on ~/Desktop into                     ║
# ║  ~/Desktop/Screenshots (which is inside iCloud Desktop when sync is on). ║
# ║  Triggered by the LaunchAgent com.amol.screenshot-tidy whenever          ║
# ║  ~/Desktop changes (WatchPaths).                                         ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

DESKTOP="$HOME/Desktop"
TARGET="$HOME/Desktop/Screenshots"
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/screenshot-tidy.log"

mkdir -p "$TARGET" "$LOG_DIR"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG"; }

# Wait briefly so the screenshot fully finishes writing & iCloud settles
sleep 2

shopt -s nullglob

moved=0
# macOS screenshot naming: "Screenshot ...", "Screen Shot ...",
# or localised variants. Match common cases without being too greedy.
for f in \
  "$DESKTOP"/Screenshot\ *.png \
  "$DESKTOP"/Screenshot\ *.jpg \
  "$DESKTOP"/Screenshot\ *.jpeg \
  "$DESKTOP"/Screen\ Shot\ *.png \
  "$DESKTOP"/Screen\ Shot\ *.jpg \
  "$DESKTOP"/Screen\ Recording\ *.mov \
  "$DESKTOP"/Screen\ Recording\ *.mp4
do
  [ -e "$f" ] || continue

  base="$(basename "$f")"
  dest="$TARGET/$base"

  # Avoid clobbering an existing file with the same name — append -1, -2, …
  if [ -e "$dest" ]; then
    ext="${base##*.}"
    stem="${base%.*}"
    i=1
    while [ -e "$TARGET/${stem}-${i}.${ext}" ]; do i=$((i+1)); done
    dest="$TARGET/${stem}-${i}.${ext}"
  fi

  if mv "$f" "$dest" 2>>"$LOG"; then
    log "moved  $base  →  ${dest#$HOME/}"
    moved=$((moved+1))
  else
    log "ERROR  failed to move $f"
  fi
done

if [ "$moved" -gt 0 ]; then
  log "done — moved $moved file(s)"
fi
