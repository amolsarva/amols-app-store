import json
import sqlite3
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from imessage_campaigns import Archive, MessageDatabase, apple_time, attributed_text, from_apple_time, send_message


class CampaignTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmp.name) / "chat.db"
        db = sqlite3.connect(self.db_path)
        db.executescript("""
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, date INTEGER, is_from_me INTEGER, attributedBody BLOB);
        INSERT INTO handle VALUES (1, '+15550001', 'iMessage'), (2, '+15550002', 'SMS');
        INSERT INTO chat_handle_join VALUES (10,1),(20,1),(20,2);
        """)
        now = apple_time(datetime.now())
        db.executemany("INSERT INTO message VALUES (?,?,?,?,?)", [
            (1, "We discussed peculiar fireworks", now-3, 0, None),
            (2, "peculiar again", now-2, 1, None),
            (3, "group peculiar", now-1, 0, None),
            (4, "reply", now+2_000_000_000, 0, None),
            (5, None, now-4, 0, b"binary-prefix Mallorca rich text suffix"),
        ])
        db.executemany("INSERT INTO chat_message_join VALUES (?,?)", [(10,1),(10,2),(20,3),(10,4),(10,5)])
        db.commit(); db.close()

    def tearDown(self): self.tmp.cleanup()

    def test_search_deduplicates_and_excludes_group_chats(self):
        rows = MessageDatabase(self.db_path).search("peculiar", 10)
        self.assertEqual([r.handle for r in rows], ["+15550001"])
        self.assertEqual(rows[0].mentions, 2)

    def test_search_with_no_matches_is_empty(self):
        self.assertEqual(MessageDatabase(self.db_path).search("definitely absent", 10), [])

    def test_search_finds_modern_attributed_body_messages(self):
        rows = MessageDatabase(self.db_path).search("mallorca", 10)
        self.assertEqual([r.handle for r in rows], ["+15550001"])
        self.assertEqual(rows[0].snippet, "binary-prefix Mallorca rich text suffix")

    def test_attributed_text_extracts_matching_printable_run(self):
        blob = b"metadata\x00NSString\x01\x01\x00Dinner in Mallorca next week?\x00NSDictionary"
        self.assertEqual(attributed_text(blob, "mallorca"), "Dinner in Mallorca next week?")

    def test_reply_after(self):
        yes, text, _ = MessageDatabase(self.db_path).reply_after("+15550001", datetime.now())
        self.assertTrue(yes); self.assertEqual(text, "reply")

    def test_archive_round_trip(self):
        archive = Archive(Path(self.tmp.name) / "archive")
        archive.save({"created_at":"2026-08-07T10:00:00", "recipients":[]})
        self.assertEqual(len(archive.list()), 1)

    def test_apple_time_round_trip(self):
        now = datetime.now().replace(microsecond=0)
        self.assertEqual(from_apple_time(apple_time(now)), now)

    @patch("imessage_campaigns.subprocess.run")
    def test_send_script_uses_non_reserved_participant_variable(self, run):
        run.return_value.returncode = 0
        run.return_value.stderr = ""
        ok, error = send_message("+15550001", "hello")
        self.assertTrue(ok)
        self.assertEqual(error, "")
        command = run.call_args.args[0]
        self.assertIn("set targetParticipant to participant recipientHandle of targetAccount", command[2])
        self.assertNotIn("set buddy to", command[2])
        self.assertEqual(run.call_args.kwargs["timeout"], 30)

    @patch("imessage_campaigns.subprocess.run")
    def test_send_timeout_becomes_a_recipient_failure(self, run):
        import subprocess
        run.side_effect = subprocess.TimeoutExpired("osascript", 30)
        self.assertEqual(send_message("+15550001", "hello"),
                         (False, "Messages did not answer AppleScript within 30 seconds"))


if __name__ == "__main__": unittest.main()
