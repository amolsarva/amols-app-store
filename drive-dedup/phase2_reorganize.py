#!/usr/bin/env python3
"""
Phase 2: Reorganizer — Dedup + Consolidate (with resume support)
=================================================================
Reads Phase 1 results and produces a consolidated folder structure.

RESUME BEHAVIOUR:
  - Tracks which copy operations have already been completed
  - On restart, skips already-copied files and continues from where it left off
  - Checkpoint: <scan_dir>/checkpoint_copy.json

Output on /Volumes/Sunflowers:
  Consolidated/
    Photos/YYYY/MM/
    Videos/YYYY/
    Mail/account-name/
    Libraries/           ← .photoslibrary bundles (one canonical copy each)
    Documents/YYYY/
    Archives/YYYY/
    Code/project-name/
    Audio/
    Other/

Usage:
    # Dry run — generates consolidate.sh, nothing moves yet
    python3 phase2_reorganize.py /Volumes/Sunflowers --scan-dir ./scan_results

    # With Claude API for smart categorization of ambiguous files
    python3 phase2_reorganize.py /Volumes/Sunflowers --scan-dir ./scan_results --claude-api-key "$ANTHROPIC_API_KEY"

    # Execute directly (resumes if interrupted)
    python3 phase2_reorganize.py /Volumes/Sunflowers --scan-dir ./scan_results --execute
"""

import os, sys, json, csv, re, argparse, shutil
from pathlib import Path
from datetime import datetime
from collections import defaultdict
from typing import Optional

# ── Date extraction ───────────────────────────────────────────────────────────

DATE_PATTERNS = [
    (re.compile(r'(\d{4})[_\-]?(\d{2})[_\-]?(\d{2})'), lambda m: (int(m[0]), int(m[1]), int(m[2]))),
    (re.compile(r'(?:IMG|VID|DSC|DSCN|DCIM|Photo|Screen)[_\-]?(\d{4})(\d{2})(\d{2})'), lambda m: (int(m[0]), int(m[1]), int(m[2]))),
    (re.compile(r'(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)[_\- ](\d{4})', re.I),
     lambda m: (int(m[1]), {'jan':1,'feb':2,'mar':3,'apr':4,'may':5,'jun':6,'jul':7,'aug':8,'sep':9,'oct':10,'nov':11,'dec':12}[m[0][:3].lower()], 1)),
]

MONTH_NAMES = {1:'01-Jan',2:'02-Feb',3:'03-Mar',4:'04-Apr',5:'05-May',6:'06-Jun',
               7:'07-Jul',8:'08-Aug',9:'09-Sep',10:'10-Oct',11:'11-Nov',12:'12-Dec'}

def extract_date_from_name(filename: str) -> Optional[tuple]:
    for pattern, extractor in DATE_PATTERNS:
        m = pattern.search(filename)
        if m:
            try:
                year, month, day = extractor(m.groups())
                if 1990 <= year <= 2030 and 1 <= month <= 12 and 1 <= day <= 31:
                    return (year, month, day)
            except (ValueError, KeyError, IndexError):
                continue
    return None

def mtime_to_date(mtime: float) -> tuple:
    dt = datetime.fromtimestamp(mtime)
    return (dt.year, dt.month, dt.day)

# ── Mail account inference ────────────────────────────────────────────────────

MAIL_ACCOUNT_PATTERNS = [
    (re.compile(r'amolpeekly|peekly', re.I), 'amol-peekly'),
    (re.compile(r'extradrwn|drwn', re.I), 'amol-drwn'),
    (re.compile(r'getpeek', re.I), 'amol-getpeek'),
    (re.compile(r'sarva', re.I), 'amol-sarva'),
    (re.compile(r'gmail', re.I), 'gmail'),
    (re.compile(r'tbird|thunderbird', re.I), 'thunderbird-archive'),
    (re.compile(r'outlook|hotmail', re.I), 'outlook-archive'),
    (re.compile(r'yahoo', re.I), 'yahoo'),
    (re.compile(r'apple.mail|mail.arch|mail arch', re.I), 'apple-mail-archive'),
]

def infer_mail_account(path: str) -> str:
    for pattern, account in MAIL_ACCOUNT_PATTERNS:
        if pattern.search(path):
            return account
    return 'unknown-account'

# ── Claude API categorization ─────────────────────────────────────────────────

def categorize_with_claude(files: list[dict], api_key: str, batch_size: int = 50) -> dict:
    try:
        import anthropic
    except ImportError:
        print("⚠️  anthropic package not installed. Run: pip3 install anthropic")
        return {}

    client = anthropic.Anthropic(api_key=api_key)
    results = {}

    for i in range(0, len(files), batch_size):
        batch = files[i:i + batch_size]
        file_list = '\n'.join([
            f"- {Path(f['path']).name} | size: {f['size_bytes']/1024:.1f}KB | mtime: {f.get('mtime_str','?')} | parent: {Path(f['path']).parent.name}"
            for f in batch
        ])

        prompt = f"""You are helping organize a personal archive drive belonging to Amol Sarva. Given these files, suggest the best subfolder path for each within a 'Consolidated/' directory. Use short, clean paths like:
  Documents/Work, Documents/Personal, Photos/Events, Photos/Family, Projects/WebDev, Projects/Design,
  Mail/Archives, Videos/Home, Videos/Screen-recordings, Audio/Music, Other/Misc

Files:
{file_list}

Respond with JSON only — a dict mapping filename to suggested path. Example:
{{"resume_2019.pdf": "Documents/Work", "vacation_2015.jpg": "Photos/Family"}}
Only use the filename (not full path) as the key."""

        try:
            response = client.messages.create(
                model="claude-opus-4-6",
                max_tokens=2000,
                messages=[{"role": "user", "content": prompt}]
            )
            text = response.content[0].text.strip()
            json_match = re.search(r'\{.*\}', text, re.DOTALL)
            if json_match:
                suggestions = json.loads(json_match.group())
                for f in batch:
                    name = Path(f['path']).name
                    if name in suggestions:
                        results[f['path']] = suggestions[name]
        except Exception as e:
            print(f"   ⚠️  Claude API error on batch {i//batch_size + 1}: {e}")

        done = min(i + batch_size, len(files))
        print(f"   🤖 Claude categorized {done}/{len(files)} files")

    return results

# ── Canonical copy picker ─────────────────────────────────────────────────────

def pick_canonical(group: list[dict]) -> dict:
    def score(r):
        path = r['path'].lower()
        penalty = sum(10 for bad in ['temp','tmp','backup','bak','old','copy','duplicate','archive'] if bad in path)
        year_bonus = len(re.findall(r'/\d{4}/', path)) * 5
        return -r.get('depth', 0) + year_bonus - penalty
    return max(group, key=score)

# ── Destination path builder ──────────────────────────────────────────────────

def build_dest_path(record: dict, consolidated_root: Path, claude_suggestions: dict = None) -> Path:
    path = Path(record['path'])
    name = path.name
    cat = record['category']
    mtime = record.get('mtime', 0)

    if claude_suggestions and record['path'] in claude_suggestions:
        return consolidated_root / claude_suggestions[record['path']] / name

    # Date: filename → parent folder names → mtime
    date = extract_date_from_name(name)
    if date is None:
        for part in reversed(path.parts[:-1]):
            date = extract_date_from_name(part)
            if date:
                break
    if date is None and mtime:
        try:
            date = mtime_to_date(float(mtime))
        except (ValueError, OSError):
            date = None

    year = str(date[0]) if date else 'Unknown'
    month = MONTH_NAMES.get(date[1], '00-Unknown') if (date and date[1]) else ''

    if cat == 'photo':
        return consolidated_root / 'Photos' / year / (month or name) / (name if month else '')
    elif cat == 'video':
        return consolidated_root / 'Videos' / year / name
    elif cat == 'audio':
        return consolidated_root / 'Audio' / name
    elif cat == 'email':
        return consolidated_root / 'Mail' / infer_mail_account(record['path']) / name
    elif cat == 'library':
        return consolidated_root / 'Libraries' / name
    elif cat == 'archive':
        return consolidated_root / 'Archives' / year / name
    elif cat == 'code':
        return consolidated_root / 'Code' / path.parent.name[:40] / name
    elif cat == 'document':
        return consolidated_root / 'Documents' / year / name
    else:
        return consolidated_root / 'Other' / name

# ── Checkpoint helpers ────────────────────────────────────────────────────────

def save_checkpoint(data: dict, path: Path):
    tmp = path.with_suffix('.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f)
    tmp.replace(path)

def load_checkpoint(path: Path) -> dict | None:
    if path.exists():
        try:
            with open(path, encoding='utf-8') as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return None

# ── Shell script generator ────────────────────────────────────────────────────

def generate_shell_script(copy_ops: list[tuple], out_path: Path):
    lines = [
        '#!/bin/bash',
        '# Drive Consolidation Script — REVIEW BEFORE RUNNING',
        f'# Generated: {datetime.now().strftime("%Y-%m-%d %H:%M")}',
        f'# Total operations: {len(copy_ops)}',
        '#',
        '# This script COPIES files (never deletes originals).',
        '# Safe to re-run — existing files are skipped (cp -n).',
        '',
        'set -e',
        'echo "Starting consolidation..."',
        '',
    ]

    dest_dirs = sorted(set(str(Path(dst).parent) for _, dst in copy_ops))
    lines.append('# Create destination directories')
    for d in dest_dirs:
        lines.append(f'mkdir -p "{d}"')

    lines += ['', '# Copy files']
    total = len(copy_ops)
    for i, (src, dst) in enumerate(copy_ops, 1):
        if i % 500 == 0:
            lines.append(f'echo "Progress: {i}/{total}..."')
        if os.path.isdir(src):
            lines.append(f'cp -rn "{src}" "{dst}"')
        else:
            lines.append(f'cp -n "{src}" "{dst}"')

    lines += ['', f'echo "✅ Done! {total} files consolidated."']
    if copy_ops:
        lines.append(f'echo "Consolidated folder: {str(Path(copy_ops[0][1]).parents[1])}"')

    with open(out_path, 'w') as f:
        f.write('\n'.join(lines))
    os.chmod(out_path, 0o755)
    print(f"   📄 consolidate.sh — {len(copy_ops):,} operations")

# ── Execute with resume ───────────────────────────────────────────────────────

def execute_with_resume(copy_ops: list[tuple], scan_dir: Path):
    checkpoint_path = scan_dir / 'checkpoint_copy.json'
    ckpt = load_checkpoint(checkpoint_path)
    completed = set(ckpt.get('completed', [])) if ckpt else set()

    remaining = [(src, dst) for src, dst in copy_ops if dst not in completed]
    total = len(copy_ops)
    already_done = len(completed)

    if already_done:
        print(f"\n🔄 Resuming copy — {already_done:,} already done, {len(remaining):,} remaining")
    else:
        print(f"\n🚀 Starting copy — {total:,} files to consolidate")

    errors = []
    copied = 0
    start_time = __import__('time').time()

    for i, (src, dst) in enumerate(remaining, 1):
        try:
            dst_path = Path(dst)
            dst_path.parent.mkdir(parents=True, exist_ok=True)

            if dst_path.exists():
                completed.add(dst)
                continue

            if os.path.isdir(src):
                shutil.copytree(src, dst, dirs_exist_ok=False)
            else:
                shutil.copy2(src, dst)

            completed.add(dst)

            if i % 100 == 0:
                save_checkpoint({'completed': list(completed)}, checkpoint_path)
                elapsed = __import__('time').time() - start_time
                rate = i / max(elapsed, 1)
                total_done = already_done + i
                pct = total_done / total * 100
                print(f"   📋 {total_done:,}/{total:,} copied ({pct:.1f}%) — {rate:.1f}/s")

        except Exception as e:
            errors.append({'src': src, 'dst': dst, 'error': str(e)})
            print(f"   ⚠️  Failed: {Path(src).name} → {e}")

    save_checkpoint({'completed': list(completed)}, checkpoint_path)

    total_done = already_done + copied + len(remaining) - len(errors)
    print(f"\n✅ Copy complete: {len(completed):,}/{total:,} files")

    if errors:
        errors_path = scan_dir / 'copy_errors.json'
        with open(errors_path, 'w') as f:
            json.dump(errors, f, indent=2)
        print(f"   ⚠️  {len(errors)} errors — see {errors_path}")

    # Clean up checkpoint on full success
    if not errors and len(completed) >= total:
        checkpoint_path.unlink(missing_ok=True)
        print("   🗑  Checkpoint cleared (run complete)")

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='Phase 2: Reorganize and consolidate (with resume)')
    parser.add_argument('drive', help='Path to external drive (e.g. /Volumes/Sunflowers)')
    parser.add_argument('--scan-dir', '-s', default='./scan_results')
    parser.add_argument('--output-folder', default='Consolidated')
    parser.add_argument('--claude-api-key', default=None)
    parser.add_argument('--claude-max-files', type=int, default=500)
    parser.add_argument('--execute', action='store_true',
                        help='Execute the copy operations directly (with resume support)')
    args = parser.parse_args()

    drive = Path(args.drive)
    scan_dir = Path(args.scan_dir)
    consolidated = drive / args.output_folder

    # Detect resume state
    copy_ckpt = scan_dir / 'checkpoint_copy.json'
    ckpt = load_checkpoint(copy_ckpt)
    already_copied = len(ckpt.get('completed', [])) if ckpt else 0
    resume_note = f"🔄 RESUMING ({already_copied:,} already done)" if already_copied else "🟡 DRY RUN" if not args.execute else "🔴 EXECUTE"

    print(f"""
╔══════════════════════════════════════════════════════╗
║       DRIVE DEDUP — Phase 2: Reorganize              ║
╠══════════════════════════════════════════════════════╣
║  Drive       : {str(drive):<41}║
║  Scan dir    : {str(scan_dir):<41}║
║  Output      : {str(consolidated):<41}║
║  Claude API  : {'✅ enabled' if args.claude_api_key else '❌ disabled':41}║
║  Mode        : {resume_note:<41}║
╚══════════════════════════════════════════════════════╝
    """)

    # Load inventory
    inventory_path = scan_dir / 'inventory.csv'
    if not inventory_path.exists():
        print(f"❌ inventory.csv not found at {inventory_path}")
        print("   Run phase1_scan.py first.")
        sys.exit(1)

    records = []
    with open(inventory_path, encoding='utf-8') as f:
        for row in csv.DictReader(f):
            row['size'] = int(row.get('size', 0) or 0)
            row['depth'] = int(row.get('depth', 0) or 0)
            row['is_bundle'] = row.get('is_bundle', '').lower() == 'true'
            row['size_bytes'] = row['size']
            records.append(row)

    # Load duplicates
    dupes_path = scan_dir / 'duplicates.json'
    dupe_groups = []
    if dupes_path.exists():
        with open(dupes_path) as f:
            dupe_groups = json.load(f)
    else:
        print("⚠️  duplicates.json not found — all files will be copied (no dedup)")

    # Build skip set (non-canonical duplicates)
    skip_paths = set()
    for group in dupe_groups:
        copies = group['copies']
        fake = [{'path': c['path'], 'depth': c.get('depth', 0)} for c in copies]
        best = pick_canonical(fake)
        for c in copies:
            if c['path'] != best['path']:
                skip_paths.add(c['path'])

    to_copy = [r for r in records if r['path'] not in skip_paths]

    print(f"📊 {len(records):,} total files  |  {len(skip_paths):,} dupes skipped  |  {len(to_copy):,} to consolidate")

    # Optional Claude categorization
    claude_suggestions = {}
    if args.claude_api_key:
        other_files = [r for r in to_copy if r['category'] == 'other'][:args.claude_max_files]
        if other_files:
            print(f"\n🤖 Sending {len(other_files):,} uncategorized files to Claude API...")
            claude_suggestions = categorize_with_claude(other_files, args.claude_api_key)
            print(f"   Got suggestions for {len(claude_suggestions):,} files")

    # Build copy operations
    copy_ops = []
    dest_seen = defaultdict(list)
    for record in to_copy:
        src = record['path']
        dest = build_dest_path(record, consolidated, claude_suggestions)
        # Resolve filename collisions
        dest_str = str(dest)
        if dest_str in dest_seen:
            hint = Path(src).parent.name[:20].replace(' ', '_')
            dest = dest.parent / f"{dest.stem}__{hint}{dest.suffix}"
        dest_seen[str(dest)].append(src)
        copy_ops.append((src, str(dest)))

    print(f"\n✅ Plan: {len(copy_ops):,} copy operations")

    # Category breakdown
    cat_counts = defaultdict(int)
    for r in to_copy:
        cat_counts[r['category']] += 1
    print("\n   By category:")
    for cat, count in sorted(cat_counts.items(), key=lambda x: -x[1]):
        print(f"   {cat:<12} {count:>6,} files")

    # Save full plan
    plan_path = scan_dir / 'consolidation_plan.json'
    with open(plan_path, 'w') as f:
        json.dump([{'src': s, 'dst': d} for s, d in copy_ops], f, indent=2)
    print(f"\n   📄 Full plan saved → {plan_path}")

    # Generate shell script (always, even if --execute)
    script_path = scan_dir / 'consolidate.sh'
    generate_shell_script(copy_ops, script_path)

    if args.execute:
        execute_with_resume(copy_ops, scan_dir)
    else:
        print(f"""
╔══════════════════════════════════════════════════════╗
║  DRY RUN COMPLETE — nothing was copied               ║
╠══════════════════════════════════════════════════════╣
║  Review the plan:                                    ║
║    open {str(plan_path):<47}║
║                                                      ║
║  Then either:                                        ║
║    bash {str(script_path):<47}║
║  or re-run with --execute for built-in resume.       ║
╚══════════════════════════════════════════════════════╝
        """)

if __name__ == '__main__':
    main()
