# iMessage archive (read me first, humans and AIs)

This folder is written every night by **imessage-sync** (`mac-scripts/imessage-sync`).
It holds every iMessage/SMS conversation from the Messages app, and it **never forgets**:
messages deleted from Messages later stay here. Don't edit files by hand; the next run
rewrites them.

## Layout

| Path | What |
|---|---|
| `INDEX.md` | Every conversation, newest activity first, with message counts and folder links. Start here. |
| `conversations/people/<Name>/<YYYY-MM>.md` | One file per person per month. All their phone numbers/emails are merged. |
| `conversations/groups/<Group name> (<id>)/<YYYY-MM>.md` | Group chats. |
| `conversations/services/<code>/…` | Short-code / business texts (banks, 2FA, deliveries). |
| `days/<YYYY>/<YYYY-MM-DD>.md` | Everything said that day, across all conversations. Best for "what happened on …" or "what's new since …". |
| `media/photos/<YYYY>/<YYYY-MM>/…jpg` | Photos, converted to JPEG, max 2048 px. |
| `media/videos/…mp4` | Videos, re-encoded to ≤720p H.264. |
| `media/pdfs/`, `media/audio/` (voice notes → .m4a), `media/documents/`, `media/other/` | Everything else, by type. Safe to move whole year folders to cold storage; the database remembers the old path. |
| `messages.db` | SQLite with everything above plus full-text search. Read-only copy; the live one is on the primary Mac. |
| `_sync/status.html` / `status.json` | Health dashboard: last runs, errors with fixes, media queue. |
| `_sync/config.json` | Settings (primary Mac, media sizes, per-person pipelines). |
| `_sync/logs/` | One log per day, last 30 days. |

In the Markdown, each line is `- **HH:MM Sender:** text`, followed by links to any media.
`(not archived yet)` means the attachment is offloaded to iCloud and is still being retried.

## Querying `messages.db`

```sql
-- full-text search (FTS5), newest first
SELECT t.sent_at, t.conversation, t.sender_name, t.text
FROM messages_fts f JOIN timeline t ON t.id = f.rowid
WHERE messages_fts MATCH 'dinner OR "birthday party"'
ORDER BY t.sent_at DESC LIMIT 50;

-- one conversation in a date range
SELECT sent_at, sender_name, text FROM timeline
WHERE folder = 'people/Jane Doe' AND sent_at >= '2026-09-01' ORDER BY sent_at;

-- media for a message / all videos from a month
SELECT kind, name, archive_path, status FROM attachments WHERE message_guid = ?;
SELECT archive_path FROM attachments WHERE kind='videos' AND archive_path LIKE 'media/videos/2026/2026-09/%';
```

Tables: `conversations` (one row per Messages chat; `folder` groups chats of the same person),
`messages` (`reaction` is set for tapbacks, `edited`/`unsent` flags), `attachments`
(`status`: done / pending / missing = offloaded, retrying / gave_up / skipped),
`timeline` (view: messages joined to conversation names, tapbacks excluded).
Times are local ISO-8601 in `sent_at`; `sent_ns` is Apple's raw nanoseconds since 2001.
