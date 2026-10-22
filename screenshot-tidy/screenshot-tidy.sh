#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  screenshot-tidy.sh                                                      ║
# ║  Sweeps stray screenshots into the Screenshots folder, wherever that     ║
# ║  folder lives on this Mac. Resolved at run time by screenshot-paths.sh:  ║
# ║  iCloud Drive › Desktop › Screenshots when iCloud Desktop exists (with   ║
# ║  or without "Desktop & Documents" sync), else ~/Desktop/Screenshots.     ║
# ║  Sources swept: both Desktops, the Screenshot Mover inbox, and whatever  ║
# ║  macOS currently saves captures into.                                    ║
# ║  Triggered by the LaunchAgent com.amol.screenshot-tidy (WatchPaths).     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=screenshot-paths.sh
source "$HERE/screenshot-paths.sh"

TARGET="$(shot_target)"
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/screenshot-tidy.log"

mkdir -p "$TARGET" "$LOG_DIR"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG"; }

# Wait briefly so the screenshot fully finishes writing & iCloud settles
sleep 2

moved=0
failed=0

while IFS= read -r src; do
  # A LaunchAgent with no Full Disk Access can see a folder but not list it —
  # that failure is silent otherwise, and looks exactly like "nothing to move".
  if ! /bin/ls "$src" >/dev/null 2>&1; then
    log "ERROR  cannot read $src (grant Full Disk Access to the agent?)"
    failed=$((failed+1))
    continue
  fi

  # macOS screenshot naming, localised and lower-case variants included
  # ("Screenshot 2026-07-08 at 1.30.27 pm.png", "Screen Shot …", recordings).
  while IFS= read -r f; do
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
      failed=$((failed+1))
    fi
  done < <(find "$src" -maxdepth 1 -type f \( \
      -iname 'Screenshot *.png'      -o -iname 'Screenshot *.jpg'  -o -iname 'Screenshot *.jpeg' -o \
      -iname 'Screen Shot *.png'     -o -iname 'Screen Shot *.jpg' -o \
      -iname 'Screen Recording *.mov' -o -iname 'Screen Recording *.mp4' \) 2>/dev/null)
done < <(shot_sources "$TARGET")

if [ "$moved" -gt 0 ] || [ "$failed" -gt 0 ]; then
  log "done — moved $moved file(s), $failed failure(s)"
fi

# Manual/Backstage runs get a summary on stdout; the agent's stdout goes to a file.
echo "Screenshots folder: $TARGET"
if [ "$failed" -gt 0 ]; then
  echo "moved $moved file(s), $failed failure(s)"
else
  echo "moved $moved file(s)"
fi
[ "$failed" -eq 0 ]
