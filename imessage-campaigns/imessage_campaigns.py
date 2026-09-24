#!/usr/bin/env python3
"""iMessage Campaign Studio — search, compose, send, archive, and bump."""

from __future__ import annotations

import argparse
import curses
import json
import logging
import os
import re
import sqlite3
import subprocess
import textwrap
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

APPLE_EPOCH = datetime(2001, 1, 1)
CHAT_DB = Path.home() / "Library/Messages/chat.db"
APP_DIR = Path(__file__).resolve().parent
ARCHIVE_DIR = APP_DIR / "campaign-archive"
LOG_FILE = APP_DIR / "imessage-campaign-studio.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("imessage-campaign-studio")


def apple_time(dt: datetime) -> int:
    return int((dt - APPLE_EPOCH).total_seconds() * 1_000_000_000)


def from_apple_time(value: int | float | None) -> datetime | None:
    if not value:
        return None
    # Older databases used seconds; newer ones use nanoseconds.
    seconds = float(value) / 1_000_000_000 if value > 10_000_000_000 else float(value)
    return APPLE_EPOCH + timedelta(seconds=seconds)


def display_date(value: int | float | None) -> str:
    dt = from_apple_time(value)
    return dt.strftime("%Y-%m-%d") if dt else "—"


def attributed_text(blob: bytes | None, phrase: str = "") -> str:
    """Recover the readable NSString run from Apple's typedstream payload.

    Messages stores modern bodies in an archived NSAttributedString. Its plain
    UTF-8 NSString is preserved as a printable run among binary metadata.
    """
    if not blob:
        return ""
    decoded = bytes(blob).decode("utf-8", "ignore")
    runs = [part.strip() for part in re.split(r"[\x00-\x1f\x7f]+", decoded)]
    runs = [part for part in runs if len(part) >= 2]
    if phrase:
        matches = [part for part in runs if phrase.casefold() in part.casefold()]
        if matches:
            return max(matches, key=len)
    # Metadata tokens are short; the message itself is generally the longest run.
    return max(runs, key=len, default="")


@dataclass
class Recipient:
    handle: str
    name: str
    mentions: int = 0
    total_messages: int = 0
    last_mention: int = 0
    snippet: str = ""
    selected: bool = True


class MessageDatabase:
    def __init__(self, path: Path = CHAT_DB):
        self.path = path

    def connect(self) -> sqlite3.Connection:
        if not self.path.exists():
            raise FileNotFoundError(
                f"Messages database not found at {self.path}. Give Terminal Full Disk Access."
            )
        db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        return db

    def search(self, phrase: str, days: int = 3650) -> list[Recipient]:
        """Find participants in one-to-one chats containing the literal phrase."""
        pattern = f"%{phrase.lower()}%"
        cutoff = apple_time(datetime.now() - timedelta(days=days))
        sql = """
        WITH direct_chats AS (
          SELECT chat_id FROM chat_handle_join GROUP BY chat_id HAVING COUNT(handle_id) = 1
        ), hits AS (
          SELECT chj.handle_id, COUNT(DISTINCT m.ROWID) mentions, MAX(m.date) last_mention
          FROM direct_chats dc
          JOIN chat_handle_join chj ON chj.chat_id = dc.chat_id
          JOIN chat_message_join cmj ON cmj.chat_id = dc.chat_id
          JOIN message m ON m.ROWID = cmj.message_id
          WHERE m.date >= ? AND (
            lower(COALESCE(m.text, '')) LIKE ? OR
            instr(lower(CAST(m.attributedBody AS TEXT)), ?) > 0
          )
          GROUP BY chj.handle_id
        ), totals AS (
          SELECT chj.handle_id, COUNT(DISTINCT cmj.message_id) total_messages
          FROM direct_chats dc
          JOIN chat_handle_join chj ON chj.chat_id = dc.chat_id
          JOIN chat_message_join cmj ON cmj.chat_id = dc.chat_id
          GROUP BY chj.handle_id
        )
        SELECT h.id handle, hits.mentions, hits.last_mention, totals.total_messages,
          (SELECT CASE WHEN lower(COALESCE(m2.text,'')) LIKE ?
                       THEN m2.text ELSE m2.attributedBody END
           FROM chat_handle_join c2
           JOIN chat_message_join j2 ON j2.chat_id=c2.chat_id
           JOIN message m2 ON m2.ROWID=j2.message_id
           WHERE c2.handle_id=h.ROWID AND (
             lower(COALESCE(m2.text,'')) LIKE ? OR
             instr(lower(CAST(m2.attributedBody AS TEXT)), ?) > 0
           )
           ORDER BY m2.date DESC LIMIT 1) snippet
        FROM hits JOIN handle h ON h.ROWID=hits.handle_id
        JOIN totals ON totals.handle_id=hits.handle_id
        WHERE h.service IN ('iMessage','SMS') AND h.id NOT LIKE 'urn:biz:%'
        ORDER BY hits.last_mention DESC
        """
        with self.connect() as db:
            rows = db.execute(sql, (
                cutoff, pattern, phrase.lower(),
                pattern, pattern, phrase.lower(),
            )).fetchall()
        logger.info("search phrase=%r days=%d results=%d", phrase, days, len(rows))
        recipients = []
        for r in rows:
            raw = r["snippet"]
            snippet = attributed_text(raw, phrase) if isinstance(raw, bytes) else (raw or "")
            recipients.append(Recipient(
                r["handle"], r["handle"], r["mentions"], r["total_messages"],
                r["last_mention"], " ".join(snippet.split()),
            ))
        return recipients

    def reply_after(self, handle: str, sent_at: datetime) -> tuple[bool, str, int]:
        sql = """
        SELECT COALESCE(m.text, '') text, m.date
        FROM handle h JOIN chat_handle_join chj ON chj.handle_id=h.ROWID
        JOIN chat_message_join cmj ON cmj.chat_id=chj.chat_id
        JOIN message m ON m.ROWID=cmj.message_id
        WHERE h.id=? AND m.is_from_me=0 AND m.date>? ORDER BY m.date DESC LIMIT 1
        """
        with self.connect() as db:
            row = db.execute(sql, (handle, apple_time(sent_at))).fetchone()
        return (True, row["text"], row["date"]) if row else (False, "", 0)


class Contacts:
    @staticmethod
    def names(handles: list[str]) -> dict[str, str]:
        """Resolve names in one Contacts AppleScript call; raw handles remain on failure."""
        if not handles:
            return {}
        clean = [h.replace('"', '') for h in handles]
        literal = ", ".join(json.dumps(h) for h in clean)
        script = f'''set hs to {{{literal}}}
set out to ""
tell application "Contacts"
 repeat with h in hs
  set hs2 to h as string
  set n to ""
  try
   set p to first person whose value of phones contains hs2
   set n to name of p
  on error
   try
    set p to first person whose value of emails contains hs2
    set n to name of p
   end try
  end try
  set out to out & hs2 & tab & n & linefeed
 end repeat
end tell
return out'''
        try:
            result = subprocess.run(["osascript", "-e", script], capture_output=True,
                                    text=True, timeout=45)
            return dict(line.split("\t", 1) for line in result.stdout.splitlines() if "\t" in line)
        except (subprocess.SubprocessError, OSError):
            return {}


class Archive:
    def __init__(self, directory: Path = ARCHIVE_DIR):
        self.directory = directory

    def list(self) -> list[dict]:
        if not self.directory.exists():
            return []
        records = []
        for path in self.directory.glob("*.json"):
            try:
                records.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        return sorted(records, key=lambda x: x.get("created_at", ""), reverse=True)

    def save(self, record: dict) -> Path:
        self.directory.mkdir(exist_ok=True)
        record.setdefault("id", str(uuid.uuid4()))
        safe_day = record["created_at"][:10]
        path = self.directory / f"{safe_day}-{record['id'][:8]}.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
        os.replace(tmp, path)
        return path


def send_message(handle: str, message: str) -> tuple[bool, str]:
    script = '''on run argv
set recipientHandle to item 1 of argv
set body to item 2 of argv
tell application "Messages"
 set targetAccount to first account whose service type = iMessage
 set targetParticipant to participant recipientHandle of targetAccount
 send body to targetParticipant
end tell
end run'''
    try:
        result = subprocess.run(["osascript", "-e", script, handle, message],
                                capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return False, "Messages did not answer AppleScript within 30 seconds"
    return result.returncode == 0, result.stderr.strip()


class Studio:
    def __init__(self, screen, db: MessageDatabase, archive: Archive, dry_run: bool):
        self.s = screen
        self.db = db
        self.archive = archive
        self.dry_run = dry_run
        curses.curs_set(0)
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_CYAN, -1)
        curses.init_pair(2, curses.COLOR_GREEN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_BLACK, curses.COLOR_CYAN)

    def draw_header(self, title: str, subtitle: str = ""):
        self.s.erase()
        h, w = self.s.getmaxyx()
        self.s.addnstr(0, 0, " iMESSAGE CAMPAIGN STUDIO ".ljust(w), w,
                       curses.color_pair(4) | curses.A_BOLD)
        self.s.addnstr(2, 2, title, w - 4, curses.A_BOLD)
        if subtitle:
            self.s.addnstr(3, 2, subtitle, w - 4, curses.color_pair(1))
        status = "DRY RUN · nothing will be sent" if self.dry_run else "LIVE MODE · sends require typing SEND"
        self.s.addnstr(h - 1, 1, status.ljust(w - 2), w - 2, curses.color_pair(3))

    def input(self, label: str, default: str = "") -> str:
        self.draw_header(label)
        self.s.addstr(5, 2, "> " + default)
        self.s.refresh(); curses.echo(); curses.curs_set(1)
        raw = self.s.getstr(5, 4 + len(default), 500)
        curses.noecho(); curses.curs_set(0)
        return default + raw.decode("utf-8", "replace")

    def notice(self, title: str, message: str, detail: str = ""):
        """Show a durable result/error screen instead of silently returning home."""
        self.draw_header(title, detail)
        h, w = self.s.getmaxyx()
        lines = textwrap.wrap(message, max(20, w - 8)) or [""]
        for i, line in enumerate(lines[:h - 10]):
            self.s.addnstr(6 + i, 4, line, w - 8)
        self.s.addnstr(h - 3, 2, "Press any key to return", w - 4, curses.A_DIM)
        self.s.refresh()
        self.s.getch()

    def menu(self, title: str, choices: list[str], subtitle: str = "") -> int:
        pos = 0
        while True:
            self.draw_header(title, subtitle)
            for i, choice in enumerate(choices):
                attr = curses.color_pair(1) | curses.A_BOLD if i == pos else 0
                self.s.addnstr(5 + i, 4, ("› " if i == pos else "  ") + choice,
                               self.s.getmaxyx()[1] - 8, attr)
            self.s.addstr(self.s.getmaxyx()[0] - 3, 2, "↑/↓ move  Enter select  q back", curses.A_DIM)
            self.s.refresh(); key = self.s.getch()
            if key in (curses.KEY_UP, ord('k')): pos = (pos - 1) % len(choices)
            elif key in (curses.KEY_DOWN, ord('j')): pos = (pos + 1) % len(choices)
            elif key in (10, 13): return pos
            elif key == ord('q'): return -1

    def select_recipients(self, recipients: list[Recipient], phrase: str) -> list[Recipient]:
        pos = top = 0
        while True:
            h, w = self.s.getmaxyx(); visible = max(4, h - 9)
            top = min(max(0, pos - visible + 1), top) if pos < top else max(top, pos - visible + 1)
            self.draw_header(f"{len(recipients)} people mentioned “{phrase}”",
                             f"{sum(r.selected for r in recipients)} selected · group chats excluded")
            self.s.addnstr(5, 2, "  NAME / HANDLE".ljust(34) + " HITS  MESSAGES  LAST MENTION", w-4, curses.A_BOLD)
            for row, r in enumerate(recipients[top:top + visible]):
                idx = top + row
                mark = "●" if r.selected else "○"
                label = r.name if r.name != r.handle else r.handle
                line = f"{mark} {label[:30]:30} {r.mentions:4} {r.total_messages:9}  {display_date(r.last_mention)}"
                attr = curses.color_pair(1) | curses.A_BOLD if idx == pos else 0
                self.s.addnstr(6 + row, 2, line, w - 4, attr)
            hint = "Space toggle  a all  n none  Enter review context  c compose  q cancel"
            self.s.addnstr(h - 3, 2, hint, w - 4, curses.A_DIM); self.s.refresh(); key = self.s.getch()
            if key in (curses.KEY_UP, ord('k')): pos = max(0, pos - 1)
            elif key in (curses.KEY_DOWN, ord('j')): pos = min(len(recipients)-1, pos+1)
            elif key == ord(' '): recipients[pos].selected = not recipients[pos].selected
            elif key == ord('a'):
                for r in recipients: r.selected = True
            elif key == ord('n'):
                for r in recipients: r.selected = False
            elif key in (10, 13):
                r = recipients[pos]; self.draw_header(r.name, r.handle)
                lines = textwrap.wrap(r.snippet, max(20, w - 8))
                for i, line in enumerate(lines[:h-9]): self.s.addnstr(6+i, 4, line, w-8)
                self.s.addstr(h-3, 2, "Any key returns", curses.A_DIM); self.s.refresh(); self.s.getch()
            elif key == ord('c'): return [r for r in recipients if r.selected]
            elif key == ord('q'): return []

    def compose(self, initial: str = "") -> str:
        # A line-oriented composer keeps pasting reliable inside curses.
        return self.input("Write the message (paste supported)", initial).strip()

    def deliver(self, phrase: str, recipients: list[Recipient], body: str,
                parent_id: str | None = None):
        if not recipients or not body: return
        self.draw_header("Final review", f"{len(recipients)} separate conversations")
        h, w = self.s.getmaxyx()
        preview = textwrap.wrap(body, max(20, w - 8))
        for i, line in enumerate(preview[:h-10]): self.s.addnstr(6+i, 4, line, w-8)
        required = "SIMULATE" if self.dry_run else "SEND"
        prompt_text = f"Type {required} to {'simulate' if self.dry_run else 'send'}: "
        self.s.addnstr(h-4, 2, prompt_text, w-4, curses.color_pair(3)|curses.A_BOLD)
        self.s.refresh(); curses.echo(); curses.curs_set(1)
        confirmation = self.s.getstr(h-4, min(w-12, 2 + len(prompt_text)), 12).decode().strip()
        curses.noecho(); curses.curs_set(0)
        if confirmation != required:
            logger.info("delivery cancelled dry_run=%s recipients=%d", self.dry_run, len(recipients))
            return
        sent, simulated, failed = [], [], []
        logger.info("delivery started dry_run=%s phrase=%r recipients=%d", self.dry_run, phrase, len(recipients))
        for i, r in enumerate(recipients, 1):
            self.draw_header("Simulating" if self.dry_run else "Sending",
                             f"{i}/{len(recipients)} · {r.name}")
            self.s.addstr(6, 4, "Preview only — Messages is not being contacted"
                          if self.dry_run else "Talking to Messages…")
            self.s.refresh()
            item = {"handle": r.handle, "name": r.name}
            if self.dry_run:
                simulated.append(item)
            else:
                ok, error = send_message(r.handle, body)
                item.update({"sent_at": datetime.now().isoformat(), "error": error})
                (sent if ok else failed).append(item)
                if ok:
                    logger.info("recipient sent handle=%r campaign_index=%d", r.handle, i)
                else:
                    logger.error("recipient failed handle=%r campaign_index=%d error=%s",
                                 r.handle, i, error)
                time.sleep(.35)
        record = {"created_at": datetime.now().isoformat(), "phrase": phrase, "message": body,
                  "dry_run": self.dry_run, "parent_campaign_id": parent_id,
                  "recipients": sent, "simulated_recipients": simulated, "failed": failed}
        path = self.archive.save(record)
        logger.info("delivery completed dry_run=%s sent=%d simulated=%d failed=%d archive=%s",
                    self.dry_run, len(sent), len(simulated), len(failed), path)
        title = "Dry run saved — 0 messages sent" if self.dry_run else "Campaign saved"
        subtitle = (f"{len(simulated)} simulated · Messages was not contacted" if self.dry_run
                    else f"{len(sent)} sent · {len(failed)} failed")
        self.draw_header(title, subtitle)
        self.s.addnstr(6, 4, str(path), w-8, curses.color_pair(2)); self.s.getch()

    def new_campaign(self):
        phrase = self.input("Find people by a word or exact phrase").strip()
        if not phrase:
            self.notice("Search cancelled", "No search phrase was entered.")
            return
        days_text = self.input("How far back? Days", "3650").strip()
        try: days = max(1, int(days_text))
        except ValueError: days = 3650
        self.draw_header("Searching Messages…", phrase); self.s.refresh()
        logger.info("search started phrase=%r days=%d", phrase, days)
        recipients = self.db.search(phrase, days)
        if not recipients:
            logger.info("search completed with no matches phrase=%r", phrase)
            self.notice(
                "No matching one-to-one conversations",
                f"Nothing containing “{phrase}” was found in the last {days} days. "
                "Try a shorter phrase, a longer lookback, or different spelling.",
                f"Search completed · log: {LOG_FILE.name}",
            )
            return
        names = Contacts.names([r.handle for r in recipients])
        for r in recipients: r.name = names.get(r.handle) or r.handle
        logger.info("recipient review opened phrase=%r recipients=%d", phrase, len(recipients))
        chosen = self.select_recipients(recipients, phrase)
        if chosen:
            body = self.compose()
            self.deliver(phrase, chosen, body)

    def archive_screen(self):
        campaigns = self.archive.list()
        if not campaigns:
            self.menu("Campaign archive", ["No campaigns yet"]); return
        labels = []
        for c in campaigns:
            live = "SIM" if c.get("dry_run") else "SENT"
            count = len(c.get("simulated_recipients", c.get("recipients", []))) if c.get("dry_run") else len(c.get("recipients", []))
            labels.append(f"{c['created_at'][:16].replace('T',' ')}  {live:4}  {count:3}  {c.get('phrase','')}")
        idx = self.menu("Campaign archive", labels, "Select one to inspect replies and prepare a bump")
        if idx < 0: return
        c = campaigns[idx]
        if c.get("dry_run"):
            count = len(c.get("simulated_recipients", c.get("recipients", [])))
            self.notice("Simulation only — 0 messages sent",
                        f"This dry run previewed {count} recipients. Messages.app was never contacted, so reply tracking is unavailable.")
            return
        unanswered = []
        replied = 0
        for item in c.get("recipients", []):
            yes, _, _ = self.db.reply_after(item["handle"], datetime.fromisoformat(item["sent_at"]))
            if yes: replied += 1
            else: unanswered.append(Recipient(item["handle"], item.get("name") or item["handle"]))
        choice = self.menu("Reply status", [f"Replied: {replied}", f"No reply: {len(unanswered)}",
                           "Bump recipients who did not reply"], c.get("message", "")[:100])
        if choice == 2 and unanswered:
            chosen = self.select_recipients(unanswered, "no reply")
            body = self.compose("Just bumping this in case it got buried — ")
            self.deliver(c.get("phrase", ""), chosen, body, c.get("id"))

    def run(self):
        logger.info("application started dry_run=%s db=%s", self.dry_run, self.db.path)
        while True:
            choice = self.menu("What would you like to do?", [
                "New campaign — search message history",
                "Campaign archive — replies and bumps",
                "Quit",
            ], "Search → review people → write → confirm → send separately")
            if choice == 0:
                try: self.new_campaign()
                except (FileNotFoundError, sqlite3.Error) as exc:
                    logger.exception("Messages search failed")
                    self.notice("Cannot read Messages", str(exc), f"Details: {LOG_FILE}")
                except Exception as exc:
                    logger.exception("Unexpected campaign error")
                    self.notice("Something went wrong", str(exc), f"Details: {LOG_FILE}")
            elif choice == 1: self.archive_screen()
            else: return


def main() -> None:
    parser = argparse.ArgumentParser(description="Search iMessage history and run safe message campaigns")
    parser.add_argument("--dry-run", action="store_true", help="exercise the full flow without sending")
    parser.add_argument("--db", type=Path, default=CHAT_DB, help="alternate chat.db (useful for testing)")
    args = parser.parse_args()
    curses.wrapper(lambda screen: Studio(screen, MessageDatabase(args.db), Archive(), args.dry_run).run())


if __name__ == "__main__":
    main()
