from __future__ import annotations

import tempfile
import unittest
from datetime import date
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from personal_contacts_analyzer.analyzer import AnalysisConfig, own_email_set, run_analysis
from personal_contacts_analyzer.cli import monthly_windows
from personal_contacts_analyzer.header_parser import parse_header_block
from personal_contacts_analyzer.imap_client import (
    AuthError,
    auth_from_env,
    compact_uid_set,
    normalize_app_password,
)
from personal_contacts_analyzer.local_importer import ImportConfig, import_local_corpus
from personal_contacts_analyzer.oauth import OAuthError, resolve_client_secrets_path
from personal_contacts_analyzer.report import ReportConfig, build_report, private_report_path
from personal_contacts_analyzer.storage import HeaderRecord, HeaderStore


class CoreTests(unittest.TestCase):
    def test_monthly_windows_newest_first(self) -> None:
        windows = monthly_windows(date(2024, 1, 15), date(2024, 3, 2))
        self.assertEqual(
            [(window.start_text, window.end_text) for window in windows],
            [
                ("2024-03-01", "2024-03-02"),
                ("2024-02-01", "2024-03-01"),
                ("2024-01-15", "2024-02-01"),
            ],
        )

    def test_compact_uid_set(self) -> None:
        self.assertEqual(compact_uid_set([1, 2, 3, 7, 9, 10]), "1:3,7,9:10")

    def test_normalize_app_password(self) -> None:
        self.assertEqual(normalize_app_password("abcd efgh ijkl mnop"), "abcdefghijklmnop")

    def test_rejects_placeholder_password(self) -> None:
        import os

        old_value = os.environ.get("PCA_GMAIL_PASSWORD")
        os.environ["PCA_GMAIL_PASSWORD"] = "your-app-password"
        try:
            with self.assertRaises(AuthError):
                auth_from_env("a@sarva.co", "password")
        finally:
            if old_value is None:
                os.environ.pop("PCA_GMAIL_PASSWORD", None)
            else:
                os.environ["PCA_GMAIL_PASSWORD"] = old_value

    def test_rejects_placeholder_oauth_path(self) -> None:
        with self.assertRaises(OAuthError):
            resolve_client_secrets_path("/path/to/client_secret.json")

    def test_parse_header_block(self) -> None:
        parsed = parse_header_block(
            b"From: Alice <alice@example.com>\r\n"
            b"To: Bob <bob@example.com>\r\n"
            b"Date: Tue, 2 Apr 2024 12:34:56 -0400\r\n"
            b"Subject: =?utf-8?q?Hello_there?=\r\n"
            b"\r\n"
        )
        self.assertEqual(parsed["from_header"], "Alice <alice@example.com>")
        self.assertEqual(parsed["to_header"], "Bob <bob@example.com>")
        self.assertEqual(parsed["subject_header"], "Hello there")
        self.assertEqual(parsed["parsed_date"], "2024-04-02T12:34:56-04:00")

    def test_store_insert_and_export(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "headers.sqlite"
            csv_path = Path(temp_dir) / "headers.csv"
            store = HeaderStore(db_path)
            try:
                inserted = store.insert_headers(
                    [
                        HeaderRecord(
                            mailbox="[Gmail]/All Mail",
                            gmail_uid=1,
                            gmail_msgid="123",
                            window_start="2024-04-01",
                            window_end="2024-05-01",
                            date_header="Tue, 2 Apr 2024 12:34:56 -0400",
                            parsed_date="2024-04-02T12:34:56-04:00",
                            from_header="Alice <alice@example.com>",
                            to_header="Bob <bob@example.com>",
                            subject_header="Hello",
                        )
                    ]
                )
                duplicate = store.insert_headers(
                    [
                        HeaderRecord(
                            mailbox="[Gmail]/All Mail",
                            gmail_uid=1,
                            gmail_msgid="123",
                            window_start="2024-04-01",
                            window_end="2024-05-01",
                            date_header="Tue, 2 Apr 2024 12:34:56 -0400",
                            parsed_date="2024-04-02T12:34:56-04:00",
                            from_header="Alice <alice@example.com>",
                            to_header="Bob <bob@example.com>",
                            subject_header="Hello",
                        )
                    ]
                )
                self.assertEqual(inserted, 1)
                self.assertEqual(duplicate, 0)
                self.assertEqual(store.count_headers(), 1)
                self.assertEqual(store.export_csv(csv_path), 1)
            finally:
                store.close()
            self.assertIn("Alice <alice@example.com>", csv_path.read_text())

    def test_analyzer_outputs_relationship_dataset(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            db_path = root / "headers.sqlite"
            output_dir = root / "analysis"
            store = HeaderStore(db_path)
            try:
                store.insert_headers(
                    [
                        HeaderRecord(
                            mailbox="[Gmail]/All Mail",
                            gmail_uid=1,
                            gmail_msgid="1",
                            window_start=None,
                            window_end=None,
                            date_header="Mon, 1 Jan 2024 10:00:00 +0000",
                            parsed_date="2024-01-01T10:00:00+00:00",
                            from_header="Me <a@sarva.co>",
                            to_header="Friend <friend@example.com>",
                            subject_header="Coffee next week",
                        ),
                        HeaderRecord(
                            mailbox="[Gmail]/All Mail",
                            gmail_uid=2,
                            gmail_msgid="2",
                            window_start=None,
                            window_end=None,
                            date_header="Mon, 1 Jan 2024 12:00:00 +0000",
                            parsed_date="2024-01-01T12:00:00+00:00",
                            from_header="Friend <friend@example.com>",
                            to_header="Me <a@sarva.co>",
                            subject_header="Re: Coffee next week",
                        ),
                        HeaderRecord(
                            mailbox="[Gmail]/All Mail",
                            gmail_uid=3,
                            gmail_msgid="3",
                            window_start=None,
                            window_end=None,
                            date_header="Tue, 2 Jan 2024 12:00:00 +0000",
                            parsed_date="2024-01-02T12:00:00+00:00",
                            from_header="No Reply <noreply@example.net>",
                            to_header="Me <a@sarva.co>",
                            subject_header="Security alert",
                        ),
                    ]
                )
            finally:
                store.close()
            summary = run_analysis(
                AnalysisConfig(
                    db_path=db_path,
                    output_dir=output_dir,
                    account="a@sarva.co",
                    own_emails=own_email_set("a@sarva.co", []),
                )
            )
            self.assertEqual(summary["contacts_scored"], 2)
            relationships = (output_dir / "relationships.csv").read_text()
            self.assertIn("friend@example.com", relationships)
            self.assertIn("noreply@example.net", relationships)
            self.assertTrue((output_dir / "contact_monthly_activity.csv").exists())
            self.assertTrue((output_dir / "domain_summary.csv").exists())

            report_path = root / "report.html"
            result = build_report(ReportConfig(analysis_dir=output_dir, output_path=report_path))
            self.assertEqual(result["contacts"], 2)
            report_html = report_path.read_text(encoding="utf-8")
            self.assertIn("Contact Relationship Intelligence", report_html)
            self.assertIn("timelineChart", report_html)
            self.assertIn("friend@example.com", report_html)

            private_path = private_report_path(report_path)
            private_result = build_report(
                ReportConfig(
                    analysis_dir=output_dir,
                    output_path=private_path,
                    anonymize_people=True,
                )
            )
            self.assertEqual(private_result["contacts"], 2)
            private_html = private_path.read_text(encoding="utf-8")
            self.assertIn("F....", private_html)
            self.assertIn("f...@e......com", private_html)
            self.assertNotIn("friend@example.com", private_html)

    def test_import_local_maildir_mbox_and_eml_headers(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            maildir = root / "maildir"
            (maildir / "cur").mkdir(parents=True)
            (maildir / "new").mkdir()
            (maildir / "tmp").mkdir()
            (maildir / "cur" / "message-1").write_bytes(
                b"From: Alice <alice@example.com>\r\n"
                b"To: Me <a@sarva.co>\r\n"
                b"Date: Tue, 2 Apr 2024 12:34:56 -0400\r\n"
                b"Subject: Maildir hello\r\n"
                b"\r\n"
                b"Body is ignored.\r\n"
            )
            mbox = root / "archive"
            mbox.write_bytes(
                b"From sender@example.com Tue Apr 02 12:34:56 2024\r\n"
                b"From: Bob <bob@example.com>\r\n"
                b"To: Me <a@sarva.co>\r\n"
                b"Date: Wed, 3 Apr 2024 12:34:56 -0400\r\n"
                b"Subject: Mbox hello\r\n"
                b"\r\n"
                b"Body is ignored.\r\n"
            )
            eml_dir = root / "eml"
            eml_dir.mkdir()
            (eml_dir / "message.eml").write_bytes(
                b"From: Carol <carol@example.com>\r\n"
                b"To: Me <a@sarva.co>\r\n"
                b"Date: Thu, 4 Apr 2024 12:34:56 -0400\r\n"
                b"Subject: EML hello\r\n"
                b"\r\n"
                b"Body is ignored.\r\n"
            )

            db_path = root / "headers.sqlite"
            summary = import_local_corpus(
                ImportConfig(paths=[root], db_path=db_path, mailbox_prefix="test")
            )
            self.assertEqual(summary.eml_files_imported, 1)
            self.assertEqual(summary.maildir_files_imported, 1)
            self.assertEqual(summary.mbox_messages_imported, 1)
            self.assertEqual(summary.inserted, 3)

            store = HeaderStore(db_path)
            try:
                self.assertEqual(store.count_headers(), 3)
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
