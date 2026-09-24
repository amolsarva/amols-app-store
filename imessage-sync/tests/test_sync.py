#!/usr/bin/env python3
"""End-to-end test on a synthetic Messages database (no real data, no Full Disk Access needed).

    python3 imessage-sync/tests/test_sync.py
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SYNC = HERE.parent / "imessage_sync.py"
NS = 1_000_000_000


def make_chat_db(path: Path, attachment: Path):
    c = sqlite3.connect(path)
    c.executescript("""
    CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
    CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT,
                      service_name TEXT, display_name TEXT);
    CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
                         handle_id INTEGER, service TEXT, date INTEGER, is_from_me INTEGER,
                         item_type INTEGER DEFAULT 0, associated_message_guid TEXT,
                         associated_message_type INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0,
                         date_retracted INTEGER DEFAULT 0, thread_originator_guid TEXT);
    CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
    CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, transfer_name TEXT,
                            mime_type TEXT, uti TEXT, total_bytes INTEGER, hide_attachment INTEGER DEFAULT 0);
    CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
    """)
    c.executemany("INSERT INTO handle VALUES (?,?,?)", [(1, "+15551230001", "iMessage"), (2, "friend@example.com", "iMessage"),
                                                        (3, "12345", "SMS")])
    c.executemany("INSERT INTO chat VALUES (?,?,?,?,?,?)", [
        (1, "iMessage;-;+15551230001", 45, "+15551230001", "iMessage", None),
        (2, "iMessage;+;chat1", 43, "chat1", "iMessage", "Book club"),
        (3, "SMS;-;12345", 45, "12345", "SMS", None)])
    c.executemany("INSERT INTO chat_handle_join VALUES (?,?)", [(1, 1), (2, 1), (2, 2), (3, 3)])
    base = 800_000_000 * NS  # 2026-05-08
    msgs = [
        (1, "m1", "Hello there", 1, base, 0, 1),
        (2, "m2", "Hi! Dinner Friday?", 0, base + 60 * NS, 1, 1),
        (3, "m3", "Welcome to book club", 2, base + 3600 * NS, 0, 2),
        (4, "m4", "Your code is 123456", 3, base + 7200 * NS, 0, 3),
        (5, "m5", "", 1, base + 86400 * NS, 0, 1),  # photo only
    ]
    for rowid, guid, text, h, date, me, chat in msgs:
        c.execute("INSERT INTO message(ROWID,guid,text,handle_id,service,date,is_from_me) VALUES (?,?,?,?,?,?,?)",
                  (rowid, guid, text, h, "iMessage", date, me))
        c.execute("INSERT INTO chat_message_join VALUES (?,?)", (chat, rowid))
    c.execute("""INSERT INTO message(ROWID,guid,text,handle_id,service,date,is_from_me,associated_message_guid,
                 associated_message_type) VALUES (6,'m6','Loved “Hello there”',0,'iMessage',?,1,'p:0/m1',2000)""",
              (base + 120 * NS,))
    c.execute("INSERT INTO chat_message_join VALUES (1,6)")
    c.execute("INSERT INTO attachment VALUES (1,'a1',?,'beach.png','image/png','public.png',?,0)",
              (str(attachment), attachment.stat().st_size))
    c.execute("INSERT INTO message_attachment_join VALUES (5,1)")
    c.commit()
    c.close()


def sync(env, *args):
    r = subprocess.run([sys.executable, str(SYNC), *args], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def main():
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        img = t / "beach.png"
        subprocess.run(["sips", "-s", "format", "png", "-z", "3000", "4000",
                        "/System/Library/Desktop Pictures/.thumbnails/Sonoma.heic", "--out", str(img)],
                       capture_output=True)
        if not img.exists():  # any image will do
            subprocess.run(["sips", "-s", "format", "png", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns",
                            "--out", str(img)], capture_output=True)
        make_chat_db(t / "chat.db", img)
        (t / "archive" / "_sync").mkdir(parents=True)
        (t / "archive" / "_sync" / "config.json").write_text(json.dumps({"name_overrides": {"+1 (555) 123-0001": "Pat Example"}}))
        env = dict(os.environ, IMESSAGE_SYNC_CHAT_DB=str(t / "chat.db"), IMESSAGE_SYNC_ARCHIVE=str(t / "archive"),
                   IMESSAGE_SYNC_STATE=str(t / "state"), IMESSAGE_SYNC_ADDRESSBOOK=str(t / "nobook"),
                   IMESSAGE_SYNC_NO_NOTIFY="1")
        out = sync(env, "run", "--force")
        a = t / "archive"
        assert "✓ done" in out, out
        month = a / "conversations/people/Pat Example/2026-05.md"
        assert month.exists(), sorted(str(p) for p in a.rglob("*.md"))
        text = month.read_text()
        assert "Hi! Dinner Friday?" in text and "reacted ❤️" in text and "[photo: beach.png](" in text, text
        assert (a / "conversations/services/12345").exists()
        assert any((a / "conversations/groups").glob("Book club (*)/2026-05.md"))
        photos = list((a / "media/photos").rglob("*.jpg"))
        assert photos, "photo not archived"
        w = subprocess.run(["sips", "-g", "pixelWidth", str(photos[0])], capture_output=True, text=True).stdout
        assert int(w.split()[-1]) <= 2048, w
        db = sqlite3.connect(a / "messages.db")
        hits = db.execute("SELECT t.text FROM messages_fts f JOIN timeline t ON t.id=f.rowid "
                          "WHERE messages_fts MATCH 'dinner'").fetchall()
        assert hits == [("Hi! Dinner Friday?",)], hits
        assert (a / "INDEX.md").exists() and list((a / "days").rglob("*.md"))
        status = json.loads((a / "_sync/status.json").read_text())
        assert status["runs"][-1]["result"] in ("ok", "warning") and "error" not in status["runs"][-1], status["runs"][-1]
        # Incremental: nothing new on the second run; an edit is picked up.
        out = sync(env, "run", "--force")
        assert '"new": 0' in out, out
        c = sqlite3.connect(t / "chat.db")
        c.execute("UPDATE message SET text='Hello there!!', date_edited=date WHERE guid='m1'")
        c.execute("UPDATE message SET date=? WHERE guid='m1'", (int((__import__('time').time() - 978307200) * NS),))
        c.commit()
        out = sync(env, "run", "--force")
        assert '"changed": 1' in out, out
        # Deleting from Messages never deletes from the archive.
        c.execute("DELETE FROM message WHERE guid='m2'")
        c.commit()
        sync(env, "run", "--force")
        assert sqlite3.connect(a / "messages.db").execute("SELECT COUNT(*) FROM messages WHERE guid='m2'").fetchone()[0] == 1
        # Missing Full Disk Access → failed run with a fix, exit 1.
        env2 = dict(env, IMESSAGE_SYNC_CHAT_DB=str(t / "missing.db"))
        r = subprocess.run([sys.executable, str(SYNC), "run", "--force"], env=env2, capture_output=True, text=True)
        assert r.returncode == 1 and "Full Disk Access" in r.stdout, r.stdout
    print("all imessage-sync tests passed")


if __name__ == "__main__":
    main()
