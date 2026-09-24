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
