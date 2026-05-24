# imessage-cleanup

Extract all your iMessage photo and video attachments into organized folders by sender, build per-contact archive folders (DB + transcript + media) for any person in your message history, and optionally free up the iCloud storage your local attachment cache is consuming.

## What it does

1. Reads your `~/Library/Messages/chat.db` (via a safe copy — never touches the original)
2. Resolves sender names using the Messages database + your Mac Contacts
3. Copies all images and videos from `~/Library/Messages/Attachments/` into:
   ```
   ~/Desktop/iMessage_Attachments/
     SenderName/
       2024-03-15_photo.jpg
       2024-03-15_video.mov
   ```
4. **(v2.1)** Lets you browse every conversation handle in a TUI, ranked by recency, with a contact-name column, the raw phone/email, message count, and a snippet of the last message as a prompt for handles you don't have a contact saved for. Pick one or more and the script builds a self-contained archive folder per person:
   ```
   <BACKUP_ROOT>/<slug>/
     chat_<slug>.db        # SQLite copy containing only that person's messages
     messages_<slug>.txt   # readable transcript
     attachments/          # every image/video/file for that person
     attachments_manifest.tsv
     metadata.json         # stats, date range, handle list, export time
     .export_status        # refresh memory for future runs
   ```
   **(v2.2)** Per-contact exports live OUTSIDE the script's folder, in a backup root you choose. Default: `~/Documents/root/imessage-backups`. The choice is remembered across runs in `~/.config/imessage_cleanup/config`. When you enter menu `[8]` you'll get a small navigator with options to: use the remembered location, use the default, use Documents or Desktop, type a custom absolute path, browse subfolders, or create a new subfolder.
   **(v2.5)** If the backup root already contains per-contact exports, menu `[8]` lists those previous people first and asks whether to refresh all or selected ones before you browse the full roster.
   **(v2.6)** Manually grouped identities are supported with `export_format=grouped_contact_v1` in `.export_status`. A grouped folder stores multiple handle ROWIDs in one archive and future refreshes update that same folder instead of splitting the person back into separate phone/email exports.
   **(v2.7)** The backup root now has a state store at `.archive_state/`. It keeps `export_history.jsonl` and `contact_aliases.json`, and asks whether to update existing archive folders in place.
   **(v2.7.1)** Archive repo folders with `messages_master.jsonl` get a dated run-log file named `YYYY-MM-DD to YYYY-MM-DD.TXT`; the script renames that file as the archive's message date range changes.
5. Optionally deletes local attachment copies so iCloud reclaims the space

## Usage

```bash
sudo bash imessage_cleanup.sh
```

(`sudo` is required to read the Messages database.)

An interactive menu lets you configure everything before anything is touched:
- Dry run mode (preview all actions without making changes)
- Filter by sender name
- Skip videos, images, or other file types
- Set minimum file size filter
- Enable/disable deletion after copy
- **Browse contacts & export per-person archive** (menu item `[8]`)

### Browsing contacts (menu `[8]`)

When you press `[8]` the script first asks where you want exports written. The default is `~/Documents/root/imessage-backups`, but you can pick any folder (or create a new one) via the built-in navigator. Your choice is saved to `~/.config/imessage_cleanup/config` so next time you'll just confirm.

If that backup root already contains prior per-contact exports, the script reads each contact folder's `.export_status`, lists those people, and asks whether to update existing archive folders in place. Press Enter or type `r` to refresh the listed archive folders directly. Type `a` to do a full refresh of all listed contacts, type comma-separated numbers to full-refresh selected previous exports, or type `s` to skip and browse normally.

Grouped exports use the same refresh screen. If a folder's `.export_status` has `export_format=grouped_contact_v1`, the script refreshes the stored combined `handle_rowids` into that exact folder. This is for one real person who appears as several phone/email handles that Contacts did not merge automatically.

When you select multiple roster rows manually, the script asks whether those handles should be combined into one named person. If you answer yes and enter a name, it writes one grouped archive folder, records the grouping in `.archive_state/contact_aliases.json`, and future refreshes keep the handles together.

The state store is append-only for history:

```
<BACKUP_ROOT>/.archive_state/
  contact_aliases.json
  export_history.jsonl
```

Each completed per-contact export appends a JSON line with the contact name, handles, handle ROWIDs, output folder, export mode, message count, and last-message cursor. Any archive repo folder under the backup root that contains `messages_master.jsonl` also gets a readable dated run log, for example `2026-01-12 to 2026-05-19.TXT`.

The roster screen then lists every handle that has at least one message, sorted by most-recent activity. Each row shows:

| # | Contact | Handle | Msgs | Last message (preview) |
|---|---------|--------|------|------------------------|

If the Mac Contacts database resolves a name for the handle, you'll see that name. If not, the row shows `(no contact)` and you can use the **last-message preview** plus the raw phone/email to remember who it is.

The roster is **sorted by total message count descending**, so your most-active people are at the top. Up to **100 rows per page**.

**Linked-handle merge.** A single person who's reached you from multiple handles — different phone numbers, or both iMessage and SMS for the same number — shows up as **one merged row**. The merge keys are:

1. AddressBook display name (if Contacts resolved one)
2. Normalized phone number (last 10 digits), for handles without a contact
3. Lower-cased email address, for email handles without a contact

The handle column will display both numbers (`+44... | +32...`) for merged rows, and the per-contact export pulls messages from every linked handle.

At the prompt you can type:

- A number (`3`) — export that one contact
- Comma-separated numbers (`1,4,9`) — export several
- `all` — export every contact (will ask for confirmation)
- `/text` — filter the roster by name / handle / last-message contents
- `n` / `p` — page through the list
- `0` — back to the main menu

## Safety features

- **Dry run by default** — shows every planned action, touches nothing
- Full SQLite backup created before any database writes
- Detailed log written to `~/Desktop/iMessage_Attachments/cleanup.log`
- Incremental runs — tracks what's already been copied via a manifest file, so re-running won't duplicate
- Never modifies the original `chat.db`
- Per-contact export writes to a separate `<BACKUP_ROOT>/<slug>/` tree, so it never collides with the sender-grouped attachment dump
- Per-contact exports are restartable — rerunning the same contact repairs partial folders, rewrites DB/transcript atomically, and skips attachments already recorded in `attachments_manifest.tsv`
- Per-contact exports keep a history ledger and cursor in `.archive_state/`, so updates know where the last archive stopped
- The TUI uses a high-contrast text palette intended to stay readable on both white and black terminal backgrounds

## Requirements

- macOS 12+ (Monterey, Ventura, Sonoma, Sequoia)
- `sudo` access
- bash, `sqlite3`, and `python3` (all pre-installed on macOS)

## Notes

- iCloud Messages must be enabled for the space-reclaim to work — once local files are deleted, iCloud keeps the originals and re-downloads on demand
- The script resolves sender names from your Address Book; unknown numbers appear with `(no contact)` and a last-message snippet to help you identify them
- Use the sender filter to extract just one person's media if that's all you need
- The per-contact export creates a portable SQLite DB you can open with `sqlite3 chat_<slug>.db` or any DB viewer

## Changelog

- **v2.7.1** — Stopped writing timestamped zip files for previous-export updates. The refresh path now updates existing archive folders in place, and archive repo folders with `messages_master.jsonl` maintain a readable `YYYY-MM-DD to YYYY-MM-DD.TXT` run-log file whose name follows the actual message date range.
- **v2.7.0** — Added `.archive_state/export_history.jsonl`, `.archive_state/contact_aliases.json`, previous-export updates, and a prompt to combine multiple selected handles into one named grouped person.
- **v2.6.0** — Added grouped previous-export support. A folder can declare `export_format=grouped_contact_v1` in `.export_status`; menu `[8]` then refreshes the stored combined handle list into that same folder. This keeps manually merged identities, such as one person spread across multiple phones/email, together on future updates.
- **v2.5.0** — Added memory for previous per-contact exports. Menu `[8]` now scans `.export_status` files in the selected backup root, lists previously exported people, and asks whether to refresh all or selected prior exports before opening the full roster. Also changed the TUI to a high-contrast palette that avoids green/cyan/dim text for core menu labels so it remains readable on light and dark terminal themes.
- **v2.4.0** — Robustness/refactor pass for menu `[8]`: removed Bash associative arrays so the roster merge works on macOS Bash 3.2, improved the roster label/UI for merged and unsaved contacts, validates handle ID lists before SQL interpolation, writes DB/transcript files atomically, keeps a per-contact `attachments_manifest.tsv`, leaves `.export_status` and `export_errors.log` in each contact folder, and lets reruns resume/repair partial exports without duplicating already-copied attachments.
- **v2.3.1** — Hard pre-flight check on `chat.db` at the start of the per-contact flow. If the copied DB is unreadable (almost always because the running Terminal lacks Full Disk Access), the script now prints a loud, specific error with the fix steps instead of returning the confusing "No handles found in chat.db." message.
- **v2.3.0** — Merge linked handles + sort by volume + bigger pages. One person who texts you from two numbers (e.g. iMessage account that links a UK and a Belgian SIM, or a handle that appears once for iMessage and again for SMS) now shows up as a single roster row whose message count is the sum across all linked handles. Per-contact export pulls from every merged handle via `WHERE handle_id IN (...)`. Roster is sorted by message count descending so your most-active people are at the top. Page size raised from 25 to 100.
- **v2.2.4** — Portability + reliability fix: dropped `ROW_NUMBER()` window functions and `.timeout` dot-commands from the roster SQL (some sqlite builds silently ignored them, returning 0 rows on real chat.db files even though the AddressBook prefetch worked). Roster build now uses a simple `GROUP BY` with `COUNT/MAX(date)` and defers the last-message-text preview to lazy on-demand fetches (cached per handle). Roster builds in seconds and previews appear as you page/filter. SQL stderr is now also written to `cleanup.log` so future query failures are visible.
- **v2.2.3** — Bug fix: `xargs: unterminated quote` errors when AddressBook contained names with apostrophes (e.g. `D'Angelo`, `O'Connor`). Replaced `xargs`-based string trim with a pure-bash `_trim()` helper. Also removed the spinner during AddressBook prefetch so error messages surface immediately instead of being interleaved with spinner frames.
- **v2.2.2** — Crash fix: the menu `[8]` handler now runs with `set +e` so a non-zero pipe in the new code path can't terminate the entire script. Replaced a `grep -c .` row-counter (which exits 1 on empty input and tripped `pipefail`) with `wc -l`. Added empty-roster guard.
- **v2.2.1** — Perf fix: roster build replaced a correlated subquery (which scanned the full `message` table once per handle and could hang for many minutes on large mailboxes) with a single CTE using `ROW_NUMBER() OVER (PARTITION BY handle_id)`. AddressBook is prefetched once into in-memory arrays; no more per-handle sqlite calls. Added log lines so progress is visible in `cleanup.log`.
- **v2.2.0** — Per-contact exports now write to a user-chosen backup root (default `~/Documents/root/imessage-backups`) outside the script's folder. Added a small folder navigator in menu `[8]` and a config file at `~/.config/imessage_cleanup/config` that remembers the choice across runs.
- **v2.1.0** — Added per-contact browse / export TUI (menu `[8]`). Per-person folder contains its own SQLite DB, transcript, attachments, and metadata.json. README and the published `scripts.html` card updated to match.
- **v2.0.0** — Initial extractor + iCloud cleanup + verify.

## Maintenance note

When this script changes, also update:

- `mac-scripts/imessage-cleanup/README.md` (this file)
- `mac-scripts/scripts.html` (the `imessage-cleanup` card on the published page)
- The header comment block + `SCRIPT_VERSION` in `imessage_cleanup.sh`
