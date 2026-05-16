# screenshot-tidy

Automatically moves screenshots off your Desktop into `~/Desktop/Screenshots` the moment they're taken — keeping your Desktop clean without any manual effort.

## What it does

Installs a macOS LaunchAgent that watches `~/Desktop` for changes. Whenever a new file appears that matches macOS screenshot naming patterns (`Screenshot *.png`, `Screen Shot *.png`, `Screen Recording *.mov`, etc.), it's automatically moved into `~/Desktop/Screenshots/`.

If iCloud Desktop sync is enabled, `~/Desktop/Screenshots/` syncs to iCloud just like the rest of your Desktop — so nothing is lost.

A second LaunchAgent (`com.amol.screenshot-clipboard`) ensures macOS always copies screenshots to your clipboard so you can paste immediately after taking one.

Everything is logged to `~/Library/Logs/screenshot-tidy.log`.

## Installation

```bash
bash screenshot-tidy-install.sh
```

That's it. The LaunchAgent installs and starts immediately. It will also restart at login automatically.

## Uninstall

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.amol.screenshot-tidy.plist
rm ~/Library/LaunchAgents/com.amol.screenshot-tidy.plist
```

## How it works

- Uses `WatchPaths` in the LaunchAgent plist — macOS triggers the script whenever `~/Desktop` changes
- A 2-second sleep lets the screenshot finish writing before the move
- Collision-safe: if a file with the same name already exists in `Screenshots/`, it appends `-1`, `-2`, etc.

## Requirements

- macOS (any modern version)
- No additional software required

## Files

| File | Purpose |
|------|---------|
| `screenshot-tidy.sh` | The worker script that moves files |
| `screenshot-tidy-install.sh` | Installs the LaunchAgent (run once) |
