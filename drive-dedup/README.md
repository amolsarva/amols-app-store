# Drive Dedup & Consolidator

A two-phase Python toolkit to find duplicate files, consolidate your drive, and optionally use Claude AI to categorize ambiguous files.

## What it does

**Phase 1 — Scan** (`phase1_scan.py`)
- Walks your entire drive
- Groups files by size, then computes SHA256 only for size-matched candidates (fast)
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
    Mail/amol-sarva/
    Libraries/           ← .photoslibrary bundles
    Documents/2018/
    Archives/2021/
    Code/my-project/
    Audio/
    Other/
  ```
- Generates `consolidate.sh` — a shell script of `cp` commands to review
- Optionally uses Claude API to categorize "Other" files intelligently

**Safety**: Everything uses `cp -n` (copy, skip if exists). Nothing is ever deleted. Your originals stay intact.

---

## Quick Start

### 1. Edit `run.sh`
```bash
DRIVE="/Volumes/YOUR_DRIVE_NAME"   # find this with: ls /Volumes/
CLAUDE_API_KEY=""                  # optional — get from console.anthropic.com
```

### 2. Run it
```bash
bash run.sh
```

### 3. Review the plan
```bash
cat scan_results/summary.txt
# Check for anything surprising in:
open scan_results/duplicates.json
open scan_results/consolidate.sh
```

### 4. Execute when ready
```bash
bash scan_results/consolidate.sh
```

---

## Manual usage

```bash
# Phase 1 only (just scan, no reorganization)
python3 phase1_scan.py /Volumes/MyDrive --output ./scan_results

# Phase 1 fast mode (no hashing — just inventory)
python3 phase1_scan.py /Volumes/MyDrive --output ./scan_results --skip-hashing

# Phase 2 dry run
python3 phase2_reorganize.py /Volumes/MyDrive --scan-dir ./scan_results

# Phase 2 with Claude AI categorization
python3 phase2_reorganize.py /Volumes/MyDrive \
  --scan-dir ./scan_results \
  --claude-api-key sk-ant-YOUR-KEY-HERE

# Phase 2 execute immediately (runs cp commands)
python3 phase2_reorganize.py /Volumes/MyDrive --scan-dir ./scan_results --execute
```

---

## Finding your drive name

```bash
ls /Volumes/
```

Or in Finder: look at what appears in the sidebar when the drive is plugged in.

---

## Expected runtime

| Drive size | Phase 1 scan | Phase 1 hashing | Phase 2 plan |
|-----------|-------------|----------------|-------------|
| 100 GB    | ~5 min      | ~10 min        | ~1 min      |
| 500 GB    | ~20 min     | ~40 min        | ~2 min      |
| 1 TB      | ~40 min     | ~90 min        | ~5 min      |

Hashing time depends heavily on drive speed. USB 3.0 drives are much faster than USB 2.0.

---

## How duplicates are picked

When multiple copies of a file exist, the "canonical" copy is chosen by:
1. Preferring shallower folder depth (more likely an organized original)
2. Preferring paths with year-like folders (`/2019/`)
3. Penalizing paths containing `backup`, `temp`, `old`, `copy`, etc.

---

## Claude API cost estimate

At ~$0.015 per 1K input tokens, categorizing 500 "Other" files costs roughly **$0.05–0.20**. The `--claude-max-files` flag (default: 500) keeps costs predictable.

Get an API key at: https://console.anthropic.com
