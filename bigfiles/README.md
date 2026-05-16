# bigfiles

Find the biggest folders on your Mac and instantly see whether they're actively used or safe to archive/delete.

## What it does

Two steps in one script:

1. **Scan** — finds the largest directories under your configured seed folders (e.g. `~/Library`, `~/Desktop`) using `du`, ranked by size.
2. **Analyze** — for each big folder, it checks:
   - Total file count
   - Date of last modification
   - Files written in the last 90 days
   - Files read in the last 90 days
   - **Verdict**: ACTIVE / LOW ACTIVITY / PROBABLY SAFE ARCHIVE

Color-coded terminal output makes the results easy to scan at a glance.

## Usage

```bash
bash bigfiles.sh
```

You may be prompted for your password — `sudo` is used to read protected Library directories.

## Configuration

Edit the top of the script to change:

```bash
AGE_DAYS=90        # How many days back to look for activity
MAX_FOLDERS=30     # How many large folders to examine
SEED_FOLDERS=(     # Where to start scanning
    "/Users/yourname/Library"
    "/Users/yourname/Desktop"
)
```

## Requirements

- macOS
- `sudo` access (to read `~/Library` subdirectories)

## Notes

- Results are also written to `/tmp/bigfolders.txt` for reference.
- The verdict is a heuristic, not a guarantee — always review before deleting anything.
- Particularly useful before clearing space before a Mac migration or upgrade.
