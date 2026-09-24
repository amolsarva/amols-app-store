# 🌙 iMessage Sync

**Every night, your whole iMessage history becomes a tidy folder that people and AIs can read.**

Messages keeps your texts in a private database that no other app can open, and it quietly
offloads old photos to iCloud. iMessage Sync copies everything out every night:

- **Every conversation, forever.** It adds new messages and never deletes old ones, so you can
  clean up Messages (see [imessage-cleanup](../imessage-cleanup/)) without losing the record.
- **Readable by AIs.** One Markdown file per person per month, one file per day across all chats,
  an `INDEX.md`, and a searchable SQLite database. Point Claude, ChatGPT or any agent at the folder.
- **Attachments sorted and shrunk.** Photos → JPEG (≤2048 px), videos → 720p MP4, voice notes → M4A,
  PDFs and documents kept as is, all filed by type and month (`media/photos/2026/2026-09/…`) so you
  can move old years to a drive.
- **Heals itself.** It checks hourly and runs overnight. If the Mac was asleep, it catches up. After
  a failure it backs off and retries (1h, 2h, 4h, 8h). Offloaded attachments are retried for weeks.
  Real problems (like a missing permission) send a notification that says what to do.
- **A dashboard and a doctor.** `status.html` shows every run, stage by stage. `run.sh doctor`
  checks permissions, disk space, the job and the primary Mac, and prints the fix for anything wrong.
- **Hooks for your own projects.** After each run it can rebuild a per-person export and run your
  scripts (for example a website or a story built from one conversation), only when there's something new.

## Install (about 2 minutes)

```bash
bash imessage-sync/run.sh install
```

Then do the one thing only you can do: **System Settings → Privacy & Security → Full Disk Access →
+ → `~/Applications/iMessage Sync.app`**. Check with `bash imessage-sync/run.sh doctor`, then
start the first full run with `bash imessage-sync/run.sh now --media-budget 0`. That run can take
a while if you have years of photos. Nightly runs are time-boxed to 40 minutes of media work.

## Commands

| `run.sh …` | Does |
|---|---|
| `now` | Run immediately (through the nightly job, so it has its permission) and show live output |
| `status` | One-screen summary: last run, errors and fixes, counts, media queue |
| `doctor` | Checks everything and explains fixes |
| `open` | Opens the dashboard |
| `retry-media` | Re-queues attachments that gave up (after you've downloaded them in Messages) |
| `take-over` | Makes this Mac the one that archives (only one Mac should) |
| `install` / `uninstall` | Adds or removes the nightly job |

## Where things go

- Archive (default): `~/Documents/root/imessage-backups/archive/`. Override with `IMESSAGE_SYNC_ARCHIVE`.
  The folder's own `README.md` explains the layout for AIs.
- Live database: `~/Library/Application Support/imessage-sync/archive.db` (local disk, one writer).
  A copy is published to the archive folder as `messages.db` after every run.
- Settings: `archive/_sync/config.json`. Per-person pipelines look like this:

```json
"pipelines": [{
  "name": "partner", "alias_person": "partner",
  "export_dir": "partner_archive", "db_name": "chat_partner.db",
  "commands": [["{python}", "pipeline/run.py", "--stage1", "--skip-compact"],
               ["{python}", "pipeline/run.py", "--stage2"]],
  "timeout_minutes": 60
}]
```

Paths are relative to the archive's parent folder. `{python}` is the Python running the sync.

## Privacy

Nothing leaves your Mac except through your own iCloud Drive, if the archive sits there.
No network calls. Read-only access to Messages: it never changes or deletes anything in the Messages app.

Requirements: macOS 13+, Python 3.9+ (built in with Command Line Tools). ffmpeg is optional (smaller videos).
