# drive-dedup

A two-phase Python toolkit to find duplicate files on an external drive, consolidate them into a clean folder structure, and optionally use Claude AI to categorize ambiguous files.

## What it does

**Phase 1 — Scan** (`phase1_scan.py`)
- Walks your entire drive
- Groups files by size, then computes SHA-256 only for size-matched candidates (fast)
- Treats `.photoslibrary` bundles as opaque units (no recursion into them)
- Outputs: `inventory.csv`, `duplicates.json`, `summary.txt`

**Phase 2 — Reorganize** (`phase2_reorganize.py`)
- Reads Phase 1 results
- Picks the best "canonical" copy from each duplicate group
- Assigns every file a destination in a clean `Consolidated/` folder:
  ```
  Consolidated/
    Photos/2019/04-Apr/
    Videos/2020/
    Documents/2018/
    Archives/2021/
    Code/my-project/
    Audio/
    Other/
  ```
- Generates `consolidate.sh` — a shell script of `cp` commands to review before running
- Optionally uses Claude API to categorize "Other" files intelligently

**Safety**: Everything uses `cp -n` (copy, never overwrite). Nothing is ever deleted. Originals stay intact.

## Quick Start

### 1. Edit `run.sh`
```bash
DRIVE="/Volumes/YOUR_DRIVE_NAME"   # find with: ls /Volumes/
CLAUDE_API_KEY="${ANTHROPIC_API_KEY:-}"  # optional — set in your shell
```

### 2. Run
```bash
bash run.sh
```

### 3. Review the plan
```bash
cat scan_results/summary.txt
open scan_results/duplicates.json
open scan_results/consolidate.sh
```

### 4. Execute when ready
```bash
bash scan_results/consolidate.sh
```

## Manual usage

```bash
# Phase 1 only
python3 phase1_scan.py /Volumes/MyDrive --output ./scan_results

# Phase 1 fast mode (inventory only, no hashing)
python3 phase1_scan.py /Volumes/MyDrive --output ./scan_results --skip-hashing

# Phase 2 dry run
python3 phase2_reorganize.py /Volumes/MyDrive --scan-dir ./scan_results

# Phase 2 with Claude AI categorization
export ANTHROPIC_API_KEY="your_api_key_here"
python3 phase2_reorganize.py /Volumes/MyDrive \
  --scan-dir ./scan_results \
  --claude-api-key "$ANTHROPIC_API_KEY"
```

## Requirements

- Python 3.8+
- No pip packages required for Phase 1
- `anthropic` pip package if using Claude categorization: `pip install anthropic`

## Expected runtime

| Drive size | Phase 1 scan | Phase 1 hashing | Phase 2 plan |
|-----------|-------------|----------------|-------------|
| 100 GB    | ~5 min      | ~10 min        | ~1 min      |
| 500 GB    | ~20 min     | ~40 min        | ~2 min      |
| 1 TB      | ~40 min     | ~90 min        | ~5 min      |

## How duplicates are picked

When multiple copies exist, the "canonical" copy is chosen by:
1. Preferring shallower folder depth
2. Preferring paths with year-like folders (`/2019/`)
3. Penalizing paths containing `backup`, `temp`, `old`, `copy`, etc.
