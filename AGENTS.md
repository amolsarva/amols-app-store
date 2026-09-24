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
│   ├── tool.json             catalog metadata: drives README, store page, launcher
│   └── ...                   the tool's actual files, config, logs
└── supporting-files/        launcher internals + publishing infra (see below) — not a tool, don't add it to any launcher's discovery list
    ├── launcher.py            the primary Tk launcher (catalog-based, see below)
    ├── main.js, mac-scripts.html, package.json, node_modules/   alternate Electron launcher
    ├── scripts.html, homepage-section-snippet.html   content for amolsarva.com (apps list is generated)
    ├── catalog/               external.json (web apps, separate repos), generated launcher.json, announcements/
    ├── publish/               build_catalog.py (generator + --check) and publish.sh (one-step publish)
    ├── MAINTENANCE.md         publishing notes
    └── archive/               stale one-time scripts, kept only as a record — do not run from here
```

Root should stay down to `AGENTS.md`, `README.md`, `launcher.command`, and
tool folders. If you're about to drop a new loose file at the repo root,
stop — it almost certainly belongs inside a tool's own folder or inside
`supporting-files/`.

## Tool folder convention

When adding a new script, give it its own folder at the repo root, named `kebab-case`, containing:

- The actual script, and a `run.sh` thin wrapper that `exec`s it (self-relative paths only:
  `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` / `Path(__file__).resolve().parent`), so it
  works when double-clicked from Finder with an unknown cwd.
- A `README.md` (public tools must have one).
- A `tool.json` (copy `imessage-sync/tool.json`; start with `"status": "review"`).
- Personal data (lists, logs, archives, config.json) must be gitignored before the first commit.

Then run `python3 supporting-files/publish/build_catalog.py`, and register it in Backstage's
`scripts.json` if Amol should be able to run it from there.

**Messages tools are split on purpose:** `imessage-sync` (nightly archive for people/AIs) and
`imessage-cleanup` (interactive exporter / space saver, its own GitHub repo) are *backup*;
`imessage-campaigns` (formerly `send-birthday-invites`) and `whatsapp-campaigns` are *outreach*.
Keep them apart in names, READMEs and the store.

## One source of truth: `tool.json` (since 2026-09-24)

Every tool folder carries a `tool.json` (name, icon, section, summary, story, tags, launcher
entry, and **status**: `public` / `review` / `private`). Tools that live in their own repos,
plus the web apps, are in `supporting-files/catalog/external.json`.
`supporting-files/publish/build_catalog.py` generates, from those files:

- the tool tables in `README.md` (between `<!-- catalog:start -->` / `<!-- catalog:end -->`),
- the `apps` list in `supporting-files/scripts.html` (the amolsarva.com/scripts page),
- `supporting-files/catalog/launcher.json` (what the Tk launcher shows),
- draft launch posts in `supporting-files/catalog/announcements/` for newly public tools.

**Never hand-edit the generated parts.** Edit `tool.json`, then run the generator.
`build_catalog.py --check` lists drift: folders without `tool.json`, tools waiting for Amol's OK
(`review`), stale README/store page, unpushed commits, private files, and a stale live page.

### Publishing (GitHub + amolsarva.com in one step)

`supporting-files/publish/publish.sh` rebuilds, validates syntax, **refuses to push anything
private-looking** (contact CSVs, campaign archives, config.json, logs, rollback lists…), then with
`--go` commits + pushes this repo, copies `scripts.html` into `../amolsarva.com/scripts.html`
(plus an `/amols-scripts` redirect), pushes that, and waits until the live page matches.
Both are in Backstage: "Publish App Store" (dry run by default) and "App Store check".
Only set a tool to `public` after Amol says so (the page and repo are public).

### Launchers

1. **`launcher.command`** → `supporting-files/launcher.py` (Tk). Reads `catalog/launcher.json`.
2. **Electron app** (`supporting-files/main.js` + `mac-scripts.html`): legacy; auto-discovers folders
   with `run.sh`/`main.py`/`run.py`; cards are hand-authored, not generated.
3. **Backstage** (`backstage/`): the command center. Its `scripts.json` is private per-Mac data.

## Known housekeeping items

- `sunlight/`: native SwiftUI Sengled controller; `run.sh` opens `dist/Sunlight.app`.
  Registered in Backstage's `scripts.json` and the Tk launcher. Firmware behavior is
  implemented as Tasmota rules, not an OTA binary. Settings backups contain credentials
  and belong in `utils and keys/vault/sunlight/`, never the public app repository.

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
