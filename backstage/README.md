# 🎛️ Backstage

**A command center for everything running behind your Mac's back.**

Backstage is a menu-bar + window app (SwiftUI) that lists every background job (your LaunchAgents,
global agents and daemons, plists that aren't loaded, crontab) and explains what each does. It spots
crash loops, missing scripts and jobs pointing into iCloud, and can load, unload, restart or reveal them.
It also keeps a shelf of **your own scripts**: run them with live output, arguments and run history,
or search the whole Mac for scripts you forgot you wrote.

```bash
./build.sh           # builds and installs ~/Applications/Backstage.app (Command Line Tools only, no Xcode)
./build.sh --pkg     # also builds an installer package for another Mac
~/Applications/Backstage.app/Contents/MacOS/Backstage --report   # plain-text health report (great for AIs)
```

Your notes and script shelf live in `scripts.json`, `job-notes.json` and `run-history.json` next to the
source. They're personal, so they're git-ignored and stay on your Macs (any AI assistant can read and
update them too). Build products go to `~/Library/Caches/backstage-build`, not your synced folders.

## New Mac setup (added 2026-09-24)

The sidebar's **New Mac setup** screen checks this Mac against `setup.json` (Command Line Tools, Homebrew, helper tools, apps, background jobs, git guards) and offers a Fix button per item: `brew install`, an install script, or Terminal for steps that need your password. It opens by itself the first time Backstage runs on a Mac, and has a "start at login" switch plus a Mac Migrator card. Terminal check: `Backstage --setup`.

`setup.json` item types. check: `command`, `app`, `path`, `agent`, `xcode-clt`. fix: `brew`, `script` (path relative to `root/`), `terminal`, `url`, `note`.

`scripts.json` and `run-history.json` now store paths as `~/...`, so they work when usernames differ between Macs (amol vs MrAnonymous).
