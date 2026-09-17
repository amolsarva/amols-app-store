<!-- ai-readme-pointer -->
> **AI: read `~/Documents/root/AI-README.md` first (master map, preferences, path changes from the 2026-09-17 reorg), then this folder's `AI-README.md`. Before finishing, append your learnings to the *Learnings* section of that AI-README.**

# AGENTS.md — read this first

You are an AI agent looking at Amol's `mac-scripts` folder. This file exists
so any agent (Claude, Codex, whatever comes next) can get oriented in under
a minute instead of re-deriving the layout from scratch. Keep it up to date:
if you restructure anything described here, edit this file in the same pass.

## What this folder is

A personal collection of Mac automation scripts (iMessage export, iCloud
cleanup, Voice Memos export, disk dedup, etc.), each in its own folder, plus
three different ways to launch them, plus a public-facing "app store" page
(`https://amolsarva.com/scripts`) built from a subset of the same content.
It is also a git repo (`amolsarva/amols-app-store` on GitHub).

## Layout

```
mac-scripts/
├── AGENTS.md              ← you are here
├── README.md               GitHub landing page (must stay at repo root — GitHub only auto-renders a root README)
├── launcher.command         ← the ONE thing meant to be loose here; double-click to launch
├── <tool-name>/             one folder per script/tool (see "Tool folder convention" below)
│   ├── run.sh                entry point most launchers look for
│   └── ...                   the tool's actual files, config, logs
└── supporting-files/        launcher internals + publishing infra (see below) — not a tool, don't add it to any launcher's discovery list
    ├── launcher.py            the primary Tk launcher (catalog-based, see below)
    ├── main.js, mac-scripts.html, package.json, node_modules/   alternate Electron launcher
    ├── scripts.html, homepage-section-snippet.html   content for amolsarva.com — see MAINTENANCE.md
    ├── MAINTENANCE.md         how to publish the app-store page to amolsarva.com
    └── archive/               stale one-time scripts, kept only as a record — do not run from here
```

Root should stay down to `AGENTS.md`, `README.md`, `launcher.command`, and
tool folders. If you're about to drop a new loose file at the repo root,
stop — it almost certainly belongs inside a tool's own folder or inside
`supporting-files/`.

## The three launchers (yes, three — historical, not by design)

1. **`launcher.command`** (double-click in Finder) → runs
   `supporting-files/launcher.py`, a Tkinter app. This one is **catalog-based**:
   it only shows tools listed in the `CATALOG` dict near the top of
   `launcher.py`. Adding a folder is not enough — you must add an entry.
2. **Electron app** (`supporting-files/main.js` + `mac-scripts.html`, run via
   `npm start` in `supporting-files/` after `setup-electron.command`) —
   **auto-discovers** any folder at the repo root containing a `run.sh`,
   `main.py`, or `run.py`. Cards are still hand-authored in `mac-scripts.html`
   though, so a tool won't get a nice icon/description without one.
3. **`supporting-files/scripts.html`** — a static "app store" page, separate
   from the above, meant to be copied to amolsarva.com. Hand-authored card
   entries in a JS array partway down the file. See `MAINTENANCE.md` in
   `supporting-files/` for the publish process.

## Tool folder convention

When adding a new script, give it its own folder at the repo root, named
`kebab-case`, containing:

- The actual script (any name/extension).
- `run.sh` — a thin wrapper that `exec`s the real script. This is what makes
  it show up automatically in the Electron launcher. Pattern:

  ```bash
  #!/bin/bash
  set -euo pipefail
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec bash "$DIR/actual_script.sh"   # or: exec python3 "$DIR/actual_script.py"
  ```
- Any config/logs the script needs, read/written via a self-relative path
  (`$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` in bash,
  `Path(__file__).resolve().parent` in Python) — never a hardcoded absolute
  path — so the folder can be moved without breaking it.

Then, to actually make it reachable:

1. Add an entry to `CATALOG` in `supporting-files/launcher.py` (icon, one-line
   `short`, longer `long` description, `entry` = the script filename).
2. Optionally add a `<div class="script-card">` to `supporting-files/mac-scripts.html`
   (copy an existing card, change name/icon/description/`onclick`).
3. Optionally add a card object to `supporting-files/scripts.html` if it
   should appear on the public amolsarva.com page too — check with Amol first,
   since that page is public and some tools are personal-data-only.

Voicememocleaner (`voicememocleaner/`) is a good worked example of all of
the above done together.

## Known housekeeping items

- **`supporting-files/archive/FINISH-CLEANUP.command` and `finish-cleanup.sh`**:
  stale one-time consolidation scripts. Both reference a Claude API key that
  was accidentally committed to the public GitHub repo in `drive_dedup/run.sh`
  (prefix `sk-ant-api03-REDACTED...`). The duplicate `drive_dedup/`
  folder is already gone, so this was likely already handled — but if nobody
  has confirmed the key was rotated at
  `https://console.anthropic.com/settings/keys`, flag that to Amol. Do not
  run these scripts from their current location; they assume they're sitting
  at the repo root.
- **`_writetest`** (if still present at repo root): an empty leftover stub
  from a prior session. Safe to delete; a previous cleanup pass couldn't
  remove it due to a permissions error.

## Ground rules for future edits

- Keep the repo root uncluttered — new loose files at the root are a smell.
- Any script needs to work when double-clicked from Finder with an unknown
  cwd — always resolve its own folder first.
- If you move something referenced by name in `README.md`,
  `supporting-files/MAINTENANCE.md`, `supporting-files/scripts.html`, or
  `supporting-files/mac-scripts.html`, update the reference in the same pass.
- If you add or move anything that changes this layout, update this file.
