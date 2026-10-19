# Maintenance: releasing mac-scripts

Since 2026-10-17 everything downstream of this repo is released by **one command**:

```bash
supporting-files/publish/release.sh            # dry run: what is stale (changes nothing)
supporting-files/publish/release.sh --local-only   # fix this Mac only: Python, catalog, installed copies, artifacts
supporting-files/publish/release.sh --go       # all of it, then push GitHub + amolsarva.com and verify live
```

Backstage ▸ ⭐ **Release mac-scripts**: Launch = `--go`, Install = `--local-only`, Repair = dry run.
Log: `~/Library/Logs/mac-scripts-release.log`.

What it runs, in order (each piece also works on its own):

| Step | Tool | Notes |
|---|---|---|
| Python | `python-guard/run.sh ensure` | Homebrew python3 + matching `python-tk@3.x` + tool venvs on the current version |
| Catalog | `publish/build_catalog.py` | README tables, `scripts.html` apps list, `catalog/launcher.json`, `.gitignore` block, announcement drafts. `--check` = drift report |
| Lint | `publish/deps.py lint` | Backstage `scripts.json`/`setup.json`, launcher entries, installs/artifacts commands all resolve |
| Validate | `publish/publish.sh` (dry run) | bash/python syntax, store page JS (node), git-privacy + private-file gate |
| Installs | `publish/deps.py sync` (`installed.sh sync`) | re-installs every installed copy whose `sources` changed (per `tool.json` `installs`) |
| Artifacts | `publish/deps.py artifacts` | Backstage dmg + `latest.json`, extension zips → `../amolsarva.com/downloads/` |
| Publish | `publish/publish.sh --go` | commit + push amols-app-store, copy `scripts.html` + downloads into amolsarva.com, push, wait for live |
| Nested | in `release.sh` | `screenshot-mover`, `imessage-cleanup`: commit tracked changes + push |
| Verify | `deps.py status`, `build_catalog.py --check`, live `latest.json` | |

Live surfaces: https://amolsarva.com/scripts · https://amolsarva.com/downloads/backstage/latest.json ·
https://github.com/amolsarva/amols-app-store · github.com/amolsarva/{screenshot-mover,imessage-cleanup}.
The website repo is `~/Documents/root/amolsarva.com` (GitHub Pages; Cloudflare in front).

Pushes use SSH, falling back to HTTPS with the Keychain login; that's why `--go` must run on a Mac.
