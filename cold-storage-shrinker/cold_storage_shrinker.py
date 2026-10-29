#!/usr/bin/env python3
"""cold-storage-shrinker — walk a folder and shrink images + PDFs in place.

Two jobs, same policy as pipeline/03_compact.py: never rm an original (it goes
to the macOS Trash via `trash`, or to _cleanup/shrunk-originals/), and never
keep a result that isn't genuinely smaller.

  images  jpg/jpeg/png/tif/heic -> <= MAX_MB (default 1.5), stepping dimensions
          and JPEG quality down until it fits.
  pdfs    re-written through a Quartz filter (default the system "Reduce File
          Size"). The filter is unreliable: on vector-heavy PDFs it RASTERISES
          and can inflate a file 10x. So every result is measured and discarded
          unless it saves at least --min-gain percent.

Skips, deliberately:
  * dataless iCloud files (st_blocks == 0) - touching one forces a full
    download of the file from iCloud, which is never what you want here.
  * package bundles (.app .photoslibrary .pages .key .numbers .rtfd ...) -
    rewriting a file inside one corrupts the document.
  * node_modules / .git / Library caches.

Original mtimes are preserved, so archive-by-age still works afterwards.

Usage:
  cold_storage_shrinker.py [FOLDER] [--max-mb 1.5] [--min-gain 5]
                           [--pdf-filter PATH] [--images-only|--pdfs-only]
                           [--dry-run] [--quiet]

FOLDER defaults to iCloud Drive's Documents folder.
Requires /usr/bin/python3 (it has PIL and pyobjc Quartz).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ICLOUD = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"

IMG_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".heif"}
PDF_EXT = {".pdf"}
# .gif is excluded on purpose: re-encoding kills animation.

BUNDLE_SUFFIXES = {".app", ".photoslibrary", ".pages", ".key", ".numbers",
                   ".rtfd", ".bundle", ".framework", ".sparsebundle",
                   ".fcpbundle", ".logicx", ".band", ".imovielibrary",
                   ".tvlibrary", ".aplibrary", ".musiclibrary", ".download"}
SKIP_DIRS = {"node_modules", ".git", ".svn", "Caches", "__pycache__",
             ".venv", "venv", ".next", "dist"}

DIMS = (3000, 2400, 2000, 1600)
QUALITIES = (85, 75, 65, 55, 45)
SIPS_TIMEOUT_S = 60
PDF_TIMEOUT_S = 180

TRASH = shutil.which("trash")

try:
    from PIL import Image, ImageOps
    HAVE_PIL = True
except Exception:
    HAVE_PIL = False
HAVE_SIPS = shutil.which("sips") is not None

try:
    import Quartz
    from Foundation import NSURL
    HAVE_QUARTZ = True
except Exception:
    HAVE_QUARTZ = False


def log(msg: str) -> None:
    if not ARGS.quiet:
        print(msg, flush=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def is_dataless(p: Path) -> bool:
    """True for an iCloud placeholder whose bytes are not on this Mac."""
    try:
        st = p.stat()
        return st.st_size > 0 and st.st_blocks == 0
    except OSError:
        return True


def retire(f: Path, parked: Path) -> None:
    """Original -> Trash (recoverable). Fall back to a park dir. Never rm."""
    if ARGS.dry_run:
        return
    if TRASH:
        r = subprocess.run([TRASH, str(f)], capture_output=True)
        if r.returncode == 0 or not f.exists():
            return
    dest = parked / f.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    i = 0
    while dest.exists():
        i += 1
        dest = parked / f"{f.stem}.{i}{f.suffix}"
    shutil.move(str(f), str(dest))


def copy_mtime(src_stat, dst: Path) -> None:
    try:
        os.utime(dst, (src_stat.st_atime, src_stat.st_mtime))
    except OSError:
        pass


# ---------------------------------------------------------------- images ----

def pil_fit(src: Path, out: Path, cap: int) -> bool:
    try:
        im = Image.open(src)
        im = ImageOps.exif_transpose(im)
    except Exception:
        return False
    has_alpha = im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info)
    if has_alpha and src.suffix.lower() == ".png":
        # keep PNG (alpha would be lost); just downscale until it fits
        for dim in DIMS:
            w = im.copy()
            w.thumbnail((dim, dim))
            out.unlink(missing_ok=True)
            try:
                w.save(out, "PNG", optimize=True)
            except Exception:
                return False
            if 0 < out.stat().st_size <= cap:
                return True
        return False
    if im.mode != "RGB":
        im = im.convert("RGB")
    for dim in DIMS:
        w = im.copy()
        w.thumbnail((dim, dim))
        for q in QUALITIES:
            out.unlink(missing_ok=True)
            try:
                w.save(out, "JPEG", quality=q, optimize=True, progressive=True)
            except Exception:
                return False
            if 0 < out.stat().st_size <= cap:
                return True
    return False


def sips_fit(src: Path, out: Path, cap: int, keep_format: bool) -> bool:
    fmt = [] if keep_format else ["-s", "format", "jpeg"]
    for dim in DIMS:
        for q in QUALITIES:
            out.unlink(missing_ok=True)
            cmd = ["sips", "-Z", str(dim)] + fmt
            if not keep_format:
                cmd += ["-s", "formatOptions", str(q)]
            cmd += [str(src), "--out", str(out)]
            try:
                r = subprocess.run(cmd, capture_output=True, timeout=SIPS_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                out.unlink(missing_ok=True)
                return False
            if r.returncode == 0 and out.exists() and 0 < out.stat().st_size <= cap:
                return True
            if keep_format:
                break  # quality loop is meaningless without a format change
    return False


def do_image(f: Path, cap: int, parked: Path, rep: dict) -> None:
    st = f.stat()
    if st.st_size <= cap:
        rep["img_skipped"] += 1
        return
    ext = f.suffix.lower()
    heic = ext in (".heic", ".heif")
    tmp = f.with_name(f".{f.stem}.csshrink{'.heic' if heic else '.jpg'}")
    ok = False
    if heic:
        ok = HAVE_SIPS and sips_fit(f, tmp, cap, keep_format=True)
    else:
        if HAVE_PIL:
            ok = pil_fit(f, tmp, cap)
        if not ok and HAVE_SIPS:
            ok = sips_fit(f, tmp, cap, keep_format=False)
    if not ok or not tmp.exists():
        tmp.unlink(missing_ok=True)
        rep["img_failed"] += 1
        rep["failures"].append(str(f))
        return
    new = tmp.stat().st_size
    if new >= st.st_size:
        tmp.unlink(missing_ok=True)
        rep["img_skipped"] += 1
        return
    if ARGS.dry_run:
        tmp.unlink(missing_ok=True)
        rep["img_shrunk"] += 1
        rep["img_saved"] += st.st_size - new
        return
    # PNG that stayed PNG, or HEIC that stayed HEIC, keeps its extension
    if tmp.suffix == ".heic" or (ext == ".png" and tmp.suffix == ".png"):
        final = f
    else:
        final = f if ext in (".jpg", ".jpeg") else f.with_suffix(".jpg")
    copy_mtime(st, tmp)
    retire(f, parked)
    tmp.replace(final)
    rep["img_shrunk"] += 1
    rep["img_saved"] += st.st_size - new


# ------------------------------------------------------------------ pdfs ----

def quartz_shrink(src: Path, dst: Path, filt: str) -> bool:
    qf = Quartz.QuartzFilter.quartzFilterWithURL_(NSURL.fileURLWithPath_(filt))
    if qf is None:
        return False
    doc = Quartz.CGPDFDocumentCreateWithURL(NSURL.fileURLWithPath_(str(src)))
    if not doc:
        return False
    n = Quartz.CGPDFDocumentGetNumberOfPages(doc)
    if n < 1:
        return False
    ctx = Quartz.CGPDFContextCreateWithURL(NSURL.fileURLWithPath_(str(dst)), None, None)
    if not ctx:
        return False
    qf.applyToContext_(ctx)
    for i in range(1, n + 1):
        page = Quartz.CGPDFDocumentGetPage(doc, i)
        if not page:
            continue
        rect = Quartz.CGPDFPageGetBoxRect(page, Quartz.kCGPDFMediaBox)
        Quartz.CGContextBeginPage(ctx, rect)
        Quartz.CGContextDrawPDFPage(ctx, page)
        Quartz.CGContextEndPage(ctx)
    Quartz.CGPDFContextClose(ctx)
    return dst.exists() and dst.stat().st_size > 0


def run_pdf_worker(src: Path, dst: Path) -> int:
    """Shrink one PDF in a child process.

    CoreGraphics can use enormous memory rasterising a big PDF; on a tight
    machine jetsam SIGKILLs the process. Doing it in a child means we lose one
    file, not the whole run. Returns the child's exit code (-9 == killed).
    """
    cmd = [sys.executable, os.path.abspath(__file__), "--worker-pdf",
           str(src), str(dst), "--pdf-filter", ARGS.pdf_filter]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=PDF_TIMEOUT_S)
        return r.returncode
    except subprocess.TimeoutExpired:
        return -99


def pdf_pages(p: Path) -> int:
    d = Quartz.PDFDocument.alloc().initWithURL_(NSURL.fileURLWithPath_(str(p)))
    return d.pageCount() if d else 0


def do_pdf(f: Path, parked: Path, rep: dict) -> None:
    st = f.stat()
    if st.st_size < ARGS.pdf_min_kb * 1024:
        rep["pdf_skipped"] += 1
        return
    tmp = f.with_name(f".{f.stem}.csshrink.pdf")
    tmp.unlink(missing_ok=True)
    rc = run_pdf_worker(f, tmp)
    if rc != 0 or not tmp.exists() or tmp.stat().st_size == 0:
        tmp.unlink(missing_ok=True)
        if rc in (-9, 137):
            rep["pdf_oom_skipped"] += 1      # too big to render on this machine
        elif rc == -99:
            rep["pdf_timeout"] += 1
        else:
            rep["pdf_failed"] += 1
            rep["failures"].append(str(f))
        return
    new = tmp.stat().st_size
    gain = (st.st_size - new) * 100.0 / st.st_size
    if gain < ARGS.min_gain:
        # the common case on vector PDFs: filter made it bigger. Keep original.
        tmp.unlink(missing_ok=True)
        rep["pdf_rejected"] += 1
        if gain < 0:
            rep["pdf_inflated"] += 1
        return
    # integrity gate: page count must survive
    if pdf_pages(tmp) != pdf_pages(f):
        tmp.unlink(missing_ok=True)
        rep["pdf_rejected"] += 1
        return
    if ARGS.dry_run:
        tmp.unlink(missing_ok=True)
        rep["pdf_shrunk"] += 1
        rep["pdf_saved"] += st.st_size - new
        return
    copy_mtime(st, tmp)
    retire(f, parked)
    tmp.replace(f)
    rep["pdf_shrunk"] += 1
    rep["pdf_saved"] += st.st_size - new


# ------------------------------------------------------------------ walk ----

def walk(root: Path):
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        d = Path(dirpath)
        if any(p.suffix.lower() in BUNDLE_SUFFIXES for p in (d, *d.parents)):
            dirnames[:] = []
            continue
        dirnames[:] = [x for x in dirnames
                       if x not in SKIP_DIRS
                       and not Path(x).suffix.lower() in BUNDLE_SUFFIXES
                       and not x.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            yield d / name


def main() -> None:
    root = Path(ARGS.folder).expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"not a folder: {root}")

    parked = root / "_cleanup" / "shrunk-originals"
    rep = {
        "generated_at": now_iso(), "root": str(root),
        "max_mb": ARGS.max_mb, "min_gain_pct": ARGS.min_gain,
        "pdf_filter": ARGS.pdf_filter, "dry_run": ARGS.dry_run,
        "img_shrunk": 0, "img_skipped": 0, "img_failed": 0, "img_saved": 0,
        "pdf_shrunk": 0, "pdf_skipped": 0, "pdf_failed": 0, "pdf_saved": 0,
        "pdf_rejected": 0, "pdf_inflated": 0, "pdf_oom_skipped": 0, "pdf_timeout": 0,
        "dataless_skipped": 0, "failures": [],
    }
    cap = int(ARGS.max_mb * 1024 * 1024)

    log(f"cold-storage-shrinker  root={root}")
    log(f"  images <= {ARGS.max_mb} MB [PIL={HAVE_PIL} sips={HAVE_SIPS}] | "
        f"pdfs via Quartz={HAVE_QUARTZ}, keep only if >= {ARGS.min_gain}% smaller")
    if ARGS.dry_run:
        log("  DRY RUN - nothing will be modified")

    t0 = time.time()
    n = 0
    for f in walk(root):
        ext = f.suffix.lower()
        want_img = ext in IMG_EXT and not ARGS.pdfs_only
        want_pdf = ext in PDF_EXT and not ARGS.images_only
        if not (want_img or want_pdf):
            continue
        try:
            if is_dataless(f):
                rep["dataless_skipped"] += 1
                continue
        except OSError:
            continue
        n += 1
        if n % 200 == 0:
            log(f"  ...{n} files, saved so far "
                f"{(rep['img_saved']+rep['pdf_saved'])/1048576:.0f} MB")
        try:
            if want_img:
                do_image(f, cap, parked, rep)
            elif want_pdf and HAVE_QUARTZ:
                do_pdf(f, parked, rep)
        except Exception as e:
            rep["failures"].append(f"{f}: {e}")

    rep["elapsed_s"] = round(time.time() - t0, 1)
    rep["total_saved_mb"] = round((rep["img_saved"] + rep["pdf_saved"]) / 1048576, 1)
    rep["failures"] = rep["failures"][:200]

    out = root / "cold_storage_shrink_report.json"
    if not ARGS.dry_run:
        out.write_text(json.dumps(rep, indent=2))

    log("")
    log(f"  images  shrunk={rep['img_shrunk']} skipped={rep['img_skipped']} "
        f"failed={rep['img_failed']}  saved={rep['img_saved']/1048576:.0f} MB")
    log(f"  pdfs    shrunk={rep['pdf_shrunk']} rejected={rep['pdf_rejected']} "
        f"(inflated={rep['pdf_inflated']}) failed={rep['pdf_failed']} "
        f"too-big={rep['pdf_oom_skipped']} timeout={rep['pdf_timeout']}  "
        f"saved={rep['pdf_saved']/1048576:.0f} MB")
    if rep["dataless_skipped"]:
        log(f"  skipped {rep['dataless_skipped']} iCloud files not downloaded locally")
    log(f"  TOTAL SAVED {rep['total_saved_mb']} MB in {rep['elapsed_s']}s")
    if not ARGS.dry_run:
        log(f"  report: {out}")
        log(f"  originals: Trash" + ("" if TRASH else f" / {parked}"))


def parse_args():
    p = argparse.ArgumentParser(description="Shrink images and PDFs in a folder tree.")
    p.add_argument("folder", nargs="?", default=str(ICLOUD),
                   help="folder to walk (default: iCloud Drive Documents)")
    p.add_argument("--max-mb", type=float, default=1.5)
    p.add_argument("--min-gain", type=float, default=5.0,
                   help="percent a PDF must shrink before the result is kept")
    p.add_argument("--pdf-min-kb", type=int, default=300,
                   help="ignore PDFs smaller than this")
    p.add_argument("--pdf-filter", default="/System/Library/Filters/Reduce File Size.qfilter")
    p.add_argument("--images-only", action="store_true")
    p.add_argument("--pdfs-only", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--quiet", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    if "--worker-pdf" in sys.argv:
        i = sys.argv.index("--worker-pdf")
        src, dst = Path(sys.argv[i + 1]), Path(sys.argv[i + 2])
        filt = "/System/Library/Filters/Reduce File Size.qfilter"
        if "--pdf-filter" in sys.argv:
            filt = sys.argv[sys.argv.index("--pdf-filter") + 1]
        try:
            sys.exit(0 if quartz_shrink(src, dst, filt) else 1)
        except Exception:
            sys.exit(1)
    ARGS = parse_args()
    main()
