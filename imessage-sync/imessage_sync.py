#!/usr/bin/env python3
"""iMessage Sync: a nightly, never-forgetting archive of every iMessage/SMS
conversation, written in formats people and AIs can read.

What one run does (each step is a "stage" with its own status and retry logic):

  1. snapshot   copy ~/Library/Messages/chat.db (read-only, WAL-safe) to a temp file
  2. contacts   resolve phone numbers / emails to names from Contacts
  3. messages   add new + recently edited messages to the permanent archive database
                (messages are never deleted from the archive, even if you delete them
                from Messages later, which is the point of a backup)
  4. markdown   rewrite only the conversation-months and days that changed
  5. media      copy attachments into media/<kind>/<year>/<month>/, shrinking photos,
                re-encoding videos, converting voice notes. Time-boxed; the rest waits
                for the next run. Missing (iCloud-offloaded) files are retried later.
  6. pipelines  rebuild per-person exports (e.g. a grouped chat db) and run their
                own build scripts, only when that person has new messages
  7. publish    copy the archive database into the shared archive folder and write
                status.json / status.html

Everything is standard-library Python 3.9+. Optional tools: ffmpeg (better video
shrinking; falls back to macOS avconvert), sips/afconvert (built into macOS).

Commands (see `--help`):
  run [--scheduled] [--force] [--no-media] [--media-budget MIN] [--no-pipelines]
  status | doctor | retry-media | take-over | open
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import html
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

VERSION = "1.0"
HOME = Path.home()
TOOL_DIR = Path(__file__).resolve().parent
APPLE_EPOCH = 978307200  # 2001-01-01 in unix seconds
LABEL = "com.amol.imessage-sync"

# ── Locations (all overridable by env for tests / other Macs) ────────────────
CHAT_DB = Path(os.environ.get("IMESSAGE_SYNC_CHAT_DB", HOME / "Library/Messages/chat.db"))
ADDRESSBOOK_DIR = Path(os.environ.get("IMESSAGE_SYNC_ADDRESSBOOK",
                                      HOME / "Library/Application Support/AddressBook"))
STATE_DIR = Path(os.environ.get("IMESSAGE_SYNC_STATE",
                                HOME / "Library/Application Support/imessage-sync"))
DEFAULT_ARCHIVE = HOME / "Documents/root/imessage-backups/archive"
ARCHIVE = Path(os.environ.get("IMESSAGE_SYNC_ARCHIVE", DEFAULT_ARCHIVE))
SYNC_DIR = ARCHIVE / "_sync"
CONFIG_PATH = SYNC_DIR / "config.json"
MASTER_DB = STATE_DIR / "archive.db"          # the one writer; local disk, not iCloud
REQUEST_PATH = STATE_DIR / "request.json"     # run.sh -> launchd job hand-off
HELPER_APP = HOME / "Applications/iMessage Sync.app"

DEFAULT_CONFIG = {
    "primary_host": None,            # set by `install` / `take-over`; other Macs stand by
    "overnight_window": [1, 6],      # scheduled runs happen between 01:00 and 06:00
    "catch_up_after_hours": 26,      # missed the night (asleep)? run at the next chance
    "media": {
        "enabled": True,
        "budget_minutes": 40,        # per run; the rest waits for tomorrow
        "photo_max_px": 2048,
        "photo_quality": 80,
        "video_max_height": 720,
        "video_crf": 28,
        "keep_original_if_smaller": True,
        "max_attempts_missing": 8,   # iCloud-offloaded files: retry for ~2 months
    },
    "markdown": {"enabled": True, "daily_digests": True},
    "notify": {"on_failure": True, "on_success": False},
    "pipelines": [],                 # see README: per-person exports + build commands
    "name_overrides": {},            # "+15551234567": "Name"
}

MEDIA_KINDS = ("photos", "videos", "pdfs", "audio", "documents", "other")
PHOTO_EXT = {"jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "webp", "bmp", "dng"}
VIDEO_EXT = {"mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"}
AUDIO_EXT = {"caf", "m4a", "mp3", "amr", "aac", "wav", "aiff", "opus"}
DOC_EXT = {"doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt",
           "rtf", "csv", "zip", "vcf", "ics", "json", "html", "md", "epub", "usdz"}
SKIP_EXT = {"pluginpayloadattachment"}
PORTABLE_EXT = {"jpg", "jpeg", "png", "gif", "mp4", "m4v", "mov", "m4a", "mp3", "pdf"}
TAPBACKS = {2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂", 2004: "‼️", 2005: "❓",
            2006: "", 2007: "sticker"}


# ── Small helpers ────────────────────────────────────────────────────────────
def now() -> dt.datetime:
    return dt.datetime.now().astimezone()


def iso(t: dt.datetime | None) -> str | None:
    return t.isoformat(timespec="seconds") if t else None


def parse_iso(s: str | None) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(s) if s else None
    except ValueError:
        return None


def apple_to_dt(v: int | None) -> dt.datetime | None:
    if not v:
        return None
    secs = v / 1_000_000_000 if abs(v) > 10_000_000_000 else v
    return dt.datetime.fromtimestamp(secs + APPLE_EPOCH).astimezone()


def dt_to_apple_ns(t: dt.datetime) -> int:
    return int((t.timestamp() - APPLE_EPOCH) * 1_000_000_000)


def host() -> str:
    try:
        out = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
        if out:
            return out
    except Exception:
        pass
    return socket.gethostname().split(".")[0]


def this_machine() -> str:
    return f"{host()}:{HOME.name}"


def slugify(name: str, limit: int = 60) -> str:
    s = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "", name).strip().strip(".")
    s = re.sub(r"\s+", " ", s)
    return (s[:limit].rstrip() or "unnamed")


def file_slug(name: str, limit: int = 40) -> str:
    s = re.sub(r"[^A-Za-z0-9._+-]+", "-", name).strip("-")
    return s[:limit] or "x"


def load_json(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_atomic(p: Path, text: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.tmp{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, p)


def human_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


class Log:
    """Writes to stdout (Backstage / launchd log) and a dated file in _sync/logs."""

    def __init__(self):
        self.lines: list[str] = []
        self.file = None

    def open_file(self):
        try:
            d = SYNC_DIR / "logs"
            d.mkdir(parents=True, exist_ok=True)
            self.file = (d / f"{now():%Y-%m-%d}.log").open("a", encoding="utf-8")
            self.file.write(f"\n==== run {iso(now())} on {this_machine()} ====\n")
            for old in sorted(d.glob("*.log"))[:-30]:
                old.unlink(missing_ok=True)
        except OSError:
            self.file = None

    def __call__(self, msg: str):
        line = f"[{now():%H:%M:%S}] {msg}"
        print(line, flush=True)
        self.lines.append(line)
        if self.file:
            self.file.write(line + "\n")
            self.file.flush()


log = Log()


def load_config() -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    user = load_json(CONFIG_PATH, {})
    for k, v in user.items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict):
            cfg[k].update(v)
        else:
            cfg[k] = v
    return cfg


def save_config(cfg: dict) -> None:
    write_atomic(CONFIG_PATH, json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")


def notify(title: str, text: str) -> None:
    if os.environ.get("IMESSAGE_SYNC_NO_NOTIFY"):
        return
    script = f'display notification {json.dumps(text[:220])} with title {json.dumps(title)}'
    subprocess.run(["osascript", "-e", script], capture_output=True, timeout=10)


# ── Error classification: turns exceptions into a reason + fix + retry policy ─
class StageError(Exception):
    def __init__(self, code: str, message: str, fix: str = "", retry: bool = True):
        super().__init__(message)
        self.code, self.fix, self.retry = code, fix, retry


def classify(exc: BaseException) -> StageError:
    if isinstance(exc, StageError):
        return exc
    text = f"{type(exc).__name__}: {exc}"
    low = text.lower()
    if "authorization denied" in low or "operation not permitted" in low or (
            "unable to open database" in low and "chat.db" in low):
        return StageError(
            "full_disk_access", text,
            "Grant Full Disk Access to “iMessage Sync” (~/Applications/iMessage Sync.app): "
            "System Settings → Privacy & Security → Full Disk Access → + . "
            "Then run: imessage-sync/run.sh doctor", retry=False)
    if "database is locked" in low or "busy" in low:
        return StageError("locked", text, "Messages was writing; will retry automatically.")
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return StageError("disk_full", text, "A disk is full. Free space (local disk or iCloud) "
                          "and run again; nothing was lost.")
    if isinstance(exc, OSError) and exc.errno in (errno.ETIMEDOUT, errno.EDEADLK):
        return StageError("icloud", text, "iCloud Drive was slow or offline; will retry.")
    return StageError("unexpected", text, "Unexpected error; see the log and traceback in "
                      "status.json. Ask an AI to read _sync/status.json and fix it.")


# ── Stage 1: snapshot ────────────────────────────────────────────────────────
def take_snapshot(dest: Path) -> dict:
    if not CHAT_DB.exists():
        # Without Full Disk Access the file is invisible or unreadable.
        raise StageError("full_disk_access", f"cannot see {CHAT_DB}",
                         classify(PermissionError("authorization denied chat.db")).fix, retry=False)
    try:  # a plain read fails fast with EPERM when Full Disk Access is missing
        with open(CHAT_DB, "rb") as fh:
            fh.read(16)
    except PermissionError as e:
        raise classify(PermissionError(f"authorization denied reading chat.db: {e}"))
    last = None
    for attempt in range(1, 5):
        try:
            src = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True, timeout=30)
            dest.unlink(missing_ok=True)
            dst = sqlite3.connect(dest)
            with dst:
                src.backup(dst)
            src.close()
            n = dst.execute("SELECT COUNT(*) FROM message").fetchone()[0]
            dst.close()
            return {"messages_in_messages_app": n, "attempts": attempt}
        except sqlite3.DatabaseError as e:
            last = classify(e)
            if not last.retry:
                raise last
            log(f"  snapshot attempt {attempt} failed ({e}); retrying in {attempt * 10}s")
            time.sleep(attempt * 10)
    # Last resort: raw file copy of db + WAL, then read that.
    try:
        tmpdir = Path(tempfile.mkdtemp(prefix="imsnap", dir=STATE_DIR))
        for suffix in ("", "-wal", "-shm"):
            p = Path(str(CHAT_DB) + suffix)
            if p.exists():
                shutil.copy2(p, tmpdir / ("chat.db" + suffix))
        src = sqlite3.connect(tmpdir / "chat.db")
        dst = sqlite3.connect(dest)
        with dst:
            src.backup(dst)
        src.close()
        n = dst.execute("SELECT COUNT(*) FROM message").fetchone()[0]
        dst.close()
        shutil.rmtree(tmpdir, ignore_errors=True)
        return {"messages_in_messages_app": n, "attempts": 5, "method": "file-copy"}
    except Exception as e:
        raise last or classify(e)


# ── Stage 2: contacts ────────────────────────────────────────────────────────
def phone_key(s: str) -> str | None:
    if not s or "@" in s:
        return None
    d = re.sub(r"\D", "", s)
    if not d:
        return None
    if len(d) == 10:          # bare US number
        d = "1" + d
    return d


def handle_key(s: str) -> str:
    s = (s or "").strip()
    if "@" in s:
        return s.lower()
    return phone_key(s) or s.lower()


def load_contacts(cfg: dict) -> tuple[dict, dict]:
    """Returns ({handle_key: name}, info). Reads every AddressBook source db."""
    names: dict[str, str] = {}
    tail9: dict[str, set] = {}
    dbs = [ADDRESSBOOK_DIR / "AddressBook-v22.abcddb"] + sorted(
        ADDRESSBOOK_DIR.glob("Sources/*/AddressBook-v22.abcddb"))
    readable = 0
    for db in dbs:
        if not db.exists():
            continue
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
            people = {}
            for pk, first, last, org, nick in con.execute(
                    "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD"):
                n = " ".join(x for x in (first, last) if x) or nick or org
                if n:
                    people[pk] = n.strip()
            for owner, num in con.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
                k = phone_key(num or "")
                if k and owner in people:
                    names.setdefault(k, people[owner])
                    tail9.setdefault(k[-9:], set()).add(people[owner])
            for owner, addr in con.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
                if addr and owner in people:
                    names.setdefault(addr.strip().lower(), people[owner])
            con.close()
            readable += 1
        except sqlite3.DatabaseError:
            continue
    # Fallback for numbers stored without country code: unique last-9-digit match.
    for k9, ns in tail9.items():
        if len(ns) == 1:
            names.setdefault("tail9:" + k9, next(iter(ns)))
    for h, n in (cfg.get("name_overrides") or {}).items():
        names[handle_key(h)] = n
    # Grouped identities from the older exporter (several handles, one person).
    aliases = load_json(ARCHIVE.parent / ".archive_state/contact_aliases.json", {})
    for person in (aliases.get("people") or {}).values():
        for h in person.get("handles", []):
            if person.get("display_name"):
                names.setdefault(handle_key(h), person["display_name"])
    return names, {"address_books_read": readable, "names": len(names)}


def resolve_name(handle: str, names: dict) -> str | None:
    k = handle_key(handle)
    if k in names:
        return names[k]
    if k.isdigit() and len(k) >= 9:
        return names.get("tail9:" + k[-9:])
    return None


# ── Archive database schema ──────────────────────────────────────────────────
SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS conversations(
  chat_guid TEXT PRIMARY KEY, chat_identifier TEXT, display_name TEXT, name TEXT,
  kind TEXT, service TEXT, participants TEXT, folder TEXT,
  first_at TEXT, last_at TEXT, message_count INTEGER DEFAULT 0, updated_at TEXT);
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY, guid TEXT UNIQUE NOT NULL, chat_guid TEXT,
  sent_at TEXT, sent_ns INTEGER, is_from_me INTEGER, sender_handle TEXT, sender_name TEXT,
  text TEXT, service TEXT, item_type INTEGER, reply_to_guid TEXT,
  reaction TEXT, reaction_to_guid TEXT, edited INTEGER DEFAULT 0, unsent INTEGER DEFAULT 0,
  attachment_count INTEGER DEFAULT 0, source_rowid INTEGER, first_seen_at TEXT, updated_at TEXT);
CREATE INDEX IF NOT EXISTS messages_chat_time ON messages(chat_guid, sent_ns);
CREATE INDEX IF NOT EXISTS messages_time ON messages(sent_ns);
CREATE TABLE IF NOT EXISTS attachments(
  guid TEXT PRIMARY KEY, message_guid TEXT, chat_guid TEXT, sent_ns INTEGER,
  source_path TEXT, name TEXT, mime TEXT, uti TEXT, bytes INTEGER, kind TEXT,
  status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, next_try_at TEXT,
  last_error TEXT, archive_path TEXT, archive_bytes INTEGER, updated_at TEXT);
CREATE INDEX IF NOT EXISTS attachments_status ON attachments(status, sent_ns);
CREATE INDEX IF NOT EXISTS attachments_message ON attachments(message_guid);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  text, sender_name, content='messages', content_rowid='id');
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, text, sender_name) VALUES (new.id, new.text, new.sender_name);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, text, sender_name)
  VALUES ('delete', old.id, old.text, old.sender_name);
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text, sender_name ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, text, sender_name)
  VALUES ('delete', old.id, old.text, old.sender_name);
  INSERT INTO messages_fts(rowid, text, sender_name) VALUES (new.id, new.text, new.sender_name);
END;
DROP VIEW IF EXISTS timeline;
CREATE VIEW timeline AS
  SELECT m.id, m.sent_at, c.name AS conversation, c.folder, m.sender_name, m.text,
         m.attachment_count, m.reaction, m.edited, m.unsent, m.guid
  FROM messages m LEFT JOIN conversations c ON c.chat_guid = m.chat_guid
  WHERE m.reaction IS NULL;
"""


def open_master() -> sqlite3.Connection:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(MASTER_DB, timeout=60)
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(SCHEMA)
    return con


def meta_get(con, key, default=None):
    r = con.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return r[0] if r else default


def meta_set(con, key, value):
    con.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, str(value)))


# ── Stage 3: messages ────────────────────────────────────────────────────────
def decode_attributed_body(data: bytes | None) -> str:
    """Pull the plain string out of an NSAttributedString typedstream blob."""
    if not data:
        return ""
    try:
        idx = data.find(b"NSString")
        if idx == -1:
            return ""
        rest = data[idx:]
        p = rest.find(b"\x2b")
        if p == -1:
            return ""
        rest = rest[p + 1:]
        ln = rest[0]
        if ln == 0x81:
            ln, start = int.from_bytes(rest[1:3], "little"), 3
        elif ln == 0x82:
            ln, start = int.from_bytes(rest[1:5], "little"), 5
        else:
            start = 1
        return rest[start:start + ln].decode("utf-8", "replace")
    except Exception:
        return ""


def clean_text(s: str) -> str:
    return (s or "").replace("\ufffc", "").replace("\u200b", "").strip()


def columns(con, table) -> set:
    return {r[1] for r in con.execute(f"PRAGMA table_info({table})")}


def conversation_folder(kind: str, name: str, chat_guid: str, handles: list) -> str:
    if kind == "group":
        return f"groups/{slugify(name, 50)} ({hashlib.sha1(chat_guid.encode()).hexdigest()[:6]})"
    if kind == "service":
        return f"services/{slugify(name)}"
    return f"people/{slugify(name)}"


def sync_conversations(snap, con, names) -> dict:
    chat_cols = columns(snap, "chat")
    participants: dict[int, list] = {}
    for chat_id, hid in snap.execute(
            "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id"):
        participants.setdefault(chat_id, []).append(hid)
    moved = 0
    rows = snap.execute(f"""SELECT ROWID, guid, chat_identifier, style,
        {'display_name' if 'display_name' in chat_cols else 'NULL'},
        {'service_name' if 'service_name' in chat_cols else 'NULL'} FROM chat""").fetchall()
    stamp = iso(now())
    for rowid, guid, ident, style, display, service in rows:
        hs = sorted(set(participants.get(rowid, [])))
        pnames = [resolve_name(h, names) or h for h in hs]
        if style == 43 or len(hs) > 1:
            kind = "group"
            name = display or ", ".join(pnames[:4]) + (f" +{len(pnames) - 4}" if len(pnames) > 4 else "")
            name = name or ident or "Group"
        else:
            h = hs[0] if hs else (ident or guid)
            resolved = resolve_name(h, names)
            digits = re.sub(r"\D", "", h)
            kind = "service" if (not resolved and "@" not in h and 0 < len(digits) <= 6) else "person"
            name = resolved or h
        folder = conversation_folder(kind, name, guid, hs)
        old = con.execute("SELECT folder FROM conversations WHERE chat_guid=?", (guid,)).fetchone()
        if old and old[0] and old[0] != folder:
            # Name got resolved/changed: move the folder if nothing else uses it.
            others = con.execute("SELECT COUNT(*) FROM conversations WHERE folder=? AND chat_guid<>?",
                                 (old[0], guid)).fetchone()[0]
            src, dst = ARCHIVE / "conversations" / old[0], ARCHIVE / "conversations" / folder
            if others == 0 and src.exists() and not dst.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                os.replace(src, dst)
            moved += 1
            meta_set(con, "markdown_full_rebuild", "1")
        con.execute("""INSERT INTO conversations(chat_guid, chat_identifier, display_name, name, kind,
                service, participants, folder, updated_at) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(chat_guid) DO UPDATE SET chat_identifier=excluded.chat_identifier,
                display_name=excluded.display_name, name=excluded.name, kind=excluded.kind,
                service=excluded.service, participants=excluded.participants,
                folder=excluded.folder, updated_at=excluded.updated_at""",
                    (guid, ident, display, name, kind, service,
                     json.dumps([{"handle": h, "name": resolve_name(h, names)} for h in hs],
                                ensure_ascii=False), folder, stamp))
    return {"conversations": len(rows), "renamed": moved}


def sync_messages(snap, con, names, lookback_days=10) -> tuple[dict, set]:
    """Upsert new + recently changed messages. Returns (stats, touched (folder, month, day))."""
    mcols = columns(snap, "message")
    opt = lambda c: c if c in mcols else "NULL"  # noqa: E731
    last_rowid = int(meta_get(con, "last_source_rowid", 0))
    max_rowid = snap.execute("SELECT COALESCE(MAX(ROWID),0) FROM message").fetchone()[0]
    if max_rowid < last_rowid:
        log(f"  Messages database looks new/rebuilt (max ROWID {max_rowid} < {last_rowid}); full rescan")
        last_rowid = 0
    since_ns = dt_to_apple_ns(now() - dt.timedelta(days=lookback_days))
    where = "m.ROWID > ? OR m.date > ?"
    params = [last_rowid, since_ns]
    for c in ("date_edited", "date_retracted"):
        if c in mcols:
            where += f" OR m.{c} > ?"
            params.append(since_ns)
    chat_of = {}
    for mid, guid in snap.execute("""SELECT cmj.message_id, c.guid FROM chat_message_join cmj
                                     JOIN chat c ON c.ROWID=cmj.chat_id ORDER BY c.style DESC"""):
        chat_of[mid] = guid  # a 1:1 (style 45) wins over a group because it comes last
    att_count = dict(snap.execute(
        "SELECT message_id, COUNT(*) FROM message_attachment_join GROUP BY message_id").fetchall())
    folders = dict(con.execute("SELECT chat_guid, folder FROM conversations").fetchall())
    sql = f"""SELECT m.ROWID, m.guid, m.text, {opt('attributedBody')}, m.is_from_me, m.date,
                     h.id, m.service, {opt('item_type')}, {opt('thread_originator_guid')},
                     {opt('associated_message_type')}, {opt('associated_message_guid')},
                     {opt('associated_message_emoji')}, {opt('date_edited')}, {opt('date_retracted')}
              FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE {where}"""
    stamp = iso(now())
    touched = set()
    new = changed = 0
    batch = snap.execute(sql, params).fetchall()
    existing = {}
    guids = [r[1] for r in batch]
    for i in range(0, len(guids), 900):
        chunk = guids[i:i + 900]
        for g, t, e, u in con.execute(
                f"SELECT guid, text, edited, unsent FROM messages WHERE guid IN ({','.join('?' * len(chunk))})",
                chunk):
            existing[g] = (t, e, u)
    with con:
        for (rowid, guid, text, body, from_me, date, handle, service, item_type, thread,
             assoc_type, assoc_guid, assoc_emoji, d_edit, d_retract) in batch:
            txt = clean_text(text or decode_attributed_body(body))
            reaction = reaction_to = None
            if assoc_type and 2000 <= assoc_type < 3000:
                reaction = TAPBACKS.get(assoc_type, "") or assoc_emoji or "reacted"
                reaction_to = re.sub(r"^(p:\d+/|bp:)", "", assoc_guid or "")
            elif assoc_type and 3000 <= assoc_type < 4000:
                reaction = "removed reaction"
                reaction_to = re.sub(r"^(p:\d+/|bp:)", "", assoc_guid or "")
            edited = 1 if (d_edit or 0) > 0 else 0
            unsent = 1 if (d_retract or 0) > 0 else 0
            chat_guid = chat_of.get(rowid)
            t = apple_to_dt(date)
            sender_handle = None if from_me else handle
            sender = "Me" if from_me else (resolve_name(handle or "", names) or handle or "unknown")
            prev = existing.get(guid)
            if prev is None:
                new += 1
            elif prev == (txt, edited, unsent):
                continue
            else:
                changed += 1
            con.execute("""INSERT INTO messages(guid, chat_guid, sent_at, sent_ns, is_from_me,
                    sender_handle, sender_name, text, service, item_type, reply_to_guid, reaction,
                    reaction_to_guid, edited, unsent, attachment_count, source_rowid, first_seen_at,
                    updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(guid) DO UPDATE SET text=CASE WHEN excluded.text<>'' THEN excluded.text
                    ELSE messages.text END, edited=excluded.edited, unsent=excluded.unsent,
                    sender_name=excluded.sender_name, chat_guid=COALESCE(excluded.chat_guid, messages.chat_guid),
                    attachment_count=excluded.attachment_count, updated_at=excluded.updated_at""",
                        (guid, chat_guid, iso(t), date, int(bool(from_me)), sender_handle, sender, txt,
                         service, item_type, thread, reaction, reaction_to, edited, unsent,
                         att_count.get(rowid, 0), rowid, stamp, stamp))
            if t:
                touched.add((folders.get(chat_guid, "other/unknown"), f"{t:%Y-%m}", f"{t:%Y-%m-%d}"))
        meta_set(con, "last_source_rowid", max_rowid)
        # Conversation rollups.
        con.execute("""UPDATE conversations SET
            message_count=(SELECT COUNT(*) FROM messages m WHERE m.chat_guid=conversations.chat_guid AND m.reaction IS NULL),
            first_at=(SELECT MIN(sent_at) FROM messages m WHERE m.chat_guid=conversations.chat_guid),
            last_at=(SELECT MAX(sent_at) FROM messages m WHERE m.chat_guid=conversations.chat_guid)""")
    total = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    return {"scanned": len(batch), "new": new, "changed": changed, "archive_total": total}, touched


def sync_attachment_rows(snap, con) -> dict:
    acols = columns(snap, "attachment")
    opt = lambda c: c if c in acols else "NULL"  # noqa: E731
    last = int(meta_get(con, "last_attachment_rowid", 0))
    maxr = snap.execute("SELECT COALESCE(MAX(ROWID),0) FROM attachment").fetchone()[0]
    if maxr < last:
        last = 0
    rows = snap.execute(f"""SELECT a.ROWID, a.guid, a.filename, COALESCE(a.transfer_name, a.filename),
            a.mime_type, {opt('uti')}, a.total_bytes, m.guid, m.date, c.guid, {opt('hide_attachment')}
        FROM attachment a JOIN message_attachment_join maj ON maj.attachment_id=a.ROWID
        JOIN message m ON m.ROWID=maj.message_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id=m.ROWID LEFT JOIN chat c ON c.ROWID=cmj.chat_id
        WHERE a.ROWID > ? GROUP BY a.ROWID""", (last,)).fetchall()
    stamp = iso(now())
    added = 0
    with con:
        for (_rid, guid, path, name, mime, uti, size, mguid, date, cguid, hidden) in rows:
            kind = media_kind(name or path or "", mime or "", uti or "")
            status = "skipped" if (kind is None or hidden) else "pending"
            cur = con.execute("""INSERT OR IGNORE INTO attachments(guid, message_guid, chat_guid, sent_ns,
                    source_path, name, mime, uti, bytes, kind, status, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                              (guid, mguid, cguid, date, path, os.path.basename(name or path or ""),
                               mime, uti, size, kind or "skip", status, stamp))
            added += cur.rowcount
        meta_set(con, "last_attachment_rowid", maxr)
    return {"new_attachments": added}


def media_kind(name: str, mime: str, uti: str) -> str | None:
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext in SKIP_EXT or "pluginpayload" in (uti or "").lower():
        return None
    if mime.startswith("image/") or ext in PHOTO_EXT:
        return "photos"
    if mime.startswith("video/") or ext in VIDEO_EXT:
        return "videos"
    if mime == "application/pdf" or ext == "pdf":
        return "pdfs"
    if mime.startswith("audio/") or ext in AUDIO_EXT:
        return "audio"
    if ext in DOC_EXT or mime.startswith("text/") or "officedocument" in mime:
        return "documents"
    return "other"


# ── Stage 4: markdown ────────────────────────────────────────────────────────
def md_line(m: dict, md_dir: Path, atts: dict, quote: dict) -> list:
    t = parse_iso(m["sent_at"])
    who = m["sender_name"] or "?"
    hhmm = f"{t:%H:%M}" if t else "??:??"
    if m["reaction"]:
        target = quote.get(m["reaction_to_guid"], "")
        target = f" to “{target[:60]}”" if target else ""
        return [f"- {hhmm} {who} reacted {m['reaction']}{target}"]
    text = m["text"] or ""
    if m["unsent"]:
        text = "(unsent)"
    elif m["edited"]:
        text += " _(edited)_"
    extras = []
    for a in atts.get(m["guid"], []):
        label = {"photos": "photo", "videos": "video", "pdfs": "PDF", "audio": "audio",
                 "documents": "file"}.get(a["kind"], "attachment")
        if a["archive_path"]:
            rel = os.path.relpath(ARCHIVE / a["archive_path"], md_dir)
            extras.append(f"[{label}: {a['name']}]({rel.replace(' ', '%20')})")
        elif a["status"] != "skipped":
            extras.append(f"[{label}: {a['name']} (not archived yet)]")
    if not text and not extras:
        return []
    body = text.replace("\n", "\n  ")
    line = f"- **{hhmm} {who}:** {body}"
    if extras:
        line += (" " if text else "") + " ".join(extras)
    return [line]


def fetch_messages(con, where, params):
    con.row_factory = sqlite3.Row
    rows = [dict(r) for r in con.execute(f"""SELECT m.*, c.name AS conv_name, c.folder
        FROM messages m LEFT JOIN conversations c ON c.chat_guid=m.chat_guid
        WHERE {where} ORDER BY m.sent_ns""", params)]
    con.row_factory = None
    return rows


def attachments_for(con, guids) -> dict:
    out: dict[str, list] = {}
    for i in range(0, len(guids), 900):
        chunk = guids[i:i + 900]
        for g, kind, name, path, status in con.execute(
                f"""SELECT message_guid, kind, name, archive_path, status FROM attachments
                    WHERE message_guid IN ({','.join('?' * len(chunk))}) ORDER BY guid""", chunk):
            out.setdefault(g, []).append({"kind": kind, "name": name, "archive_path": path, "status": status})
    return out


def quotes_for(con, rows) -> dict:
    targets = [r["reaction_to_guid"] for r in rows if r["reaction_to_guid"]]
    out = {}
    for i in range(0, len(targets), 900):
        chunk = targets[i:i + 900]
        for g, t in con.execute(f"SELECT guid, text FROM messages WHERE guid IN ({','.join('?' * len(chunk))})", chunk):
            out[g] = (t or "").replace("\n", " ")
    return out


def write_conversation_month(con, folder: str, month: str) -> None:
    start = dt.datetime.strptime(month, "%Y-%m").astimezone()
    end = (start + dt.timedelta(days=32)).replace(day=1)
    rows = fetch_messages(con, "c.folder=? AND m.sent_ns>=? AND m.sent_ns<?",
                          (folder, dt_to_apple_ns(start), dt_to_apple_ns(end)))
    path = ARCHIVE / "conversations" / folder / f"{month}.md"
    if not rows:
        path.unlink(missing_ok=True)
        return
    atts, quote = attachments_for(con, [r["guid"] for r in rows]), quotes_for(con, rows)
    name = rows[0]["conv_name"] or folder.split("/")[-1]
    handles = set()
    for (p,) in con.execute("SELECT participants FROM conversations WHERE folder=?", (folder,)):
        handles.update(x["handle"] for x in json.loads(p or "[]"))
    n = sum(1 for r in rows if not r["reaction"])
    out = [f"# {name} — {start:%B %Y}", "",
           f"_{n} messages · handles: {', '.join(sorted(handles)) or 'n/a'} · "
           f"archived by imessage-sync; times are local_", ""]
    day = None
    for r in rows:
        t = parse_iso(r["sent_at"])
        d = f"{t:%A %Y-%m-%d}" if t else "unknown date"
        if d != day:
            out += ["", f"## {d}", ""]
            day = d
        out += md_line(r, path.parent, atts, quote)
    write_atomic(path, "\n".join(out) + "\n")


def write_day(con, day: str) -> None:
    start = dt.datetime.strptime(day, "%Y-%m-%d").astimezone()
    end = start + dt.timedelta(days=1)
    rows = fetch_messages(con, "m.sent_ns>=? AND m.sent_ns<?", (dt_to_apple_ns(start), dt_to_apple_ns(end)))
    path = ARCHIVE / "days" / day[:4] / f"{day}.md"
    if not rows:
        path.unlink(missing_ok=True)
        return
    atts, quote = attachments_for(con, [r["guid"] for r in rows]), quotes_for(con, rows)
    by_conv: dict[str, list] = {}
    for r in rows:
        by_conv.setdefault(r["folder"] or "other/unknown", []).append(r)
    out = [f"# Messages on {start:%A %B %-d, %Y}", "",
           f"_{sum(1 for r in rows if not r['reaction'])} messages in {len(by_conv)} conversations_", ""]
    for folder, rs in sorted(by_conv.items(), key=lambda kv: -len(kv[1])):
        rel = os.path.relpath(ARCHIVE / "conversations" / folder / f"{day[:7]}.md", path.parent)
        out += [f"## {rs[0]['conv_name'] or folder} ([month]({rel.replace(' ', '%20')}))", ""]
        for r in rs:
            out += md_line(r, path.parent, atts, quote)
        out.append("")
    write_atomic(path, "\n".join(out) + "\n")


def write_index(con) -> None:
    rows = con.execute("""SELECT folder, MAX(name), SUM(message_count), MIN(first_at), MAX(last_at), MAX(kind)
        FROM conversations WHERE message_count>0 GROUP BY folder ORDER BY MAX(last_at) DESC""").fetchall()
    out = ["# iMessage archive — conversation index", "",
           f"_Updated {now():%Y-%m-%d %H:%M} · {len(rows)} conversations · newest first · "
           "see README.md for how this archive is laid out_", "",
           "| Conversation | Kind | Messages | First | Last | Folder |", "|---|---|---:|---|---|---|"]
    for folder, name, n, first, last, kind in rows:
        link = f"conversations/{folder}".replace(" ", "%20")
        out.append(f"| {name.replace('|', '/')} | {kind} | {n} | {(first or '')[:10]} | {(last or '')[:10]} | [{folder}]({link}) |")
    write_atomic(ARCHIVE / "INDEX.md", "\n".join(out) + "\n")


def stage_markdown(con, touched: set, cfg) -> dict:
    full = meta_get(con, "markdown_full_rebuild", "1") == "1"
    if full:
        con.row_factory = None
        touched = set()
        for folder, ns in con.execute(
                "SELECT c.folder, m.sent_ns FROM messages m JOIN conversations c ON c.chat_guid=m.chat_guid"):
            t = apple_to_dt(ns)
            if t:
                touched.add((folder, f"{t:%Y-%m}", f"{t:%Y-%m-%d}"))
    months = sorted({(f, m) for f, m, _ in touched})
    days = sorted({d for _, _, d in touched})
    for f, m in months:
        write_conversation_month(con, f, m)
    if cfg["markdown"].get("daily_digests", True):
        for d in days:
            write_day(con, d)
    write_index(con)
    readme = TOOL_DIR / "ARCHIVE_README.md"
    if readme.exists():
        write_atomic(ARCHIVE / "README.md", readme.read_text(encoding="utf-8"))
    meta_set(con, "markdown_full_rebuild", "0")
    con.commit()
    return {"months_written": len(months), "days_written": len(days) if cfg["markdown"].get("daily_digests") else 0,
            "full_rebuild": full}


# ── Stage 5: media ───────────────────────────────────────────────────────────
def run_tool(cmd, timeout):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"{Path(cmd[0]).name} exit {r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")


def convert_media(kind: str, src: Path, dest_stem: Path, mcfg: dict) -> Path:
    ext = src.suffix.lower().lstrip(".")
    tmpdir = Path(tempfile.mkdtemp(prefix="imsync-media-", dir=STATE_DIR))
    try:
        if kind == "photos" and ext not in ("gif",):
            out = tmpdir / "out.jpg"
            run_tool(["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(mcfg["photo_quality"]),
                      "-Z", str(mcfg["photo_max_px"]), str(src), "--out", str(out)], 120)
            final_ext = "jpg"
        elif kind == "videos":
            out = tmpdir / "out.mp4"
            ffmpeg = shutil.which("ffmpeg") or next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg")
                                                     if Path(p).exists()), None)
            h = int(mcfg["video_max_height"])
            if ffmpeg:
                run_tool([ffmpeg, "-nostdin", "-y", "-loglevel", "error", "-i", str(src),
                          "-vf", f"scale=-2:'min({h},ih)'", "-c:v", "libx264", "-preset", "veryfast",
                          "-crf", str(mcfg["video_crf"]), "-c:a", "aac", "-b:a", "96k",
                          "-movflags", "+faststart", str(out)], 1800)
            else:
                run_tool(["avconvert", "--preset", "Preset1280x720" if h >= 720 else "Preset960x540",
                          "--source", str(src), "--output", str(out)], 1800)
            final_ext = "mp4"
        elif kind == "audio" and ext == "caf":
            out = tmpdir / "out.m4a"
            run_tool(["afconvert", "-f", "m4af", "-d", "aac", str(src), str(out)], 300)
            final_ext = "m4a"
        else:
            out, final_ext = src, ext or "bin"
        # Keep the original only when it is already in a format every tool (and AI) can open.
        if (mcfg.get("keep_original_if_smaller", True) and out != src and ext in PORTABLE_EXT
                and out.stat().st_size >= src.stat().st_size):
            out, final_ext = src, ext
        dest = dest_stem.with_name(dest_stem.name + "." + final_ext)
        n = 2
        while dest.exists():
            dest = dest_stem.with_name(f"{dest_stem.name}-{n}.{final_ext}")
            n += 1
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp_dest = dest.with_name("." + dest.name + ".part")
        shutil.copyfile(out, tmp_dest)
        os.replace(tmp_dest, dest)
        return dest
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def backoff_hours(attempts: int) -> float:
    return min(24 * 7, 12 * (2 ** max(0, attempts - 1)))  # 12h, 1d, 2d, 4d, 7d …


def stage_media(con, cfg, budget_minutes: float) -> tuple[dict, set]:
    mcfg = cfg["media"]
    deadline = time.monotonic() + budget_minutes * 60 if budget_minutes > 0 else float("inf")
    stamp_now = now()
    done = missing = failed = gave_up = 0
    saved = 0
    touched = set()
    rows = con.execute("""SELECT a.guid, a.source_path, a.name, a.kind, a.sent_ns, a.attempts, a.bytes,
                                 c.folder, c.name FROM attachments a
        LEFT JOIN conversations c ON c.chat_guid=a.chat_guid
        WHERE a.status IN ('pending','missing','failed') AND (a.next_try_at IS NULL OR a.next_try_at <= ?)
        ORDER BY a.sent_ns DESC""", (iso(stamp_now),)).fetchall()
    for guid, spath, name, kind, sent_ns, attempts, size, folder, conv_name in rows:
        if time.monotonic() > deadline:
            break
        src = Path(os.path.expanduser(spath or ""))
        t = apple_to_dt(sent_ns) or stamp_now
        attempts = (attempts or 0) + 1
        if not spath or not src.exists():
            # Offloaded to iCloud (Messages in iCloud) or deleted. Ask Messages' iCloud to fetch
            # nothing here: there is no public API. Retry later with growing gaps.
            limit = int(mcfg.get("max_attempts_missing", 8))
            status = "gave_up" if attempts >= limit else "missing"
            gave_up += status == "gave_up"
            missing += status == "missing"
            con.execute("""UPDATE attachments SET status=?, attempts=?, next_try_at=?, last_error=?, updated_at=?
                           WHERE guid=?""", (status, attempts, iso(stamp_now + dt.timedelta(hours=backoff_hours(attempts))),
                                             "file not on this Mac (offloaded to iCloud or deleted)", iso(stamp_now), guid))
            continue
        who = file_slug((conv_name or "unknown").split(",")[0], 24)
        stem = file_slug(Path(name or src.name).stem, 40)
        dest_stem = ARCHIVE / "media" / kind / f"{t:%Y}" / f"{t:%Y-%m}" / f"{t:%Y-%m-%d_%H%M%S}_{who}_{stem}"
        try:
            dest = convert_media(kind, src, dest_stem, mcfg)
            rel = str(dest.relative_to(ARCHIVE))
            nbytes = dest.stat().st_size
            saved += max(0, (size or src.stat().st_size) - nbytes)
            con.execute("""UPDATE attachments SET status='done', attempts=?, archive_path=?, archive_bytes=?,
                           last_error=NULL, next_try_at=NULL, updated_at=? WHERE guid=?""",
                        (attempts, rel, nbytes, iso(now()), guid))
            done += 1
            touched.add((folder or "other/unknown", f"{t:%Y-%m}", f"{t:%Y-%m-%d}"))
        except OSError as e:
            if e.errno == errno.ENOSPC:
                raise
            failed += 1
            con.execute("""UPDATE attachments SET status=?, attempts=?, next_try_at=?, last_error=?, updated_at=?
                           WHERE guid=?""", ("gave_up" if attempts >= 3 else "failed", attempts,
                                             iso(stamp_now + dt.timedelta(hours=6 * attempts)), str(e)[:300], iso(now()), guid))
        except (RuntimeError, subprocess.TimeoutExpired) as e:
            failed += 1
            # After two failed conversions, keep the untouched original instead.
            if attempts >= 2:
                try:
                    dest = convert_media("other", src, dest_stem, mcfg)
                    con.execute("""UPDATE attachments SET status='done', attempts=?, archive_path=?, archive_bytes=?,
                                   last_error=?, updated_at=? WHERE guid=?""",
                                (attempts, str(dest.relative_to(ARCHIVE)), dest.stat().st_size,
                                 f"kept original; conversion failed: {e}"[:300], iso(now()), guid))
                    touched.add((folder or "other/unknown", f"{t:%Y-%m}", f"{t:%Y-%m-%d}"))
                    continue
                except OSError:
                    pass
            con.execute("""UPDATE attachments SET status='failed', attempts=?, next_try_at=?, last_error=?, updated_at=?
                           WHERE guid=?""", (attempts, iso(stamp_now + dt.timedelta(hours=6)), str(e)[:300], iso(now()), guid))
        if (done + failed) % 50 == 0:
            con.commit()
    con.commit()
    left = con.execute("SELECT COUNT(*) FROM attachments WHERE status IN ('pending','failed')").fetchone()[0]
    return ({"archived": done, "missing_retry_later": missing, "failed": failed, "gave_up": gave_up,
             "space_saved": human_bytes(saved), "still_queued": left,
             "budget_hit": time.monotonic() > deadline}, touched)


# ── Stage 6: per-person pipelines ────────────────────────────────────────────
def build_grouped_db(snap_path: Path, handles: list, out_db: Path) -> dict:
    """Same shape as imessage_cleanup.sh's chat_<slug>.db, but built from the snapshot.
    Handle ROWIDs differ between Macs, so resolve them by handle string."""
    s = sqlite3.connect(snap_path)
    wanted = {handle_key(h) for h in handles}
    ids = [r for r, hid in s.execute("SELECT ROWID, id FROM handle") if handle_key(hid) in wanted]
    s.close()
    if not ids:
        raise StageError("pipeline", f"none of the handles {handles} exist in Messages", retry=False)
    idl = ",".join(str(i) for i in ids)
    tmp = out_db.with_name(f".{out_db.name}.tmp{os.getpid()}")
    tmp.unlink(missing_ok=True)
    c = sqlite3.connect(tmp)
    c.executescript(f"""
        ATTACH DATABASE '{str(snap_path).replace("'", "''")}' AS src;
        CREATE TABLE handle AS SELECT * FROM src.handle WHERE ROWID IN ({idl});
        CREATE TABLE message AS SELECT * FROM src.message WHERE handle_id IN ({idl}) OR ROWID IN
          (SELECT message_id FROM src.chat_message_join WHERE chat_id IN
            (SELECT chat_id FROM src.chat_handle_join WHERE handle_id IN ({idl})));
        CREATE TABLE chat AS SELECT * FROM src.chat WHERE ROWID IN
          (SELECT chat_id FROM src.chat_handle_join WHERE handle_id IN ({idl}));
        CREATE TABLE chat_handle_join AS SELECT * FROM src.chat_handle_join WHERE handle_id IN ({idl});
        CREATE TABLE chat_message_join AS SELECT * FROM src.chat_message_join WHERE message_id IN (SELECT ROWID FROM message);
        CREATE TABLE message_attachment_join AS SELECT * FROM src.message_attachment_join WHERE message_id IN (SELECT ROWID FROM message);
        CREATE TABLE attachment AS SELECT * FROM src.attachment WHERE ROWID IN (SELECT attachment_id FROM message_attachment_join);
        DETACH DATABASE src;""")
    n, last = c.execute("SELECT COUNT(*), MAX(date) FROM message").fetchone()
    ok = c.execute("PRAGMA integrity_check").fetchone()[0]
    c.close()
    if ok != "ok" or not n:
        tmp.unlink(missing_ok=True)
        raise StageError("pipeline", f"grouped db check failed (integrity={ok}, messages={n})")
    os.replace(tmp, out_db)
    return {"messages": n, "last_ns": last, "handle_rowids": idl}


def stage_pipelines(con, cfg, snap_path: Path, only_if_new=True) -> dict:
    results = {}
    aliases = load_json(ARCHIVE.parent / ".archive_state/contact_aliases.json", {}).get("people", {})
    for p in cfg.get("pipelines", []):
        name = p.get("name", "pipeline")
        if not p.get("enabled", True):
            results[name] = "disabled"
            continue
        handles = p.get("handles") or aliases.get(p.get("alias_person", ""), {}).get("handles", [])
        base = ARCHIVE.parent
        out_dir = (base / p["export_dir"]).resolve()
        out_db = out_dir / p.get("db_name", f"chat_{out_dir.name}.db")
        keys = {handle_key(h) for h in handles}
        last_seen = con.execute(f"""SELECT MAX(sent_ns) FROM messages m WHERE sender_handle IN
            (SELECT value FROM json_each(?)) OR chat_guid IN (SELECT chat_guid FROM conversations c,
            json_each(c.participants) j WHERE json_extract(j.value,'$.handle') IN (SELECT value FROM json_each(?)))""",
                                (json.dumps(handles), json.dumps(handles))).fetchone()[0] or 0
        mark = f"pipeline_last_ns:{name}"
        if only_if_new and str(last_seen) == meta_get(con, mark) and out_db.exists():
            results[name] = "no new messages; skipped"
            log(f"  {name}: no new messages since last build; skipped")
            continue
        log(f"  {name}: building {out_db.name} for {len(handles)} handle(s)")
        info = build_grouped_db(snap_path, handles, out_db)
        meta_file = out_dir / "metadata.json"
        if meta_file.exists():
            m = load_json(meta_file, {})
            lt = apple_to_dt(info["last_ns"])
            m.update({"message_count": info["messages"], "handle_rowids": info["handle_rowids"],
                      "last_message": f"{lt:%Y-%m-%d %H:%M:%S}" if lt else m.get("last_message"),
                      "last_message_ns": info["last_ns"], "exported_at": f"{now():%Y-%m-%d %H:%M:%S}",
                      "source_db": str(CHAT_DB), "script_version": f"imessage-sync {VERSION}", "status": "complete"})
            write_atomic(meta_file, json.dumps(m, indent=2, ensure_ascii=False) + "\n")
        env = dict(os.environ, IMESSAGE_SYNC_HEADLESS="1", PYTHONUNBUFFERED="1")
        for cmd in p.get("commands", []):
            argv = [sys.executable if a == "{python}" else a for a in cmd]
            log(f"  {name}: $ {' '.join(argv)}")
            r = subprocess.run(argv, cwd=base, env=env, capture_output=True, text=True,
                               timeout=int(p.get("timeout_minutes", 60)) * 60)
            for line in (r.stdout + r.stderr).strip().splitlines()[-15:]:
                log(f"      {line}")
            if r.returncode != 0:
                raise StageError("pipeline", f"{name}: {' '.join(cmd[-2:])} exited {r.returncode}",
                                 f"See the log. Re-run with: run.sh now (it also retries automatically).")
        meta_set(con, mark, last_seen)
        con.commit()
        results[name] = f"rebuilt ({info['messages']} messages)"
    return results


# ── Stage 7: publish + status ────────────────────────────────────────────────
def publish_db(con) -> dict:
    dest = ARCHIVE / "messages.db"
    tmp = ARCHIVE / f".messages.db.tmp{os.getpid()}"
    tmp.unlink(missing_ok=True)
    out = sqlite3.connect(tmp)
    with out:
        con.backup(out)
    out.execute("PRAGMA journal_mode=DELETE")
    out.close()
    os.replace(tmp, dest)
    return {"messages_db": human_bytes(dest.stat().st_size)}


def queue_counts(con) -> dict:
    return dict(con.execute("SELECT status, COUNT(*) FROM attachments GROUP BY status").fetchall())


def media_breakdown(con) -> dict:
    out = {}
    for kind, n, b in con.execute("""SELECT kind, COUNT(*), COALESCE(SUM(archive_bytes),0) FROM attachments
                                     WHERE status='done' GROUP BY kind"""):
        out[kind] = {"files": n, "size": human_bytes(b)}
    return out


def read_status() -> dict:
    shared, local = SYNC_DIR / "status.json", STATE_DIR / "status.json"
    newest = max((p for p in (shared, local) if p.exists()), key=lambda p: p.stat().st_mtime, default=shared)
    return load_json(newest, {"runs": []})


def write_status(status: dict) -> None:
    status["runs"] = status.get("runs", [])[-40:]
    text = json.dumps(status, indent=2, ensure_ascii=False, default=str) + "\n"
    try:
        write_atomic(SYNC_DIR / "status.json", text)
        write_atomic(SYNC_DIR / "status.html", render_status_html(status))
    except OSError as e:  # archive folder unreachable (no permission yet, iCloud offline)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        write_atomic(STATE_DIR / "status.json", text)
        print(f"(could not write status to {SYNC_DIR}: {e}; wrote {STATE_DIR / 'status.json'})")


def render_status_html(st: dict) -> str:
    e = html.escape
    last = (st.get("runs") or [{}])[-1]
    ok = last.get("result") == "ok"
    state_word = {"ok": "Healthy", "warning": "Finished with warnings", "failed": "Failed",
                  "running": "Running now"}.get(last.get("result"), "No runs yet")
    color = {"ok": "#1f8a4c", "warning": "#b7791f", "failed": "#c53030", "running": "#2b6cb0"}.get(
        last.get("result"), "#666")
    rows = []
    for r in reversed(st.get("runs", [])[-20:]):
        rows.append(f"<tr><td>{e(str(r.get('started', ''))[:16].replace('T', ' '))}</td><td>{e(r.get('trigger', ''))}</td>"
                    f"<td class='{e(r.get('result', ''))}'>{e(r.get('result', ''))}</td><td>{e(str(r.get('seconds', '')))}s</td>"
                    f"<td>{e(str((r.get('stages', {}).get('messages') or {}).get('new', '')))}</td>"
                    f"<td>{e(str((r.get('stages', {}).get('media') or {}).get('archived', '')))}</td>"
                    f"<td>{e(r.get('error', {}).get('message', '') if r.get('error') else '')[:120]}</td></tr>")
    stage_rows = []
    for name, s in (last.get("stages") or {}).items():
        stage_rows.append(f"<tr><td>{e(name)}</td><td><code>{e(json.dumps(s, ensure_ascii=False)[:400])}</code></td></tr>")
    err = last.get("error")
    err_html = ""
    if err:
        err_html = (f"<div class='err'><b>{e(err.get('stage', ''))}: {e(err.get('code', ''))}</b><br>"
                    f"{e(err.get('message', ''))}<br><br><b>Fix:</b> {e(err.get('fix', ''))}<br>"
                    f"<b>Retry:</b> {'automatic (' + e(str(st.get('next_retry', ''))) + ')' if err.get('retry') else 'after you fix it, run: run.sh now'}</div>")
    warns = "".join(f"<li>{e(w)}</li>" for w in last.get("warnings", []))
    q = st.get("queue", {})
    media = st.get("media", {})
    return f"""<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="60">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>iMessage Sync status</title>
<style>
:root{{--bg:#fff;--fg:#1a1a1a;--mut:#666;--card:#f5f5f4;--line:#e2e2e0}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1b1b1d;--fg:#eee;--mut:#9a9a9a;--card:#26262a;--line:#38383c}}}}
body{{font:15px/1.45 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg);max-width:1000px;margin:0 auto;padding:20px 16px}}
h1{{font-size:22px;margin:0 0 4px}} .pill{{display:inline-block;padding:3px 10px;border-radius:99px;color:#fff;background:{color};font-weight:600}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin:16px 0}}
.card{{background:var(--card);border-radius:10px;padding:10px 12px}} .card b{{display:block;font-size:20px}}
.mut{{color:var(--mut)}} table{{border-collapse:collapse;width:100%;font-size:13px}} td,th{{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line);vertical-align:top}}
.failed{{color:#c53030;font-weight:600}} .warning{{color:#b7791f;font-weight:600}} .ok{{color:#1f8a4c}}
.err{{background:#c5303018;border:1px solid #c5303055;border-radius:10px;padding:12px;margin:12px 0}}
code{{font-size:12px;word-break:break-all}} .wrap{{overflow-x:auto}}
</style></head><body>
<h1>iMessage Sync</h1>
<div><span class="pill">{e(state_word)}</span> <span class="mut">last run {e(str(last.get('started', '—'))[:16].replace('T', ' '))} on {e(last.get('machine', ''))} · primary Mac: {e(str(st.get('primary', 'not set')))}</span></div>
{err_html}
{'<ul>' + warns + '</ul>' if warns else ''}
<div class="grid">
 <div class="card"><span class="mut">Messages archived</span><b>{e(str(st.get('totals', {}).get('messages', '—')))}</b></div>
 <div class="card"><span class="mut">Conversations</span><b>{e(str(st.get('totals', {}).get('conversations', '—')))}</b></div>
 <div class="card"><span class="mut">Last success</span><b>{e(str(st.get('last_success', '—'))[:16].replace('T', ' '))}</b></div>
 <div class="card"><span class="mut">Media archived / queued</span><b>{e(str(q.get('done', 0)))} / {e(str(q.get('pending', 0) + q.get('failed', 0)))}</b></div>
 <div class="card"><span class="mut">Offloaded, retrying / gave up</span><b>{e(str(q.get('missing', 0)))} / {e(str(q.get('gave_up', 0)))}</b></div>
</div>
<p class="mut">Media by kind: {e(', '.join(f"{k} {v['files']} ({v['size']})" for k, v in media.items()) or '—')}</p>
<h2>Last run, stage by stage</h2><div class="wrap"><table>{''.join(stage_rows) or '<tr><td>—</td></tr>'}</table></div>
<h2>Recent runs</h2><div class="wrap"><table><tr><th>Started</th><th>Trigger</th><th>Result</th><th>Time</th><th>New msgs</th><th>Media</th><th>Error</th></tr>{''.join(rows)}</table></div>
<h2>Commands</h2><p class="mut">In Backstage, open <b>iMessage sync</b> and type one of these in Arguments, or run <code>mac-scripts/imessage-sync/run.sh &lt;command&gt;</code>:
<br><code>now</code> run immediately · <code>status</code> · <code>doctor</code> check everything and explain fixes · <code>retry-media</code> retry files that gave up ·
<code>take-over</code> make this Mac the primary · <code>install</code> / <code>uninstall</code> the nightly job</p>
<p class="mut">Files: archive <code>{e(str(ARCHIVE))}</code> · logs <code>_sync/logs/</code> · machine-readable status <code>_sync/status.json</code></p>
</body></html>"""


# ── Orchestration ────────────────────────────────────────────────────────────
def due(cfg, status, trigger) -> tuple[bool, str]:
    if trigger != "scheduled":
        return True, "manual"
    t = now()
    last_ok = parse_iso(status.get("last_success"))
    last_try = parse_iso(status.get("last_attempt"))
    fails = int(status.get("consecutive_failures", 0))
    lo, hi = cfg.get("overnight_window", [1, 6])
    if fails and last_try:
        if fails >= 6:
            return False, "paused after 6 failures in a row (run doctor, then run.sh now)"
        wait = min(8, 2 ** (fails - 1))
        if t - last_try >= dt.timedelta(hours=wait):
            return True, f"retry #{fails} after {wait}h backoff"
        return False, f"waiting for retry backoff ({wait}h after failure #{fails})"
    if lo <= t.hour < hi and (not last_ok or last_ok.date() < t.date()):
        return True, "overnight run"
    if not last_ok or t - last_ok > dt.timedelta(hours=cfg.get("catch_up_after_hours", 26)):
        return True, "catch-up (missed the overnight window)"
    return False, "not due"


@contextlib.contextmanager
def single_instance():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fh = open(STATE_DIR / "run.lock", "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise StageError("already_running", "another sync is already running", "Wait for it to finish.", retry=False)
    try:
        yield
    finally:
        fcntl.flock(fh, fcntl.LOCK_UN)
        fh.close()


def cmd_run(args) -> int:
    cfg = load_config()
    status = read_status()
    trigger = "scheduled" if args.scheduled else "manual"
    req = load_json(REQUEST_PATH, None)
    if req and args.scheduled:  # run.sh asked launchd to run now
        REQUEST_PATH.unlink(missing_ok=True)
        trigger = "requested"
        if req.get("action") == "doctor":
            return cmd_doctor(args)
        if req.get("action") == "run":
            args.force = True
            args.no_media = req.get("no_media", False)
            if req.get("media_budget") is not None:
                args.media_budget = req["media_budget"]
    me = this_machine()
    primary = cfg.get("primary_host")
    if primary and primary != me:
        msg = f"standby: this Mac ({me}) is not the primary ({primary}); run.sh take-over to switch"
        print(msg)
        return 0
    ok, why = due(cfg, status, trigger) if not args.force else (True, "forced")
    if not ok:
        print(f"not running: {why}")
        return 0

    log.open_file()
    started = now()
    run = {"started": iso(started), "trigger": f"{trigger} ({why})", "machine": me, "version": VERSION,
           "result": "running", "stages": {}, "warnings": []}
    status.setdefault("runs", []).append(run)
    status["last_attempt"] = iso(started)
    status["primary"] = primary or f"{me} (unset)"
    write_status(status)
    log(f"iMessage Sync {VERSION} · {why} · archive {ARCHIVE}")
    snap_path = STATE_DIR / "snapshot.db"
    current = "setup"
    try:
        with single_instance():
            SYNC_DIR.mkdir(parents=True, exist_ok=True)
            con = open_master()

            def stage(name, fn, *a, fatal=True):
                nonlocal current
                current = name
                t0 = time.monotonic()
                log(f"▶ {name}")
                try:
                    res = fn(*a)
                except Exception as ex:  # noqa: BLE001
                    err = classify(ex)
                    if fatal:
                        raise
                    log(f"  ⚠ {name} failed: {err}  → {err.fix}")
                    run["warnings"].append(f"{name}: {err} — {err.fix}")
                    run["stages"][name] = {"warning": str(err)[:300]}
                    return None
                out = res[0] if isinstance(res, tuple) else res
                if isinstance(out, dict):
                    out = dict(out, seconds=round(time.monotonic() - t0, 1))
                run["stages"][name] = out
                log(f"  ✓ {name}: {json.dumps(out, ensure_ascii=False, default=str)[:300]}")
                return res

            stage("snapshot", take_snapshot, snap_path)
            names, cinfo = load_contacts(cfg)
            run["stages"]["contacts"] = cinfo
            if cinfo["address_books_read"] == 0:
                run["warnings"].append("Contacts not readable: names show as phone numbers. "
                                       "Full Disk Access also covers Contacts; run doctor.")
            snap = sqlite3.connect(snap_path)
            stage("conversations", sync_conversations, snap, con, names)
            _, touched = stage("messages", sync_messages, snap, con, names)
            stage("attachments", sync_attachment_rows, snap, con)
            snap.close()
            media_touched = set()
            if cfg["media"].get("enabled", True) and not args.no_media:
                budget = args.media_budget if args.media_budget is not None else cfg["media"]["budget_minutes"]
                res = stage("media", stage_media, con, cfg, float(budget), fatal=False)
                if res:
                    media_touched = res[1]
            if cfg["markdown"].get("enabled", True):
                stage("markdown", stage_markdown, con, touched | media_touched, cfg)
            if cfg.get("pipelines") and not args.no_pipelines:
                stage("pipelines", stage_pipelines, con, cfg, snap_path, fatal=False)
            stage("publish", publish_db, con)
            status["totals"] = {
                "messages": con.execute("SELECT COUNT(*) FROM messages WHERE reaction IS NULL").fetchone()[0],
                "conversations": con.execute("SELECT COUNT(DISTINCT folder) FROM conversations WHERE message_count>0").fetchone()[0],
                "first": con.execute("SELECT MIN(sent_at) FROM messages").fetchone()[0],
                "last": con.execute("SELECT MAX(sent_at) FROM messages").fetchone()[0]}
            status["queue"] = queue_counts(con)
            status["media"] = media_breakdown(con)
            con.close()
        run["result"] = "warning" if run["warnings"] else "ok"
        status["last_success"] = iso(now())
        status["consecutive_failures"] = 0
        status.pop("next_retry", None)
        if cfg["notify"].get("on_success") or (run["warnings"] and cfg["notify"].get("on_failure")):
            notify("iMessage Sync", f"Done with {len(run['warnings'])} warning(s): {run['warnings'][0][:150]}"
                   if run["warnings"] else f"Archived {run['stages'].get('messages', {}).get('new', 0)} new messages")
        code = 0
    except Exception as ex:  # noqa: BLE001
        err = classify(ex)
        tb = traceback.format_exc()
        log(f"✗ {current} failed: {err}")
        log(f"  fix: {err.fix}")
        run["result"] = "failed"
        run["error"] = {"stage": current, "code": err.code, "message": str(err)[:500], "fix": err.fix,
                        "retry": err.retry, "traceback": tb[-3000:]}
        fails = int(status.get("consecutive_failures", 0)) + 1
        status["consecutive_failures"] = fails
        wait = min(8, 2 ** (fails - 1))
        if fails >= 6:
            status["next_retry"] = "paused after 6 failures; fix, then run.sh now"
        elif err.retry:
            status["next_retry"] = iso(now() + dt.timedelta(hours=wait))
        else:
            status["next_retry"] = f"{iso(now() + dt.timedelta(hours=wait))}, but it needs your fix first"
        if cfg["notify"].get("on_failure") and err.code != "already_running":
            notify("iMessage Sync failed", f"{current}: {err.fix or err}")
        code = 1
    finally:
        snap_path.unlink(missing_ok=True)
    run["seconds"] = round((now() - started).total_seconds())
    status["runs"][-1] = run
    write_status(status)
    log(f"{'✓ done' if code == 0 else '✗ failed'} in {run['seconds']}s · status: {SYNC_DIR / 'status.html'}")
    return code


def cmd_status(_args) -> int:
    st = read_status()
    cfg = load_config()
    last = (st.get("runs") or [{}])[-1]
    print(f"iMessage Sync {VERSION}")
    print(f"  archive:       {ARCHIVE}")
    print(f"  primary Mac:   {cfg.get('primary_host') or 'not set (run install)'}   this Mac: {this_machine()}")
    print(f"  last success:  {st.get('last_success', 'never')}")
    print(f"  last run:      {last.get('started', 'never')}  → {last.get('result', '—')}  ({last.get('trigger', '')})")
    if last.get("error"):
        print(f"  error:         [{last['error']['stage']}] {last['error']['message'][:200]}")
        print(f"  fix:           {last['error']['fix']}")
        print(f"  next retry:    {st.get('next_retry', '—')}")
    for w in last.get("warnings", []):
        print(f"  warning:       {w[:200]}")
    t = st.get("totals", {})
    if t:
        print(f"  archived:      {t.get('messages')} messages in {t.get('conversations')} conversations "
              f"({str(t.get('first', ''))[:10]} → {str(t.get('last', ''))[:10]})")
    q = st.get("queue", {})
    if q:
        print(f"  media:         {q.get('done', 0)} archived · {q.get('pending', 0)} queued · "
              f"{q.get('missing', 0)} offloaded (retrying) · {q.get('failed', 0)} failed · {q.get('gave_up', 0)} gave up")
    ok, why = due(cfg, st, "scheduled")
    print(f"  next check:    hourly; would run now? {'yes' if ok else 'no'} ({why})")
    print(f"  dashboard:     {SYNC_DIR / 'status.html'}")
    return 0


def cmd_doctor(_args) -> int:
    """Checks everything a run needs and prints a fix for each problem."""
    cfg = load_config()
    problems = 0

    def check(ok, label, fix=""):
        nonlocal problems
        print(f"  {'✅' if ok else '❌'} {label}" + ("" if ok else f"\n      fix: {fix}"))
        problems += 0 if ok else 1

    print(f"iMessage Sync doctor · {this_machine()} · {iso(now())}")
    in_job = bool(os.environ.get("XPC_SERVICE_NAME", "").startswith(LABEL))
    print(f"  (running {'inside the nightly job' if in_job else 'from a terminal/Backstage'}; "
          f"Full Disk Access results apply to {'the job' if in_job else 'this app only'})")
    try:
        c = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
        n = c.execute("SELECT COUNT(*) FROM message").fetchone()[0]
        c.close()
        check(True, f"Messages database readable ({n} messages)")
    except Exception as ex:  # noqa: BLE001
        check(False, f"Messages database readable ({ex})", classify(PermissionError("authorization denied chat.db")).fix)
    _, ci = load_contacts(cfg)
    check(ci["address_books_read"] > 0, f"Contacts readable ({ci['names']} names)",
          "Same Full Disk Access grant covers Contacts; also make sure Contacts has synced.")
    check(HELPER_APP.exists(), f"helper app installed ({HELPER_APP})", "run.sh install")
    plist = HOME / f"Library/LaunchAgents/{LABEL}.plist"
    loaded = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True).returncode == 0
    check(plist.exists() and loaded, "nightly job installed and loaded", "run.sh install")
    primary = cfg.get("primary_host")
    check(primary == this_machine(), f"this Mac is the primary (primary: {primary})",
          "If this is the Mac that should archive, run: run.sh take-over")
    try:
        SYNC_DIR.mkdir(parents=True, exist_ok=True)
        probe = SYNC_DIR / ".probe"
        probe.write_text("ok")
        probe.unlink()
        check(True, f"archive folder writable ({ARCHIVE})")
    except OSError as ex:
        check(False, f"archive folder writable ({ex})", "Check iCloud Drive is signed in and not full.")
    for label, path in (("local disk", STATE_DIR if STATE_DIR.exists() else HOME), ("archive disk", ARCHIVE.parent)):
        try:
            free = shutil.disk_usage(path).free
            check(free > 5 * 1024 ** 3, f"{label} free space {human_bytes(free)}", "Free up space (need > 5 GB).")
        except OSError:
            pass
    check(bool(shutil.which("sips")), "sips (photo resizing) available", "Built into macOS; odd if missing.")
    ff = shutil.which("ffmpeg") or Path("/opt/homebrew/bin/ffmpeg").exists()
    print(f"  {'✅' if ff else 'ℹ️ '} ffmpeg {'available' if ff else 'not found (using macOS avconvert; brew install ffmpeg for smaller videos)'}")
    for p in cfg.get("pipelines", []):
        d = (ARCHIVE.parent / p["export_dir"]).resolve()
        check(d.exists(), f"pipeline '{p.get('name')}' folder exists ({d})", "Fix export_dir in _sync/config.json")
    st = read_status()
    last_ok = parse_iso(st.get("last_success"))
    fresh = bool(last_ok and now() - last_ok < dt.timedelta(hours=30))
    check(fresh, f"last successful sync: {st.get('last_success', 'never')}",
          "Run now: run.sh now  (then read the error it prints)")
    q = st.get("queue", {})
    if q.get("gave_up"):
        print(f"  ℹ️  {q['gave_up']} attachment(s) gave up (not on this Mac). Open Messages and scroll to them, "
              "or turn off Settings → Messages → Keep Messages optimization, then: run.sh retry-media")
    print(f"\n{'All good.' if not problems else f'{problems} problem(s) found.'}")
    return 1 if problems else 0


def cmd_retry_media(_args) -> int:
    con = open_master()
    with con:
        n = con.execute("""UPDATE attachments SET status='pending', attempts=0, next_try_at=NULL
                           WHERE status IN ('gave_up','failed','missing')""").rowcount
    print(f"Re-queued {n} attachment(s); they will be tried on the next run.")
    return 0


def cmd_take_over(_args) -> int:
    cfg = load_config()
    old = cfg.get("primary_host")
    cfg["primary_host"] = this_machine()
    save_config(cfg)
    print(f"Primary Mac: {old or 'none'} → {cfg['primary_host']}")
    if old and old != cfg["primary_host"]:
        print("Note: this Mac keeps its own local archive database. If the old Mac had one, it is safe;\n"
              "messages.db in the archive folder already contains everything it archived, and this Mac\n"
              "will seed from it on its first run.")
    return 0


def seed_from_published() -> None:
    """New primary Mac with no local db: start from the shared copy so nothing is lost."""
    pub = ARCHIVE / "messages.db"
    if not MASTER_DB.exists() and pub.exists():
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        src = sqlite3.connect(f"file:{pub}?mode=ro", uri=True)
        dst = sqlite3.connect(MASTER_DB)
        with dst:
            src.backup(dst)
        src.close()
        dst.execute("UPDATE meta SET value='0' WHERE key IN ('last_source_rowid','last_attachment_rowid')")
        dst.commit()
        dst.close()
        log(f"seeded local archive from {pub}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Nightly iMessage archive for people and AIs.")
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("run", help="sync now (or, with --scheduled, only if due)")
    r.add_argument("--scheduled", action="store_true", help="called by the hourly job; runs only when due")
    r.add_argument("--force", action="store_true", help="run even if not due")
    r.add_argument("--no-media", action="store_true")
    r.add_argument("--no-pipelines", action="store_true")
    r.add_argument("--media-budget", type=float, default=None, help="minutes for media this run (0 = unlimited)")
    sub.add_parser("status")
    sub.add_parser("doctor")
    sub.add_parser("retry-media")
    sub.add_parser("take-over")
    args = ap.parse_args(argv)
    if args.cmd == "run":
        seed_from_published()
        return cmd_run(args)
    return {"status": cmd_status, "doctor": cmd_doctor, "retry-media": cmd_retry_media,
            "take-over": cmd_take_over}.get(args.cmd, lambda a: (ap.print_help(), 0)[1])(args)


if __name__ == "__main__":
    sys.exit(main())
