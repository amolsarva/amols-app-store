#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  screenshot-paths.sh                                                     ║
# ║  Shared path resolver for screenshot-tidy / screenshot-settings.         ║
# ║  Source it; it defines SHOT_TARGET and SHOT_SOURCES.                     ║
# ║                                                                          ║
# ║  Why this exists: ~/Desktop is only the iCloud Desktop on Macs that have ║
# ║  "Desktop & Documents Folders" sync turned on. On a Mac where it is off, ║
# ║  the screenshots live in iCloud Drive › Desktop › Screenshots while      ║
# ║  ~/Desktop is a separate local folder — so anything hard-coded to        ║
# ║  ~/Desktop silently does nothing. Resolve at run time instead.           ║
# ╚══════════════════════════════════════════════════════════════════════════╝

ICLOUD_DESKTOP="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Desktop"
LOCAL_DESKTOP="$HOME/Desktop"
MOVER_INBOX="$HOME/Library/Application Support/Screenshot Mover/Inbox"

# Same directory? (handles the sync-on case, where ~/Desktop *is* the iCloud one)
shot_same_dir() {
  [ -d "$1" ] && [ -d "$2" ] || return 1
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  [ "$a" = "$b" ]
}

# A config value, from the tidy config or the Screenshot Mover one (shared on purpose).
shot_config_dir() {
  local f key val
  for f in "$HOME/.config/screenshot-tidy/config" "$HOME/.config/screenshot-mover/config"; do
    [ -f "$f" ] || continue
    for key in SCREENSHOTS_DIR DEST_DIR; do
      val="$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$f" | tail -1)"
      val="${val%\"}"; val="${val#\"}"
      if [ -n "$val" ]; then printf '%s\n' "${val/#\~/$HOME}"; return 0; fi
    done
  done
  return 1
}

# Where screenshots should end up.
shot_target() {
  local v
  if [ -n "${SCREENSHOTS_DIR:-}" ]; then printf '%s\n' "${SCREENSHOTS_DIR/#\~/$HOME}"; return; fi
  if v="$(shot_config_dir)"; then printf '%s\n' "$v"; return; fi
  # iCloud Desktop wins when it exists — that is where the library actually is.
  if [ -d "$ICLOUD_DESKTOP" ]; then printf '%s\n' "$ICLOUD_DESKTOP/Screenshots"; return; fi
  printf '%s\n' "$LOCAL_DESKTOP/Screenshots"
}

# Folders worth sweeping: both Desktops, the Screenshot Mover inbox, and
# whatever macOS is currently told to save captures into. Deduped, target excluded.
shot_sources() {
  local target="$1" d loc seen=""
  loc="$(/usr/bin/defaults read com.apple.screencapture location 2>/dev/null || true)"
  # Skip the Screenshot Mover inbox while its agent is running — that folder is
  # its business (it copies to the clipboard first); only sweep it if it is dead.
  local skip_inbox=""
  /bin/launchctl print "gui/$(id -u)/com.amol.screenshot-mover" >/dev/null 2>&1 && skip_inbox=1
  for d in "$LOCAL_DESKTOP" "$ICLOUD_DESKTOP" "$MOVER_INBOX" "${loc/#\~/$HOME}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    shot_same_dir "$d" "$target" && continue
    [ -n "$skip_inbox" ] && shot_same_dir "$d" "$MOVER_INBOX" && continue
    d="$(cd "$d" && pwd -P)"
    case ":$seen:" in *":$d:"*) continue ;; esac
    seen="$seen:$d"
    printf '%s\n' "$d"
  done
}
