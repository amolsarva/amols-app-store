# Google Photos Space Rescue HQ

One script for the whole job of getting a Google Photos library out of Takeout
and back into shape.

```
bash ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/root/mac-scripts/rescue-hq/rescue.sh
```

Or launch it from Mac Scripts (🛟 card).

## Menu

| | |
|---|---|
| **1** Merge Takeout zips | `takeout-*.zip` → one `ORGANIZED/` tree. One zip at a time, verified, resumable, can Trash each zip as it goes. |
| **2** Sort photos & videos | → `PHOTOS/` (flat, drag-uploadable) and `VIDEOS/<year>/` (flat, stitchable). |
| **3** Repair a sorted tree | Fixes wrong extensions and clears exiftool `_original` backups. |
| **4** Everything | Merge → sort → repair, back to back. |
| **5** Join videos by year | One video per year. Conforms mixed formats first. Needs ffmpeg. |
| **6** YouTube-ready | Splits anything over YouTube's ~12h limit. Needs ffmpeg. |
| **7** Audit | Read-only status report. |
| **8** Stitch (stream-copy) | Fast, lossless, but only if every clip already shares a format. |
| **d** | Re-check dependencies |

Every stage dry-runs first. **Nothing is ever deleted** — excluded files go to
`_EXCLUDED/`, sorted by reason.

## Dependencies

Checked at startup. `unzip`, `ditto`, `osascript`, `python3` ship with macOS.
`exiftool` is optional (used for dates) and the script offers to install it via
Homebrew, installing Homebrew first if needed.

## What it knows about Takeout

- **Live Photos** are found by Apple's `com.apple.quicktime.live-photo` marker,
  not by filename. Takeout splits the still and its motion clip across
  different zips, so filename pairing finds almost none. On a real archive:
  filename matching found 59, the marker found 6,436 — **51 GB**.
- **Extensions lie.** Takeout ships JPEGs named `.PNG` and `.HEIC`. Every file
  is identified by its magic bytes and renamed to the truth. exiftool refuses
  to write to a mismatched container, so this is not cosmetic.
- **Missing extensions** are restored the same way — that recovered 153
  QuickTime videos on one archive.
- **Duplicates** collapse `IMG_1(1).PNG` onto `IMG_1.PNG`, keeping the cleanest
  name and preferring the `Photos from YYYY` copy over an album copy.
- **Sidecars.** Google does not read `.json` on re-upload; it reads EXIF. So
  dates are baked into the files, then the sidecars are set aside.

## exiftool gotcha

Options placed *before* `-@ argfile` apply only to the first `-execute` batch.
That silently drops `-overwrite_original` and `-wm cg`, which makes exiftool
back up every file it touches and overwrite real camera dates. This script uses
`-common_args` after the argfile so the options apply to every batch:

```
exiftool -@ FILE.args -common_args -q -m -wm cg -overwrite_original
```

## Joining videos by year (stage 5)

A plain "just join them" is impossible on a real phone library. Measured on one
year of an actual export: **253 distinct formats across 705 clips**, only 10%
matching the most common one. Mixed h264/hevc, portrait and landscape,
30/29.97/60/240fps, stereo/mono/silent. `-c copy` concat requires all of those
to match, which is why naive attempts produce a file that plays the first clip
then garbles.

So stage 5 conforms every clip to one target (1920x1080 @30, stereo) — scaled
and **padded, never cropped**, so portrait clips get pillarbox bars — then
stream-copies the uniform pieces together. Silent clips get a real silent audio
track, without which the concat desyncs. Hardware encoding via
`h264_videotoolbox` when available.

**Originals are never deleted by this stage.** Already-joined years are skipped
on re-run.

It also defaults to **camera footage only** (`IMG_*`, `MVI_*`, `DSC*`, `PXL_*`...).
A Google Photos export is usually full of screen recordings (`RPReplay_*`), app
exports (TocaLife, Vont, Beat.ly) and social downloads — in one real archive
2021 was 539 of 705 clips non-camera, which would have made a "year video"
that was 76% screen recordings.

## Stitching (stage 8)

Stages 5-7 are ported verbatim from `media_pipeline.sh` (Jul 2026), which this
script replaces. The stitch is deliberately two-pass: each clip's audio is
normalized in its **own isolated ffmpeg process** before a stream-copy concat.
A single continuous decode pass over heterogeneous AAC configs desyncs the
decoder at a clip boundary and silently corrupts audio from that point on, even
though every clip is fine individually. Video is never re-encoded or resized.

Before deleting any original it verifies the joined file: fully decodes both
streams looking for real decode errors (container duration is not trusted — a
concat can carry bogus duration and still be fine, and the reverse has slipped
through before), then checks the size ratio. **A year that fails any check is
left completely untouched** and retried on the next run. Years already done are
skipped.

Year assignment prefers the `VIDEOS/<year>/` folder name, since our sorter
derived that from the Takeout sidecar — more reliable than the container
metadata Takeout often strips. Falls back to metadata, then file mtime.

## Superseded

Replaces `takeout-merge`, `media-sort`, `media-repair`, `takeout-pipeline`, and
`media-pipeline`. Everything they did lives here; the two Python tools are
embedded in this file, so it has no siblings to keep in sync.
