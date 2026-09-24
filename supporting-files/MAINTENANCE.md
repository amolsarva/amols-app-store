# App store maintenance

> This file lives in `supporting-files/` now (moved 2026-08-07 during a
> cleanup — see `AGENTS.md` at the mac-scripts repo root for the full
> picture and the general "how do I add a new tool" playbook). Everything
> below is specifically about the amolsarva.com app-store publishing side.

This folder currently owns the static app-store page for:

- Public page: `https://amolsarva.com/scripts`
- GitHub source shelf: `https://github.com/amolsarva/amols-app-store`
- Related GitHub projects now represented in the store:
  - `https://github.com/amolsarva/dadsbot`
  - `https://github.com/amolsarva/opensore`
  - `https://github.com/amolsarva/OpenSNORE`

## How publishing works now (2026-09-24)

Everything below the line is history. The current process is one command:

```bash
supporting-files/publish/publish.sh                  # dry run: rebuild, validate, privacy gate, show what goes out
supporting-files/publish/publish.sh --go             # push GitHub + amolsarva.com, wait for the live page
supporting-files/publish/build_catalog.py --check    # what needs attention
```

Lists are generated from each tool's `tool.json` (see AGENTS.md). The live page is
https://amolsarva.com/scripts (`/amols-scripts` redirects there). The website repo is
`~/Documents/root/amolsarva.com` (GitHub Pages; `scripts.html` sits at its root).

---

## Current publication status

Checked on 2026-05-27.

- Local `scripts.html` is now a broader 16-item app store, not only a Mac scripts catalog.
- It includes DadsBot, OpenSore, and OpenSnoRE as first-class featured projects.
- The live `https://amolsarva.com/scripts` page may still be stale until this `scripts.html` is copied/deployed there.

When this app store changes, remember to update amolsarva.com as well as GitHub.

## Canonical local files

All paths below are relative to this `supporting-files/` folder unless noted.

- `scripts.html`: full public app-store page content for amolsarva.com.
- `homepage-section-snippet.html`: homepage teaser snippet for amolsarva.com.
- `../README.md`: GitHub landing page and Mac script index (stays at repo root — GitHub only auto-renders a root README).
- `launcher.py`: local Tk launcher for the Mac scripts collection (catalog-based; new tools must be added to its `CATALOG` dict).
- `../launcher.command`: double-click entry point for the local launcher (stays at repo root on purpose; runs `python3 supporting-files/launcher.py`).
- `main.js` + `mac-scripts.html` + `package.json`: the alternate Electron launcher, auto-discovers any repo-root folder with a `run.sh`/`main.py`/`run.py` inside it.

## Release checklist

1. Validate the static page:

   ```bash
   cd supporting-files
   git diff --check
   node -e "const fs=require('fs'); const html=fs.readFileSync('scripts.html','utf8'); const scripts=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]); for (const s of scripts) new Function(s); console.log('scripts_ok=', scripts.length);"
   ```

2. Validate Mac script syntax (run from the mac-scripts repo root):

   ```bash
   for f in abbu-to-csv/abbu_to_csv.sh bigfiles/bigfiles.sh cleanicloud/cleanicloud.sh cpu-guard/cpu-guard-install.sh drive-dedup/run.sh github-autopush/github-autopush-manager.sh github-autopush/github-autopush-runner.sh imessage-cleanup/imessage_cleanup.sh mac-migrator/mac_background_migrator.sh pdf-to-xls/pdftoxls.sh screenshot-tidy/screenshot-tidy.sh screenshot-tidy/screenshot-tidy-install.sh media-pipeline/media_pipeline.sh voicememocleaner/VOICEMEMOCLEANER.sh voicememocleaner/run.sh; do bash -n "$f" || exit 1; done
   ```

3. Commit and push:

   ```bash
   git status --short
   git add -A
   git commit -m "Update app store page"
   git push origin main
   ```

4. Update amolsarva.com:

   - Replace the live `/scripts` page with the current `scripts.html`.
   - Update any homepage App Store teaser/count if it still describes the page as only Mac scripts.
   - Keep links to DadsBot, OpenSore, OpenSnoRE, and the Mac scripts shelf visible.

5. Check after publishing:

   - `https://amolsarva.com/scripts`
   - `https://github.com/amolsarva/amols-app-store`
   - `https://github.com/amolsarva/dadsbot`
   - `https://github.com/amolsarva/opensore`
   - `https://github.com/amolsarva/OpenSNORE`
