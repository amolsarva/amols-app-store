from __future__ import annotations

import imaplib
import os
import re
import ssl
from dataclasses import dataclass
from datetime import date, datetime
from email.utils import parsedate_to_datetime
from getpass import getpass
from typing import Iterable

from .header_parser import parse_header_block
from .storage import HeaderRecord


GMAIL_IMAP_HOST = "imap.gmail.com"
GMAIL_IMAP_PORT = 993
HEADER_FIELDS = "FROM TO DATE SUBJECT"
UID_RE = re.compile(rb"\bUID\s+(\d+)\b")
X_GM_MSGID_RE = re.compile(rb"\bX-GM-MSGID\s+(\d+)\b")
PLACEHOLDER_PASSWORDS = {"your-app-password", "your app password", "app-password"}


class AuthError(RuntimeError):
    pass


@dataclass(frozen=True)
class ImapAuth:
    kind: str
    account: str
    secret: str


class GmailImapClient:
    def __init__(
        self,
        auth: ImapAuth,
        host: str = GMAIL_IMAP_HOST,
        port: int = GMAIL_IMAP_PORT,
        timeout: int = 60,
    ):
        self.auth = auth
        self.host = host
        self.port = port
        self.timeout = timeout
        self.conn: imaplib.IMAP4_SSL | None = None

    def __enter__(self) -> "GmailImapClient":
        self.connect()
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def connect(self) -> None:
        if self.conn is not None:
            self.close()
        context = ssl.create_default_context()
        self.conn = imaplib.IMAP4_SSL(
            self.host,
            self.port,
            ssl_context=context,
            timeout=self.timeout,
        )
        try:
            if self.auth.kind == "password":
                status, data = self.conn.login(self.auth.account, self.auth.secret)
            elif self.auth.kind == "oauth2":
                auth_string = build_xoauth2_string(self.auth.account, self.auth.secret)
                status, data = self.conn.authenticate("XOAUTH2", lambda _: auth_string)
            else:
                raise ValueError(f"Unsupported auth kind: {self.auth.kind}")
            require_ok(status, data, "login")
        except imaplib.IMAP4.error as error:
            raise AuthError(format_auth_error(self.auth, error)) from error

    def close(self) -> None:
        if self.conn is None:
            return
        try:
            self.conn.close()
        except imaplib.IMAP4.error:
            pass
        finally:
            try:
                self.conn.logout()
            except imaplib.IMAP4.error:
                pass
            self.conn = None

    def reconnect(self, mailbox: str | None = None) -> int | None:
        self.connect()
        if mailbox is None:
            return None
        return self.select_mailbox(mailbox)

    def list_mailboxes(self) -> list[str]:
        conn = self.require_conn()
        status, data = conn.list()
        require_ok(status, data, "LIST")
        mailboxes: list[str] = []
        for item in data:
            if not item:
                continue
            text = item.decode("utf-8", errors="replace")
            mailboxes.append(text)
        return mailboxes

    def select_mailbox(self, mailbox: str) -> int:
        conn = self.require_conn()
        status, data = conn.select(f'"{mailbox}"', readonly=True)
        require_ok(status, data, f"SELECT {mailbox}")
        if not data or not data[0]:
            return 0
        return int(data[0])

    def search_window(self, since: date, before: date) -> list[int]:
        conn = self.require_conn()
        status, data = conn.uid(
            "SEARCH",
            None,
            "SINCE",
            format_imap_date(since),
            "BEFORE",
            format_imap_date(before),
        )
        require_ok(status, data, f"UID SEARCH {since} {before}")
        if not data or not data[0]:
            return []
        return [int(uid) for uid in data[0].split()]

    def fetch_headers(
        self,
        mailbox: str,
        uids: list[int],
        window_start: str | None = None,
        window_end: str | None = None,
    ) -> list[HeaderRecord]:
        if not uids:
            return []
        conn = self.require_conn()
        uid_set = compact_uid_set(uids)
        fetch_spec = f"(X-GM-MSGID BODY.PEEK[HEADER.FIELDS ({HEADER_FIELDS})])"
        status, data = conn.uid("FETCH", uid_set, fetch_spec)
        require_ok(status, data, f"UID FETCH {uid_set}")
        return parse_fetch_response(data, mailbox, window_start, window_end)

    def require_conn(self) -> imaplib.IMAP4_SSL:
        if self.conn is None:
            raise RuntimeError("IMAP client is not connected")
        return self.conn


def auth_from_env(account: str, auth_kind: str, oauth_token: str | None = None) -> ImapAuth:
    if auth_kind == "password":
        secret = os.environ.get("PCA_GMAIL_PASSWORD")
        if not secret:
            secret = getpass(f"App password for {account}: ")
        secret = normalize_app_password(secret)
        if secret.lower() in PLACEHOLDER_PASSWORDS:
            raise AuthError(
                "PCA_GMAIL_PASSWORD is still set to the README placeholder. "
                "Replace it with the real 16-character Google app password, "
                "or use --auth oauth2."
            )
        return ImapAuth(kind="password", account=account, secret=secret)
    if auth_kind == "oauth2":
        secret = oauth_token or os.environ.get("PCA_GMAIL_OAUTH_TOKEN")
        if not secret:
            secret = getpass(f"OAuth access token for {account}: ")
        return ImapAuth(kind="oauth2", account=account, secret=secret)
    raise ValueError(f"Unsupported auth kind: {auth_kind}")


def normalize_app_password(secret: str) -> str:
    return "".join(secret.strip().split())


def build_xoauth2_string(account: str, access_token: str) -> bytes:
    raw = f"user={account}\x01auth=Bearer {access_token}\x01\x01"
    return raw.encode("utf-8")


def require_ok(status: str, data: object, operation: str) -> None:
    if status != "OK":
        raise RuntimeError(f"{operation} failed: {status} {data!r}")


def format_auth_error(auth: ImapAuth, error: BaseException) -> str:
    if auth.kind == "password":
        return (
            f"Gmail rejected the password for {auth.account}. Use a real Google app "
            "password, not your normal account password and not the README placeholder. "
            "If this Workspace account blocks app passwords, run with --auth oauth2."
        )
    return (
        f"Gmail rejected the OAuth token for {auth.account}. Re-run the OAuth login "
        "or delete data/oauth_token.json and try again."
    )


def format_imap_date(value: date) -> str:
    return value.strftime("%d-%b-%Y")


def compact_uid_set(uids: Iterable[int]) -> str:
    unique = sorted(set(int(uid) for uid in uids))
    if not unique:
        return ""
    ranges: list[str] = []
    start = previous = unique[0]
    for uid in unique[1:]:
        if uid == previous + 1:
            previous = uid
            continue
        ranges.append(format_uid_range(start, previous))
        start = previous = uid
    ranges.append(format_uid_range(start, previous))
    return ",".join(ranges)


def format_uid_range(start: int, end: int) -> str:
    if start == end:
        return str(start)
    return f"{start}:{end}"


def parse_fetch_response(
    data: list[bytes | tuple[bytes, bytes]],
    mailbox: str,
    window_start: str | None,
    window_end: str | None,
) -> list[HeaderRecord]:
    records: list[HeaderRecord] = []
    for item in data:
        if not isinstance(item, tuple) or len(item) != 2:
            continue
        metadata, header_bytes = item
        uid_match = UID_RE.search(metadata)
        if not uid_match:
            continue
        msgid_match = X_GM_MSGID_RE.search(metadata)
        parsed = parse_header_block(header_bytes)
        records.append(
            HeaderRecord(
                mailbox=mailbox,
                gmail_uid=int(uid_match.group(1)),
                gmail_msgid=msgid_match.group(1).decode("ascii") if msgid_match else None,
                window_start=window_start,
                window_end=window_end,
                date_header=parsed["date_header"] or "",
                parsed_date=parsed["parsed_date"],
                from_header=parsed["from_header"] or "",
                to_header=parsed["to_header"] or "",
                subject_header=parsed["subject_header"] or "",
            )
        )
    return records


def coerce_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError:
        parsed = parsedate_to_datetime(value)
        if isinstance(parsed, datetime):
            return parsed.date()
        raise
