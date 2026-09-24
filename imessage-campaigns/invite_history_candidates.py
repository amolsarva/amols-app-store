#!/usr/bin/env python3
"""Create a read-only list of people recently invited to social events."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sqlite3
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from imessage_campaigns import APPLE_EPOCH, CHAT_DB, apple_time, attributed_text

WHATSAPP_DB = Path.home() / "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
WHATSAPP_CONTACTS = Path.home() / "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ContactsV2.sqlite"
ADDRESS_BOOK = Path.home() / "Library/Application Support/AddressBook"

# Your own past events (names, addresses, invite-link codes) live in the Mac-only event-rules.json
# (git-ignored). Copy event-rules.example.json to start. Each rule: {"label": ..., "pattern": regex}.
def _load_event_rules() -> list[tuple[str, str]]:
    here = Path(__file__).resolve().parent
    for name in ("event-rules.json", "event-rules.example.json"):
        f = here / name
        if f.exists():
            return [(r["label"], r["pattern"]) for r in json.loads(f.read_text(encoding="utf-8"))]
    return []


EVENT_RULES = _load_event_rules()


DIRECT_INVITE = re.compile(
    r"(?:\b(?:would you like to|do you want to|want to|wanna)\b.{0,50}"
    r"\b(?:come|join|go|stop by|hang out|watch|attend|have (?:a|one) drink)\b|"
    r"\b(?:can you|could you|will you)\b.{0,35}\b(?:come|join|make it|stop by|attend)\b|"
    r"\bhope you can\b.{0,30}\b(?:come|join|make it|attend)\b|"
    r"\b(?:join us for|may i invite you|invite you to|inviting you to|hope to see you|please rsvp)\b)",
    re.I,
)
SOCIAL_NOUN = re.compile(
    r"\b(?:party|dinner|drinks?|brunch|lunch|breakfast|bbq|barbecue|cookout|picnic|gathering|salon|"
    r"celebration|birthday|wedding|reception|housewarming|screening|concert|opera|symposium|event|eclipse)\b",
    re.I,
)
NON_SOCIAL = re.compile(
    r"\b(?:zoom|google meet|teams call|phone call|calendar invite|board meeting|agm|interview|office hours)\b",
    re.I,
)
NEGATIVE = re.compile(
    r"\b(?:invited me|invited us|invite me|invite us|was invited|got invited|not invited|your invite|"
    r"thanks for (?:the )?invite|thank you for (?:the )?invite|send me an invite|ask .{0,30} to invite me|"
    r"i(?:'m| am) not going to invite you|i was going to invite you.{0,30}not going)\b",
    re.I,
)


@dataclass
class Invite:
    key: str
    handle: str
    name: str
    platform: str
    date: datetime
    event: str
    tier: str
    text: str


def clean_text(value: str) -> str:
    text = " ".join(value.split()).strip()
    if re.match(r"^\+.{1}[A-Za-z“‘]", text):
        text = text[2:]
    return text


def normalize_phone(value: str) -> str:
    return re.sub(r"\D", "", value or "")


def identity_key(handle: str) -> str:
    base = handle.split("@", 1)[0]
    digits = normalize_phone(base)
    if len(digits) >= 8:
        return f"phone:{digits}"
    if "@" in handle and not handle.endswith(("@lid", "@s.whatsapp.net")):
        return f"email:{handle.casefold()}"
    return f"id:{handle.casefold()}"


def event_for(text: str) -> tuple[str, str] | None:
    if NEGATIVE.search(text):
        return None
    for label, pattern in EVENT_RULES:
        if re.search(pattern, text, re.I):
            return label, "Named event"
    if DIRECT_INVITE.search(text) and SOCIAL_NOUN.search(text) and not NON_SOCIAL.search(text):
        return "Informal social invitation", "Informal"
    return None


def address_book_names() -> dict[str, str]:
    names: dict[str, str] = {}
    for path in ADDRESS_BOOK.glob("**/AddressBook-v22.abcddb"):
        try:
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            for name, number in db.execute("""
                SELECT COALESCE(NULLIF(r.ZNAME,''), trim(COALESCE(r.ZFIRSTNAME,'') || ' ' || COALESCE(r.ZLASTNAME,''))),
                       p.ZFULLNUMBER
                FROM ZABCDPHONENUMBER p JOIN ZABCDRECORD r ON r.Z_PK=COALESCE(p.ZOWNER,p.Z22_OWNER)
                WHERE p.ZFULLNUMBER IS NOT NULL
            """):
                digits = normalize_phone(number)
                if name and len(digits) >= 8:
                    names[f"phone:{digits}"] = name
            for name, email in db.execute("""
                SELECT COALESCE(NULLIF(r.ZNAME,''), trim(COALESCE(r.ZFIRSTNAME,'') || ' ' || COALESCE(r.ZLASTNAME,''))),
                       e.ZADDRESS
                FROM ZABCDEMAILADDRESS e JOIN ZABCDRECORD r ON r.Z_PK=COALESCE(e.ZOWNER,e.Z22_OWNER)
                WHERE e.ZADDRESS IS NOT NULL
            """):
                if name and email:
                    names[f"email:{email.casefold()}"] = name
            db.close()
        except sqlite3.Error:
            continue
    return names


def whatsapp_directory() -> tuple[dict[str, tuple[str, str]], dict[str, str]]:
    lids: dict[str, tuple[str, str]] = {}
    names: dict[str, str] = {}
    if not WHATSAPP_CONTACTS.exists():
        return lids, names
    db = sqlite3.connect(f"file:{WHATSAPP_CONTACTS}?mode=ro", uri=True)
    for lid, phone_jid, name in db.execute("""
        SELECT ZLID, ZWHATSAPPID, COALESCE(ZFULLNAME,ZBUSINESSNAME,ZGIVENNAME,ZLOCALIZEDPHONENUMBER)
        FROM ZWAADDRESSBOOKCONTACT
    """):
        canonical = phone_jid or lid or ""
        if lid:
            lids[lid] = (canonical, name or "")
        key = identity_key(canonical)
        if name:
            names[key] = name
    db.close()
    return lids, names


def imessage_invites(cutoff: datetime) -> list[Invite]:
    db = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    rows = db.execute("""
        WITH direct_chats AS (
          SELECT chat_id FROM chat_handle_join GROUP BY chat_id HAVING COUNT(handle_id)=1
        )
        SELECT m.text, m.attributedBody, m.date, h.id handle
        FROM direct_chats dc
        JOIN chat_handle_join chj ON chj.chat_id=dc.chat_id
        JOIN handle h ON h.ROWID=chj.handle_id
        JOIN chat_message_join cmj ON cmj.chat_id=dc.chat_id
        JOIN message m ON m.ROWID=cmj.message_id
        WHERE m.is_from_me=1 AND m.date>=? AND h.id NOT LIKE 'urn:biz:%'
        ORDER BY m.date DESC
    """, (apple_time(cutoff),))
    found = []
    for row in rows:
        raw = row["text"] if row["text"] is not None else attributed_text(row["attributedBody"])
        text = clean_text(raw or "")
        classification = event_for(text)
        if not classification:
            continue
        seconds = row["date"] / 1_000_000_000 if row["date"] > 10_000_000_000 else row["date"]
        date = APPLE_EPOCH + timedelta(seconds=seconds)
        event, tier = classification
        handle = row["handle"]
        found.append(Invite(identity_key(handle), handle, handle, "iMessage", date, event, tier, text))
    db.close()
    return found


def whatsapp_invites(cutoff: datetime, lids: dict[str, tuple[str, str]]) -> list[Invite]:
    db = sqlite3.connect(f"file:{WHATSAPP_DB}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    cutoff_value = (cutoff - APPLE_EPOCH).total_seconds()
    rows = db.execute("""
        SELECT m.ZTEXT text, m.ZMESSAGEDATE date, c.ZCONTACTJID handle,
               COALESCE(c.ZPARTNERNAME,c.ZCONTACTIDENTIFIER,c.ZCONTACTJID) name
        FROM ZWAMESSAGE m JOIN ZWACHATSESSION c ON c.Z_PK=m.ZCHATSESSION
        WHERE m.ZISFROMME=1 AND m.ZMESSAGEDATE>=? AND m.ZTEXT IS NOT NULL
          AND (c.ZCONTACTJID LIKE '%@s.whatsapp.net' OR c.ZCONTACTJID LIKE '%@lid')
        ORDER BY m.ZMESSAGEDATE DESC
    """, (cutoff_value,))
    found = []
    for row in rows:
        text = clean_text(row["text"] or "")
        classification = event_for(text)
        if not classification:
            continue
        original = row["handle"]
        canonical, contact_name = lids.get(original, (original, ""))
        event, tier = classification
        found.append(Invite(identity_key(canonical), canonical, contact_name or row["name"], "WhatsApp",
                            APPLE_EPOCH + timedelta(seconds=row["date"]), event, tier, text))
    db.close()
    return found


def report(invites: list[Invite], names: dict[str, str], output: Path) -> list[dict[str, str]]:
    people: dict[str, list[Invite]] = defaultdict(list)
    for invite in invites:
        people[invite.key].append(invite)
    identity_rows = []
    for key, records in people.items():
        records.sort(key=lambda item: item.date, reverse=True)
        newest = records[0]
        known_names = [names.get(key, "")] + [item.name for item in records]
        name = next((value for value in known_names if value and value != newest.handle and "@" not in value), newest.name)
        identity_rows.append({
            "name": name,
            "contact": newest.handle,
            "platforms": ", ".join(sorted({item.platform for item in records})),
            "most_recent_invite": newest.date.strftime("%Y-%m-%d"),
            "events": "; ".join(dict.fromkeys(item.event for item in records)),
            "tier": "Named event" if any(item.tier == "Named event" for item in records) else "Informal",
            "evidence_messages": str(len(records)),
            "latest_evidence": newest.text[:240],
        })
    # Contacts can expose the same person under a phone number, email address,
    # and WhatsApp ID. A resolved, non-generic full name is the safest common key.
    merged: dict[str, dict[str, str]] = {}
    for row in identity_rows:
        resolved_name = row["name"].strip()
        mergeable = bool(re.search(r"[A-Za-z].*[ A-Za-z]", resolved_name)) and not re.fullmatch(r"\+?[\d ()-]+", resolved_name)
        key = f"name:{resolved_name.casefold()}" if mergeable else f"contact:{row['contact']}"
        if key not in merged:
            merged[key] = row
            continue
        current = merged[key]
        current["contact"] = "; ".join(dict.fromkeys(current["contact"].split("; ") + row["contact"].split("; ")))
        current["platforms"] = ", ".join(sorted(set(current["platforms"].split(", ") + row["platforms"].split(", "))))
        current["events"] = "; ".join(dict.fromkeys(current["events"].split("; ") + row["events"].split("; ")))
        current["tier"] = "Named event" if "Named event" in (current["tier"], row["tier"]) else "Informal"
        current["evidence_messages"] = str(int(current["evidence_messages"]) + int(row["evidence_messages"]))
        if row["most_recent_invite"] > current["most_recent_invite"]:
            current["most_recent_invite"] = row["most_recent_invite"]
            current["latest_evidence"] = row["latest_evidence"]
    result = list(merged.values())
    result.sort(key=lambda row: (row["most_recent_invite"], row["name"].casefold()), reverse=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(result[0]) if result else ["name"])
        writer.writeheader()
        writer.writerows(result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--months", type=int, default=6)
    parser.add_argument("--as-of", default=datetime.now().date().isoformat())
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    as_of = datetime.fromisoformat(args.as_of)
    cutoff = as_of - timedelta(days=round(args.months * 365.25 / 12))
    lids, whatsapp_names = whatsapp_directory()
    names = {**address_book_names(), **whatsapp_names}
    rows = report(imessage_invites(cutoff) + whatsapp_invites(cutoff, lids), names, args.output)
    named = sum(row["tier"] == "Named event" for row in rows)
    informal = len(rows) - named
    print(f"{len(rows)} people: {named} named-event invitees, {informal} informal invitees")
    print(args.output)


if __name__ == "__main__":
    main()
