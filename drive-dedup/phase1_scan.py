#!/usr/bin/env python3
"""
Phase 1: Drive Scanner & Duplicate Detector — with resume support
=================================================================
Walks an external drive, fingerprints all files, detects exact duplicates.

RESUME BEHAVIOUR:
  - Saves a checkpoint every 100 items during scanning
  - Saves a checkpoint every 100 items during hashing
  - On restart, detects existing checkpoints and picks up from where it left off
  - Checkpoints stored in: <output_dir>/checkpoint_scan.json
                           <output_dir>/checkpoint_hash.json

Outputs:
  inventory.csv       — every file with metadata
  duplicates.json     — groups of exact duplicate files
  summary.txt         — human-readable report

Usage:
    python3 phase1_scan.py /Volumes/Sunflowers [--output ./scan_results]
    python3 phase1_scan.py /Volumes/Sunflowers --output ./scan_results  # resumes automatically
"""

import os, sys, csv, json, hashlib, argparse, time
from collections import defaultdict
from pathlib import Path
from datetime import datetime

# ── Config ────────────────────────────────────────────────────────────────────

OPAQUE_BUNDLES = {'.photoslibrary', '.photos library', '.app', '.fcpbundle', '.imovielibrary'}

CATEGORY_MAP = {
    'photo':    {'.jpg','.jpeg','.png','.gif','.heic','.heif','.tiff','.tif','.raw',
                 '.cr2','.nef','.arw','.bmp','.webp'},
    'video':    {'.mp4','.mov','.avi','.mkv','.m4v','.wmv','.flv','.3gp','.mts'},
    'audio':    {'.mp3','.m4a','.aac','.flac','.wav','.aiff','.ogg'},
    'document': {'.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.pages',
                 '.numbers','.key','.txt','.rtf','.md','.csv'},
    'email':    {'.mbox','.eml','.emlx','.msg'},
    'archive':  {'.zip','.tar','.gz','.bz2','.7z','.rar','.tgz'},
    'code':     {'.py','.js','.ts','.html','.css','.php','.rb','.java','.c','.cpp',
                 '.h','.sh','.sql','.json','.xml','.yaml','.yml'},
    'library':  {'.photoslibrary','.imovielibrary','.fcpbundle'},
}

CHECKPOINT_INTERVAL = 100  # save progress every N items

def get_category(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in CATEGORY_MAP['library']:
        return 'library'
    for cat, exts in CATEGORY_MAP.items():
        if suffix in exts:
            return cat
    return 'other'

# ── Hashing ───────────────────────────────────────────────────────────────────

def full_sha256(path: Path) -> str | None:
    h = hashlib.sha256()
    try:
        with open(path, 'rb') as f:
            while chunk := f.read(65536):
                h.update(chunk)
        return h.hexdigest()
    except (OSError, PermissionError):
        return None

def dir_size(path: Path) -> int:
    total = 0
    try:
        for entry in os.scandir(path):
            if entry.is_file(follow_symlinks=False):
                total += entry.stat().st_size
            elif entry.is_dir(follow_symlinks=False):
                total += dir_size(Path(entry.path))
    except (OSError, PermissionError):
        pass
    return total

def dir_sha256(path: Path) -> str | None:
    h = hashlib.sha256()
    try:
        all_files = sorted(path.rglob('*'))
        for f in all_files:
            if f.is_file(follow_symlinks=False):
                fh = full_sha256(f)
                if fh:
                    h.update(f.name.encode())
                    h.update(fh.encode())
    except (OSError, PermissionError):
        return None
    return h.hexdigest()

# ── Checkpoint helpers ────────────────────────────────────────────────────────

def save_checkpoint(data: dict, path: Path):
    tmp = path.with_suffix('.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f)
    tmp.replace(path)  # atomic replace

def load_checkpoint(path: Path) -> dict | None:
    if path.exists():
        try:
            with open(path, encoding='utf-8') as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            print(f"   ⚠️  Checkpoint file corrupt, ignoring: {path}")
    return None

# ── Scanner with resume ───────────────────────────────────────────────────────

def is_opaque_bundle(path: Path) -> bool:
    suffix = path.suffix.lower()
    return suffix in OPAQUE_BUNDLES or path.name.lower().endswith('.photos library')

def should_skip(path: Path) -> bool:
    name = path.name
    if name.startswith('.') or name in {'Thumbs.db','desktop.ini','.DS_Store',
                                         '.Spotlight-V100','.Trashes','.fseventsd',
                                         '.TemporaryItems','.VolumeIcon.icns','Consolidated'}:
        return True
    return False

def scan_drive(root: Path, out_dir: Path) -> list[dict]:
    checkpoint_path = out_dir / 'checkpoint_scan.json'
    ckpt = load_checkpoint(checkpoint_path)

    if ckpt:
        records = ckpt['records']
        visited_paths = set(ckpt['visited_paths'])
        print(f"\n🔄 Resuming scan — {len(records):,} items already scanned, "
              f"{len(visited_paths):,} directories already visited")
    else:
        records = []
        visited_paths = set()
        print(f"\n🔍 Starting fresh scan of: {root}")

    print("   Progress shown every 500 items. Checkpointed every 100.\n")

    total_scanned = len(records)
    start = time.time()

    def walk(path: Path, depth: int = 0):
        nonlocal total_scanned

        path_str = str(path)
        if path_str in visited_paths:
            return  # already done in a previous run

        try:
            entries = list(os.scandir(path))
        except (PermissionError, OSError) as e:
            print(f"   ⚠️  Skipping {path}: {e}")
            visited_paths.add(path_str)
            return

        for entry in entries:
            p = Path(entry.path)
            if should_skip(p):
                continue
            if entry.is_symlink():
                continue

            if entry.is_dir(follow_symlinks=False):
                if is_opaque_bundle(p):
                    size = dir_size(p)
                    mtime = entry.stat().st_mtime
                    records.append({
                        'path': str(p),
                        'name': p.name,
                        'size': size,
                        'mtime': mtime,
                        'mtime_str': datetime.fromtimestamp(mtime).strftime('%Y-%m-%d'),
                        'category': get_category(p),
                        'is_bundle': True,
                        'sha256': None,
                        'depth': depth,
                    })
                    total_scanned += 1
                else:
                    walk(p, depth + 1)
            elif entry.is_file(follow_symlinks=False):
                stat = entry.stat()
                records.append({
                    'path': str(p),
                    'name': p.name,
                    'size': stat.st_size,
                    'mtime': stat.st_mtime,
                    'mtime_str': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d'),
                    'category': get_category(p),
                    'is_bundle': False,
                    'sha256': None,
                    'depth': depth,
                })
                total_scanned += 1

            if total_scanned % CHECKPOINT_INTERVAL == 0:
                save_checkpoint({'records': records, 'visited_paths': list(visited_paths)}, checkpoint_path)

            if total_scanned % 500 == 0:
                elapsed = time.time() - start
                rate = total_scanned / max(elapsed, 1)
                print(f"   📄 {total_scanned:,} items scanned... ({elapsed:.0f}s elapsed, {rate:.0f}/s)")

        visited_paths.add(path_str)
        save_checkpoint({'records': records, 'visited_paths': list(visited_paths)}, checkpoint_path)

    walk(root)

    # Save final checkpoint
    save_checkpoint({'records': records, 'visited_paths': list(visited_paths)}, checkpoint_path)

    elapsed = time.time() - start
    print(f"\n✅ Scan complete: {len(records):,} items in {elapsed:.1f}s")
    return records

# ── Duplicate detection with resume ──────────────────────────────────────────

def find_duplicates(records: list[dict], out_dir: Path) -> list[dict]:
    checkpoint_path = out_dir / 'checkpoint_hash.json'
    ckpt = load_checkpoint(checkpoint_path)

    # Build hash cache — seed from BOTH checkpoint file AND any sha256s
    # already present in the inventory rows (handles interrupted previous runs)
    hash_cache = {}
    if ckpt:
        hash_cache = ckpt.get('hash_cache', {})

    # Seed from inventory rows that already have hashes (e.g. from a prior partial run)
    seeded_from_inventory = 0
    for r in records:
        h = r.get('sha256')
        if h and isinstance(h, str) and len(h) == 64 and r['path'] not in hash_cache:
            hash_cache[r['path']] = h
            seeded_from_inventory += 1

    if hash_cache:
        print(f"\n🔄 Resuming hashing — {len(hash_cache):,} files already hashed "
              f"({seeded_from_inventory:,} loaded from inventory, "
              f"{len(hash_cache) - seeded_from_inventory:,} from checkpoint)")
    else:
        print(f"\n🔐 Starting fresh hashing pass...")

    # Pass 1: group by size
    size_groups = defaultdict(list)
    for r in records:
        if r['size'] > 0:
            size_groups[r['size']].append(r)

    candidate_groups = {size: group for size, group in size_groups.items() if len(group) > 1}
    candidate_count = sum(len(g) for g in candidate_groups.values())
    already_done = sum(1 for g in candidate_groups.values() for r in g if r['path'] in hash_cache)

    print(f"   Size-collision groups: {len(candidate_groups):,} ({candidate_count:,} files to hash, {already_done:,} already done)")

    # Pass 2: full hash (skip already cached)
    hash_groups = defaultdict(list)
    hashed_this_run = 0
    start = time.time()

    for size, group in candidate_groups.items():
        for r in group:
            p = Path(r['path'])
            path_str = r['path']

            if path_str in hash_cache:
                h = hash_cache[path_str]
            else:
                if r['is_bundle']:
                    h = dir_sha256(p)
                else:
                    h = full_sha256(p)

                if h:
                    hash_cache[path_str] = h
                hashed_this_run += 1

                if hashed_this_run % CHECKPOINT_INTERVAL == 0:
                    save_checkpoint({'hash_cache': hash_cache}, checkpoint_path)
                    elapsed = time.time() - start
                    total_done = already_done + hashed_this_run
                    pct = (total_done / candidate_count * 100) if candidate_count else 0
                    print(f"   🔐 {total_done:,}/{candidate_count:,} hashed ({pct:.1f}%) — {elapsed:.0f}s elapsed")

            if h:
                r['sha256'] = h
                hash_groups[h].append(r)

    # Final checkpoint
    save_checkpoint({'hash_cache': hash_cache}, checkpoint_path)

    duplicates = [group for group in hash_groups.values() if len(group) > 1]
    print(f"\n✅ Hashing complete: {len(duplicates):,} duplicate groups found")
    return duplicates

# ── Output writers ────────────────────────────────────────────────────────────

def write_inventory(records: list[dict], out_dir: Path):
    out = out_dir / 'inventory.csv'
    fieldnames = ['path','name','size','mtime_str','category','is_bundle','sha256','depth']
    with open(out, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in records:
            writer.writerow({k: r.get(k, '') for k in fieldnames})
    print(f"   📄 inventory.csv — {len(records):,} items")

def write_duplicates(dupes: list[dict], out_dir: Path):
    out = out_dir / 'duplicates.json'

    def wasted(group):
        return group[0]['size'] * (len(group) - 1)

    sorted_dupes = sorted(dupes, key=wasted, reverse=True)
    output = []
    for group in sorted_dupes:
        output.append({
            'sha256': group[0]['sha256'],
            'size_bytes': group[0]['size'],
            'size_mb': round(group[0]['size'] / 1_048_576, 2),
            'count': len(group),
            'wasted_mb': round(wasted(group) / 1_048_576, 2),
            'category': group[0]['category'],
            'copies': [{'path': r['path'], 'mtime': r['mtime_str'], 'depth': r['depth']} for r in group]
        })

    with open(out, 'w', encoding='utf-8') as f:
        json.dump(output, f, indent=2)
    print(f"   📄 duplicates.json — {len(output):,} groups")
    return output

def write_summary(records: list[dict], dupes_output: list[dict], out_dir: Path):
    out = out_dir / 'summary.txt'

    total_size = sum(r['size'] for r in records)
    total_wasted_mb = sum(d['wasted_mb'] for d in dupes_output)
    total_dupe_files = sum(d['count'] - 1 for d in dupes_output)

    cat_stats = defaultdict(lambda: {'count': 0, 'size': 0})
    for r in records:
        cat_stats[r['category']]['count'] += 1
        cat_stats[r['category']]['size'] += r['size']

    lines = [
        "=" * 60,
        "  DRIVE SCAN SUMMARY",
        f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        "=" * 60,
        "",
        f"  Total items scanned : {len(records):,}",
        f"  Total size          : {total_size / 1_073_741_824:.2f} GB",
        f"  Duplicate groups    : {len(dupes_output):,}",
        f"  Redundant files     : {total_dupe_files:,}",
        f"  Wasted space        : {total_wasted_mb / 1024:.2f} GB",
        "",
        "─" * 60,
        "  BREAKDOWN BY CATEGORY",
        "─" * 60,
    ]
    for cat, stats in sorted(cat_stats.items(), key=lambda x: -x[1]['size']):
        size_gb = stats['size'] / 1_073_741_824
        lines.append(f"  {cat:<12} {stats['count']:>6,} items   {size_gb:>7.2f} GB")

    lines += ["", "─" * 60, "  TOP 20 LARGEST DUPLICATE GROUPS", "─" * 60]
    for i, d in enumerate(dupes_output[:20], 1):
        lines.append(f"\n  #{i}  [{d['category']}]  {d['size_mb']:.1f} MB × {d['count']} copies = {d['wasted_mb']:.1f} MB wasted")
        for copy in d['copies']:
            lines.append(f"       {copy['path']}")

    lines += [
        "", "=" * 60, "  NEXT STEPS", "=" * 60, "",
        "  1. Review duplicates.json to understand what's duplicated",
        "  2. Run phase2_reorganize.py to generate a consolidation plan",
        "     python3 phase2_reorganize.py /Volumes/Sunflowers --scan-dir ./scan_results",
        "  3. Review the generated shell script before running it", "",
    ]

    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    print(f"   📄 summary.txt written")
    print('\n' + '\n'.join(lines))

# ── Status detector ───────────────────────────────────────────────────────────

def detect_status(out_dir: Path) -> str:
    """
    Returns one of:
      'fresh'        — no prior work found
      'scan_partial' — scan checkpoint exists but inventory.csv is missing
      'scan_done'    — inventory.csv exists, hashing not yet started
      'hash_partial' — inventory exists with some hashes, but not all files hashed
      'complete'     — inventory.csv exists and every candidate file has a sha256
    """
    ckpt_scan = out_dir / 'checkpoint_scan.json'
    inventory  = out_dir / 'inventory.csv'

    if not inventory.exists():
        if ckpt_scan.exists():
            return 'scan_partial'
        return 'fresh'

    # Inventory exists — check how complete the hashing is
    # Sample the inventory to count hashed vs unhashed
    total = 0
    hashed = 0
    try:
        with open(inventory, encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                total += 1
                if row.get('sha256', '').strip():
                    hashed += 1
    except OSError:
        return 'scan_partial'

    if total == 0:
        return 'scan_partial'
    if hashed == 0:
        return 'scan_done'
    if hashed < total:
        return 'hash_partial'
    return 'complete'

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='Phase 1: Scan drive and detect duplicates (with resume)')
    parser.add_argument('drive', help='Path to the external drive')
    parser.add_argument('--output', '-o', default='./scan_results')
    parser.add_argument('--skip-hashing', action='store_true',
                        help='Skip SHA256 hashing — just produce inventory')
    parser.add_argument('--force-restart', action='store_true',
                        help='Ignore all checkpoints and start completely fresh')
    args = parser.parse_args()

    root = Path(args.drive)
    if not root.exists():
        print(f"❌ Error: {root} does not exist. Is the drive mounted?")
        sys.exit(1)

    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.force_restart:
        for f in ['checkpoint_scan.json','checkpoint_hash.json','inventory.csv','duplicates.json','summary.txt']:
            p = out_dir / f
            if p.exists():
                p.unlink()
                print(f"   🗑  Removed {f}")

    status = detect_status(out_dir)

    print(f"""
╔══════════════════════════════════════════════════════╗
║          DRIVE DEDUP — Phase 1: Scan                 ║
╠══════════════════════════════════════════════════════╣
║  Drive  : {str(root):<43}║
║  Output : {str(out_dir):<43}║
║  Status : {status:<43}║
╚══════════════════════════════════════════════════════╝
    """)

    if status == 'complete':
        print("✅ Hashing is complete.")
        print("   Run phase2_reorganize.py to build the consolidation plan.")
        print("   Use --force-restart to re-scan and re-hash from scratch.")
        return

    # ── SCAN PHASE ──
    if status in ('fresh', 'scan_partial'):
        records = scan_drive(root, out_dir)
        print("\n📝 Writing inventory...")
        write_inventory(records, out_dir)
    else:
        # scan_done or hash_partial — load existing inventory
        print(f"\n📂 Loading existing inventory...")
        records = []
        with open(out_dir / 'inventory.csv', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                row['size'] = int(row.get('size', 0) or 0)
                row['depth'] = int(row.get('depth', 0) or 0)
                row['is_bundle'] = row.get('is_bundle', '').lower() == 'true'
                row['mtime'] = float(row.get('mtime', 0) or 0) if 'mtime' in row else 0
                row['sha256'] = row.get('sha256') or None
                records.append(row)
        has_hash = sum(1 for r in records if r.get('sha256'))
        print(f"   Loaded {len(records):,} items — {has_hash:,} already hashed, "
              f"{len(records)-has_hash:,} still need hashing")

    if args.skip_hashing:
        print("\n⏭️  Skipping hashing (--skip-hashing flag set)")
        return

    # ── HASH PHASE ──
    print("\n🔐 Computing hashes for duplicate candidates...")
    dupes = find_duplicates(records, out_dir)

    # Re-write inventory with hashes filled in
    print("\n📝 Writing final outputs...")
    write_inventory(records, out_dir)
    dupes_output = write_duplicates(dupes, out_dir)
    write_summary(records, dupes_output, out_dir)

    print(f"\n🎉 Done! Results saved to: {out_dir.absolute()}")
    print(f"   Next: python3 phase2_reorganize.py /Volumes/Sunflowers --scan-dir {out_dir}")

if __name__ == '__main__':
    main()
