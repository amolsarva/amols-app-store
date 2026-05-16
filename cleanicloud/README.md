# cleanicloud

Interactive iCloud Drive cleaner — finds duplicate files and large file clusters, then asks before deleting anything.

## What it does

Scans your entire `~/Library/Mobile Documents` (iCloud Drive) in two passes:

**Pass 1 — Duplicate detection**
- Hashes every file over 4 KB using SHA-256
- Groups identical files together
- For each group, shows you all copies and lets you choose which to delete (keeps the newest/largest by default)

**Pass 2 — Large file detection**
- Finds files over a configurable size threshold (default: 200 MB)
- Groups them by file extension and modification time proximity
- Offers to delete the whole cluster at once, or walk through them one by one

Nothing is deleted without an explicit `y` confirmation.

## Usage

```bash
bash cleanicloud.sh
```

Run it from Terminal. It will walk you through everything interactively.

## Configuration

Edit the top of the script:

```bash
LARGE_THRESHOLD_MB=200   # files larger than this are flagged as "large"
WINDOW_MINUTES=30        # time window for grouping similar large files
```

## Requirements

- macOS
- `shasum` (pre-installed on macOS)

## Safety

- **Interactive only** — every deletion requires explicit `y` input
- Files are permanently deleted with `rm` (not moved to Trash), so review carefully
- Run a backup before using this on an iCloud Drive with irreplaceable files
- Skips `.Trash` directories automatically
