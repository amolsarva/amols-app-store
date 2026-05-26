# mac-scripts

A collection of shell scripts and Python tools to make macOS easier to live with — built up over time for real everyday use.

Each script is self-contained in its own folder with a README explaining what it does, how to run it, and what to watch out for.

---

## Scripts

| Script | What it does |
|--------|-------------|
| [abbu-to-csv](./abbu-to-csv/) | Export Apple Contacts `.abbu` backup to CSV |
| [bigfiles](./bigfiles/) | Find the biggest folders on your Mac and see if they're still in use |
| [cleanicloud](./cleanicloud/) | Find and interactively delete iCloud duplicates and large files |
| [cpu-guard](./cpu-guard/) | Stop noisy macOS background processes when they sustain high CPU |
| [drive-dedup](./drive-dedup/) | Scan an external drive for duplicates and consolidate into a clean folder structure |
| [github-autopush](./github-autopush/) | Auto-push your git repos to GitHub in the background via LaunchAgent |
| [google-voice-exporter-extension](./google-voice-exporter-extension/) | Export the open Google Voice conversation from Chrome as JSON, CSV, or TXT |
| [imessage-cleanup](./imessage-cleanup/) | Extract iMessage attachments by sender, refresh previous exports, keep grouped multi-handle contacts together, export restartable archive folders (DB + transcript + media + manifest), and optionally free iCloud storage |
| [mac-migrator](./mac-migrator/) | Bundle your Mac's config and background tasks for migration to a new machine |
| [meet-tab-sidecar-extension](./meet-tab-sidecar-extension/) | Chrome extension for joining a Google Meet call while another controlled browser tab plays audio, speaks an intro, or runs the presentation work |
| [pdf-to-xls](./pdf-to-xls/) | Convert a PDF to an Excel spreadsheet in one command |
| [personalcontacts-analyzer](./personalcontacts-analyzer/) | Archive Gmail headers locally and analyze your communication patterns |
| [screenshot-tidy](./screenshot-tidy/) | Auto-move screenshots off your Desktop into a Screenshots folder |

---

## Philosophy

These are practical tools, not polished products. They're designed to:

- Run on a standard macOS setup with no exotic dependencies
- Ask before deleting anything
- Leave your data intact (copies before changes, dry-run modes where possible)
- Be readable — short scripts you can audit before running

---

## Usage

Clone the repo and run individual scripts from their folders:

```bash
git clone https://github.com/amolsarva/amols-app-store.git
cd amols-app-store/<script-name>
bash script.sh   # or python3 script.py
```

Each folder's README has specific instructions.

---

## Catalog and publishing

- `launcher.command` opens the local Mac Scripts launcher.
- `scripts.html` is the full public catalog page for amolsarva.com.
- `homepage-section-snippet.html` is the homepage app-store teaser.
- `MAINTENANCE.md` has the release checklist and live-site update reminder.

---

## Author

[Amol Sarva](https://amolsarva.com)
