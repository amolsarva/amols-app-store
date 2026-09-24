# 🎙️ VOICEMEMOCLEANER

**Get every Voice Memo out: original audio, a compressed copy, and a catalog of what, when and where.**

- Exports a full-quality copy of every recording plus a compressed MP3 into a folder you choose.
- Reads each memo's title, date, duration and (when present) GPS location, and writes a JSON sidecar
  per file plus one CSV/JSONL catalog, so you can analyze everything without opening each file.
- **Read-only:** never modifies or deletes anything in Voice Memos. Dry-run mode shows every action first.
- Incremental: re-runs skip memos already exported, so refreshing after recording more is fast.

```bash
bash run.sh          # or: bash VOICEMEMOCLEANER.sh
```

Needs Full Disk Access for Terminal (Voice Memos keeps its library in a protected folder) and
`ffmpeg` for the compressed copies (`brew install ffmpeg`). `rename_exports.sh` tidies exported
filenames. macOS 12 or later.
