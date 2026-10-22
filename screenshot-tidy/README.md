# screenshot-tidy

Sweeps stray screenshots into your Screenshots folder — wherever that folder lives on the Mac you're on.

## What it does

Installs a macOS LaunchAgent that watches your Desktop folders and moves any file matching macOS screenshot naming (`Screenshot *.png`, `Screen Shot *.png`, `Screen Recording *.mov`, lower-case `am`/`pm` variants, etc.) into the Screenshots folder.

**The folder is resolved at run time, not hard-coded.** `~/Desktop` is only the iCloud Desktop on a Mac that has *Desktop & Documents Folders* sync turned on. On a Mac where that sync is off, the screenshots live in `iCloud Drive › Desktop › Screenshots` while `~/Desktop` is a separate local folder — so anything pinned to `~/Desktop` silently does nothing. `screenshot-paths.sh` works it out per Mac:

| Order | Screenshots folder |
|---|---|
| 1 | `SCREENSHOTS_DIR` in the environment |
| 2 | `SCREENSHOTS_DIR` / `DEST_DIR` in `~/.config/screenshot-tidy/config` or `~/.config/screenshot-mover/config` (shared with Screenshot Mover on purpose) |
| 3 | `iCloud Drive › Desktop › Screenshots`, when the iCloud Desktop exists |
| 4 | `~/Desktop/Screenshots` |

Folders swept: the local Desktop, the iCloud Desktop, and whatever macOS currently saves captures into. The Screenshot Mover inbox is swept only when Mover's agent is *not* running (that inbox is its business — it copies to the clipboard first).

A second LaunchAgent (`com.amol.screenshot-clipboard`) keeps macOS pointed at the same folder and copies screenshots to the clipboard — unless Screenshot Mover is installed, in which case it leaves the capture location alone rather than fighting it.

Everything is logged to `~/Library/Logs/screenshot-tidy.log`.

## Installation

```bash
bash screenshot-tidy-install.sh
```

The LaunchAgent installs, starts immediately, and restarts at login.

### One-time privacy grant

A LaunchAgent can see the Desktop and iCloud Drive but **cannot list them** unless the shell running it has Full Disk Access. Without that grant the agent exits cleanly having moved nothing — indistinguishable from "nothing to do", which is exactly how this tool failed quietly before. The script now logs `ERROR cannot read …`, and the installer says so.

Fix: System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ `+` ▸ ⌘⇧G ▸ `/bin/bash`.

Running it by hand — Backstage ▸ Launch, or a Terminal — works without that grant, since those already have access.

## Uninstall

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.amol.screenshot-tidy.plist
rm ~/Library/LaunchAgents/com.amol.screenshot-tidy.plist
```

## How it works

- `WatchPaths` in the plist, filled in with the folders resolved for this Mac — the target folder is deliberately not watched, or moving files into it would retrigger the agent
- A 2-second sleep lets the screenshot finish writing (and iCloud settle) before the move
- Collision-safe: an existing name gets `-1`, `-2`, …
- Case-insensitive matching, so localised and lower-case `pm` filenames are caught

## Files

| File | Purpose |
|------|---------|
| `screenshot-paths.sh` | Shared resolver: the Screenshots folder and the folders to sweep |
| `screenshot-tidy.sh` | The worker script that moves files |
| `screenshot-settings.sh` | Points macOS at the folder; yields to Screenshot Mover |
| `screenshot-tidy-install.sh` | Installs both LaunchAgents (run once) |
