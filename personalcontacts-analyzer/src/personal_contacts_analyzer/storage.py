from __future__ import annotations

import csv
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, TypeVar


SCHEMA_VERSION = 1
T = TypeVar("T")


@dataclass(frozen=True)
class HeaderRecord:
    mailbox: str
    gmail_uid: int
    gmail_msgid: str | None
    window_start: str | None
    window_end: str | None
    date_header: str
    parsed_date: str | None
    from_header: str
    to_header: str
    subject_header: str


@dataclass(frozen=True)
class ScanWindow:
    mailbox: str
    window_start: str
    window_end: str
    status: str
    uid_count: int
    fetched_count: int
    updated_at: str


class HeaderStore:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.ensure_schema()

    def close(self) -> None:
        self.conn.close()

    def ensure_schema(self) -> None:
        with self.conn:
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS mail_headers (
                    mailbox TEXT NOT NULL,
                    gmail_uid INTEGER NOT NULL,
                    gmail_msgid TEXT,
                    window_start TEXT,
                    window_end TEXT,
                    date_header TEXT NOT NULL DEFAULT '',
                    parsed_date TEXT,
                    from_header TEXT NOT NULL DEFAULT '',
                    to_header TEXT NOT NULL DEFAULT '',
                    subject_header TEXT NOT NULL DEFAULT '',
                    fetched_at TEXT NOT NULL,
                    PRIMARY KEY (mailbox, gmail_uid)
                )
                """
            )
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS scan_windows (
                    mailbox TEXT NOT NULL,
                    window_start TEXT NOT NULL,
                    window_end TEXT NOT NULL,
                    status TEXT NOT NULL,
                    uid_count INTEGER NOT NULL DEFAULT 0,
                    fetched_count INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (mailbox, window_start, window_end)
                )
                """
            )
            self.conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_mail_headers_parsed_date
                ON mail_headers(parsed_date)
                """
            )
            self.conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_mail_headers_from_header
                ON mail_headers(from_header)
                """
            )
            self.conn.execute(
                """
                INSERT OR REPLACE INTO schema_meta(key, value)
                VALUES ('schema_version', ?)
                """,
                (str(SCHEMA_VERSION),),
            )

    def upsert_window(
        self,
        mailbox: str,
        window_start: str,
        window_end: str,
        status: str,
        uid_count: int = 0,
        fetched_count: int = 0,
    ) -> None:
        now = utc_now()
        with self.conn:
            self.conn.execute(
                """
                INSERT INTO scan_windows (
                    mailbox, window_start, window_end, status,
                    uid_count, fetched_count, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(mailbox, window_start, window_end)
                DO UPDATE SET
                    status = excluded.status,
                    uid_count = excluded.uid_count,
                    fetched_count = excluded.fetched_count,
                    updated_at = excluded.updated_at
                """,
                (mailbox, window_start, window_end, status, uid_count, fetched_count, now),
            )

    def add_window_fetch_count(
        self,
        mailbox: str,
        window_start: str,
        window_end: str,
        increment: int,
        status: str = "running",
    ) -> None:
        now = utc_now()
        with self.conn:
            self.conn.execute(
                """
                UPDATE scan_windows
                SET fetched_count = fetched_count + ?,
                    status = ?,
                    updated_at = ?
                WHERE mailbox = ? AND window_start = ? AND window_end = ?
                """,
                (increment, status, now, mailbox, window_start, window_end),
            )

    def get_window(
        self, mailbox: str, window_start: str, window_end: str
    ) -> ScanWindow | None:
        row = self.conn.execute(
            """
            SELECT * FROM scan_windows
            WHERE mailbox = ? AND window_start = ? AND window_end = ?
            """,
            (mailbox, window_start, window_end),
        ).fetchone()
        if row is None:
            return None
        return ScanWindow(**dict(row))

    def unfinished_windows(self, mailbox: str) -> list[ScanWindow]:
        rows = self.conn.execute(
            """
            SELECT * FROM scan_windows
            WHERE mailbox = ? AND status != 'complete'
            ORDER BY window_end DESC
            """,
            (mailbox,),
        ).fetchall()
        return [ScanWindow(**dict(row)) for row in rows]

    def stored_uids(self, mailbox: str, uids: Iterable[int]) -> set[int]:
        uid_list = list(uids)
        if not uid_list:
            return set()
        found: set[int] = set()
        for chunk in chunked(uid_list, 900):
            placeholders = ",".join("?" for _ in chunk)
            rows = self.conn.execute(
                f"""
                SELECT gmail_uid FROM mail_headers
                WHERE mailbox = ? AND gmail_uid IN ({placeholders})
                """,
                (mailbox, *chunk),
            ).fetchall()
            found.update(int(row["gmail_uid"]) for row in rows)
        return found

    def insert_headers(self, records: Iterable[HeaderRecord]) -> int:
        record_list = list(records)
        if not record_list:
            return 0
        now = utc_now()
        before = self.conn.total_changes
        with self.conn:
            self.conn.executemany(
                """
                INSERT OR IGNORE INTO mail_headers (
                    mailbox, gmail_uid, gmail_msgid, window_start, window_end,
                    date_header, parsed_date, from_header, to_header,
                    subject_header, fetched_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        record.mailbox,
                        record.gmail_uid,
                        record.gmail_msgid,
                        record.window_start,
                        record.window_end,
                        record.date_header,
                        record.parsed_date,
                        record.from_header,
                        record.to_header,
                        record.subject_header,
                        now,
                    )
                    for record in record_list
                ],
            )
        return self.conn.total_changes - before

    def count_headers(self, mailbox: str | None = None) -> int:
        if mailbox:
            row = self.conn.execute(
                "SELECT COUNT(*) AS count FROM mail_headers WHERE mailbox = ?",
                (mailbox,),
            ).fetchone()
        else:
            row = self.conn.execute("SELECT COUNT(*) AS count FROM mail_headers").fetchone()
        return int(row["count"])

    def export_csv(self, output_path: Path) -> int:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        rows = self.conn.execute(
            """
            SELECT
                mailbox,
                gmail_uid,
                gmail_msgid,
                parsed_date,
                date_header,
                from_header,
                to_header,
                subject_header,
                fetched_at
            FROM mail_headers
            ORDER BY parsed_date DESC, gmail_uid DESC
            """
        )
        count = 0
        with output_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(
                [
                    "mailbox",
                    "gmail_uid",
                    "gmail_msgid",
                    "parsed_date",
                    "date",
                    "from",
                    "to",
                    "subject",
                    "fetched_at",
                ]
            )
            for row in rows:
                writer.writerow([row[column] for column in row.keys()])
                count += 1
        return count


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def chunked(items: list[T], size: int) -> Iterable[list[T]]:
    for index in range(0, len(items), size):
        yield items[index : index + size]
