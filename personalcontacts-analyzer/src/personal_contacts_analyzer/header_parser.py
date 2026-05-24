from __future__ import annotations

from email import policy
from email.parser import BytesParser
from email.utils import parsedate_to_datetime


def parse_header_block(header_bytes: bytes) -> dict[str, str | None]:
    message = BytesParser(policy=policy.default).parsebytes(header_bytes)
    date_header = clean_header(message.get("date", ""))
    parsed_date = parse_date(date_header)
    return {
        "date_header": date_header,
        "parsed_date": parsed_date,
        "from_header": clean_header(message.get("from", "")),
        "to_header": clean_header(message.get("to", "")),
        "subject_header": clean_header(message.get("subject", "")),
    }


def clean_header(value: object) -> str:
    if value is None:
        return ""
    return " ".join(str(value).replace("\r", " ").replace("\n", " ").split())


def parse_date(value: str) -> str | None:
    if not value:
        return None
    try:
        parsed = parsedate_to_datetime(value)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None
    if parsed is None:
        return None
    return parsed.isoformat()
