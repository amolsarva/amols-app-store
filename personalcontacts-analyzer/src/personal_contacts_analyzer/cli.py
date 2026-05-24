from __future__ import annotations

import argparse
import imaplib
import sys
import time
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Callable, TypeVar

from .analyzer import (
    DEFAULT_ANALYSIS_DIR,
    DEFAULT_FEEDBACK_PATH,
    AnalysisConfig,
    own_email_set,
    run_analysis,
)
from .imap_client import AuthError, GmailImapClient, ImapAuth, auth_from_env, coerce_date
from .local_importer import ImportConfig, LocalCorpusImporter, format_import_progress, iter_batches
from .oauth import DEFAULT_TOKEN_PATH, OAuthError, get_access_token
from .paths import configured_data_home, data_path, rebase_default_path, resolve_data_home_interactively
from .report import DEFAULT_REPORT_PATH, ReportConfig, build_report, private_report_path
from .storage import HeaderStore, chunked


DEFAULT_DB = data_path("mail_headers.sqlite")
DEFAULT_EXPORT = data_path("exports/mail_headers.csv")
DEFAULT_MAILBOX = "[Gmail]/All Mail"
T = TypeVar("T")


@dataclass(frozen=True)
class DateWindow:
    start: date
    end: date

    @property
    def start_text(self) -> str:
        return self.start.isoformat()

    @property
    def end_text(self) -> str:
        return self.end.isoformat()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args = resolve_default_data_paths(args)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        print("\nInterrupted. Rerun with `resume` or the same `scan` command.", file=sys.stderr)
        return 130
    except AuthError as error:
        print(f"Authentication failed: {error}", file=sys.stderr)
        return 2
    except OAuthError as error:
        print(f"OAuth setup failed: {error}", file=sys.stderr)
        return 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pca",
        description="Local Gmail IMAP header archiver.",
    )
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="SQLite database path.")
    subparsers = parser.add_subparsers(required=True, dest="command")

    mailboxes = subparsers.add_parser("mailboxes", help="List IMAP mailboxes.")
    add_auth_args(mailboxes)
    mailboxes.set_defaults(func=cmd_mailboxes)

    auth_check = subparsers.add_parser("auth-check", help="Verify Gmail IMAP login.")
    add_auth_args(auth_check)
    auth_check.set_defaults(func=cmd_auth_check)

    sample = subparsers.add_parser("sample", help="Fetch a small recent sample.")
    add_auth_args(sample)
    add_mailbox_arg(sample)
    sample.add_argument("--count", type=int, default=10, help="Number of headers to fetch.")
    sample.add_argument(
        "--since",
        default=(date.today() - timedelta(days=30)).isoformat(),
        help="Search sample messages since this date.",
    )
    sample.set_defaults(func=cmd_sample)

    scan = subparsers.add_parser("scan", help="Scan date windows and store headers.")
    add_auth_args(scan)
    add_mailbox_arg(scan)
    add_scan_args(scan)
    scan.set_defaults(func=cmd_scan)

    resume = subparsers.add_parser("resume", help="Resume unfinished scan windows.")
    add_auth_args(resume)
    add_mailbox_arg(resume)
    resume.add_argument("--batch-size", type=int, default=1000)
    resume.set_defaults(func=cmd_resume)

    export_csv = subparsers.add_parser("export-csv", help="Export stored headers to CSV.")
    export_csv.add_argument("--output", type=Path, default=DEFAULT_EXPORT)
    export_csv.set_defaults(func=cmd_export_csv)

    stats = subparsers.add_parser("stats", help="Show local database stats.")
    stats.add_argument("--mailbox", default=None)
    stats.set_defaults(func=cmd_stats)

    import_local = subparsers.add_parser(
        "import-local",
        help="Import headers from local Maildir and mbox corpus files.",
    )
    import_local.add_argument("paths", nargs="+", type=Path, help="Local corpus path(s) to scan.")
    import_local.add_argument(
        "--mailbox-prefix",
        default="local",
        help="Prefix used for imported local mailbox labels.",
    )
    import_local.add_argument("--batch-size", type=int, default=1000)
    import_local.add_argument(
        "--include-zips",
        action="store_true",
        help="Also scan mbox files inside .zip archives.",
    )
    import_local.add_argument("--limit-messages", type=int, default=None)
    import_local.set_defaults(func=cmd_import_local)

    analyze = subparsers.add_parser("analyze", help="Build relationship analysis datasets.")
    analyze.add_argument("--account", default="a@sarva.co", help="Your primary email address.")
    analyze.add_argument(
        "--own-email",
        action="append",
        default=[],
        help="Additional email alias that should count as you. Repeatable.",
    )
    analyze.add_argument("--output-dir", type=Path, default=DEFAULT_ANALYSIS_DIR)
    analyze.add_argument("--feedback-file", type=Path, default=DEFAULT_FEEDBACK_PATH)
    analyze.add_argument("--max-recipients-per-message", type=int, default=100)
    analyze.add_argument("--min-messages", type=int, default=1)
    analyze.set_defaults(func=cmd_analyze)

    report = subparsers.add_parser("report", help="Build a static HTML insights report.")
    report.add_argument("--analysis-dir", type=Path, default=DEFAULT_ANALYSIS_DIR)
    report.add_argument("--output", type=Path, default=DEFAULT_REPORT_PATH)
    report.add_argument("--title", default="Contact Relationship Intelligence")
    report.add_argument("--top-contacts", type=int, default=500)
    report.add_argument(
        "--anonymize-people",
        action="store_true",
        help="Only write the PVT anonymized report instead of writing both reports.",
    )
    report.set_defaults(func=cmd_report)

    return parser


def resolve_default_data_paths(args: argparse.Namespace) -> argparse.Namespace:
    defaults_by_command: dict[str, list[tuple[str, Path]]] = {
        "sample": [("db", DEFAULT_DB)],
        "scan": [("db", DEFAULT_DB)],
        "resume": [("db", DEFAULT_DB)],
        "export-csv": [("db", DEFAULT_DB), ("output", DEFAULT_EXPORT)],
        "stats": [("db", DEFAULT_DB)],
        "import-local": [("db", DEFAULT_DB)],
        "analyze": [
            ("db", DEFAULT_DB),
            ("output_dir", DEFAULT_ANALYSIS_DIR),
            ("feedback_file", DEFAULT_FEEDBACK_PATH),
        ],
        "report": [("analysis_dir", DEFAULT_ANALYSIS_DIR), ("output", DEFAULT_REPORT_PATH)],
    }
    path_defaults = list(defaults_by_command.get(args.command, []))
    if getattr(args, "auth", None) == "oauth2":
        path_defaults.append(("oauth_token_file", DEFAULT_TOKEN_PATH))
    if not path_defaults:
        return args

    old_data_home = configured_data_home()
    if old_data_home.exists():
        return args

    new_data_home = resolve_data_home_interactively()
    for attr, default in path_defaults:
        current = Path(getattr(args, attr))
        if current == default:
            setattr(args, attr, rebase_default_path(default, old_data_home, new_data_home))
    return args


def add_auth_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--account", default="a@sarva.co", help="Gmail account email.")
    parser.add_argument(
        "--auth",
        choices=["password", "oauth2"],
        default="password",
        help="Authentication method.",
    )
    parser.add_argument(
        "--oauth-client-secrets",
        default=None,
        help="Google OAuth client secrets JSON file. Used with --auth oauth2.",
    )
    parser.add_argument(
        "--oauth-token-file",
        type=Path,
        default=DEFAULT_TOKEN_PATH,
        help="OAuth token cache path. Used with --auth oauth2.",
    )


def add_mailbox_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--mailbox", default=DEFAULT_MAILBOX, help="IMAP mailbox to scan.")


def add_scan_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--since", required=True, help="Earliest message date, YYYY-MM-DD.")
    parser.add_argument(
        "--before",
        default=(date.today() + timedelta(days=1)).isoformat(),
        help="Exclusive upper date bound, YYYY-MM-DD.",
    )
    parser.add_argument("--batch-size", type=int, default=1000)
    parser.add_argument("--oldest-first", action="store_true")
    parser.add_argument("--limit-windows", type=int, default=None)
    parser.add_argument("--rescan-complete", action="store_true")


def cmd_mailboxes(args: argparse.Namespace) -> int:
    auth = build_auth(args)
    with GmailImapClient(auth) as client:
        for mailbox in client.list_mailboxes():
            print(mailbox)
    return 0


def cmd_auth_check(args: argparse.Namespace) -> int:
    auth = build_auth(args)
    with GmailImapClient(auth) as client:
        mailboxes = client.list_mailboxes()
    print(f"Authentication OK for {args.account}. {len(mailboxes)} mailboxes visible.")
    return 0


def cmd_sample(args: argparse.Namespace) -> int:
    since = coerce_date(args.since)
    before = date.today() + timedelta(days=1)
    auth = build_auth(args)
    store = HeaderStore(args.db)
    try:
        with GmailImapClient(auth) as client:
            total = client.select_mailbox(args.mailbox)
            print(f"Selected {args.mailbox}: {total:,} messages visible")
            uids = client.search_window(since, before)
            sample_uids = sorted(uids, reverse=True)[: args.count]
            records = client.fetch_headers(
                args.mailbox,
                sample_uids,
                since.isoformat(),
                before.isoformat(),
            )
            inserted = store.insert_headers(records)
            for record in records:
                print(
                    f"{record.gmail_uid} | {record.parsed_date or record.date_header} | "
                    f"{record.from_header} -> {record.to_header} | {record.subject_header}"
                )
            print(f"Stored {inserted:,} new sample rows in {args.db}")
    finally:
        store.close()
    return 0


def cmd_scan(args: argparse.Namespace) -> int:
    since = coerce_date(args.since)
    before = coerce_date(args.before)
    if before <= since:
        raise SystemExit("--before must be after --since")
    windows = monthly_windows(since, before, newest_first=not args.oldest_first)
    if args.limit_windows is not None:
        windows = windows[: args.limit_windows]
    return run_windows(
        db_path=args.db,
        auth=build_auth(args),
        mailbox=args.mailbox,
        windows=windows,
        batch_size=args.batch_size,
        skip_complete=not args.rescan_complete,
    )


def cmd_resume(args: argparse.Namespace) -> int:
    store = HeaderStore(args.db)
    try:
        unfinished = store.unfinished_windows(args.mailbox)
    finally:
        store.close()
    if not unfinished:
        print(f"No unfinished windows for {args.mailbox} in {args.db}")
        return 0
    windows = [
        DateWindow(coerce_date(window.window_start), coerce_date(window.window_end))
        for window in unfinished
    ]
    return run_windows(
        db_path=args.db,
        auth=build_auth(args),
        mailbox=args.mailbox,
        windows=windows,
        batch_size=args.batch_size,
        skip_complete=False,
    )


def cmd_export_csv(args: argparse.Namespace) -> int:
    store = HeaderStore(args.db)
    try:
        count = store.export_csv(args.output)
    finally:
        store.close()
    print(f"Exported {count:,} rows to {args.output}")
    return 0


def cmd_stats(args: argparse.Namespace) -> int:
    store = HeaderStore(args.db)
    try:
        count = store.count_headers(args.mailbox)
    finally:
        store.close()
    label = args.mailbox or "all mailboxes"
    print(f"{label}: {count:,} stored headers")
    return 0


def cmd_import_local(args: argparse.Namespace) -> int:
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be positive")
    config = ImportConfig(
        paths=args.paths,
        db_path=args.db,
        mailbox_prefix=args.mailbox_prefix,
        batch_size=args.batch_size,
        include_zips=args.include_zips,
        limit_messages=args.limit_messages,
    )
    importer = LocalCorpusImporter(config)
    store = HeaderStore(args.db)
    started = time.monotonic()
    inserted = 0
    imported = 0
    try:
        for batch_index, batch in enumerate(
            iter_batches(importer.iter_records(), args.batch_size), start=1
        ):
            inserted += store.insert_headers(batch)
            imported += len(batch)
            print(
                f"batch {batch_index}: "
                f"{format_import_progress(started, imported, inserted)}",
                flush=True,
            )
    finally:
        store.close()
    print(
        "Done. "
        f"eml files: {importer.eml_files_imported:,}/{importer.eml_files_seen:,}; "
        f"Maildir files: {importer.maildir_files_imported:,}/{importer.maildir_files_seen:,}; "
        f"mbox messages: {importer.mbox_messages_imported:,} from "
        f"{importer.mbox_files_seen:,} files; "
        f"zip messages: {importer.zip_messages_imported:,} from "
        f"{importer.zip_files_seen:,} zip files; "
        f"inserted {inserted:,} new rows into {args.db}.",
        flush=True,
    )
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
    config = AnalysisConfig(
        db_path=args.db,
        output_dir=args.output_dir,
        account=args.account,
        own_emails=own_email_set(args.account, args.own_email),
        max_recipients_per_message=args.max_recipients_per_message,
        min_messages=args.min_messages,
        feedback_path=args.feedback_file,
    )
    summary = run_analysis(config)
    print(
        f"Analyzed {summary['headers_processed']:,} headers into "
        f"{summary['contacts_scored']:,} contact rows."
    )
    print(
        f"Likely humans: {summary['likely_humans']:,}; "
        f"likely noise: {summary['noise_senders']:,}."
    )
    print(f"Wrote analysis files to {args.output_dir}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    results = []
    if not args.anonymize_people:
        results.append(
            build_report(
                ReportConfig(
                    analysis_dir=args.analysis_dir,
                    output_path=args.output,
                    title=args.title,
                    top_contacts=args.top_contacts,
                    anonymize_people=False,
                )
            )
        )
    results.append(
        build_report(
            ReportConfig(
                analysis_dir=args.analysis_dir,
                output_path=private_report_path(args.output),
                title=f"{args.title} PVT",
                top_contacts=args.top_contacts,
                anonymize_people=True,
            )
        )
    )
    for result in results:
        print(
            f"Wrote report to {result['output_path']} "
            f"using {result['contacts']:,} contacts and {result['domains']:,} domains."
        )
    return 0


def run_windows(
    db_path: Path,
    auth: ImapAuth,
    mailbox: str,
    windows: list[DateWindow],
    batch_size: int,
    skip_complete: bool,
) -> int:
    if batch_size <= 0:
        raise SystemExit("--batch-size must be positive")

    store = HeaderStore(db_path)
    started = time.monotonic()
    total_inserted = 0
    total_seen = 0
    try:
        with GmailImapClient(auth) as client:
            visible = client.select_mailbox(mailbox)
            print(f"Selected {mailbox}: {visible:,} messages visible")
            for index, window in enumerate(windows, start=1):
                existing = store.get_window(mailbox, window.start_text, window.end_text)
                if skip_complete and existing and existing.status == "complete":
                    print(
                        f"[{index}/{len(windows)}] {window.start_text}..{window.end_text}: "
                        "already complete"
                    )
                    continue

                window_started = time.monotonic()
                print(f"[{index}/{len(windows)}] Searching {window.start_text}..{window.end_text}")
                uids = with_imap_retry(
                    client,
                    mailbox,
                    lambda: client.search_window(window.start, window.end),
                    f"search {window.start_text}..{window.end_text}",
                )
                total_seen += len(uids)
                store.upsert_window(
                    mailbox,
                    window.start_text,
                    window.end_text,
                    "running",
                    uid_count=len(uids),
                    fetched_count=0,
                )
                if not uids:
                    store.upsert_window(
                        mailbox,
                        window.start_text,
                        window.end_text,
                        "complete",
                        uid_count=0,
                        fetched_count=0,
                    )
                    print(f"[{index}/{len(windows)}] No messages")
                    continue

                stored = store.stored_uids(mailbox, uids)
                pending = [uid for uid in uids if uid not in stored]
                already = len(stored)
                print(
                    f"[{index}/{len(windows)}] {len(uids):,} messages, "
                    f"{already:,} already stored, {len(pending):,} pending"
                )

                fetched_this_window = already
                for batch_index, uid_batch in enumerate(chunked(pending, batch_size), start=1):
                    records = with_imap_retry(
                        client,
                        mailbox,
                        lambda: client.fetch_headers(
                            mailbox,
                            uid_batch,
                            window.start_text,
                            window.end_text,
                        ),
                        f"fetch {uid_batch[0]}..{uid_batch[-1]}",
                    )
                    inserted = store.insert_headers(records)
                    total_inserted += inserted
                    fetched_this_window += len(uid_batch)
                    store.upsert_window(
                        mailbox,
                        window.start_text,
                        window.end_text,
                        "running",
                        uid_count=len(uids),
                        fetched_count=fetched_this_window,
                    )
                    elapsed = max(time.monotonic() - started, 0.001)
                    rate = total_inserted / elapsed * 60
                    print(
                        f"  batch {batch_index}: fetched {len(uid_batch):,}, "
                        f"inserted {inserted:,}, total new {total_inserted:,}, "
                        f"{rate:,.0f} new rows/min"
                    )

                store.upsert_window(
                    mailbox,
                    window.start_text,
                    window.end_text,
                    "complete",
                    uid_count=len(uids),
                    fetched_count=len(uids),
                )
                seconds = time.monotonic() - window_started
                print(
                    f"[{index}/{len(windows)}] Complete {window.start_text}..{window.end_text} "
                    f"in {seconds:.1f}s"
                )

        stored_total = store.count_headers(mailbox)
        elapsed = time.monotonic() - started
        print(
            f"Done. Saw {total_seen:,} window UIDs, inserted {total_inserted:,} new rows, "
            f"{stored_total:,} stored total in {elapsed / 60:.1f} minutes."
        )
    finally:
        store.close()
    return 0


def monthly_windows(since: date, before: date, newest_first: bool = True) -> list[DateWindow]:
    windows: list[DateWindow] = []
    cursor = date(since.year, since.month, 1)
    while cursor < before:
        next_month = add_month(cursor)
        start = max(cursor, since)
        end = min(next_month, before)
        if start < end:
            windows.append(DateWindow(start, end))
        cursor = next_month
    if newest_first:
        windows.reverse()
    return windows


def add_month(value: date) -> date:
    if value.month == 12:
        return date(value.year + 1, 1, 1)
    return date(value.year, value.month + 1, 1)


def build_auth(args: argparse.Namespace):
    if args.auth == "oauth2":
        token = get_access_token(args)
        return auth_from_env(args.account, args.auth, oauth_token=token)
    return auth_from_env(args.account, args.auth)


def with_imap_retry(
    client: GmailImapClient,
    mailbox: str,
    operation: Callable[[], T],
    label: str,
    attempts: int = 3,
) -> T:
    last_error: BaseException | None = None
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except (imaplib.IMAP4.abort, imaplib.IMAP4.error, OSError, TimeoutError) as error:
            last_error = error
            if attempt == attempts:
                break
            pause = min(30, 2**attempt)
            print(f"  {label} failed ({error}); reconnecting in {pause}s")
            time.sleep(pause)
            client.reconnect(mailbox)
    raise RuntimeError(f"{label} failed after {attempts} attempts: {last_error}")


if __name__ == "__main__":
    raise SystemExit(main())
