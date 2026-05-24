from __future__ import annotations

import hashlib
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator, TypeVar

from .header_parser import parse_header_block
from .storage import HeaderRecord, HeaderStore


T = TypeVar("T")


HEADER_LIMIT_BYTES = 1_000_000
SKIP_SUFFIXES = {
    ".db",
    ".DS_Store",
    ".exe",
    ".icloud",
    ".jpg",
    ".jpeg",
    ".mab",
    ".msf",
    ".pdf",
    ".png",
    ".sqlite",
    ".tif",
    ".tiff",
}
SKIP_DIR_NAME_FRAGMENTS = ("attachment",)


@dataclass(frozen=True)
class ImportSummary:
    eml_files_seen: int
    eml_files_imported: int
    maildir_files_seen: int
    maildir_files_imported: int
    mbox_files_seen: int
    mbox_messages_imported: int
    zip_files_seen: int
    zip_messages_imported: int
    inserted: int

    @property
    def messages_imported(self) -> int:
        return (
            self.eml_files_imported
            + self.maildir_files_imported
            + self.mbox_messages_imported
            + self.zip_messages_imported
        )


@dataclass(frozen=True)
class ImportConfig:
    paths: list[Path]
    db_path: Path
    mailbox_prefix: str = "local"
    batch_size: int = 1000
    include_zips: bool = False
    limit_messages: int | None = None


def import_local_corpus(config: ImportConfig) -> ImportSummary:
    if config.batch_size <= 0:
        raise ValueError("batch_size must be positive")
    store = HeaderStore(config.db_path)
    importer = LocalCorpusImporter(config)
    inserted = 0
    try:
        for batch in iter_batches(importer.iter_records(), config.batch_size):
            inserted += store.insert_headers(batch)
    finally:
        store.close()
    return ImportSummary(
        eml_files_seen=importer.eml_files_seen,
        eml_files_imported=importer.eml_files_imported,
        maildir_files_seen=importer.maildir_files_seen,
        maildir_files_imported=importer.maildir_files_imported,
        mbox_files_seen=importer.mbox_files_seen,
        mbox_messages_imported=importer.mbox_messages_imported,
        zip_files_seen=importer.zip_files_seen,
        zip_messages_imported=importer.zip_messages_imported,
        inserted=inserted,
    )


class LocalCorpusImporter:
    def __init__(self, config: ImportConfig):
        self.config = config
        self.eml_files_seen = 0
        self.eml_files_imported = 0
        self.maildir_files_seen = 0
        self.maildir_files_imported = 0
        self.mbox_files_seen = 0
        self.mbox_messages_imported = 0
        self.zip_files_seen = 0
        self.zip_messages_imported = 0
        self._emitted = 0

    def iter_records(self) -> Iterator[HeaderRecord]:
        for root in self.config.paths:
            root = root.expanduser()
            if not root.exists():
                raise FileNotFoundError(root)
            yield from self._iter_path(root)

    def _iter_path(self, root: Path) -> Iterator[HeaderRecord]:
        if root.is_file():
            yield from self._iter_file(root, root.parent)
            return
        stack = [root]
        while stack:
            current = stack.pop()
            if is_hidden_path(current, root):
                continue
            if should_skip_directory(current):
                continue
            if is_maildir(current):
                yield from self._iter_maildir(current, root)
                if self._at_limit():
                    return
                continue
            try:
                children = sorted(current.iterdir(), key=lambda item: item.name.lower())
            except OSError:
                continue
            for path in [child for child in children if child.is_file()]:
                yield from self._iter_file(path, root)
                if self._at_limit():
                    return
            dirs = [child for child in children if child.is_dir()]
            stack.extend(reversed(dirs))

    def _iter_maildir(self, maildir: Path, root: Path) -> Iterator[HeaderRecord]:
        mailbox = mailbox_name(self.config.mailbox_prefix, root, maildir)
        for message_dir in (maildir / "cur", maildir / "new"):
            if not message_dir.exists():
                continue
            for path in walk_files(message_dir):
                if self._at_limit():
                    return
                self.maildir_files_seen += 1
                header_bytes = read_header_bytes(path)
                if not looks_like_mail_headers(header_bytes):
                    continue
                record = record_from_headers(
                    header_bytes=header_bytes,
                    mailbox=mailbox,
                    source_id=str(path),
                    window_start=None,
                    window_end=None,
                )
                self.maildir_files_imported += 1
                self._emitted += 1
                yield record

    def _iter_file(self, path: Path, root: Path) -> Iterator[HeaderRecord]:
        if self._at_limit() or should_skip_file(path):
            return
        lower_name = path.name.lower()
        if lower_name.endswith(".zip"):
            if self.config.include_zips:
                yield from self._iter_zip(path, root)
            return
        if lower_name.endswith(".eml"):
            yield from self._iter_eml(path, root)
            return
        if not is_mbox_file(path):
            return
        self.mbox_files_seen += 1
        mailbox = mailbox_name(self.config.mailbox_prefix, root, path)
        try:
            with path.open("rb") as stream:
                for message_index, header_bytes in iter_mbox_headers(stream):
                    if self._at_limit():
                        return
                    if not looks_like_mail_headers(header_bytes):
                        continue
                    self.mbox_messages_imported += 1
                    self._emitted += 1
                    yield record_from_headers(
                        header_bytes=header_bytes,
                        mailbox=mailbox,
                        source_id=f"{path}:{message_index}",
                        window_start=None,
                        window_end=None,
                    )
        except OSError:
            return

    def _iter_eml(self, path: Path, root: Path) -> Iterator[HeaderRecord]:
        self.eml_files_seen += 1
        header_bytes = read_header_bytes(path)
        if not looks_like_mail_headers(header_bytes):
            return
        self.eml_files_imported += 1
        self._emitted += 1
        yield record_from_headers(
            header_bytes=header_bytes,
            mailbox=mailbox_name(self.config.mailbox_prefix, root, path.parent),
            source_id=str(path),
            window_start=None,
            window_end=None,
        )

    def _iter_zip(self, path: Path, root: Path) -> Iterator[HeaderRecord]:
        self.zip_files_seen += 1
        try:
            archive = zipfile.ZipFile(path)
        except (OSError, zipfile.BadZipFile):
            return
        with archive:
            for member in archive.infolist():
                if self._at_limit():
                    return
                if member.is_dir() or should_skip_zip_member(member.filename):
                    continue
                try:
                    with archive.open(member) as stream:
                        first_line = stream.readline()
                        if not first_line.startswith(b"From "):
                            continue
                        mailbox = mailbox_name(
                            self.config.mailbox_prefix,
                            root,
                            Path(f"{path.name}!{member.filename}"),
                        )
                        for message_index, header_bytes in iter_mbox_headers(
                            stream, first_separator=first_line
                        ):
                            if self._at_limit():
                                return
                            if not looks_like_mail_headers(header_bytes):
                                continue
                            self.zip_messages_imported += 1
                            self._emitted += 1
                            yield record_from_headers(
                                header_bytes=header_bytes,
                                mailbox=mailbox,
                                source_id=f"{path}!{member.filename}:{message_index}",
                                window_start=None,
                                window_end=None,
                            )
                except (OSError, RuntimeError, zipfile.BadZipFile):
                    continue

    def _at_limit(self) -> bool:
        return self.config.limit_messages is not None and self._emitted >= self.config.limit_messages


def find_maildirs(root: Path) -> Iterator[Path]:
    for directory in walk_dirs(root):
        if is_maildir(directory):
            yield directory


def is_maildir(directory: Path) -> bool:
    return (directory / "cur").is_dir() and (directory / "new").is_dir()


def walk_dirs(root: Path) -> Iterator[Path]:
    stack = [root]
    while stack:
        current = stack.pop()
        if is_hidden_path(current, root):
            continue
        try:
            children = sorted(current.iterdir(), key=lambda item: item.name.lower())
        except OSError:
            continue
        dirs = [child for child in children if child.is_dir()]
        stack.extend(reversed(dirs))
        yield current


def walk_files(root: Path) -> Iterator[Path]:
    if root.is_file():
        yield root
        return
    stack = [root]
    while stack:
        current = stack.pop()
        if is_hidden_path(current, root):
            continue
        if should_skip_directory(current):
            continue
        try:
            children = sorted(current.iterdir(), key=lambda item: item.name.lower())
        except OSError:
            continue
        dirs = [child for child in children if child.is_dir()]
        files = [child for child in children if child.is_file()]
        stack.extend(reversed(dirs))
        yield from files


def read_header_bytes(path: Path) -> bytes:
    header = bytearray()
    try:
        with path.open("rb") as stream:
            for line in stream:
                header.extend(line)
                if line in (b"\n", b"\r\n", b"\r"):
                    break
                if len(header) > HEADER_LIMIT_BYTES:
                    break
    except OSError:
        return b""
    return bytes(header)


def iter_mbox_headers(
    stream: BinaryIO, first_separator: bytes | None = None
) -> Iterator[tuple[int, bytes]]:
    separator = first_separator if first_separator is not None else stream.readline()
    if not separator.startswith(b"From "):
        return
    message_index = 0
    header = bytearray()
    reading_headers = True
    yielded_current = False
    while True:
        line = stream.readline()
        if line == b"":
            if reading_headers and header and not yielded_current:
                yield message_index, bytes(header)
            return
        if line.startswith(b"From "):
            if reading_headers and header and not yielded_current:
                yield message_index, bytes(header)
            message_index += 1
            header = bytearray()
            reading_headers = True
            yielded_current = False
            continue
        if not reading_headers:
            continue
        header.extend(line)
        if line in (b"\n", b"\r\n", b"\r"):
            yield message_index, bytes(header)
            reading_headers = False
            yielded_current = True
        elif len(header) > HEADER_LIMIT_BYTES:
            reading_headers = False
            yielded_current = True


def is_mbox_file(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.readline().startswith(b"From ")
    except OSError:
        return False


def record_from_headers(
    header_bytes: bytes,
    mailbox: str,
    source_id: str,
    window_start: str | None,
    window_end: str | None,
) -> HeaderRecord:
    parsed = parse_header_block(header_bytes)
    message_id = parse_message_id(header_bytes)
    return HeaderRecord(
        mailbox=mailbox,
        gmail_uid=stable_int_id(source_id),
        gmail_msgid=message_id or f"local:{stable_hex_id(source_id)}",
        window_start=window_start,
        window_end=window_end,
        date_header=parsed["date_header"] or "",
        parsed_date=parsed["parsed_date"],
        from_header=parsed["from_header"] or "",
        to_header=parsed["to_header"] or "",
        subject_header=parsed["subject_header"] or "",
    )


def parse_message_id(header_bytes: bytes) -> str | None:
    for line in header_bytes.splitlines():
        if line.lower().startswith(b"message-id:"):
            value = line.split(b":", 1)[1].strip().decode("utf-8", errors="replace")
            return " ".join(value.split()) or None
    return None


def stable_int_id(value: str) -> int:
    digest = hashlib.sha256(value.encode("utf-8", errors="surrogateescape")).digest()
    return int.from_bytes(digest[:8], "big") & ((1 << 63) - 1)


def stable_hex_id(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="surrogateescape")).hexdigest()[:24]


def mailbox_name(prefix: str, root: Path, path: Path) -> str:
    try:
        relative = path.relative_to(root)
    except ValueError:
        relative = path
    return f"{prefix}:{relative.as_posix()}"


def looks_like_mail_headers(header_bytes: bytes) -> bool:
    lowered = header_bytes[:4096].lower()
    return b"\nfrom:" in b"\n" + lowered and (b"\ndate:" in b"\n" + lowered or b"\nsubject:" in b"\n" + lowered)


def should_skip_file(path: Path) -> bool:
    if path.name.startswith("."):
        return True
    suffix = path.suffix
    return suffix in SKIP_SUFFIXES


def should_skip_directory(path: Path) -> bool:
    lowered = path.name.lower()
    return any(fragment in lowered for fragment in SKIP_DIR_NAME_FRAGMENTS)


def should_skip_zip_member(name: str) -> bool:
    path = Path(name)
    if any(part.startswith(".") for part in path.parts):
        return True
    suffix = path.suffix
    return bool(suffix and suffix in SKIP_SUFFIXES and suffix != ".mbox")


def is_hidden_path(path: Path, root: Path) -> bool:
    if path == root:
        return False
    try:
        relative = path.relative_to(root)
    except ValueError:
        return path.name.startswith(".")
    return any(part.startswith(".") for part in relative.parts)


def format_import_progress(started: float, imported: int, inserted: int) -> str:
    elapsed = max(time.monotonic() - started, 0.001)
    return f"imported {imported:,}, inserted {inserted:,}, {imported / elapsed * 60:,.0f} messages/min"


def iter_batches(items: Iterable[T], size: int) -> Iterator[list[T]]:
    batch: list[T] = []
    for item in items:
        batch.append(item)
        if len(batch) == size:
            yield batch
            batch = []
    if batch:
        yield batch
