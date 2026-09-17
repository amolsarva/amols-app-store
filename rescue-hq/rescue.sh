#!/bin/bash
#
# rescue.sh — Google Photos Space Rescue HQ
#
#   1. Check and install dependencies
#   2. Merge a multi-part Takeout zip set into one tree
#   3. Sort it into PHOTOS/ (flat) and VIDEOS/<year>/ for upload
#
# Self-contained: the Python sorter is embedded at the bottom of this file.
# Nothing is ever deleted — excluded files are moved aside for you to review.
#
set -uo pipefail
VERSION="4.0"

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; CYN=$'\033[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""
fi

hr()   { printf '%s\n' "${DIM}────────────────────────────────────────────────────────────────${R}"; }
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "  ${GRN}✓${R} $*"; }
warn() { printf '%s\n' "  ${YEL}!${R} $*"; }
err()  { printf '%s\n' "  ${RED}✗${R} $*"; }
head1(){ clear; printf '\n%s\n' "${B}${BLU}  Google Photos Space Rescue HQ${R}  ${DIM}v${VERSION}${R}"; hr; }
pause(){ printf '\n%s' "  ${DIM}Press Return to continue...${R}"; read -r _; }
die()  { err "$*"; exit 1; }

hbytes() {
  awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB PB",u," ");i=1;
    while(b>=1024&&i<6){b/=1024;i++} printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'
}
fsize()      { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
free_bytes() { df -k "$1" 2>/dev/null | awk 'NR==2 {print $4*1024}'; }
trash_size() { [ -d "$HOME/.Trash" ] || { echo 0; return; }
               du -sk "$HOME/.Trash" 2>/dev/null | awk '{print $1*1024}' || echo 0; }
to_trash() {
  [ -e "$1" ] || return 1
  osascript <<EOF >/dev/null 2>&1
tell application "Finder"
  move POSIX file "$1" to trash
end tell
EOF
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# exiftool is the only one that may need installing; the rest ship with macOS.
HAVE_EXIFTOOL=0

check_deps() {
  head1
  printf '%s\n' "  ${B}Checking dependencies${R}"
  hr
  local missing=0

  if [ "$(uname)" != "Darwin" ]; then
    err "This script is macOS-only (it uses ditto, Finder, and osascript)."
    exit 1
  fi
  ok "macOS $(sw_vers -productVersion 2>/dev/null)"

  for t in unzip ditto osascript; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"
    else err "$t missing — this should ship with macOS"; missing=1; fi
  done

  if command -v python3 >/dev/null 2>&1; then
    ok "python3 ($(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null))"
  else
    err "python3 missing"
    info "Install the Command Line Tools with:  ${B}xcode-select --install${R}"
    missing=1
  fi

  if command -v exiftool >/dev/null 2>&1; then
    ok "exiftool ($(exiftool -ver 2>/dev/null))"
    HAVE_EXIFTOOL=1
  else
    warn "exiftool ${DIM}— optional, used to stamp dates missing from photos${R}"
    echo
    info "Without it, screenshots and edited photos will land on the wrong"
    info "date in Google Photos. Camera photos are unaffected."
    echo
    if command -v brew >/dev/null 2>&1; then
      printf '%s' "  Install exiftool with Homebrew now? [Y/n] "; read -r a
      if [[ ! "$a" =~ ^[Nn] ]]; then
        info "Running: brew install exiftool ${DIM}(a few minutes)${R}"
        if brew install exiftool; then
          ok "exiftool installed"; HAVE_EXIFTOOL=1
        else
          warn "Install failed — continuing without it."
        fi
      fi
    else
      warn "Homebrew not installed either."
      printf '%s' "  Install Homebrew, then exiftool? (downloads from brew.sh) [y/N] "; read -r a
      if [[ "$a" =~ ^[Yy] ]]; then
        info "Installing Homebrew — it will ask for your password."
        if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
          for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$p" ] && eval "$("$p" shellenv)"
          done
          brew install exiftool && { ok "exiftool installed"; HAVE_EXIFTOOL=1; }
        else
          warn "Homebrew install failed — continuing without exiftool."
        fi
      else
        info "Skipping. You can install it later with:"
        info "  ${DIM}brew install exiftool${R}"
      fi
    fi
  fi

  [ "$missing" -eq 0 ] || { echo; die "Missing required tools — see above."; }
  echo; ok "${B}Ready${R}"
  pause
}

# ---------------------------------------------------------------------------
# Folder browser
# ---------------------------------------------------------------------------
browse_folder() {
  local title="$1" cur="${2:-$HOME}" hint="${3:-zip}"
  cur="${cur%/}"; [ -d "$cur" ] || cur="$HOME"
  while true; do
    head1
    printf '%s\n' "  ${B}$title${R}"
    printf '%s\n' "  ${DIM}$cur${R}"
    local n
    if [ "$hint" = "zip" ]; then
      n=$(find "$cur" -maxdepth 1 -type f -iname "*.zip" 2>/dev/null | wc -l | tr -d ' ')
      [ "$n" -gt 0 ] && printf '%s\n' "  ${GRN}$n zip file(s) here${R}"
    else
      n=$(find "$cur" -maxdepth 2 -type f \( -iname "*.jpg" -o -iname "*.heic" \
          -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.png" \) 2>/dev/null | wc -l | tr -d ' ')
      [ "$n" -gt 0 ] && printf '%s\n' "  ${GRN}$n media file(s) at or just below here${R}"
    fi
    hr
    local -a dirs=(); local d
    while IFS= read -r d; do dirs+=("$d"); done \
      < <(find "$cur" -maxdepth 1 -mindepth 1 -type d ! -name ".*" 2>/dev/null | sort)
    local i=1
    if [ ${#dirs[@]} -eq 0 ]; then printf '%s\n' "  ${DIM}(no subfolders)${R}"
    else for d in "${dirs[@]}"; do printf "  %3d) %s\n" "$i" "$(basename "$d")"; i=$((i+1)); done; fi
    hr
    printf '%s\n' "  ${B}u${R} up   ${B}h${R} home   ${B}d${R} Downloads   ${B}p${R} type a path"
    printf '%s\n' "  ${B}s${R} ${GRN}SELECT this folder${R}   ${B}q${R} quit"
    printf '\n%s' "  > "
    local choice; read -r choice
    case "$choice" in
      s|S) PICKED="$cur"; return 0 ;;
      u|U) cur="$(dirname "$cur")" ;;
      h|H) cur="$HOME" ;;
      d|D) cur="$HOME/Downloads" ;;
      q|Q) echo; exit 0 ;;
      p|P) printf '%s' "  Path: "; read -r t
           t="${t/#\~/$HOME}"; t="${t%\'}"; t="${t#\'}"; t="${t%\"}"; t="${t#\"}"
           if [ -d "$t" ]; then cur="${t%/}"; else warn "Not a folder."; sleep 1; fi ;;
      ''|*[!0-9]*) ;;
      *) [ "$choice" -ge 1 ] && [ "$choice" -le ${#dirs[@]} ] && cur="${dirs[$((choice-1))]}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Embedded Python sorter (written to a temp file at runtime)
# ---------------------------------------------------------------------------
extract_python() {
cat <<'___PYEOF___'
#!/usr/bin/env python3
"""
sort_media.py — reorganize a merged Google Takeout tree for re-upload.

  VIDEOS/<year>/   flat, one folder per year of creation (for stitching)
  PHOTOS/          one flat folder (for drag-and-drop upload)
  _EXCLUDED/       everything held back, by reason, for review before deleting

Nothing is deleted. Every file is MOVED within the same volume, so the whole
run is near-instant and needs no extra disk space.

Usage:
  sort_media.py --src DIR [--dest DIR] [--apply] [--dates] [--keep-screenshots]

Without --apply it runs as a dry run and only writes a plan CSV.
"""

import argparse
import csv
import json
import os
import re
import sys
import time
from collections import defaultdict

# Extensions that mean the same container, so we don't rename .jpeg -> .jpg
# for no reason.
EXT_EQUIV = {".jpeg": ".jpg", ".heif": ".heic", ".tif": ".tiff"}

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mpg", ".mpeg", ".3gp", ".wmv"}
IMAGE_EXT = {".heic", ".heif", ".jpg", ".jpeg", ".png", ".webp",
             ".gif", ".tiff", ".tif", ".avif", ".bmp", ".dng"}

# "IMG_1234(1).PNG", "IMG_1234 (2).PNG", "IMG_1234(1)(1).PNG" -> "IMG_1234.PNG"
COPY_SUFFIX = re.compile(r"(?:\s*\(\d+\))+$")
# iPhone screenshots are PNGs named IMG_####.PNG (camera output is HEIC/JPG)
SCREENSHOT = re.compile(r"^IMG_\d+$", re.I)
YEAR_DIR = re.compile(r"Photos from (\d{4})", re.I)


def norm_stem(stem):
    """Strip trailing copy markers so IMG_9(1) and IMG_9 collide."""
    prev = None
    while prev != stem:
        prev = stem
        stem = COPY_SUFFIX.sub("", stem)
    return stem


def sidecar_for(path):
    """Google writes <file>.supplemental-metadata.json (and older variants)."""
    for cand in (path + ".supplemental-metadata.json",
                 path + ".json",
                 os.path.splitext(path)[0] + ".json"):
        if os.path.exists(cand):
            return cand
    return None


def taken_time(sidecar):
    """Epoch seconds a photo was actually taken, per the sidecar."""
    try:
        with open(sidecar, "r", encoding="utf-8", errors="replace") as fh:
            d = json.load(fh)
    except Exception:
        return None
    for key in ("photoTakenTime", "creationTime"):
        ts = (d.get(key) or {}).get("timestamp")
        if ts:
            try:
                return int(ts)
            except (TypeError, ValueError):
                pass
    return None


def year_of(path, epoch):
    if epoch:
        return time.strftime("%Y", time.localtime(epoch))
    m = YEAR_DIR.search(path)
    if m:
        return m.group(1)
    try:
        return time.strftime("%Y", time.localtime(os.path.getmtime(path)))
    except OSError:
        return "unknown"


LIVE_MARK = b"com.apple.quicktime.live-photo"
CID_MARK = b"com.apple.quicktime.content.identifier"


def live_markers(path):
    """(has_live_photo_tag, has_content_identifier).

    Apple stamps the motion half of a Live Photo with these keys. Reading them
    is the only reliable test: matching filenames fails because Takeout splits
    a Live Photo's still and video across different zips, and duration alone
    misclassifies short real clips.  Only the first and last 1 MB are read.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(1 << 20)
            a, b = LIVE_MARK in head, CID_MARK in head
            if a and b:
                return True, True
            fh.seek(0, 2)
            size = fh.tell()
            if size > (1 << 20):
                fh.seek(max(0, size - (1 << 20)))
                tail = fh.read()
                a = a or LIVE_MARK in tail
                b = b or CID_MARK in tail
            return a, b
    except OSError:
        return False, False


def sniff(path):
    """Identify a file by magic bytes. Google Takeout sometimes strips the
    extension entirely; those files are real photos and videos. Returns an
    extension like '.mov', or '' if unrecognized."""
    try:
        with open(path, "rb") as fh:
            h = fh.read(16)
    except OSError:
        return ""
    if len(h) < 12:
        return ""
    if h[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if h[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if h[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if h[:4] == b"RIFF" and h[8:12] == b"WEBP":
        return ".webp"
    if h[:2] in (b"II", b"MM") and h[2:4] in (b"\x2a\x00", b"\x00\x2a"):
        return ".tiff"
    # ISO base media (MP4 / MOV / HEIC) — the brand at offset 8 decides
    if h[4:8] == b"ftyp":
        brand = h[8:12]
        if brand[:2] == b"qt":
            return ".mov"
        if brand in (b"heic", b"heix", b"hevc", b"mif1", b"msf1", b"heim"):
            return ".heic"
        if brand == b"avif":
            return ".avif"
        return ".mp4"
    # bare QuickTime atoms
    if h[4:8] in (b"wide", b"mdat", b"moov", b"free", b"skip"):
        return ".mov"
    return ""


def unique(path):
    """Pick a non-colliding target name."""
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(f"{base}__{n}{ext}"):
        n += 1
    return f"{base}__{n}{ext}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--dest")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dates", action="store_true",
                    help="write an exiftool argfile to stamp missing dates")
    ap.add_argument("--keep-screenshots", action="store_true")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    dest = os.path.abspath(args.dest or os.path.dirname(src))

    photos_dir = os.path.join(dest, "PHOTOS")
    videos_dir = os.path.join(dest, "VIDEOS")
    excl_dir = os.path.join(dest, "_EXCLUDED")

    # ---- pass 1: inventory -------------------------------------------------
    print("  Scanning...", flush=True)
    files = []
    videos = []
    still_stems = set()
    for dp, dns, fns in os.walk(src):
        # don't descend into our own output
        dns[:] = [d for d in dns if os.path.join(dp, d) not in
                  (photos_dir, videos_dir, excl_dir)]
        for f in fns:
            p = os.path.join(dp, f)
            if not os.path.isfile(p) or os.path.islink(p):
                continue
            stem, e = os.path.splitext(f)
            e = e.lower()
            key = norm_stem(stem).lower()
            if e in IMAGE_EXT:
                still_stems.add(key)
            elif e in VIDEO_EXT or not e:
                videos.append((p, key))
            files.append(p)

    print(f"  {len(files):,} files found", flush=True)

    # ---- Live Photo detection ---------------------------------------------
    # Filename pairing is not enough: Takeout scatters a Live Photo's still and
    # its motion clip across different zips, so they rarely end up as siblings.
    # Read Apple's own marker instead.
    live_movs = set()
    if videos:
        print(f"  Checking {len(videos):,} videos for Live Photo markers...",
              end="", flush=True)
        for i, (p, key) in enumerate(videos, 1):
            has_live, has_cid = live_markers(p)
            # The live-photo tag is definitive. A bare content-identifier only
            # counts when a matching still exists, so a real video that happens
            # to carry one is never discarded.
            if has_live or (has_cid and key in still_stems):
                live_movs.add(p)
            if i % 500 == 0:
                print(f"\r  Checking {len(videos):,} videos for Live Photo "
                      f"markers... {i:,}", end="", flush=True)
        print(f"\r  {len(live_movs):,} Live Photo clips identified"
              f"{' ' * 30}", flush=True)

    # ---- pass 2: classify --------------------------------------------------
    plan = []
    seen = {}
    counts = defaultdict(int)
    bytes_ = defaultdict(int)
    date_jobs = []

    # Order matters: the first file seen for a given key is the one we keep.
    # Prefer the copy WITHOUT a "(1)" suffix, and prefer a real "Photos from
    # YYYY" folder over an album folder, so the kept copy has the cleanest name
    # and the most reliable date.
    def keep_priority(p):
        stem = os.path.splitext(os.path.basename(p))[0]
        return (0 if not COPY_SUFFIX.search(stem) else 1,
                0 if YEAR_DIR.search(p) else 1,
                len(p), p)

    for p in sorted(files, key=keep_priority):
        rel = os.path.relpath(p, src)
        name = os.path.basename(p)
        stem, ext = os.path.splitext(name)
        ext = ext.lower()
        try:
            size = os.path.getsize(p)
        except OSError:
            continue

        # Always trust the bytes over the extension. Takeout ships JPEGs named
        # .PNG and .HEIC, which breaks exiftool and confuses uploaders. Files
        # with no extension at all get one.
        if ext != ".json" and not name.endswith("_original"):
            probed = sniff(p)
            if probed and EXT_EQUIV.get(ext, ext) != EXT_EQUIV.get(probed, probed):
                ext = probed
                base = os.path.splitext(name)[0] if os.path.splitext(name)[1] else name
                name = base + probed

        reason = ""
        # Never re-ingest our own output. If the source folder contains a
        # previous run's PHOTOS/VIDEOS/_EXCLUDED, those files have already
        # been judged once; sorting them again resurrects duplicates and
        # backups as if they were fresh photos.
        parts_ = rel.split(os.sep)
        if "_EXCLUDED" in parts_:
            bucket, target = "excluded", os.path.join(excl_dir, "previously-excluded", rel)
            reason = "already excluded by an earlier run"
        elif name.endswith("_original"):
            bucket, target = "excluded", os.path.join(excl_dir, "exiftool-backups", name)
            reason = "exiftool backup"
        elif ext == ".json":
            bucket, target = "excluded", os.path.join(excl_dir, "json", rel)
            reason = "sidecar"
        elif os.sep + "Failed Videos" + os.sep in p + os.sep:
            bucket, target = "excluded", os.path.join(excl_dir, "failed-videos", name)
            reason = "google export failed"
        elif p in live_movs:
            bucket, target = "excluded", os.path.join(excl_dir, "live-photos", name)
            reason = "live photo motion"
        elif ext == ".ds_store" or name == ".DS_Store":
            bucket, target = "excluded", os.path.join(excl_dir, "junk", name)
            reason = "system file"
        elif ext in VIDEO_EXT or ext in IMAGE_EXT:
            key = (norm_stem(stem).lower() + ext, size)
            if key in seen:
                bucket = "excluded"
                target = os.path.join(excl_dir, "duplicates", name)
                reason = "dupe of " + os.path.relpath(seen[key], src)
            else:
                seen[key] = p
                is_shot = ext == ".png" and SCREENSHOT.match(norm_stem(stem))
                if is_shot and not args.keep_screenshots:
                    bucket = "excluded"
                    target = os.path.join(excl_dir, "screenshots", name)
                    reason = "screenshot"
                elif ext in VIDEO_EXT:
                    sc = sidecar_for(p)
                    yr = year_of(p, taken_time(sc) if sc else None)
                    bucket = "video"
                    target = os.path.join(videos_dir, yr, name)
                else:
                    bucket = "photo"
                    target = os.path.join(photos_dir, name)
        else:
            bucket, target = "excluded", os.path.join(excl_dir, "other", name)
            reason = "unrecognized type"

        if bucket in ("photo", "video") and args.dates:
            sc = sidecar_for(p)
            t = taken_time(sc) if sc else None
            if t:
                date_jobs.append((target, t))

        plan.append((bucket, reason, p, target, size))
        counts[bucket] += 1
        bytes_[bucket] += size
        if reason:
            counts["excl:" + reason.split(" of ")[0]] += 1
            bytes_["excl:" + reason.split(" of ")[0]] += size

    # ---- report ------------------------------------------------------------
    def gb(b):
        return f"{b / 2**30:.1f} GB"

    print()
    print(f"  {'PHOTOS':<22}{counts['photo']:>8,} files   {gb(bytes_['photo']):>10}")
    print(f"  {'VIDEOS':<22}{counts['video']:>8,} files   {gb(bytes_['video']):>10}")
    print(f"  {'EXCLUDED':<22}{counts['excluded']:>8,} files   {gb(bytes_['excluded']):>10}")
    for k in sorted(counts):
        if k.startswith("excl:"):
            print(f"      {k[5:]:<18}{counts[k]:>8,}   {gb(bytes_[k]):>10}")

    years = defaultdict(int)
    for b, _, _, t, _ in plan:
        if b == "video":
            years[os.path.basename(os.path.dirname(t))] += 1
    if years:
        print("\n  Videos by year:")
        for y in sorted(years):
            print(f"      {y}   {years[y]:>6,}")

    os.makedirs(dest, exist_ok=True)
    csv_path = os.path.join(dest, "sort_plan.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["bucket", "reason", "source", "target", "bytes"])
        w.writerows(plan)
    print(f"\n  Plan written to: {csv_path}")

    if not args.apply:
        print("  DRY RUN — nothing moved. Re-run with --apply to execute.")
        return 0

    # ---- execute -----------------------------------------------------------
    print("\n  Moving files...", flush=True)
    moved = failed = 0
    for i, (bucket, reason, srcp, target, size) in enumerate(plan, 1):
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            os.rename(srcp, unique(target))
            moved += 1
        except OSError as exc:
            failed += 1
            print(f"\n  ! {srcp}: {exc}", flush=True)
        if i % 500 == 0:
            print(f"\r  {i:,}/{len(plan):,}   ", end="", flush=True)
    print(f"\r  moved {moved:,} files" + (f", {failed} failed" if failed else ""))

    # prune the emptied directory tree
    for dp, dns, fns in os.walk(src, topdown=False):
        if not os.listdir(dp) and os.path.abspath(dp) != src:
            try:
                os.rmdir(dp)
            except OSError:
                pass

    # ---- exiftool argfile --------------------------------------------------
    if args.dates and date_jobs:
        arg_path = os.path.join(dest, "exiftool_dates.args")
        with open(arg_path, "w", encoding="utf-8") as fh:
            for target, epoch in date_jobs:
                if not os.path.exists(target):
                    continue
                stamp = time.strftime("%Y:%m:%d %H:%M:%S", time.localtime(epoch))
                # -wm cg = only write tags that are absent; never overwrites a
                # real camera date.
                fh.write(f"-DateTimeOriginal={stamp}\n")
                fh.write(f"-CreateDate={stamp}\n")
                fh.write(f"-FileModifyDate={stamp}\n")
                fh.write(f"{target}\n")
                fh.write("-execute\n")
        print(f"  exiftool argfile: {arg_path}  ({len(date_jobs):,} files)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
___PYEOF___
}

# ---------------------------------------------------------------------------
# Embedded Python repairer
# ---------------------------------------------------------------------------
extract_repair() {
cat <<'___REPEOF___'
#!/usr/bin/env python3
"""
repair_media.py — fix an already-sorted PHOTOS/VIDEOS tree.

Three repairs, all safe to re-run:

  1. exiftool "_original" backups        -> moved to _EXCLUDED/exiftool-backups
  2. extension doesn't match content     -> renamed to the true extension
  3. files exiftool couldn't stamp       -> new argfile written for a retry

Nothing is deleted. Usage:
  repair_media.py --root DIR [--apply]
"""

import argparse
import csv
import json
import os
import sys
import time

EXT_EQUIV = {".jpeg": ".jpg", ".heif": ".heic", ".tif": ".tiff"}


def sniff(path):
    try:
        with open(path, "rb") as fh:
            h = fh.read(16)
    except OSError:
        return ""
    if len(h) < 12:
        return ""
    if h[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if h[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if h[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if h[:4] == b"RIFF" and h[8:12] == b"WEBP":
        return ".webp"
    if h[:2] in (b"II", b"MM") and h[2:4] in (b"\x2a\x00", b"\x00\x2a"):
        return ".tiff"
    if h[4:8] == b"ftyp":
        b = h[8:12]
        if b[:2] == b"qt":
            return ".mov"
        if b in (b"heic", b"heix", b"hevc", b"mif1", b"msf1", b"heim"):
            return ".heic"
        if b == b"avif":
            return ".avif"
        return ".mp4"
    if h[4:8] in (b"wide", b"mdat", b"moov", b"free", b"skip"):
        return ".mov"
    return ""


def unique(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(f"{base}__{n}{ext}"):
        n += 1
    return f"{base}__{n}{ext}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="folder holding PHOTOS/ and VIDEOS/")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    backup_dir = os.path.join(root, "_EXCLUDED", "exiftool-backups")

    targets = [d for d in (os.path.join(root, "PHOTOS"), os.path.join(root, "VIDEOS"))
               if os.path.isdir(d)]
    if not targets:
        print(f"  No PHOTOS/ or VIDEOS/ folder in {root}")
        return 1

    print("  Scanning...", flush=True)
    backups, renames = [], []
    renamed_map = {}

    for base in targets:
        for dp, _, fns in os.walk(base):
            for fn in fns:
                p = os.path.join(dp, fn)
                if fn.endswith("_original"):
                    backups.append(p)
                    continue
                ext = os.path.splitext(fn)[1].lower()
                real = sniff(p)
                if not real:
                    continue
                if EXT_EQUIV.get(ext, ext) != EXT_EQUIV.get(real, real):
                    stem = os.path.splitext(p)[0] if os.path.splitext(fn)[1] else p
                    renames.append((p, stem + real))

    tot_backup = sum(os.path.getsize(p) for p in backups if os.path.exists(p))
    print()
    print(f"  exiftool backups   {len(backups):>8,}   {tot_backup / 2**30:.1f} GB"
          f"   -> _EXCLUDED/exiftool-backups")
    print(f"  wrong extension    {len(renames):>8,}   -> renamed to true type")

    if renames:
        from collections import Counter
        c = Counter((os.path.splitext(a)[1].lower(), os.path.splitext(b)[1].lower())
                    for a, b in renames)
        for (a, b), n in c.most_common(12):
            print(f"      {a or '(none)':<8} -> {b:<8} {n:>7,}")

    if not args.apply:
        print("\n  DRY RUN — nothing changed. Re-run with --apply.")
        return 0

    print("\n  Repairing...", flush=True)
    moved = 0
    for p in backups:
        rel = os.path.relpath(p, root)
        target = os.path.join(backup_dir, rel)
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            os.rename(p, unique(target))
            moved += 1
        except OSError as exc:
            print(f"  ! {p}: {exc}")
    print(f"  moved {moved:,} backup files aside")

    fixed = 0
    for src, dst in renames:
        try:
            final = unique(dst)
            os.rename(src, final)
            renamed_map[src] = final
            fixed += 1
        except OSError as exc:
            print(f"  ! {src}: {exc}")
    print(f"  renamed {fixed:,} files to their true extension")

    # ---- rebuild the exiftool argfile against current paths ---------------
    old_args = os.path.join(root, "exiftool_dates.args")
    new_args = os.path.join(root, "exiftool_dates_retry.args")
    if os.path.exists(old_args):
        jobs = []
        stamp = None
        with open(old_args, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.startswith("-DateTimeOriginal="):
                    stamp = line.split("=", 1)[1]
                elif line.startswith("/") and stamp:
                    p = renamed_map.get(line, line)
                    if os.path.exists(p):
                        jobs.append((p, stamp))
                    stamp = None
        with open(new_args, "w", encoding="utf-8") as fh:
            for p, s in jobs:
                fh.write(f"-DateTimeOriginal={s}\n-CreateDate={s}\n"
                         f"-FileModifyDate={s}\n{p}\n-execute\n")
        print(f"  retry argfile: {new_args}  ({len(jobs):,} files)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
___REPEOF___
}

# ---------------------------------------------------------------------------
# Merge helper: fold one extracted Takeout tree into ORGANIZED
# ---------------------------------------------------------------------------
merge_tree() {
  local staging="$1" dest="$2"
  local moved=0 duped=0
  local takeout_dir
  while IFS= read -r takeout_dir; do
    local svc_path
    while IFS= read -r svc_path; do
      local svc; svc="$(basename "$svc_path")"
      local out="$dest/$svc"
      mkdir -p "$out"
      local f rel target
      while IFS= read -r f; do
        rel="${f#$svc_path/}"
        target="$out/$rel"
        mkdir -p "$(dirname "$target")"
        if [ -e "$target" ]; then
          local s1 s2
          s1=$(fsize "$f"); s2=$(fsize "$target")
          if [ "$s1" = "$s2" ]; then
            local dup="$dest/DUPES/$svc/$rel"
            mkdir -p "$(dirname "$dup")"
            mv -n "$f" "$dup" 2>/dev/null && duped=$((duped+1))
            continue
          else
            local base ext n=2
            base="${target%.*}"; ext="${target##*.}"
            [ "$base" = "$target" ] && ext=""
            while [ -e "${base}__$n${ext:+.$ext}" ]; do n=$((n+1)); done
            target="${base}__$n${ext:+.$ext}"
          fi
        fi
        mv -n "$f" "$target" 2>/dev/null && moved=$((moved+1))
        if [ $(( (moved + duped) % 250 )) -eq 0 ]; then
          printf '\r  ...merged %s files   ' "$((moved + duped))"
        fi
      done < <(find "$svc_path" -type f ! -name ".DS_Store" 2>/dev/null)
    done < <(find "$takeout_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done < <(find "$staging" -type d -name "Takeout" 2>/dev/null)

  local leftover
  while IFS= read -r leftover; do
    local rel2="${leftover#$staging/}"
    local target2="$dest/_Unsorted/$rel2"
    mkdir -p "$(dirname "$target2")"
    mv -n "$leftover" "$target2" 2>/dev/null && moved=$((moved+1))
  done < <(find "$staging" -type f ! -name ".DS_Store" 2>/dev/null)

  printf '\r%*s\r' 40 ''
  MERGED_MOVED=$moved
  MERGED_DUPED=$duped
}

# ---------------------------------------------------------------------------
# STAGE 1 — merge a multi-part zip set
# ---------------------------------------------------------------------------
stage_merge() {
  PICKED=""
  browse_folder "Select the folder holding your takeout-*.zip files" "$HOME/Downloads" zip
  SRC="$PICKED"

  ZIPS=()
  while IFS= read -r _z; do [ -n "$_z" ] && ZIPS+=("$_z"); done \
    < <(find "$SRC" -maxdepth 1 -type f -iname "*.zip" 2>/dev/null | sort)
  if [ ${#ZIPS[@]} -eq 0 ]; then
    head1; err "No .zip files in:"; info "$SRC"; pause; return 1
  fi

  TOTAL_BYTES=0
  for z in "${ZIPS[@]}"; do TOTAL_BYTES=$(( TOTAL_BYTES + $(fsize "$z") )); done

  DEST="$SRC/ORGANIZED"
  head1
  printf '%s\n' "  ${B}Destination${R}"
  info "Default: ${CYN}$DEST${R}"
  printf '\n%s' "  Use default? [Y/n] "; read -r a
  if [[ "$a" =~ ^[Nn] ]]; then
    PICKED=""; browse_folder "Select the PARENT folder for the output" "$SRC" media
    printf '%s' "  Output folder name [ORGANIZED]: "; read -r on
    DEST="$PICKED/${on:-ORGANIZED}"
  fi

  STAGING="$DEST/.staging"; STATE="$DEST/.done_zips"; LOG="$DEST/takeout_merge.log"
  mkdir -p "$DEST" "$STAGING" || { err "Cannot create $DEST"; return 1; }
  touch "$STATE" "$LOG"

  FREE=$(free_bytes "$SRC")
  head1
  printf '%s\n' "  ${B}Plan${R}"
  info "Source:      $SRC"
  info "Destination: $DEST"
  info "Archives:    ${#ZIPS[@]} zip(s), $(hbytes "$TOTAL_BYTES")"
  info "Free space:  $(hbytes "$FREE")"
  echo
  [ "$FREE" -lt "$TOTAL_BYTES" ] && {
    warn "${YEL}Not enough room for zips and extracted copies at once.${R}"
    info "Trashing each zip after it verifies is strongly recommended."; echo; }
  printf '%s\n' "  Move each zip to the ${B}Finder Trash${R} after it verifies?"
  printf '%s\n' "  ${DIM}(Recoverable. You empty the Trash yourself.)${R}"
  printf '\n%s' "  Trash verified zips? [y/N] "; read -r a
  TRASH_ZIPS=0; [[ "$a" =~ ^[Yy] ]] && TRASH_ZIPS=1

  DONE_COUNT=$(grep -c . "$STATE" 2>/dev/null | head -1); DONE_COUNT=${DONE_COUNT:-0}
  [ "$DONE_COUNT" -gt 0 ] && { echo; info "${CYN}Resuming:${R} $DONE_COUNT zip(s) already done."; }

  echo; printf '%s' "  ${B}Start?${R} [y/N] "; read -r go
  [[ "$go" =~ ^[Yy] ]] || return 1
  echo "=== run $(date '+%F %T') src=$SRC dest=$DEST trash=$TRASH_ZIPS ===" >> "$LOG"

  IDX=0; TOTAL_MOVED=0; TOTAL_DUPED=0; FAILED=()
  for z in "${ZIPS[@]}"; do
    IDX=$((IDX+1)); ZNAME="$(basename "$z")"
    if grep -Fxq "$ZNAME" "$STATE"; then
      head1; info "[$IDX/${#ZIPS[@]}] ${DIM}$ZNAME — already done${R}"; sleep 0.3; continue
    fi

    head1
    printf '%s\n' "  ${B}[$IDX/${#ZIPS[@]}] $ZNAME${R}"
    info "$(hbytes "$(fsize "$z")")"
    hr

    ZSIZE=$(fsize "$z"); FREE=$(free_bytes "$DEST"); NEED=$(( ZSIZE + ZSIZE / 10 ))
    if [ "$FREE" -lt "$NEED" ]; then
      err "Only $(hbytes "$FREE") free; need about $(hbytes "$NEED")."
      echo "SPACE-LOW at $ZNAME free=$FREE need=$NEED" >> "$LOG"
      TSIZE=$(trash_size)
      if [ "${TSIZE:-0}" -gt 0 ]; then
        echo
        info "The Trash holds ${B}$(hbytes "$TSIZE")${R}."
        info "${DIM}Zips this script already extracted, verified and merged.${R}"
        echo
        warn "Emptying the Trash is ${B}permanent${R}. Spot-check first:"
        warn "${CYN}$DEST${R}"
        echo
        printf '%s' "  Type ${B}EMPTY${R} to empty Trash and continue, or Return to stop: "
        read -r conf
        if [ "$conf" = "EMPTY" ]; then
          info "Emptying Trash..."
          osascript -e 'tell application "Finder" to empty trash' >/dev/null 2>&1
          sleep 3; FREE=$(free_bytes "$DEST")
          ok "Now $(hbytes "$FREE") free"
          echo "TRASH-EMPTIED free=$FREE" >> "$LOG"
        fi
      fi
      FREE=$(free_bytes "$DEST")
      if [ "$FREE" -lt "$NEED" ]; then
        echo; err "Still not enough room."
        warn "Free space, then run this again — it resumes at $ZNAME."
        echo "SPACE-STOP at $ZNAME free=$FREE need=$NEED" >> "$LOG"
        pause; break
      fi
    fi

    info "Reading archive index..."
    EXPECTED=$(unzip -Z1 "$z" 2>/dev/null | grep -cv '/$')
    if [ "${EXPECTED:-0}" -eq 0 ]; then
      err "Archive is corrupt or unreadable — skipping."
      warn "Re-download this one from Google Takeout."
      echo "CORRUPT $ZNAME" >> "$LOG"; FAILED+=("$ZNAME (corrupt)"); pause; continue
    fi
    ok "$EXPECTED files in archive"

    rm -rf "$STAGING"; mkdir -p "$STAGING"
    info "Extracting... ${DIM}(CRC-checked as it goes)${R}"
    echo "EXTRACT-START $ZNAME expected=$EXPECTED $(date '+%T')" >> "$LOG"

    ditto -x -k --noqtn "$z" "$STAGING" >>"$LOG" 2>&1 </dev/null &
    XPID=$!
    SPIN='|/-\'; si=0; last=0; stall=0
    while kill -0 "$XPID" 2>/dev/null; do
      n=$(find "$STAGING" -type f 2>/dev/null | wc -l | tr -d ' ')
      pct=$(( EXPECTED > 0 ? n * 100 / EXPECTED : 0 ))
      si=$(( (si + 1) % 4 ))
      printf '\r  %s  %s / %s files  (%s%%)   ' "${SPIN:$si:1}" "$n" "$EXPECTED" "$pct"
      if [ "$n" -eq "$last" ]; then stall=$((stall+1)); else stall=0; last=$n; fi
      if [ "$stall" -ge 60 ]; then
        printf '\r%s\n' "  ${YEL}! no new files for 2 min — large file, or stuck${R}"
        stall=0
      fi
      sleep 2
    done
    wait "$XPID"; XRC=$?
    printf '\r%*s\r' 60 ''

    if [ "$XRC" -ne 0 ]; then
      err "Extraction failed (exit $XRC):"; tail -3 "$LOG" | sed 's/^/    /'
      echo "EXTRACT-FAIL $ZNAME rc=$XRC" >> "$LOG"
      FAILED+=("$ZNAME (extract failed)"); pause; continue
    fi

    ACTUAL=$(find "$STAGING" -type f ! -name ".DS_Store" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$ACTUAL" -lt "$EXPECTED" ]; then
      err "Verify failed: expected $EXPECTED, found $ACTUAL."
      warn "Zip left in place. Staging kept at: $STAGING"
      echo "VERIFY-FAIL $ZNAME expected=$EXPECTED actual=$ACTUAL" >> "$LOG"
      FAILED+=("$ZNAME (verify $ACTUAL/$EXPECTED)"); pause; continue
    fi
    ok "Verified $ACTUAL files"

    info "Merging..."
    MERGED_MOVED=0; MERGED_DUPED=0
    merge_tree "$STAGING" "$DEST"
    ok "Merged $MERGED_MOVED file(s)${MERGED_DUPED:+, $MERGED_DUPED dupe(s) aside}"
    TOTAL_MOVED=$(( TOTAL_MOVED + MERGED_MOVED )); TOTAL_DUPED=$(( TOTAL_DUPED + MERGED_DUPED ))

    rm -rf "$STAGING"; mkdir -p "$STAGING"
    echo "$ZNAME" >> "$STATE"
    echo "DONE $ZNAME files=$MERGED_MOVED dupes=$MERGED_DUPED" >> "$LOG"

    if [ "$TRASH_ZIPS" -eq 1 ]; then
      if to_trash "$z"; then ok "Moved to Trash"; echo "TRASHED $ZNAME" >> "$LOG"
      else warn "Could not Trash — zip left in place."; fi
    fi
    sleep 0.4
  done

  rmdir "$STAGING" 2>/dev/null
  head1
  printf '%s\n' "  ${B}Merge summary${R}"; hr
  ok "Files merged:     $TOTAL_MOVED"
  [ "$TOTAL_DUPED" -gt 0 ] && info "Duplicates aside:  $TOTAL_DUPED ${DIM}(DUPES/)${R}"
  info "Output:            $DEST"
  info "Log:               $LOG"
  if [ ${#FAILED[@]} -gt 0 ]; then
    echo; warn "${#FAILED[@]} archive(s) need attention:"
    for f in "${FAILED[@]}"; do info "  • $f"; done
  fi
  MERGE_DEST="$DEST"
  pause
}

# ---------------------------------------------------------------------------
# STAGE 2 — sort into PHOTOS/ and VIDEOS/<year>/
# ---------------------------------------------------------------------------
stage_sort() {
  local start="${MERGE_DEST:-$HOME/Downloads}"
  PICKED=""
  browse_folder "Select the folder to sort (e.g. ORGANIZED/Google Photos)" "$start" media
  local SRC="$PICKED"
  local DEST; DEST="$(dirname "$SRC")"

  if [ -d "$SRC/PHOTOS" ] || [ -d "$SRC/VIDEOS" ] || [ -d "$SRC/_EXCLUDED" ]; then
    head1
    warn "${YEL}That folder already contains output from a previous sort.${R}"
    info "Sorting it again re-reads files this tool already judged once."
    info "Previously-excluded files are held back, but pick the ${B}original${R}"
    info "source folder if you can — not the folder you sorted into."
    echo
    confirm "Continue anyway?" || return 0
  fi

  head1
  printf '%s\n' "  ${B}Options${R}"; echo
  info "${DIM}Duplicate copies are removed either way.${R}"
  printf '%s' "  Keep (de-duplicated) screenshots in PHOTOS? [y/N] "; read -r a
  local KEEP_SS=""; [[ "$a" =~ ^[Yy] ]] && KEEP_SS="--keep-screenshots"

  local DATES="--dates"
  if [ "$HAVE_EXIFTOOL" -eq 1 ]; then
    printf '%s' "  Stamp missing dates from Takeout sidecars? [Y/n] "; read -r a
    [[ "$a" =~ ^[Nn] ]] && DATES=""
  else
    warn "exiftool not installed — an argfile will be written for later."
  fi

  printf '\n%s\n' "  Output: ${CYN}$DEST${R}/{PHOTOS,VIDEOS,_EXCLUDED}"

  head1
  info "${B}Dry run${R} — nothing will move yet."; hr
  python3 "$PYTOOL" --src "$SRC" --dest "$DEST" $KEEP_SS $DATES
  echo; hr
  printf '%s' "  Apply this plan for real? [y/N] "; read -r go
  if [[ ! "$go" =~ ^[Yy] ]]; then
    echo; info "Nothing changed. sort_plan.csv is there if you want to read it."
    pause; return 0
  fi

  head1
  python3 "$PYTOOL" --src "$SRC" --dest "$DEST" --apply $KEEP_SS $DATES || {
    err "Sort reported errors."; pause; return 1; }

  local ARGS="$DEST/exiftool_dates.args"
  if [ -n "$DATES" ] && [ -f "$ARGS" ]; then
    echo; hr
    if [ "$HAVE_EXIFTOOL" -eq 1 ]; then
      local N; N=$(grep -c '^-execute$' "$ARGS" 2>/dev/null | head -1); N=${N:-0}
      info "Ready to stamp dates on ${B}$N${R} files."
      info "${DIM}Only fills absent tags — never overwrites a camera date.${R}"
      printf '\n%s' "  Run exiftool now? (20-40 min) [y/N] "; read -r a
      if [[ "$a" =~ ^[Yy] ]]; then
        info "Stamping... ${DIM}(safe to leave running)${R}"
        exiftool -@ "$ARGS" -common_args -q -m -wm cg -overwrite_original -charset filename=utf8
        ok "Dates stamped"
      else
        info "Later:  ${DIM}exiftool -@ \"$ARGS\" -common_args -q -m -wm cg -overwrite_original${R}"
      fi
    else
      warn "exiftool missing. Install then run:"
      info "  ${DIM}brew install exiftool${R}"
      info "  ${DIM}exiftool -@ \"$ARGS\" -common_args -q -m -wm cg -overwrite_original${R}"
    fi
  fi

  head1
  printf '%s\n' "  ${B}Done${R}"; hr
  [ -d "$DEST/PHOTOS" ] && info "PHOTOS     $(find "$DEST/PHOTOS" -type f | wc -l | tr -d ' ') files"
  [ -d "$DEST/VIDEOS" ] && info "VIDEOS     $(find "$DEST/VIDEOS" -type f | wc -l | tr -d ' ') files across $(find "$DEST/VIDEOS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') years"
  [ -d "$DEST/_EXCLUDED" ] && info "_EXCLUDED  $(find "$DEST/_EXCLUDED" -type f | wc -l | tr -d ' ') files ${DIM}($(du -sh "$DEST/_EXCLUDED" 2>/dev/null | cut -f1)) — review then delete${R}"
  echo; info "Plan detail: ${DIM}$DEST/sort_plan.csv${R}"
  echo; printf '%s' "  Open the output folder? [Y/n] "; read -r a
  [[ "$a" =~ ^[Nn] ]] || open "$DEST"
  pause
}

# ---------------------------------------------------------------------------
# STAGE 3 — repair an already-sorted tree
# ---------------------------------------------------------------------------
stage_repair() {
  local start="${MERGE_DEST:-$HOME/Downloads}"
  PICKED=""
  browse_folder "Select the folder containing PHOTOS/ and VIDEOS/" "$start" media
  local ROOT="$PICKED"

  head1
  info "${B}Dry run${R} — nothing will change yet."
  hr
  python3 "$PYREPAIR" --root "$ROOT"
  echo; hr
  printf '%s' "  Apply these repairs? [y/N] "; read -r go
  if [[ ! "$go" =~ ^[Yy] ]]; then echo; info "Nothing changed."; pause; return 0; fi

  head1
  python3 "$PYREPAIR" --root "$ROOT" --apply || { err "Repair reported errors."; pause; return 1; }

  local RETRY="$ROOT/exiftool_dates_retry.args"
  if [ -f "$RETRY" ]; then
    echo; hr
    if [ "$HAVE_EXIFTOOL" -eq 1 ]; then
      local N; N=$(grep -c '^-execute$' "$RETRY" 2>/dev/null | head -1); N=${N:-0}
      info "Ready to re-stamp dates on ${B}$N${R} files."
      info "${DIM}Uses -common_args, so no new _original backups are made.${R}"
      printf '\n%s' "  Run exiftool now? [y/N] "; read -r a
      if [[ "$a" =~ ^[Yy] ]]; then
        info "Stamping... ${DIM}(safe to leave running)${R}"
        exiftool -@ "$RETRY" -common_args -q -m -wm cg -overwrite_original -charset filename=utf8
        ok "Done"
      else
        info "Later:  ${DIM}exiftool -@ \"$RETRY\" -common_args -q -m -wm cg -overwrite_original${R}"
      fi
    else
      warn "exiftool not installed."
      info "  ${DIM}brew install exiftool${R}"
    fi
  fi

  head1
  printf '%s\n' "  ${B}Repair done${R}"; hr
  [ -d "$ROOT/PHOTOS" ] && info "PHOTOS  $(find "$ROOT/PHOTOS" -type f | wc -l | tr -d ' ') files"
  [ -d "$ROOT/VIDEOS" ] && info "VIDEOS  $(find "$ROOT/VIDEOS" -type f | wc -l | tr -d ' ') files"
  pause
}

# ===========================================================================
# Ported verbatim from media_pipeline.sh (Jul 2026), which this script
# replaces. The stitch logic in particular is battle-tested: it normalizes
# each clip's audio in an isolated ffmpeg process before a stream-copy
# concat, because a single continuous decode pass desyncs on heterogeneous
# AAC configs and silently corrupts audio from that splice onward.
# ===========================================================================

# --- config for the ported stages ------------------------------------------
LOG_DIR="${TMPDIR:-/tmp}/rescue_hq_logs"
mkdir -p "$LOG_DIR"
RUN_LOG=""
VIDEO_TIMEOUT_SECS=1800
META_TIMEOUT_SECS=20
PROGRESS_EVERY=250
STITCH_TIMEOUT_SECS=7200
STITCH_MIN_DURATION_RATIO=0.90
STITCH_MIN_SIZE_RATIO=0.85
STITCH_MAX_SIZE_RATIO=1.10
YT_MAX_SECS=43200

# --- shims so the ported code speaks this script's dialect -----------------
banner()  { head1; }
say()     { info "$*"; }
confirm() { printf '%s' "  $* [y/N] "; local a; read -r a; [[ "$a" =~ ^[Yy] ]]; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Required tool '$1' not found. $2"; exit 1; }
}

# Enables job control so backgrounded work gets its own process group.
set -m
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  # stdout/stderr closed here on purpose: if this watchdog inherits the
  # caller's stdout it keeps a command-substitution pipe open, and $( ... )
  # blocks for the full timeout even after the real command has exited.
  ( sleep "$secs"; kill -0 "$pid" 2>/dev/null && kill -9 -"$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local status=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $status
}


step_audit() {
  banner; echo "  STEP 4: AUDIT (read-only — nothing is changed)"; hr
  require_source || return 1
  derive_paths
  echo "Source:      $SRC"
  echo "Resized:     $RESIZED"
  echo "Dupes:       $DUPES"
  echo "Master:      $MASTER"
  echo

  for d in "$SRC" "$RESIZED" "$DUPES" "$MASTER"; do
    [ -d "$d" ] || continue
    echo "$(c '1;36' "$d")"
    printf '  size: '; du -sh "$d" 2>/dev/null | cut -f1
    if [ -d "$d/Photos" ] || [ -d "$d/Videos" ]; then
      [ -d "$d/Photos" ] && printf '  Photos:    %s\n' "$(find "$d/Photos" -type f | wc -l | tr -d ' ')"
      [ -d "$d/Videos" ] && printf '  Videos:    %s\n' "$(find "$d/Videos" -type f | wc -l | tr -d ' ')"
      [ -d "$d/LivePhotoClips" ] && printf '  LivePhotoClips (Live Photo companions, not real videos): %s\n' "$(find "$d/LivePhotoClips" -type f | wc -l | tr -d ' ')"
      [ -d "$d/Documents" ] && printf '  Documents: %s\n' "$(find "$d/Documents" -type f | wc -l | tr -d ' ')"
      [ -d "$d/Other" ] && printf '  Other:     %s\n' "$(find "$d/Other" -type f | wc -l | tr -d ' ')"
    else
      local photos=0 videos=0 path base ext
      while IFS= read -r path; do
        base="${path##*/}"
        ext=$(real_ext "$base")
        if is_in_list "$ext" $IMAGE_EXTS; then photos=$((photos + 1))
        elif is_in_list "$ext" $VIDEO_EXTS; then videos=$((videos + 1))
        fi
      done < <(find "$d" -type f 2>/dev/null)
      printf '  Photos (by extension): %s\n' "$photos"
      printf '  Videos (by extension): %s\n' "$videos"
    fi
    echo
  done

  echo "$(c '1;36' 'Recent step logs (failures/anomalies only):')"
  for lg in "${LOG_DIR}/shrink.log" "${LOG_DIR}/dedupe.log" "${LOG_DIR}/consolidate.log"; do
    [ -f "$lg" ] || continue
    local n; n=$({ grep -cE "^(FAIL|SELF_CHECK_FAILED)" "$lg" 2>/dev/null || true; })
    echo "  $(basename "$lg"): $n FAIL/SELF_CHECK_FAILED lines"
  done

  echo
  echo "$(c '1;36' 'Spot-checking capture-date metadata survived on a few random photos/videos in _MASTER:')"
  if [ -d "$MASTER/Photos" ]; then
    find "$MASTER/Photos" -type f \( -iname "*.jpg" -o -iname "*.heic" \) 2>/dev/null | shuf -n 3 2>/dev/null | while IFS= read -r f; do
      local d; d=$(sips -g all "$f" 2>/dev/null | awk -F': ' '/exif:DateTimeOriginal/{print $2; exit}')
      printf '  %s: %s\n' "$(basename "$f")" "${d:-(no EXIF date found)}"
    done
  fi
  if [ -d "$MASTER/Videos" ]; then
    find "$MASTER/Videos" -type f -iname "*.mp4" 2>/dev/null | shuf -n 2 2>/dev/null | while IFS= read -r f; do
      local d; d=$(ffprobe -v quiet -show_entries format_tags=creation_time -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
      printf '  %s: %s\n' "$(basename "$f")" "${d:-(no creation_time found)}"
    done
  fi
  echo
  ok "Audit complete. This step never modifies anything."
}

# ============================================================================
# STEP 5: STITCH (join each year's real videos into one file per year)
# ============================================================================
# Best-effort capture year for a video: prefer the same creation_time
# metadata dedupe uses, fall back to file modification time so nothing
# gets silently skipped just because its metadata is missing.

stitch_get_year() {
  local f="$1" log="$2" out date tmpout
  # Prefer the parent folder name when it is a 4-digit year. Our own sorter
  # derived that from the Takeout sidecar's photoTakenTime, which is more
  # reliable than container metadata — Takeout strips creation_time from
  # plenty of clips.
  local parent; parent="$(basename "$(dirname "$f")")"
  if printf '%s' "$parent" | grep -qE '^(19|20)[0-9]{2}$'; then
    printf '%s' "$parent"; return 0
  fi
  tmpout=$(mktemp /tmp/mp_stitch_meta.XXXXXX)
  run_with_timeout "$META_TIMEOUT_SECS" ffprobe -v quiet -print_format flat \
        -show_entries format_tags=creation_time "$f" > "$tmpout" 2>/dev/null
  out=$(cat "$tmpout" 2>/dev/null); rm -f "$tmpout"
  date=$(printf '%s\n' "$out" | awk -F'"' '/creation_time/{print $2; exit}')
  if [ -n "$date" ] && [ "${#date}" -ge 4 ]; then
    printf '%s' "${date:0:4}"; return 0
  fi
  printf 'NO_METADATA: %s\n' "$f" >> "$log"
  # Fallback to file mtime year. Sanitized defensively: any command output
  # that isn't cleanly a 4-digit year (wrong platform's stat flags, odd
  # permissions, whatever) is rejected rather than trusted, since this
  # value gets embedded in a tab-delimited row and must never contain
  # stray whitespace/newlines.
  local mt; mt=$(stat -f "%Sm" -t "%Y" "$f" 2>/dev/null | head -1 | tr -d '[:space:]')
  [ -n "$mt" ] || mt=$(date -r "$f" +%Y 2>/dev/null | tr -d '[:space:]')
  if printf '%s' "$mt" | grep -qE '^[0-9]{4}$'; then printf '%s' "$mt"; return 0; fi
  printf 'MTIME_FALLBACK_ALSO_FAILED: %s\n' "$f" >> "$log"
  return 1
}
# Best-effort sortable timestamp (epoch seconds) for ordering clips within
# a year before joining, so the combined file plays in chronological order.
stitch_get_sort_key() {
  local f="$1" out tmpout
  tmpout=$(mktemp /tmp/mp_stitch_meta.XXXXXX)
  run_with_timeout "$META_TIMEOUT_SECS" ffprobe -v quiet -print_format flat \
        -show_entries format_tags=creation_time "$f" > "$tmpout" 2>/dev/null
  out=$(cat "$tmpout" 2>/dev/null); rm -f "$tmpout"
  local date; date=$(printf '%s\n' "$out" | awk -F'"' '/creation_time/{print $2; exit}')
  local epoch=""
  if [ -n "$date" ]; then
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${date:0:19}" "+%s" 2>/dev/null | head -1 | tr -d '[:space:]')
    printf '%s' "$epoch" | grep -qE '^[0-9]+$' || epoch=""
  fi
  if [ -z "$epoch" ]; then
    epoch=$(stat -f "%m" "$f" 2>/dev/null | head -1 | tr -d '[:space:]')
    printf '%s' "$epoch" | grep -qE '^[0-9]+$' || epoch=""
  fi
  [ -z "$epoch" ] && epoch=0
  printf '%s' "$epoch"
}
stitch_get_duration() {
  ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null
}

# True if this year's video is already "done" in ANY known form: the plain
# combined file, a youtube_ready file/parts, or an UPLOADED_-prefixed
# variant of either (the prefix we apply once a year is confirmed uploaded).
# Without this, a year that's already been renamed downstream would look
# "not stitched" again and get needlessly rejoined from scratch.
stitch_year_already_done() {
  local master="$1" year="$2"
  [ -f "${master}/Videos/${year}_combined.mp4" ] && return 0
  compgen -G "${master}/Videos/*${year}_youtube_ready*" > /dev/null 2>&1 && return 0
  return 1
}

# Joins every video in "$1/Videos" into one file per capture year
# ("$1/Videos/<year>_combined.mp4"), stream-copied (no re-encode, no
# resizing — "most basic stitching"). Verifies the joined file's duration
# and size against the sum of its inputs BEFORE deleting anything.
# Resumable: a year whose combined file already exists is skipped.
# Never touches LivePhotoClips — only the real, standalone Videos bucket.

step_stitch() {
  local master="$1"
  banner; echo "  STEP 5: STITCH (join each year's videos into one file)"; hr
  require_cmd ffmpeg "Install with: brew install ffmpeg"
  require_cmd ffprobe "Comes with ffmpeg — brew install ffmpeg"
  [ -d "$master/Videos" ] || { warn "No Videos folder found at $master/Videos — nothing to stitch."; return 0; }

  local log="${LOG_DIR}/stitch.log"; : > "$log"
  say "Videos folder: $master/Videos"

  local filelist="/tmp/mp_stitch_files.$$"
  find "$master/Videos" -type f ! -iname "*_combined.mp4" > "$filelist"
  local total; total=$(wc -l < "$filelist" | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    warn "No un-joined videos found (maybe everything's already stitched)."
    rm -f "$filelist"; return 0
  fi
  say "Found $total video(s) to sort into years..."

  local yearfile="/tmp/mp_stitch_yearkeys.$$"; : > "$yearfile"
  local n=0
  while IFS= read -r f; do
    n=$((n + 1))
    local year sortkey
    year=$(stitch_get_year "$f" "$log") || { printf 'SKIP_NO_YEAR\t%s\n' "$f" >> "$log"; continue; }
    sortkey=$(stitch_get_sort_key "$f")
    printf '%s\t%s\t%s\n' "$year" "$sortkey" "$f" >> "$yearfile"
    if [ "$((n % PROGRESS_EVERY))" -eq 0 ]; then say "  ...read metadata for $n/$total"; fi
  done < "$filelist"
  rm -f "$filelist"

  local years; years=$(awk -F'\t' '{print $1}' "$yearfile" | sort -un)
  local year_count; year_count=$(printf '%s\n' "$years" | grep -c . || true)
  say "Found $year_count distinct year(s) of video."

  local stitched=0 skipped=0 failed=0
  while IFS= read -r year; do
    [ -z "$year" ] && continue
    local outfile="${master}/Videos/${year}_combined.mp4"
    if stitch_year_already_done "$master" "$year"; then
      say "  ${year}: already stitched/uploaded (found an existing combined or youtube_ready file) — skipping."
      skipped=$((skipped + 1)); continue
    fi

    local group="/tmp/mp_stitch_group.$$"
    awk -F'\t' -v y="$year" '$1==y{print $2"\t"$3}' "$yearfile" | sort -n | awk -F'\t' '{print $2}' > "$group"
    local gcount; gcount=$(wc -l < "$group" | tr -d ' ')
    say "  ${year}: joining $gcount clip(s)..."

    if [ "$gcount" -eq 1 ]; then
      # Nothing to actually stitch — just adopt the single file as the
      # year's combined video, no re-encoding, zero risk.
      local only; only=$(cat "$group")
      if cp -p "$only" "${outfile}.tmp" 2>>"$log" && [ -s "${outfile}.tmp" ]; then
        mv "${outfile}.tmp" "$outfile"
        rm -f "$only"
        printf 'OK\tsingle\t%s\t->\t%s\n' "$only" "$outfile" >> "$log"
        say "  ${year}: only one clip — adopted as-is, original removed."
        stitched=$((stitched + 1))
      else
        printf 'FAIL\tsingle_copy\t%s\n' "$only" >> "$log"
        err "  ${year}: failed to adopt the single clip — original left untouched."
        rm -f "${outfile}.tmp"; failed=$((failed + 1))
      fi
      rm -f "$group"; continue
    fi

    # Sum expected duration/size across the group before touching anything.
    local sum_dur=0 sum_bytes=0 bad_input=0
    while IFS= read -r f; do
      local d b
      d=$(stitch_get_duration "$f")
      b=$(fsize "$f")
      if [ -z "$d" ]; then bad_input=$((bad_input + 1)); printf 'UNREADABLE_INPUT\t%s\n' "$f" >> "$log"; continue; fi
      sum_dur=$(awk -v a="$sum_dur" -v b="$d" 'BEGIN{printf "%.3f", a+b}')
      sum_bytes=$((sum_bytes + b))
    done < "$group"
    if [ "$bad_input" -gt 0 ]; then
      err "  ${year}: $bad_input clip(s) couldn't be read by ffprobe — skipping this year untouched, check $log."
      rm -f "$group"; failed=$((failed + 1)); continue
    fi

    # Two-pass join, not one. Feeding a single continuous ffmpeg decode
    # pass a concat of many heterogeneous clips is fragile: the audio
    # decoder carries internal state across the WHOLE stream, and clips
    # with even slightly different AAC configs sitting next to each other
    # can desync the decoder at that boundary — corrupting audio from
    # that point on even though every clip is perfectly fine on its own
    # (confirmed by testing each individually). So audio is normalized to
    # one uniform format per clip FIRST, in its own isolated ffmpeg
    # process (no shared decoder state possible), and only THEN are the
    # now-uniform pieces joined via plain stream copy. Video is never
    # touched in either pass — no resizing, no re-encoding.
    local normdir="/tmp/mp_stitch_norm_${year}.$$"
    mkdir -p "$normdir"
    local ni=0 norm_ok=1
    local normlist="/tmp/mp_stitch_normlist.$$"; : > "$normlist"
    while IFS= read -r f; do
      ni=$((ni + 1))
      local normf; normf=$(printf '%s/part%04d.mp4' "$normdir" "$ni")
      if ! run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -i "$f" \
            -c:v copy -c:a aac -ar 48000 -ac 2 -b:a 192k -movflags +faststart -f mp4 \
            "$normf" </dev/null >>"$log" 2>&1; then
        printf 'FAIL\tnormalize_audio\t%s\n' "$f" >> "$log"
        err "  ${year}: couldn't normalize audio for one clip ($(basename "$f")) — skipping this year untouched, check $log."
        norm_ok=0; break
      fi
      if [ ! -s "$normf" ]; then
        printf 'FAIL\tnormalize_empty\t%s\n' "$f" >> "$log"
        err "  ${year}: audio normalization produced an empty file for $(basename "$f") — skipping this year untouched."
        norm_ok=0; break
      fi
      printf '%s\n' "$normf" >> "$normlist"
    done < "$group"

    if [ "$norm_ok" -ne 1 ]; then
      rm -rf "$normdir"; rm -f "$normlist" "$group"; failed=$((failed + 1)); continue
    fi

    local listfile="/tmp/mp_stitch_list.$$"; : > "$listfile"
    while IFS= read -r f; do
      local esc; esc=$(printf '%s' "$f" | sed "s/'/'\\\\''/g")
      printf "file '%s'\n" "$esc" >> "$listfile"
    done < "$normlist"
    rm -f "$normlist"

    # Now a plain stream-copy concat — safe, since every piece already
    # shares identical audio parameters after the normalize pass above.
    if ! run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -f concat -safe 0 -i "$listfile" \
          -c copy -movflags +faststart -f mp4 "${outfile}.tmp" </dev/null >>"$log" 2>&1; then
      printf 'FAIL\tconcat_timeout_or_error\t%s\n' "$year" >> "$log"
      err "  ${year}: ffmpeg concat failed or timed out — originals left untouched, check $log."
      rm -f "${outfile}.tmp" "$listfile"; rm -rf "$normdir"; rm -f "$group"; failed=$((failed + 1)); continue
    fi
    rm -f "$listfile"
    rm -rf "$normdir"

    if [ ! -s "${outfile}.tmp" ]; then
      printf 'FAIL\tempty_output\t%s\n' "$year" >> "$log"
      err "  ${year}: joined file came out empty — originals left untouched."
      rm -f "${outfile}.tmp" "$group"; failed=$((failed + 1)); continue
    fi

    # The real corruption check: fully decode both streams and look for
    # actual decode errors. Container "duration" metadata is NOT trusted
    # for this — concat'd files can carry bogus/inflated duration values
    # from timestamp discontinuities even when content is fine, and the
    # reverse (plausible-looking duration hiding real corruption) is
    # exactly what slipped through here before. Decode errors are the one
    # signal that can't lie.
    local decode_errs decode_scan_log="/tmp/mp_stitch_decodescan.$$"
    run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -v error -i "${outfile}.tmp" -map 0 -f null - </dev/null > "$decode_scan_log" 2>&1
    decode_errs=$({ grep -c "Error while decoding\|Invalid data found" "$decode_scan_log" 2>/dev/null || true; })
    cat "$decode_scan_log" >> "$log"; rm -f "$decode_scan_log"
    local accept_corruption=0
    if [ "${decode_errs:-0}" -gt 0 ]; then
      printf 'WARN\tdecode_errors\t%s\t%s errors\n' "$year" "$decode_errs" >> "$log"
      warn "  ${year}: joined file has $decode_errs decode error(s) — usually brief hiccups right at a clip-to-clip splice"
      warn "  ${year}: (different clips can have slightly different video encoder settings), not whole-file corruption."
      if confirm "  ${year}: keep this joined file anyway (accepting these $decode_errs error(s)) and delete the ${gcount} originals?"; then
        accept_corruption=1
      else
        err "  ${year}: originals left untouched, joined file discarded — check $log."
        rm -f "${outfile}.tmp" "$group"; failed=$((failed + 1)); continue
      fi
    fi

    local out_dur out_bytes size_ratio
    out_dur=$(stitch_get_duration "${outfile}.tmp")
    out_bytes=$(fsize "${outfile}.tmp")
    if [ -z "$out_dur" ]; then
      printf 'FAIL\tunreadable_output\t%s\n' "$year" >> "$log"
      err "  ${year}: joined file isn't readable by ffprobe — originals left untouched."
      rm -f "${outfile}.tmp" "$group"; failed=$((failed + 1)); continue
    fi
    size_ratio=$(awk -v o="$out_bytes" -v s="$sum_bytes" 'BEGIN{if(s>0) printf "%.3f", o/s; else print 0}')
    local size_ok
    size_ok=$(awk -v r="$size_ratio" -v lo="$STITCH_MIN_SIZE_RATIO" 'BEGIN{print (r>=lo)?1:0}')
    # No upper bound on size here: audio is now re-encoded at a fixed
    # bitrate rather than copied, so output size legitimately varies from
    # input size and isn't a reliable ceiling signal anymore.
    if [ "$size_ok" -ne 1 ]; then
      printf 'FAIL\tself_check\t%s\tsize_ratio=%s\n' "$year" "$size_ratio" >> "$log"
      err "  ${year}: self-check failed (size ratio ${size_ratio}, output suspiciously small) — originals left untouched, check $log."
      rm -f "${outfile}.tmp" "$group"; failed=$((failed + 1)); continue
    fi

    mv "${outfile}.tmp" "$outfile"
    if [ "$accept_corruption" -eq 1 ]; then
      warn "  ${year}: joined $gcount clips -> $(basename "$outfile") (duration ${out_dur}s) — kept DESPITE $decode_errs decode error(s), by your choice."
    else
      ok "  ${year}: joined $gcount clips -> $(basename "$outfile") (duration ${out_dur}s, checks passed)."
    fi
    while IFS= read -r f; do
      rm -f "$f" && printf 'DELETED\t%s\n' "$f" >> "$log"
    done < "$group"
    rm -f "$group"
    stitched=$((stitched + 1))
  done <<< "$years"
  rm -f "$yearfile"

  echo
  ok "Stitch done: $stitched year(s) joined, $skipped already done, $failed failed (left untouched)."
  [ "$failed" -gt 0 ] && warn "Re-run this step any time — failed years are retried, successful ones are skipped."
  return 0
}

# ============================================================================
# STEP 6: YOUTUBE-READY (split anything over YouTube's ~12h length cap)
# ============================================================================
# YouTube rejects ("Processing abandoned — Video is too long") anything
# over ~12 hours. Any *_combined.mp4 under that cap is just renamed to
# "<year>_youtube_ready.mp4" (free — no re-encoding). Anything over the
# cap is split into "<year>_youtube_ready_partNN.mp4" pieces via stream-
# copy segmenting (no re-encode, no resizing — same philosophy as stitch).
# Every part is verified (readable, under the cap, decodes clean, and the
# parts' total duration adds back up to the original) BEFORE the oversized
# original is deleted. Resumable: a year with a "_youtube_ready" file or
# any "_youtube_ready_part*" files already present is skipped.

step_youtube_ready() {
  local master="$1"
  banner; echo "  STEP 6: YOUTUBE-READY (split anything over YouTube's ~12h limit)"; hr
  require_cmd ffmpeg "Install with: brew install ffmpeg"
  require_cmd ffprobe "Comes with ffmpeg — brew install ffmpeg"
  [ -d "$master/Videos" ] || { warn "No Videos folder found at $master/Videos — nothing to do."; return 0; }

  local log="${LOG_DIR}/youtube_ready.log"; : > "$log"
  local filelist="/tmp/mp_yt_files.$$"
  find "$master/Videos" -maxdepth 1 -iname "*_combined.mp4" > "$filelist"
  local total; total=$(wc -l < "$filelist" | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    warn "No *_combined.mp4 files found in $master/Videos — run stitch first."
    rm -f "$filelist"; return 0
  fi
  say "Found $total combined video(s) to check against YouTube's length limit."

  local ready=0 split=0 skipped=0 failed=0
  while IFS= read -r f; do
    local base year
    base=$(basename "$f" .mp4)
    year="${base%_combined}"

    if compgen -G "${master}/Videos/${year}_youtube_ready*" > /dev/null 2>&1; then
      say "  ${year}: already youtube-ready — skipping."
      skipped=$((skipped + 1)); continue
    fi

    local dur; dur=$(stitch_get_duration "$f")
    if [ -z "$dur" ]; then
      err "  ${year}: couldn't read duration — skipping, check $log."
      printf 'FAIL\tunreadable\t%s\n' "$f" >> "$log"
      failed=$((failed + 1)); continue
    fi

    local over; over=$(awk -v d="$dur" -v m="$YOUTUBE_MAX_DURATION_SECS" 'BEGIN{print (d>m)?1:0}')
    if [ "$over" -ne 1 ]; then
      # Under the limit, but "under the limit" is not the same as "not
      # corrupted" — this file may have been made by an older/buggy join,
      # so it gets the exact same full decode-error scan as a freshly
      # split part would, before it's ever labeled ready.
      say "  ${year}: under the length limit (${dur}s) — verifying it actually decodes clean before marking ready..."
      local decode_scan="/tmp/mp_yt_wholescan.$$"
      run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -v error -i "$f" -map 0 -f null - </dev/null > "$decode_scan" 2>&1
      local werrs; werrs=$({ grep -c "Error while decoding\|Invalid data found" "$decode_scan" 2>/dev/null || true; })
      cat "$decode_scan" >> "$log"; rm -f "$decode_scan"
      local accept_corruption=0
      if [ "${werrs:-0}" -gt 0 ]; then
        warn "  ${year}: has $werrs known decode error(s) — almost certainly inherited from an old join, not something new."
        printf 'WARN\tdecode_errors_whole\t%s\t%s errors\n' "$f" "$werrs" >> "$log"
        if confirm "  ${year}: use it anyway (accepting these $werrs error(s)) and mark it youtube-ready?"; then
          accept_corruption=1
        else
          err "  ${year}: left as-is, NOT marked ready — check $log."
          failed=$((failed + 1)); continue
        fi
      fi
      local readyname="${master}/Videos/${year}_youtube_ready.mp4"
      [ "$accept_corruption" -eq 1 ] && readyname="${master}/Videos/${year}_youtube_ready_HASERRORS.mp4"
      if mv "$f" "$readyname" 2>>"$log"; then
        if [ "$accept_corruption" -eq 1 ]; then
          warn "  ${year}: renamed to $(basename "$readyname") — kept DESPITE $werrs known decode error(s), by your choice."
        else
          ok "  ${year}: under the limit (${dur}s), decodes clean — renamed to ${year}_youtube_ready.mp4."
        fi
        ready=$((ready + 1))
      else
        err "  ${year}: rename failed — check $log."
        printf 'FAIL\trename\t%s\n' "$f" >> "$log"
        failed=$((failed + 1))
      fi
      continue
    fi

    say "  ${year}: ${dur}s exceeds YouTube's length limit — splitting into parts..."
    local segdir="/tmp/mp_yt_seg_${year}.$$"
    mkdir -p "$segdir"
    if ! run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -i "$f" -map 0 -c copy \
          -f segment -segment_time "$YOUTUBE_MAX_DURATION_SECS" -reset_timestamps 1 \
          "${segdir}/part%03d.mp4" </dev/null >>"$log" 2>&1; then
      err "  ${year}: split failed or timed out — original left untouched, check $log."
      rm -rf "$segdir"; failed=$((failed + 1)); continue
    fi

    local partlist="/tmp/mp_yt_parts.$$"
    find "$segdir" -type f -iname "part*.mp4" | sort > "$partlist"
    local part_n; part_n=$(wc -l < "$partlist" | tr -d ' ')
    if [ "$part_n" -eq 0 ]; then
      err "  ${year}: split produced no parts — original left untouched."
      rm -rf "$segdir"; rm -f "$partlist"; failed=$((failed + 1)); continue
    fi

    # ffmpeg's segment muxer can only cut at the nearest keyframe, so a
    # part can still come out over YouTube's real cap despite our small
    # split target (sparse keyframes in some phone/camera clips). Rather
    # than failing the whole year over one oversized part, re-split just
    # that part at a much finer target and splice the pieces back in.
    local fixedlist="/tmp/mp_yt_parts_fixed.$$"; : > "$fixedlist"
    local hardcap_tol; hardcap_tol=$(awk -v c="$YOUTUBE_HARD_CAP_SECS" -v t="$YOUTUBE_CAP_TOLERANCE_SECS" 'BEGIN{print c+t}')
    while IFS= read -r p; do
      local pdur0; pdur0=$(stitch_get_duration "$p")
      local over_cap; over_cap=$(awk -v d="${pdur0:-0}" -v c="$hardcap_tol" 'BEGIN{print (d>c)?1:0}')
      if [ "$over_cap" -eq 1 ]; then
        say "    $(basename "$p") is ${pdur0}s — over the real cap even after splitting, re-splitting it finer..."
        local resplitdir="${p}.resplit"; mkdir -p "$resplitdir"
        if run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -i "$p" -map 0 -c copy \
              -f segment -segment_time 3600 -reset_timestamps 1 \
              "${resplitdir}/sub%03d.mp4" </dev/null >>"$log" 2>&1; then
          find "$resplitdir" -type f -iname "sub*.mp4" | sort >> "$fixedlist"
          rm -f "$p"
        else
          warn "    re-split of $(basename "$p") failed — leaving it as-is, it'll likely fail verification below."
          printf '%s\n' "$p" >> "$fixedlist"
        fi
      else
        printf '%s\n' "$p" >> "$fixedlist"
      fi
    done < "$partlist"
    mv "$fixedlist" "$partlist"
    part_n=$(wc -l < "$partlist" | tr -d ' ')

    # Verify every single part BEFORE touching the original. Hard failures
    # (empty, unreadable, still too long) always block — there's no way to
    # use a part like that. Decode errors are different: on these known-
    # corrupted years, they're expected (inherited from the old join), so
    # instead of auto-failing, ask once whether to keep the parts anyway.
    local bad=0 corrupt_parts=0 total_derrs=0 sum_parts_dur=0
    while IFS= read -r p; do
      if [ ! -s "$p" ]; then bad=$((bad + 1)); printf 'FAIL\tempty_part\t%s\n' "$p" >> "$log"; continue; fi
      local pdur; pdur=$(stitch_get_duration "$p")
      if [ -z "$pdur" ]; then bad=$((bad + 1)); printf 'FAIL\tunreadable_part\t%s\n' "$p" >> "$log"; continue; fi
      # Checked against YouTube's REAL cap (with slack), not our small
      # split target — a part landing anywhere under ~12h is fine to
      # upload even though we aimed for 6h; keyframe placement decides
      # exactly where each part could be cut, not us.
      local ptoolong; ptoolong=$(awk -v d="$pdur" -v c="$YOUTUBE_HARD_CAP_SECS" -v t="$YOUTUBE_CAP_TOLERANCE_SECS" 'BEGIN{print (d>c+t)?1:0}')
      if [ "$ptoolong" -eq 1 ]; then bad=$((bad + 1)); printf 'FAIL\tpart_still_too_long\t%s\t%s\n' "$p" "$pdur" >> "$log"; continue; fi
      local decode_scan="/tmp/mp_yt_decodescan.$$"
      run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -v error -i "$p" -map 0 -f null - </dev/null > "$decode_scan" 2>&1
      local derrs; derrs=$({ grep -c "Error while decoding\|Invalid data found" "$decode_scan" 2>/dev/null || true; })
      cat "$decode_scan" >> "$log"; rm -f "$decode_scan"
      if [ "${derrs:-0}" -gt 0 ]; then
        corrupt_parts=$((corrupt_parts + 1)); total_derrs=$((total_derrs + derrs))
        printf 'WARN\tdecode_errors_part\t%s\t%s\n' "$p" "$derrs" >> "$log"
      fi
      sum_parts_dur=$(awk -v a="$sum_parts_dur" -v b="$pdur" 'BEGIN{printf "%.3f", a+b}')
    done < "$partlist"

    if [ "$bad" -gt 0 ]; then
      err "  ${year}: $bad part(s) failed verification — original left untouched, check $log."
      rm -rf "$segdir"; rm -f "$partlist"; failed=$((failed + 1)); continue
    fi

    local accept_corruption=0
    if [ "$corrupt_parts" -gt 0 ]; then
      warn "  ${year}: $corrupt_parts of $part_n part(s) have $total_derrs known decode error(s) total — almost certainly inherited from the old join."
      if confirm "  ${year}: keep and use these parts anyway (accepting the corruption) so you can at least upload the rest?"; then
        accept_corruption=1
      else
        err "  ${year}: left as-is, NOT split — check $log."
        rm -rf "$segdir"; rm -f "$partlist"; failed=$((failed + 1)); continue
      fi
    fi

    local dur_ratio dur_ok
    dur_ratio=$(awk -v o="$sum_parts_dur" -v s="$dur" 'BEGIN{if(s>0) printf "%.3f", o/s; else print 0}')
    dur_ok=$(awk -v r="$dur_ratio" -v m="$STITCH_MIN_DURATION_RATIO" 'BEGIN{print (r>=m)?1:0}')
    if [ "$dur_ok" -ne 1 ]; then
      err "  ${year}: split parts' total duration (${sum_parts_dur}s) doesn't match the original (${dur}s) — original left untouched, check $log."
      rm -rf "$segdir"; rm -f "$partlist"; failed=$((failed + 1)); continue
    fi

    local partname_tag="part"
    [ "$accept_corruption" -eq 1 ] && partname_tag="part_HASERRORS"
    local pn=0
    while IFS= read -r p; do
      pn=$((pn + 1))
      mv "$p" "${master}/Videos/${year}_youtube_ready_${partname_tag}$(printf '%02d' "$pn").mp4"
    done < "$partlist"
    rm -rf "$segdir"; rm -f "$partlist"
    rm -f "$f"
    if [ "$accept_corruption" -eq 1 ]; then
      warn "  ${year}: split into $pn part(s) and kept DESPITE $total_derrs known decode error(s), by your choice — original replaced."
    else
      ok "  ${year}: split into $pn verified part(s), original replaced."
    fi
    split=$((split + 1))
  done < "$filelist"
  rm -f "$filelist"

  echo
  ok "YouTube-ready done: $ready renamed as-is, $split split into parts, $skipped already done, $failed failed (left untouched)."
  [ "$failed" -gt 0 ] && warn "Re-run this step any time — failed years are retried, successful ones are skipped."
  return 0
}

# ============================================================================
# REFRESH: recover specific years whose combined/youtube_ready video got
# deleted (e.g. because it was found corrupted), WITHOUT re-touching any
# year that's already done, and WITHOUT re-processing photos at all.
#
# Use case this exists for: some already-joined years turned out to have
# real audio corruption baked in from an old buggy join. Their original
# per-clip sources are already gone, so the only way to rebuild them is
# from a fresh Takeout re-export. This lets you point at that fresh export,
# pulls ONLY the video files out of it (photos are completely ignored —
# they're already organized/uploaded, no need to touch or duplicate them),
# and only stitches years that are actually missing an output file.
# ============================================================================

# Pulls ONLY video files (by extension) out of $1 and moves them into
# $2/Videos. Everything else (photos, json, docs) is left in place,
# untouched. Safe to run against a fresh Takeout export whose Videos
# folder path may differ, and against a folder that also contains photos.

# ---------------------------------------------------------------------------
# STAGE 4/5/6 wrappers — pick the folder, then run the ported step
# ---------------------------------------------------------------------------
# The ported steps expect a "master" folder holding a Videos/ subfolder.
# Our sorter produces VIDEOS/ (uppercase, one subfolder per year), so we
# present a flat view to them via a temporary staging folder of symlinks...
# no: simpler and safer, we just point them at a folder we prepare.
_pick_videos_root() {
  local start="${MERGE_DEST:-$HOME/Downloads}"
  PICKED=""
  browse_folder "Select the folder that CONTAINS your videos folder" "$start" media
  VID_PARENT="$PICKED"
  if [ -d "$VID_PARENT/VIDEOS" ]; then
    STITCH_MASTER="$VID_PARENT/.stitch_view"
    rm -rf "$STITCH_MASTER"; mkdir -p "$STITCH_MASTER"
    ln -s "$VID_PARENT/VIDEOS" "$STITCH_MASTER/Videos"
    return 0
  fi
  if [ -d "$VID_PARENT/Videos" ]; then
    STITCH_MASTER="$VID_PARENT"
    return 0
  fi
  err "No VIDEOS/ or Videos/ folder inside:"
  info "$VID_PARENT"
  pause; return 1
}

stage_stitch() {
  command -v ffmpeg >/dev/null 2>&1 || {
    head1; err "ffmpeg is required to stitch videos."
    info "Install it once:  ${B}brew install ffmpeg${R}"
    if command -v brew >/dev/null 2>&1; then
      printf '\n%s' "  Install ffmpeg now? [y/N] "; read -r a
      [[ "$a" =~ ^[Yy] ]] && brew install ffmpeg
    fi
    command -v ffmpeg >/dev/null 2>&1 || { pause; return 1; }
  }
  _pick_videos_root || return 1
  head1
  warn "This joins each year's clips into one file and ${B}deletes the originals${R},"
  warn "but only after verifying the joined file decodes cleanly and is the"
  warn "expected size. A year that fails is left completely untouched."
  echo
  confirm "Proceed?" || { info "Cancelled."; pause; return 0; }
  step_stitch "$STITCH_MASTER"
  [ -L "$STITCH_MASTER/Videos" ] && rm -rf "$STITCH_MASTER"
  pause
}

stage_youtube() {
  command -v ffmpeg >/dev/null 2>&1 || { head1; err "ffmpeg required — brew install ffmpeg"; pause; return 1; }
  _pick_videos_root || return 1
  step_youtube_ready "$STITCH_MASTER"
  [ -L "$STITCH_MASTER/Videos" ] && rm -rf "$STITCH_MASTER"
  pause
}

stage_audit() {
  local start="${MERGE_DEST:-$HOME/Downloads}"
  PICKED=""
  browse_folder "Select the folder to audit" "$start" media
  step_audit "$PICKED"
  pause
}


# ---------------------------------------------------------------------------
# STAGE 5 — join each year into one video (normalize, then concat)
# ---------------------------------------------------------------------------
# A plain stream-copy concat only works when every clip shares codec,
# resolution, frame rate and audio layout. Real phone libraries don't:
# one measured year had 253 distinct formats across 705 clips, only 10%
# matching the most common one. So each clip is conformed to a single
# target first (scaled and padded, never cropped, aspect preserved), then
# the uniform pieces are stream-copied together.
#
# Originals are never deleted here.

JOIN_W=1920; JOIN_H=1080; JOIN_FPS=30
JOIN_RATE=(-b:v 8M); JOIN_LABEL="1080p high bitrate"
# Camera-origin names. Everything else in a Google Photos export tends to be
# screen recordings (RPReplay), app exports (TocaLife, Vont, Beat.ly) and
# social downloads — which is not what a family year-video should be.
JOIN_CAMERA_RE='^(IMG_|MVI_|DSC|VID_|PXL_|MOV_|GOPR|trim\.|FullSizeRender)'

_join_encoder() {
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then
    echo "h264_videotoolbox"
  else
    echo "libx264"
  fi
}

stage_join() {
  command -v ffmpeg >/dev/null 2>&1 || {
    head1; err "ffmpeg is required."
    info "Install once:  ${B}brew install ffmpeg${R}"
    if command -v brew >/dev/null 2>&1; then
      printf '\n%s' "  Install ffmpeg now? [y/N] "; read -r a
      [[ "$a" =~ ^[Yy] ]] && brew install ffmpeg
    fi
    command -v ffmpeg >/dev/null 2>&1 || { pause; return 1; }
  }

  PICKED=""
  browse_folder "Select the folder of per-year video folders (e.g. VIDEOS_CLEAN)" \
                "${MERGE_DEST:-$HOME/Downloads}" media
  local ROOT="$PICKED"
  local OUT="$ROOT/_JOINED"

  head1
  printf '%s\n' "  ${B}Quality${R}"; echo
  printf '%s\n' "    ${B}1${R}  1080p, high bitrate   ${DIM}camera footage you'll rewatch${R}"
  printf '%s\n' "    ${B}2${R}  720p, quality-based   ${DIM}screen recordings, game capture${R}"
  printf '%s\n' "    ${B}3${R}  480p, smallest        ${DIM}keep-a-record only${R}"
  printf '\n%s' "  > [1] "; read -r q
  case "$q" in
    2) JOIN_W=1280; JOIN_H=720;  JOIN_RATE=(-crf 26); JOIN_LABEL="720p quality-based" ;;
    3) JOIN_W=854;  JOIN_H=480;  JOIN_RATE=(-crf 28); JOIN_LABEL="480p smallest" ;;
    *) JOIN_W=1920; JOIN_H=1080; JOIN_RATE=(-b:v 8M); JOIN_LABEL="1080p high bitrate" ;;
  esac

  head1
  printf '%s\n' "  ${B}Options${R}"; echo
  info "Target: ${B}${JOIN_W}x${JOIN_H}${R} @ ${JOIN_FPS}fps, stereo ${DIM}($JOIN_LABEL)${R}"
  info "Scaled and padded to fit. Portrait clips get bars, never cropped."
  echo
  printf '%s' "  Camera footage only (skip screen recordings & app exports)? [Y/n] "
  read -r a; local CAMONLY=1; [[ "$a" =~ ^[Nn] ]] && CAMONLY=0
  local ENC; ENC=$(_join_encoder)
  # videotoolbox has no CRF mode; use libx264 when a quality target is set
  case "${JOIN_RATE[0]}" in -crf) ENC="libx264" ;; esac
  info "Encoder: ${B}$ENC${R}$([ "$ENC" = "h264_videotoolbox" ] && echo " ${DIM}(hardware)${R}")"

  mkdir -p "$OUT"
  local log="$OUT/join.log"; : > "$log"

  # ---- survey -----------------------------------------------------------
  head1; printf '%s\n' "  ${B}Plan${R}"; hr
  local years=() y n
  while IFS= read -r y; do
    y="$(basename "$y")"
    n=$(find "$ROOT/$y" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r f; do
          b="$(basename "$f")"
          if [ "$CAMONLY" -eq 1 ]; then
            printf '%s' "$b" | grep -qE "$JOIN_CAMERA_RE" && echo x
          else echo x; fi
        done | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 0 ] && { years+=("$y"); printf "   %s   %4s clip(s)\n" "$y" "$n"; }
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "_JOINED" | sort)

  [ ${#years[@]} -gt 0 ] || { echo; err "No matching clips found."; pause; return 1; }
  echo; info "Output: ${CYN}$OUT${R}"
  info "${DIM}Originals are never deleted by this step.${R}"
  echo
  confirm "Start joining?" || { info "Cancelled."; pause; return 0; }

  # ---- per year ---------------------------------------------------------
  local done_=0 failed=0
  for y in "${years[@]}"; do
    local outfile="$OUT/${y}.mp4"
    if [ -f "$outfile" ]; then
      head1; info "[$y] already joined — skipping."; sleep 0.3; continue
    fi
    head1; printf '%s\n' "  ${B}$y${R}"; hr

    local list=(); local f b
    while IFS= read -r f; do
      b="$(basename "$f")"
      if [ "$CAMONLY" -eq 1 ]; then
        printf '%s' "$b" | grep -qE "$JOIN_CAMERA_RE" || continue
      fi
      list+=("$f")
    done < <(find "$ROOT/$y" -maxdepth 1 -type f | sort)

    local total=${#list[@]}
    info "$total clip(s) to conform"
    local normdir; normdir=$(mktemp -d "${TMPDIR:-/tmp}/join_${y}.XXXXXX")
    local cat="$normdir/list.txt"; : > "$cat"
    local i=0 bad=0

    for f in "${list[@]}"; do
      i=$((i+1))
      printf '\r  conforming %s/%s   ' "$i" "$total"
      local part; part=$(printf '%s/p%05d.mp4' "$normdir" "$i")
      local has_audio
      has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null | head -1)
      local vf="scale=${JOIN_W}:${JOIN_H}:force_original_aspect_ratio=decrease,pad=${JOIN_W}:${JOIN_H}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${JOIN_FPS},format=yuv420p"
      if [ -n "$has_audio" ]; then
        run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -i "$f" \
          -vf "$vf" -c:v "$ENC" "${JOIN_RATE[@]}" -preset veryfast -c:a aac -ar 48000 -ac 2 -b:a 160k \
          -movflags +faststart -f mp4 "$part" </dev/null >>"$log" 2>&1
      else
        # give silent clips a real silent track, or concat desyncs
        run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -i "$f" \
          -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
          -vf "$vf" -c:v "$ENC" "${JOIN_RATE[@]}" -preset veryfast -c:a aac -ar 48000 -ac 2 -b:a 160k \
          -shortest -movflags +faststart -f mp4 "$part" </dev/null >>"$log" 2>&1
      fi
      if [ ! -s "$part" ]; then
        printf 'SKIP_UNREADABLE\t%s\n' "$f" >> "$log"; bad=$((bad+1)); continue
      fi
      printf "file '%s'\n" "$(printf '%s' "$part" | sed "s/'/'\\\\''/g")" >> "$cat"
    done
    printf '\r%*s\r' 40 ''
    [ "$bad" -gt 0 ] && warn "$bad clip(s) unreadable — skipped, listed in join.log"

    if [ ! -s "$cat" ]; then
      err "$y: nothing conformed successfully."
      rm -rf "$normdir"; failed=$((failed+1)); continue
    fi

    # remember the expected total so we can verify the join afterwards
    local sum_dur=0 d
    while IFS= read -r f2; do
      d=$(stitch_get_duration "$f2"); [ -n "$d" ] && \
        sum_dur=$(awk -v a="$sum_dur" -v b="$d" 'BEGIN{printf "%.2f",a+b}')
    done < <(printf '%s\n' "${list[@]}")

    info "joining..."
    if ! run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -nostdin -y -f concat -safe 0 -i "$cat" \
          -c copy -movflags +faststart -f mp4 "${outfile}.tmp" </dev/null >>"$log" 2>&1; then
      err "$y: concat failed — see $log"
      rm -f "${outfile}.tmp"; rm -rf "$normdir"; failed=$((failed+1)); continue
    fi

    # verify the join actually decodes before we call it done
    local derr scan="$OUT/.decodescan"
    run_with_timeout "$STITCH_TIMEOUT_SECS" ffmpeg -v error -i "${outfile}.tmp" -map 0 -f null - \
      </dev/null > "$scan" 2>&1
    derr=$(grep -c "Error while decoding\|Invalid data found" "$scan" 2>/dev/null | head -1); derr=${derr:-0}
    cat "$scan" >> "$log" 2>/dev/null; rm -f "$scan"
    if [ "${derr:-0}" -gt 0 ]; then
      warn "$y: $derr decode error(s) — usually brief hiccups at a splice."
      confirm "  Keep this file anyway?" || {
        rm -f "${outfile}.tmp"; rm -rf "$normdir"; failed=$((failed+1)); continue; }
    fi

    # Duration self-check. A truncated piece can slip into the concat and
    # still decode without a single error — the only tell is that the result
    # is shorter than the sum of its inputs.
    local got ratio
    got=$(stitch_get_duration "${outfile}.tmp")
    ratio=$(awk -v o="${got:-0}" -v s="$sum_dur" 'BEGIN{print (s>0)? o/s : 0}')
    if awk -v r="$ratio" 'BEGIN{exit !(r<0.97)}'; then
      err "$y: joined file is $(awk -v r="$ratio" 'BEGIN{printf "%.0f",r*100}')% of the expected length"
      info "   ${DIM}got ${got:-0}s, expected ${sum_dur}s — a clip was truncated${R}"
      warn "Discarding it; originals untouched. Re-run to try again."
      rm -f "${outfile}.tmp"; rm -rf "$normdir"; failed=$((failed+1)); continue
    fi

    mv "${outfile}.tmp" "$outfile"
    rm -rf "$normdir"
    local dur; dur=$(stitch_get_duration "$outfile")
    ok "$y -> $(basename "$outfile")  ${DIM}($(printf '%.0f' "${dur:-0}")s, $(hbytes "$(fsize "$outfile")"))${R}"
    done_=$((done_+1))
    sleep 0.3
  done

  head1; printf '%s\n' "  ${B}Join complete${R}"; hr
  ok "$done_ year(s) joined"
  [ "$failed" -gt 0 ] && warn "$failed year(s) failed — originals untouched, see $log"
  info "Output: ${CYN}$OUT${R}"
  echo
  printf '%s' "  Open the folder? [Y/n] "; read -r a
  [[ "$a" =~ ^[Nn] ]] || open "$OUT"
  pause
}


# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
PYTOOL="${TMPDIR:-/tmp}/rescue_hq_sorter.$$.py"
PYREPAIR="${TMPDIR:-/tmp}/rescue_hq_repair.$$.py"
trap 'rm -f "$PYTOOL" "$PYREPAIR"' EXIT INT TERM
extract_python > "$PYTOOL"
extract_repair > "$PYREPAIR"

MERGE_DEST=""
check_deps

while true; do
  head1
  printf '%s\n' "  ${B}What do you want to do?${R}"
  echo
  printf '%s\n' "    ${B}1${R}  Merge Takeout zips        ${DIM}takeout-*.zip → ORGANIZED/${R}"
  printf '%s\n' "    ${B}2${R}  Sort photos & videos      ${DIM}→ PHOTOS/ + VIDEOS/<year>/${R}"
  printf '%s\n' "    ${B}3${R}  Repair a sorted tree      ${DIM}bad extensions, exiftool backups${R}"
  printf '%s\n' "    ${B}4${R}  Everything, back to back  ${DIM}merge → sort → repair${R}"
  echo
  printf '%s\n' "    ${B}5${R}  Join videos by year       ${DIM}one file per year (needs ffmpeg)${R}"
  printf '%s\n' "    ${B}6${R}  Make videos YouTube-ready ${DIM}split anything over ~12h${R}"
  printf '%s\n' "    ${B}7${R}  Audit / status report     ${DIM}read-only${R}"
  printf '%s\n' "    ${B}8${R}  Stitch (stream-copy only) ${DIM}fast, needs identical formats${R}"
  echo
  printf '%s\n' "    ${B}d${R}  Re-check dependencies"
  printf '%s\n' "    ${B}q${R}  Quit"
  printf '\n%s' "  > "
  read -r pick || { echo; exit 0; }   # Ctrl-C / EOF exits cleanly
  case "$pick" in
    1) stage_merge ;;
    2) stage_sort ;;
    3) stage_repair ;;
    4) stage_merge && stage_sort && stage_repair ;;
    5) stage_join ;;
    6) stage_youtube ;;
    7) stage_audit ;;
    8) stage_stitch ;;
    d|D) check_deps ;;
    q|Q) echo; exit 0 ;;
  esac
done
