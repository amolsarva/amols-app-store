<!-- ai-readme-pointer -->
> **AI: read `~/Documents/root/AI-README.md` first (master map, preferences, path changes from the 2026-09-17 reorg), then this folder's `AI-README.md`. Before finishing, append your learnings to the *Learnings* section of that AI-README.**

# AGENTS.md: read this first

You are an AI agent in Amol's `mac-scripts` folder (GitHub: `amolsarva/amols-app-store`, **public**).
Many things outside this folder are built from it, run copies of it, or publish it. **If you change
anything here, you are responsible for everything downstream.** That is the Touch protocol below.
Keep this file current: if you restructure something it describes, edit this file in the same pass.

## ⚠️ Touch protocol: every change, however small

A "touch" is any edit, add, move, rename or delete under `mac-scripts/`, including docs and `tool.json`.
Before you tell Amol you're done:

1. **Know the baseline first.** Before editing, run `supporting-files/publish/release.sh` (dry run,
   changes nothing). It shows what is *already* stale or uncommitted, possibly from another session.
   Don't sweep someone else's half-done work into a public release without looking at it.
2. **Make the change properly:**
   - Behavior or description changed → update that tool's `tool.json` (summary, launcher entry,
     `installs`, `artifacts`) and its `README.md`. New tool → its own folder with `run.sh`,
     `README.md` and `tool.json` (`"status": "review"`).
   - It installs a copy of itself anywhere outside this folder (a LaunchAgent running a copy, a
     built `.app`, a git hook, anything in `~/bin` or `~/Library/Application Support`) → declare
     it under `installs` in `tool.json`. Undeclared copies go stale silently; that has caused
     every "it just stopped working" bug here.
   - It produces something people download (dmg, zip) → declare it under `artifacts`.
   - It uses Python → go through `python-guard` (below). Never bare `python3` for Tk or
     third-party packages, never `pip install --user` or `--break-system-packages`, and never a venv inside iCloud.
   - Amol should be able to run it → register it in `backstage/scripts.json` (Launch/Install/Repair args).
     A new Mac needs it → add an item to `backstage/setup.json`.
   - Paths are self-relative; never hard-code `/Users/<name>` (two Macs, two home folders).
3. **Release.** On a Mac: `supporting-files/publish/release.sh --go`, or Backstage ▸ ⭐ "Release mac-scripts" ▸ Launch.
   This does all of it, in order: Python health → regenerate README, store page and launcher catalog → lint
   Backstage registrations → syntax and privacy gate → re-install stale copies on this Mac →
   rebuild Backstage dmg + update feed and extension zips → push GitHub → push amolsarva.com
   → push own-repo tools → verify the live site and update feed.
   **In a Linux/AI sandbox** (no swift, launchctl or Keychain): run the dry run, fix everything it
   reports, then tell Amol, in so many words: *"Run Backstage ▸ Release mac-scripts (or
   `release.sh --go`)."* Don't claim it's published.
4. **Verify, don't assume:** `supporting-files/publish/installed.sh` (everything ✅),
   `supporting-files/publish/build_catalog.py --check`, and the last release's full output in
   `supporting-files/publish/.last-release.log` (private, synced by iCloud; readable from a sandbox). Backstage's
   `backstage/run-history.json` records the exit code of every button press.
5. **Write back** learnings to `mac-scripts/AI-README.md` (private) and, if you changed how
   things fit together, this file.

Hard rules: only Amol flips a tool from `review` to `public`. But a tool that a *public* tool depends
on must itself be public, or the public repo breaks. Nothing personal goes in tracked files (names,
numbers, emails, hostnames, Mac names; `publish.sh` gates the obvious ones, and you catch the rest).
Secrets live in `~/Documents/root/utils and keys/vault/`, never here.

## What depends on this folder (the downstream map)

| Downstream | Built/updated from | How it stays current |
|---|---|---|
| github.com/amolsarva/amols-app-store | this repo (public tools only; non-public folders are auto-gitignored) | `release.sh --go` → `publish.sh --go` |
| amolsarva.com/scripts (+ `/amols-scripts` redirect) | `supporting-files/scripts.html` (app list generated from `tool.json`) | copied to `../amolsarva.com/` and pushed (GitHub Pages) |
| amolsarva.com/downloads/backstage/ `Backstage-<v>.dmg` + `latest.json` | `backstage/` (`build.sh --dmg`) | `artifacts` in `backstage/tool.json`; **every installed Backstage polls latest.json** to self-update |
| amolsarva.com/downloads/*.zip (Chrome extensions) | e.g. `meet-tab-sidecar-extension/package-extension.sh` | `artifacts` in that `tool.json` |
| README.md tool tables, `catalog/launcher.json`, announcement drafts | `tool.json` files | `build_catalog.py` (never hand-edit generated parts) |
| Installed copies on each Mac: LaunchAgents' copies, `~/Applications/Backstage.app`, `Mac Scripts Launcher.app`, `Sunlight.app`, `iMessage Sync.app`, `Screenshot Mover.app`, git hooks | each tool's `installs` | `release.sh` (this Mac); other Macs: Backstage ▸ New Mac setup ▸ "Installed tools match the source" |
| Python + Tk + tool venvs on each Mac | `python-guard/` | its LaunchAgent re-runs after every Homebrew Python change |
| Own-repo tools: `screenshot-mover/`, `imessage-cleanup/` (nested git repos, gitignored here) | themselves | `release.sh` step 8 commits tracked changes and pushes |
| Backstage's lists: `backstage/scripts.json`, `setup.json`, `job-notes.json` | hand-maintained (scripts.json/job-notes are private) | `deps.py lint` flags entries pointing at missing files |
| Separate projects shown in the store: dadsbot, opensore, OpenSNORE | their own repos | cards only, via `supporting-files/catalog/external.json` |

## Layout

```
mac-scripts/
├── AGENTS.md / CLAUDE.md   ← you are here (CLAUDE.md just points here)
├── README.md               GitHub landing page (tool tables generated)
├── launcher.command        ← the ONE loose file: double-click opens the Tk launcher
├── <tool>/                 one folder per tool: run.sh · README.md · tool.json · the code
├── python-guard/           shared Python resolver (Tk, venvs, self-heal agent): use it, don't reinvent it
├── downloads/              build output of extension zips (published to amolsarva.com/downloads/)
└── supporting-files/       not a tool
    ├── launcher.py           THE launcher (Tk). launcher.command and Mac Scripts Launcher.app both run it
    ├── scripts.html          amolsarva.com/scripts page (apps list generated)
    ├── catalog/              external.json (web apps + own-repo tools), launcher.json (generated), announcements/
    ├── publish/              release.sh (everything) · publish.sh (git + site) · build_catalog.py (generator,
    │                         --check) · deps.py (installs/artifacts/lint engine) · installed.sh (wrapper)
    ├── icons/                make-app-icon.swift: every app icon
    ├── main.js, mac-scripts.html   legacy Electron launcher (auto-discovers folders; not generated)
    ├── MAINTENANCE.md        publishing notes
    └── archive/              (gitignored) stale scripts kept as a record; never run from here
```

Repo root stays: `AGENTS.md`, `CLAUDE.md`, `README.md`, `launcher.command`, tool folders. Anything
else at the root is clutter: put it in a tool folder or `supporting-files/`.
Big local-only trees (gitignored, no store page): `opensore/`, `opensnore/`, `repo2audiobook/`.

## tool.json (one source of truth per tool)

`name, icon, section, kind, status (public|review|private), category, tags, color, summary, story,
launcher {entry, short, long}, store_path, added`, plus optional:

```json
"installs": [{ "id": "cpu-guard-agent", "what": "…",
               "present": ["agent:com.amol.cpu-guard"],          // or "path:~/Applications/X.app"
               "sources": ["cpu_guard.py", "cpu-guard-install.sh"],
               "update": "cpu-guard-install.sh", "auto": true,    // false = needs a human (sudo, privacy re-grant)
               "note": "…" }],
"artifacts": [{ "id": "backstage-dmg", "sources": ["Sources", "Package.swift", "build.sh"],
                "build": "build.sh --dmg", "outputs": ["dist/Backstage-*.dmg", "dist/latest.json"],
                "site": "downloads/backstage/" }]
```

`supporting-files/publish/deps.py` hashes `sources` and compares with what was last installed on
this Mac (`~/Library/Application Support/mac-scripts/installs.json`) or last built
(`supporting-files/publish/.release-state.json`, private and iCloud-synced). Own-repo tools carry these
keys in `catalog/external.json` instead.

## Python: always through python-guard

```bash
G="$(dirname "$0")/../python-guard/pyenv.sh"
/bin/bash "$G" exec --tk -- app.py "$@"                             # Tk apps
PY="$(/bin/bash "$G" venv my-tool --pkg pandas --pkg PyYAML:yaml)"  # third-party packages (pip:module)
/bin/bash "$G" find                                                 # stdlib-only scripts: best python3
```

Why: Homebrew's Python ships without Tk (`python-tk@3.x` is separate), refuses pip (PEP 668), and
every minor upgrade strands venvs. `pyenv.sh venv` keeps venvs in `~/Library/Application Support/python-guard/venvs/`
(not iCloud), rebuilds them on the new Python, and restarts the LaunchAgents registered with `--restart`.
Apple's `/usr/bin/python3` is 3.9: keep code 3.9-compatible (no 3.12-only f-string quote nesting).

## Launchers

1. `launcher.command` and **Mac Scripts Launcher.app** (`mac-scripts-launcher/build_app.sh`) both run
   `supporting-files/launcher.py` from this folder, through python-guard (Tk). The app only bundles a fallback copy.
2. **Backstage** (`backstage/`): the command center (jobs, scripts, New Mac setup, recipes, self-update).
3. Electron (`supporting-files/main.js`): legacy, hand-authored cards.

## Messages tools are split on purpose

`imessage-sync` (nightly archive) and `imessage-cleanup` (interactive exporter, own repo) are *backup*;
`imessage-campaigns` and `whatsapp-campaigns` are *outreach*. Keep them apart in names, READMEs, store.

## Known housekeeping

- `supporting-files/archive/FINISH-CLEANUP.command` / `finish-cleanup.sh`: stale one-time scripts that
  reference an Anthropic key once committed to this public repo (`drive_dedup/run.sh`, prefix
  `sk-ant-api03-REDACTED…`). If nobody has confirmed it was rotated, flag it to Amol. Don't run them.
