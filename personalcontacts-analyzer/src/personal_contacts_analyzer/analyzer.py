from __future__ import annotations

import csv
import json
import math
import re
import sqlite3
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.utils import getaddresses, parsedate_to_datetime
from pathlib import Path
from statistics import median
from typing import Iterable
from zoneinfo import ZoneInfo

from .paths import data_path


ANALYZER_VERSION = "personal-closeness-v4"
DEFAULT_ANALYSIS_DIR = data_path("analysis")
DEFAULT_FEEDBACK_PATH = data_path("relationship_feedback.json")
MAX_TOP_TERMS = 12
MAX_TOP_SUBJECTS = 12
LOCAL_TIMEZONE = ZoneInfo("America/New_York")

SUBJECT_PREFIX_RE = re.compile(r"^(\s*(re|fw|fwd|aw|sv)\s*:\s*)+", re.IGNORECASE)
BRACKET_TAG_RE = re.compile(r"^\s*(\[[^\]]{1,80}\]\s*)+")
TOKEN_RE = re.compile(r"[a-z][a-z0-9']{1,}")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

NOISE_LOCAL_PARTS = {
    "noreply",
    "no-reply",
    "donotreply",
    "do-not-reply",
    "notification",
    "notifications",
    "notify",
    "alerts",
    "alert",
    "updates",
    "newsletter",
    "news",
    "billing",
    "receipts",
    "receipt",
    "invoices",
    "invoice",
    "admin",
    "support",
    "help",
    "info",
    "marketing",
    "mailer-daemon",
    "postmaster",
}

NOISE_LOCAL_FRAGMENTS = (
    "noreply",
    "no-reply",
    "notification",
    "newsletter",
    "digest",
    "alert",
    "updates",
    "billing",
    "receipt",
    "invoice",
    "support",
)

SUBJECT_KEYWORDS = {
    "personal_warmth": {
        "thank",
        "thanks",
        "sorry",
        "congrats",
        "congratulations",
        "miss",
        "love",
        "proud",
        "appreciate",
        "welcome",
        "hello",
        "hi",
        "hey",
        "checking",
        "grateful",
    },
    "coordination": {
        "coffee",
        "dinner",
        "lunch",
        "breakfast",
        "drinks",
        "party",
        "bday",
        "meet",
        "meeting",
        "call",
        "zoom",
        "chat",
        "catch",
        "visit",
        "plan",
        "plans",
        "schedule",
        "invite",
        "intro",
        "introduction",
    },
    "life_event": {
        "birthday",
        "wedding",
        "baby",
        "family",
        "home",
        "trip",
        "travel",
        "holiday",
        "graduation",
        "anniversary",
        "memorial",
        "condolences",
        "celebration",
    },
    "work_operational": {
        "status",
        "project",
        "proposal",
        "contract",
        "deck",
        "doc",
        "document",
        "review",
        "feedback",
        "launch",
        "roadmap",
        "candidate",
        "interview",
        "engineer",
        "engineering",
        "software",
        "website",
        "server",
        "servers",
        "aws",
        "bug",
        "staging",
        "deploy",
        "github",
        "investment",
        "investor",
        "fund",
        "funding",
        "venture",
        "startup",
        "board",
        "sales",
        "customer",
        "client",
        "product",
        "press",
        "speaker",
        "roundtable",
        "mobile",
        "database",
        "code",
        "migration",
        "migrating",
        "knote",
        "props",
    },
    "professional_service": {
        "rental",
        "rent",
        "lease",
        "tenant",
        "renter",
        "apartment",
        "condo",
        "unit",
        "offer",
        "sale",
        "seller",
        "buyer",
        "broker",
        "listing",
        "closing",
        "contract",
        "payment",
        "check",
        "issue",
        "applicant",
        "financial",
        "docs",
        "east",
        "jackson",
        "avenue",
        "ave",
        "tasks",
        "task",
        "jobs",
        "job",
        "hrs",
        "hours",
        "plumber",
        "elevator",
        "paint",
        "materials",
        "boiler",
        "bulb",
        "bulbs",
        "electric",
        "electrical",
        "heaters",
        "heat",
        "leak",
        "leaking",
        "maintenance",
        "move",
        "out",
        "repair",
        "repairs",
        "shower",
        "fixed",
        "washer",
        "room",
        "building",
        "property",
        "office",
        "offices",
        "school",
        "teacher",
        "student",
        "students",
        "class",
        "classes",
        "course",
        "college",
        "university",
        "columbia",
        "parent",
        "parents",
    },
    "transactional": {
        "invoice",
        "receipt",
        "payment",
        "paid",
        "order",
        "shipment",
        "delivery",
        "statement",
        "subscription",
        "renewal",
        "ticket",
        "case",
    },
    "automated": {
        "notification",
        "alert",
        "digest",
        "newsletter",
        "unsubscribe",
        "verify",
        "verification",
        "code",
        "otp",
        "login",
        "security",
        "reminder",
        "calendar",
        "invitation",
        "confirmed",
        "confirmation",
        "reset",
    },
    "urgency": {
        "urgent",
        "asap",
        "important",
        "deadline",
        "today",
        "tomorrow",
        "needed",
        "action",
        "blocked",
    },
}

STOPWORDS = {
    "about",
    "after",
    "again",
    "all",
    "and",
    "are",
    "but",
    "can",
    "for",
    "from",
    "have",
    "into",
    "just",
    "not",
    "our",
    "out",
    "re",
    "the",
    "this",
    "to",
    "with",
    "you",
    "your",
}

WEAK_WARMTH_TERMS = {
    "checking",
    "hello",
    "hey",
    "hi",
    "thank",
    "thanks",
    "welcome",
}

WEAK_COORDINATION_TERMS = {
    "call",
    "chat",
    "invite",
    "introduction",
    "intro",
    "meeting",
    "meet",
    "plan",
    "plans",
    "schedule",
    "zoom",
}

SOCIAL_COORDINATION_TERMS = {
    "bday",
    "breakfast",
    "catch",
    "coffee",
    "dinner",
    "drinks",
    "lunch",
    "party",
    "visit",
}

PROFESSIONAL_DOMAIN_HINTS = {
    "edu",
    "gov",
}


@dataclass(frozen=True)
class Address:
    name: str
    email: str

    @property
    def domain(self) -> str:
        return self.email.split("@", 1)[1] if "@" in self.email else ""

    @property
    def local_part(self) -> str:
        return self.email.split("@", 1)[0] if "@" in self.email else self.email


@dataclass(frozen=True)
class MessageEvent:
    timestamp: datetime
    direction: str
    subject_key: str


@dataclass
class ContactAccumulator:
    email: str
    names: Counter[str] = field(default_factory=Counter)
    domains: Counter[str] = field(default_factory=Counter)
    inbound_count: int = 0
    outbound_count: int = 0
    unknown_count: int = 0
    direct_count: int = 0
    group_count: int = 0
    large_group_count: int = 0
    messages_with_subject: int = 0
    timestamps: list[datetime] = field(default_factory=list)
    weekend_count: int = 0
    evening_count: int = 0
    weekday_business_count: int = 0
    off_hours_weight: float = 0.0
    active_months: set[str] = field(default_factory=set)
    active_years: set[str] = field(default_factory=set)
    subject_roots: Counter[str] = field(default_factory=Counter)
    subject_terms: Counter[str] = field(default_factory=Counter)
    subject_categories: Counter[str] = field(default_factory=Counter)
    thread_events: dict[str, list[MessageEvent]] = field(default_factory=lambda: defaultdict(list))
    monthly_counts: dict[str, Counter[str]] = field(default_factory=lambda: defaultdict(Counter))
    skipped_recipient_overflow: int = 0

    def add(
        self,
        address: Address,
        timestamp: datetime,
        direction: str,
        subject: str,
        subject_key: str,
        direct: bool,
        large_group: bool,
    ) -> None:
        if address.name:
            self.names[address.name] += 1
        if address.domain:
            self.domains[address.domain] += 1
        if direction == "inbound":
            self.inbound_count += 1
        elif direction == "outbound":
            self.outbound_count += 1
        else:
            self.unknown_count += 1
        if direct:
            self.direct_count += 1
        else:
            self.group_count += 1
        if large_group:
            self.large_group_count += 1
        if subject:
            self.messages_with_subject += 1
        self.timestamps.append(timestamp)
        local_time = timestamp.astimezone(LOCAL_TIMEZONE)
        if local_time.weekday() >= 5:
            self.weekend_count += 1
            self.off_hours_weight += 1.0
        elif local_time.hour < 9 or local_time.hour >= 18:
            self.evening_count += 1
            self.off_hours_weight += 0.7
        else:
            self.weekday_business_count += 1
            self.off_hours_weight += 0.2
        month = timestamp.strftime("%Y-%m")
        self.active_months.add(month)
        self.active_years.add(str(timestamp.year))
        self.monthly_counts[month]["total"] += 1
        self.monthly_counts[month][direction] += 1
        if direct:
            self.monthly_counts[month]["direct"] += 1
        else:
            self.monthly_counts[month]["group"] += 1
        if subject_key:
            self.subject_roots[subject_key] += 1
            self.thread_events[subject_key].append(MessageEvent(timestamp, direction, subject_key))
        for term in subject_terms(subject):
            self.subject_terms[term] += 1
        for category, count in classify_subject(subject).items():
            self.subject_categories[category] += count

    @property
    def total_count(self) -> int:
        return self.inbound_count + self.outbound_count + self.unknown_count


@dataclass(frozen=True)
class AnalysisConfig:
    db_path: Path
    output_dir: Path
    account: str
    own_emails: set[str]
    max_recipients_per_message: int = 100
    min_messages: int = 1
    feedback_path: Path = DEFAULT_FEEDBACK_PATH


def run_analysis(config: AnalysisConfig) -> dict[str, object]:
    output_dir = config.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    contacts, summary = build_contact_accumulators(config)
    rows = score_contacts(contacts, config)
    rows = [row for row in rows if row["total_count"] >= config.min_messages]

    relationships_path = output_dir / "relationships.csv"
    likely_humans_path = output_dir / "likely_humans.csv"
    noise_path = output_dir / "noise_senders.csv"
    features_path = output_dir / "relationship_features.json"
    subject_terms_path = output_dir / "contact_subject_terms.csv"
    subjects_path = output_dir / "contact_subject_roots.csv"
    monthly_path = output_dir / "contact_monthly_activity.csv"
    domains_path = output_dir / "domain_summary.csv"
    summary_path = output_dir / "analysis_summary.json"

    write_relationships_csv(relationships_path, rows)
    write_relationships_csv(
        likely_humans_path,
        [row for row in rows if row["automation_probability"] < 0.45],
    )
    write_relationships_csv(
        noise_path,
        [row for row in rows if row["automation_probability"] >= 0.65],
    )
    write_json(features_path, rows)
    write_contact_counter_csv(
        subject_terms_path,
        contacts,
        "top_subject_terms",
        lambda contact: contact.subject_terms,
    )
    write_contact_counter_csv(
        subjects_path,
        contacts,
        "top_subject_roots",
        lambda contact: contact.subject_roots,
    )
    write_monthly_activity_csv(monthly_path, contacts)
    write_domain_summary_csv(domains_path, rows)

    summary = {
        **summary,
        "analyzer_version": ANALYZER_VERSION,
        "account": config.account,
        "own_emails": sorted(config.own_emails),
        "feedback_path": str(config.feedback_path),
        "feedback_entries": len(load_feedback(config.feedback_path)),
        "contacts_scored": len(rows),
        "likely_humans": sum(1 for row in rows if row["automation_probability"] < 0.45),
        "noise_senders": sum(1 for row in rows if row["automation_probability"] >= 0.65),
        "output_files": {
            "relationships": str(relationships_path),
            "likely_humans": str(likely_humans_path),
            "noise_senders": str(noise_path),
            "relationship_features": str(features_path),
            "contact_subject_terms": str(subject_terms_path),
            "contact_subject_roots": str(subjects_path),
            "contact_monthly_activity": str(monthly_path),
            "domain_summary": str(domains_path),
        },
    }
    write_json(summary_path, summary)
    return summary


def build_contact_accumulators(
    config: AnalysisConfig,
) -> tuple[dict[str, ContactAccumulator], dict[str, object]]:
    conn = sqlite3.connect(config.db_path)
    conn.row_factory = sqlite3.Row
    contacts: dict[str, ContactAccumulator] = {}
    processed = 0
    skipped_bad_date = 0
    skipped_no_participants = 0
    recipient_overflow_messages = 0
    try:
        rows = conn.execute(
            """
            SELECT gmail_uid, parsed_date, date_header, from_header, to_header, subject_header
            FROM mail_headers
            ORDER BY parsed_date ASC, gmail_uid ASC
            """
        )
        for row in rows:
            timestamp = parse_message_datetime(row["parsed_date"], row["date_header"])
            if timestamp is None:
                skipped_bad_date += 1
                continue
            from_addresses = parse_addresses(row["from_header"])
            to_addresses = parse_addresses(row["to_header"])
            if not from_addresses and not to_addresses:
                skipped_no_participants += 1
                continue
            subject = row["subject_header"] or ""
            subject_key = normalize_subject(subject)
            sender = from_addresses[0] if from_addresses else None
            sender_is_own = sender is not None and sender.email in config.own_emails
            to_non_own = [address for address in to_addresses if address.email not in config.own_emails]
            to_has_own = any(address.email in config.own_emails for address in to_addresses)
            total_recipients = len(to_addresses)
            large_group = total_recipients > config.max_recipients_per_message

            if sender_is_own:
                recipients = to_non_own[: config.max_recipients_per_message]
                if len(to_non_own) > config.max_recipients_per_message:
                    recipient_overflow_messages += 1
                direct = len(to_non_own) == 1
                for address in recipients:
                    contact = contacts.setdefault(address.email, ContactAccumulator(address.email))
                    contact.add(
                        address,
                        timestamp,
                        "outbound",
                        subject,
                        subject_key,
                        direct=direct,
                        large_group=large_group,
                    )
                    if large_group:
                        contact.skipped_recipient_overflow += max(
                            0, len(to_non_own) - config.max_recipients_per_message
                        )
            elif sender is not None and sender.email not in config.own_emails:
                non_own_participants = {address.email for address in to_non_own}
                direct = to_has_own and len(non_own_participants) == 0
                contact = contacts.setdefault(sender.email, ContactAccumulator(sender.email))
                contact.add(
                    sender,
                    timestamp,
                    "inbound",
                    subject,
                    subject_key,
                    direct=direct,
                    large_group=large_group,
                )
            else:
                for address in to_non_own[: config.max_recipients_per_message]:
                    contact = contacts.setdefault(address.email, ContactAccumulator(address.email))
                    contact.add(
                        address,
                        timestamp,
                        "unknown",
                        subject,
                        subject_key,
                        direct=False,
                        large_group=large_group,
                    )
            processed += 1
    finally:
        conn.close()

    summary = {
        "headers_processed": processed,
        "skipped_bad_date": skipped_bad_date,
        "skipped_no_participants": skipped_no_participants,
        "recipient_overflow_messages": recipient_overflow_messages,
        "raw_contacts_seen": len(contacts),
    }
    return contacts, summary


def score_contacts(
    contacts: dict[str, ContactAccumulator],
    config: AnalysisConfig,
) -> list[dict[str, object]]:
    if not contacts:
        return []
    max_log_count = max(math.log1p(contact.total_count) for contact in contacts.values()) or 1.0
    now = max(max(contact.timestamps) for contact in contacts.values() if contact.timestamps)
    feedback_by_email = load_feedback(config.feedback_path)

    rows: list[dict[str, object]] = []
    for contact in contacts.values():
        if not contact.timestamps:
            continue
        timestamps = sorted(contact.timestamps)
        first_seen = timestamps[0]
        last_seen = timestamps[-1]
        span_days = max(0, (last_seen - first_seen).days)
        span_months = max(1, months_between(first_seen, last_seen) + 1)
        gaps = [
            max(0.0, (later - earlier).total_seconds() / 86400)
            for earlier, later in zip(timestamps, timestamps[1:])
        ]
        max_gap_days = max(gaps) if gaps else 0.0
        median_gap_days = median(gaps) if gaps else 0.0
        active_months = len(contact.active_months)
        active_years = len(contact.active_years)
        active_month_ratio = active_months / span_months if span_months else 0.0

        total = contact.total_count
        directional_total = contact.inbound_count + contact.outbound_count
        mutuality = (
            2 * min(contact.inbound_count, contact.outbound_count) / directional_total
            if directional_total
            else 0.0
        )
        direct_ratio = contact.direct_count / total if total else 0.0
        large_group_ratio = contact.large_group_count / total if total else 0.0
        distinct_subjects = len(contact.subject_roots)
        subject_entropy_score = normalized_entropy(contact.subject_roots)

        reply_features = compute_reply_features(contact.thread_events)
        subject_scores = compute_subject_scores(contact)
        automation_probability = compute_automation_probability(
            contact,
            mutuality=mutuality,
            direct_ratio=direct_ratio,
            large_group_ratio=large_group_ratio,
            subject_scores=subject_scores,
        )

        frequency_score = math.log1p(total) / max_log_count
        longevity_score = clamp(math.log1p(span_days) / math.log1p(3650))
        gap_factor = 1.0
        if span_days > 0 and max_gap_days > 0:
            gap_factor = clamp(1.0 - (max_gap_days / max(span_days, 1)) * 0.85)
        steadiness_score = clamp((active_month_ratio * 0.75) + (gap_factor * 0.25))
        recency_score = math.exp(-max(0, (now - last_seen).days) / 730)
        directness_score = clamp(direct_ratio - large_group_ratio * 0.5)
        depth_score = clamp(
            (math.log1p(distinct_subjects) / math.log1p(60)) * 0.45
            + subject_entropy_score * 0.25
            + min(1.0, active_years / 8) * 0.30
        )
        subject_affinity_score = subject_scores["subject_affinity_score"]
        personal_signal_score = subject_scores["personal_signal_score"]
        evidence_profile = compute_evidence_profile(
            total=total,
            active_months=active_months,
            distinct_subjects=distinct_subjects,
            span_days=span_days,
            active_month_ratio=active_month_ratio,
            contact=contact,
        )
        professional_probability = compute_professional_probability(
            contact,
            subject_scores=subject_scores,
            direct_ratio=direct_ratio,
            evidence_profile=evidence_profile,
        )
        off_hours_score = contact.off_hours_weight / total if total else 0.0
        weekend_ratio = contact.weekend_count / total if total else 0.0
        evening_ratio = contact.evening_count / total if total else 0.0
        weekday_business_ratio = contact.weekday_business_count / total if total else 0.0
        reply_score = reply_features["reply_rhythm_score"]

        operational_intensity_score = 100 * (
            frequency_score * 0.17
            + mutuality * 0.15
            + longevity_score * 0.13
            + steadiness_score * 0.13
            + recency_score * 0.09
            + directness_score * 0.09
            + reply_score * 0.08
            + subject_affinity_score * 0.08
            + depth_score * 0.08
        )
        operational_intensity_score *= 1.0 - automation_probability * 0.62
        operational_intensity_score = round(clamp(operational_intensity_score / 100) * 100, 2)

        qualified_off_hours_score = (
            off_hours_score
            * evidence_profile["off_hours_qualification"]
            * (1.0 - professional_probability * 0.75)
            * (1.0 - automation_probability * 0.45)
        )
        personal_closeness = 100 * (
            personal_signal_score * 0.17
            + qualified_off_hours_score * 0.09
            + mutuality * 0.10
            + directness_score * 0.08
            + reply_score * 0.08
            + longevity_score * 0.11
            + steadiness_score * 0.10
            + depth_score * 0.13
            + evidence_profile["evidence_confidence"] * 0.12
            + recency_score * 0.01
            + frequency_score * 0.01
        )
        personal_closeness *= 1.0 - automation_probability * 0.55
        personal_closeness *= 1.0 - professional_probability * 0.78
        personal_closeness *= evidence_profile["confidence_multiplier"]
        personal_closeness = min(personal_closeness, evidence_profile["score_cap"])
        if professional_probability >= 0.75:
            personal_closeness = min(personal_closeness, 32.0)
        elif professional_probability >= 0.62:
            personal_closeness = min(personal_closeness, 42.0)
        elif professional_probability >= 0.50:
            personal_closeness = min(personal_closeness, 52.0)
        elif professional_probability >= 0.40:
            personal_closeness = min(personal_closeness, 62.0)
        if automation_probability >= 0.65:
            personal_closeness = min(personal_closeness, 28.0)
        elif automation_probability >= 0.45:
            personal_closeness = min(personal_closeness, 46.0)
        personal_closeness = round(clamp(personal_closeness / 100) * 100, 2)

        display_name = best_display_name(contact)
        row = {
            "rank": 0,
            "email": contact.email,
            "display_name": display_name,
            "domain": contact.email.split("@", 1)[1] if "@" in contact.email else "",
            "relationship_strength": personal_closeness,
            "personal_closeness_score": personal_closeness,
            "operational_intensity_score": operational_intensity_score,
            "relationship_class": relationship_class(
                personal_closeness, automation_probability, professional_probability
            ),
            "feedback_label": "",
            "automation_probability": round(automation_probability, 3),
            "professional_probability": round(professional_probability, 3),
            "evidence_confidence": round(evidence_profile["evidence_confidence"], 3),
            "evidence_score_cap": round(evidence_profile["score_cap"], 2),
            "burst_penalty": round(evidence_profile["burst_penalty"], 3),
            "off_hours_qualification": round(evidence_profile["off_hours_qualification"], 3),
            "qualified_off_hours_score": round(qualified_off_hours_score, 3),
            "weak_warmth_count": int(subject_scores["weak_warmth_count"]),
            "human_probability": round(1 - automation_probability, 3),
            "total_count": total,
            "inbound_count": contact.inbound_count,
            "outbound_count": contact.outbound_count,
            "unknown_count": contact.unknown_count,
            "mutuality": round(mutuality, 3),
            "first_seen": first_seen.isoformat(),
            "last_seen": last_seen.isoformat(),
            "span_days": span_days,
            "active_months": active_months,
            "active_years": active_years,
            "active_month_ratio": round(active_month_ratio, 3),
            "max_gap_days": round(max_gap_days, 2),
            "median_gap_days": round(median_gap_days, 2),
            "direct_count": contact.direct_count,
            "group_count": contact.group_count,
            "direct_ratio": round(direct_ratio, 3),
            "large_group_ratio": round(large_group_ratio, 3),
            "distinct_subject_roots": distinct_subjects,
            "subject_entropy": round(subject_entropy_score, 3),
            "top_subject_roots": json.dumps(top_counter(contact.subject_roots, MAX_TOP_SUBJECTS)),
            "top_subject_terms": json.dumps(top_counter(contact.subject_terms, MAX_TOP_TERMS)),
            "personal_warmth_count": contact.subject_categories["personal_warmth"],
            "coordination_count": contact.subject_categories["coordination"],
            "life_event_count": contact.subject_categories["life_event"],
            "work_operational_count": contact.subject_categories["work_operational"],
            "transactional_count": contact.subject_categories["transactional"],
            "automated_count": contact.subject_categories["automated"],
            "urgency_count": contact.subject_categories["urgency"],
            "professional_service_count": contact.subject_categories["professional_service"],
            "subject_affinity_score": round(subject_affinity_score, 3),
            "personal_signal_score": round(personal_signal_score, 3),
            "weekend_count": contact.weekend_count,
            "evening_count": contact.evening_count,
            "weekday_business_count": contact.weekday_business_count,
            "weekend_ratio": round(weekend_ratio, 3),
            "evening_ratio": round(evening_ratio, 3),
            "weekday_business_ratio": round(weekday_business_ratio, 3),
            "off_hours_score": round(off_hours_score, 3),
            "reply_alternations": reply_features["reply_alternations"],
            "median_response_hours_to_you": reply_features["median_response_hours_to_you"],
            "median_response_hours_from_you": reply_features["median_response_hours_from_you"],
            "reply_rhythm_score": round(reply_score, 3),
            "frequency_score": round(frequency_score, 3),
            "longevity_score": round(longevity_score, 3),
            "steadiness_score": round(steadiness_score, 3),
            "recency_score": round(recency_score, 3),
            "directness_score": round(directness_score, 3),
            "depth_score": round(depth_score, 3),
            "explanation": explanation(
                total=total,
                span_days=span_days,
                active_months=active_months,
                mutuality=mutuality,
                direct_ratio=direct_ratio,
                automation_probability=automation_probability,
                subject_scores=subject_scores,
                reply_features=reply_features,
                professional_probability=professional_probability,
                off_hours_score=off_hours_score,
                evidence_profile=evidence_profile,
            ),
        }
        apply_feedback(row, feedback_by_email.get(contact.email))
        rows.append(row)

    rows.sort(
        key=lambda row: (
            float(row["relationship_strength"]),
            int(row["total_count"]),
            str(row["last_seen"]),
        ),
        reverse=True,
    )
    for index, row in enumerate(rows, start=1):
        row["rank"] = index
    return rows


def load_feedback(path: Path) -> dict[str, dict[str, object]]:
    if not path.exists():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    by_email: dict[str, dict[str, object]] = {}
    for person in raw.get("people", []):
        for email in person.get("emails", []):
            normalized = normalize_email(str(email))
            if normalized:
                by_email[normalized] = person
    return by_email


def apply_feedback(row: dict[str, object], feedback: dict[str, object] | None) -> None:
    if not feedback:
        return
    score = float(row["relationship_strength"])
    score += float(feedback.get("score_adjust", 0) or 0)
    if "score_cap" in feedback:
        score = min(score, float(feedback["score_cap"]))
    if "score_floor" in feedback:
        score = max(score, float(feedback["score_floor"]))
    score = round(clamp(score / 100) * 100, 2)
    row["relationship_strength"] = score
    row["personal_closeness_score"] = score
    if "professional_probability" in feedback:
        row["professional_probability"] = round(float(feedback["professional_probability"]), 3)
    if feedback.get("class_override"):
        row["relationship_class"] = str(feedback["class_override"])
    row["feedback_label"] = str(feedback.get("label", ""))
    note = f"User calibration: {row['feedback_label'].replace('_', ' ')}."
    row["explanation"] = f"{note} {row['explanation']}"


def parse_addresses(header: str) -> list[Address]:
    addresses: list[Address] = []
    for name, email in getaddresses([header or ""]):
        normalized = normalize_email(email)
        if not normalized:
            continue
        addresses.append(Address(clean_name(name), normalized))
    return addresses


def normalize_email(email: str) -> str:
    value = email.strip().strip("<>").lower()
    if not value or "@" not in value or not EMAIL_RE.match(value):
        return ""
    return value


def clean_name(name: str) -> str:
    return " ".join((name or "").replace('"', "").split())


def parse_message_datetime(parsed_date: str | None, date_header: str | None) -> datetime | None:
    value = parsed_date or ""
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        try:
            dt = parsedate_to_datetime(date_header or "")
        except (TypeError, ValueError, IndexError, OverflowError):
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def normalize_subject(subject: str) -> str:
    value = subject or ""
    value = SUBJECT_PREFIX_RE.sub("", value)
    value = BRACKET_TAG_RE.sub("", value)
    value = re.sub(r"\s+", " ", value).strip().lower()
    value = re.sub(r"\b(id|ticket|case|ref)[\s:#-]*[a-z0-9-]{4,}\b", "", value)
    value = re.sub(r"\b\d{5,}\b", "", value)
    return value[:240]


def subject_terms(subject: str) -> list[str]:
    normalized = normalize_subject(subject)
    terms = []
    for token in TOKEN_RE.findall(normalized):
        if token in STOPWORDS or len(token) < 3:
            continue
        terms.append(token)
    return terms


def classify_subject(subject: str) -> Counter[str]:
    terms = set(subject_terms(subject))
    counts: Counter[str] = Counter()
    for category, keywords in SUBJECT_KEYWORDS.items():
        counts[category] = len(terms & keywords)
    return counts


def compute_subject_scores(contact: ContactAccumulator) -> dict[str, float]:
    category_total = sum(contact.subject_categories.values()) or 1
    subject_denominator = max(1, contact.messages_with_subject)
    warm = contact.subject_categories["personal_warmth"]
    weak_warmth = weak_warmth_count(contact)
    substantive_warm = max(0.0, warm - weak_warmth * 0.85)
    coordination = contact.subject_categories["coordination"]
    weak_coordination = weak_coordination_count(contact)
    social_coordination = social_coordination_count(contact)
    substantive_coordination = max(0.0, coordination - weak_coordination * 0.75)
    life = contact.subject_categories["life_event"]
    work = contact.subject_categories["work_operational"]
    transactional = contact.subject_categories["transactional"]
    automated = contact.subject_categories["automated"]
    urgency = contact.subject_categories["urgency"]
    professional_service = contact.subject_categories["professional_service"]
    positive = (
        substantive_warm * 1.1
        + social_coordination * 0.85
        + substantive_coordination * 0.25
        + life * 1.35
        + urgency * 0.08
    )
    neutral = work * 0.05
    negative = transactional * 0.75 + automated * 1.0 + professional_service * 1.15 + work * 0.42
    subject_affinity = clamp((positive + neutral) / category_total - negative / category_total + 0.5)
    personal_signal = clamp(
        (substantive_warm * 1.25 + life * 1.6 + social_coordination * 0.7) / subject_denominator
    )
    return {
        "subject_affinity_score": subject_affinity,
        "automated_subject_ratio": automated / category_total,
        "transactional_subject_ratio": transactional / category_total,
        "professional_subject_ratio": (professional_service + work * 0.9) / category_total,
        "personal_subject_ratio": (substantive_warm + social_coordination + life) / category_total,
        "personal_signal_score": personal_signal,
        "weak_warmth_count": weak_warmth,
        "weak_coordination_count": weak_coordination,
        "social_coordination_count": social_coordination,
    }


def weak_warmth_count(contact: ContactAccumulator) -> int:
    return sum(contact.subject_terms.get(term, 0) for term in WEAK_WARMTH_TERMS)


def weak_coordination_count(contact: ContactAccumulator) -> int:
    return sum(contact.subject_terms.get(term, 0) for term in WEAK_COORDINATION_TERMS)


def social_coordination_count(contact: ContactAccumulator) -> int:
    return sum(contact.subject_terms.get(term, 0) for term in SOCIAL_COORDINATION_TERMS)


def compute_evidence_profile(
    total: int,
    active_months: int,
    distinct_subjects: int,
    span_days: int,
    active_month_ratio: float,
    contact: ContactAccumulator,
) -> dict[str, float]:
    count_confidence = clamp(math.log1p(total) / math.log1p(500))
    month_confidence = clamp(active_months / 60)
    subject_confidence = clamp(distinct_subjects / 140)
    duration_confidence = clamp(span_days / (365 * 8))
    evidence_confidence = clamp(
        count_confidence * 0.27
        + month_confidence * 0.32
        + subject_confidence * 0.31
        + duration_confidence * 0.10
    )

    warnings = 0
    warnings += 1 if total < 120 else 0
    warnings += 1 if active_months < 30 else 0
    warnings += 1 if distinct_subjects < 45 else 0
    warnings += 1 if span_days < 365 * 2 else 0

    if warnings >= 3:
        score_cap = 48.0
    elif warnings == 2:
        score_cap = 58.0
    elif warnings == 1:
        score_cap = 68.0
    else:
        score_cap = 100.0

    if active_months <= 4 and distinct_subjects <= 8:
        score_cap = min(score_cap, 40.0)
    elif active_months < 12:
        score_cap = min(score_cap, 50.0)
    elif active_months < 24:
        score_cap = min(score_cap, 62.0)
    if total < 25:
        score_cap = min(score_cap, 38.0)
    elif total < 50:
        score_cap = min(score_cap, 48.0)
    elif total < 100:
        score_cap = min(score_cap, 58.0)
    if distinct_subjects < 12:
        score_cap = min(score_cap, 40.0)
    elif distinct_subjects < 25:
        score_cap = min(score_cap, 52.0)
    elif distinct_subjects < 40:
        score_cap = min(score_cap, 62.0)

    repeated_subject_ratio = (
        contact.subject_roots.most_common(1)[0][1] / max(1, total)
        if contact.subject_roots
        else 0.0
    )
    sparse_long_span = active_month_ratio < 0.16 and span_days > 365 * 3
    burst_penalty = 0.0
    burst_penalty += 0.22 if sparse_long_span else 0.0
    burst_penalty += max(0.0, repeated_subject_ratio - 0.16) * 0.70
    burst_penalty += 0.14 if active_months < 12 and span_days > 365 else 0.0
    burst_penalty = clamp(burst_penalty, 0.0, 0.58)
    if repeated_subject_ratio >= 0.40:
        score_cap = min(score_cap, 42.0)
    elif repeated_subject_ratio >= 0.30:
        score_cap = min(score_cap, 52.0)
    elif repeated_subject_ratio >= 0.22:
        score_cap = min(score_cap, 62.0)

    confidence_multiplier = clamp(0.52 + evidence_confidence * 0.48 - burst_penalty, 0.28, 1.0)
    off_hours_qualification = clamp((evidence_confidence * 1.15) - burst_penalty, 0.0, 1.0)

    return {
        "evidence_confidence": evidence_confidence,
        "score_cap": score_cap,
        "burst_penalty": burst_penalty,
        "confidence_multiplier": confidence_multiplier,
        "off_hours_qualification": off_hours_qualification,
        "repeated_subject_ratio": repeated_subject_ratio,
    }


def compute_reply_features(
    thread_events: dict[str, list[MessageEvent]]
) -> dict[str, float | int | None]:
    to_you: list[float] = []
    from_you: list[float] = []
    alternations = 0
    for events in thread_events.values():
        if len(events) < 2:
            continue
        sorted_events = sorted(events, key=lambda event: event.timestamp)
        previous = sorted_events[0]
        for event in sorted_events[1:]:
            if previous.direction == event.direction:
                previous = event
                continue
            hours = max(0.0, (event.timestamp - previous.timestamp).total_seconds() / 3600)
            if hours <= 24 * 45:
                alternations += 1
                if previous.direction == "outbound" and event.direction == "inbound":
                    to_you.append(hours)
                elif previous.direction == "inbound" and event.direction == "outbound":
                    from_you.append(hours)
            previous = event
    total_pairs = len(to_you) + len(from_you)
    balance = 0.0
    if total_pairs:
        balance = 2 * min(len(to_you), len(from_you)) / total_pairs
    rhythm = clamp((math.log1p(alternations) / math.log1p(50)) * 0.7 + balance * 0.3)
    return {
        "reply_alternations": alternations,
        "median_response_hours_to_you": round(median(to_you), 2) if to_you else None,
        "median_response_hours_from_you": round(median(from_you), 2) if from_you else None,
        "reply_rhythm_score": rhythm,
    }


def compute_automation_probability(
    contact: ContactAccumulator,
    mutuality: float,
    direct_ratio: float,
    large_group_ratio: float,
    subject_scores: dict[str, float],
) -> float:
    local = contact.email.split("@", 1)[0] if "@" in contact.email else contact.email
    local_noise = local in NOISE_LOCAL_PARTS or any(fragment in local for fragment in NOISE_LOCAL_FRAGMENTS)
    one_way = (
        (contact.inbound_count == 0 or contact.outbound_count == 0)
        and contact.inbound_count + contact.outbound_count >= 5
    )
    repeated_subject_ratio = (
        contact.subject_roots.most_common(1)[0][1] / max(1, contact.total_count)
        if contact.subject_roots
        else 0.0
    )
    probability = 0.05
    probability += 0.35 if local_noise else 0.0
    probability += subject_scores["automated_subject_ratio"] * 0.28
    probability += subject_scores["transactional_subject_ratio"] * 0.20
    probability += 0.14 if one_way else 0.0
    probability += max(0.0, repeated_subject_ratio - 0.35) * 0.32
    probability += max(0.0, 0.35 - direct_ratio) * 0.18
    probability += large_group_ratio * 0.16
    probability -= mutuality * 0.22
    probability -= subject_scores["personal_subject_ratio"] * 0.20
    if contact.total_count <= 2:
        probability *= 0.75
    return clamp(probability)


def compute_professional_probability(
    contact: ContactAccumulator,
    subject_scores: dict[str, float],
    direct_ratio: float,
    evidence_profile: dict[str, float],
) -> float:
    repeated_subject_ratio = (
        contact.subject_roots.most_common(1)[0][1] / max(1, contact.total_count)
        if contact.subject_roots
        else 0.0
    )
    weekday_business_ratio = contact.weekday_business_count / max(1, contact.total_count)
    service_ratio = contact.subject_categories["professional_service"] / max(1, contact.total_count)
    work_ratio = contact.subject_categories["work_operational"] / max(1, contact.total_count)
    domain = contact.email.rsplit(".", 1)[-1] if "." in contact.email else ""
    probability = 0.04
    probability += subject_scores["professional_subject_ratio"] * 0.92
    probability += subject_scores["transactional_subject_ratio"] * 0.34
    probability += min(0.45, service_ratio * 2.20)
    probability += min(0.36, work_ratio * 1.35)
    probability += weekday_business_ratio * 0.16
    probability += max(0.0, repeated_subject_ratio - 0.10) * 0.42
    probability += evidence_profile["burst_penalty"] * 0.24
    probability += max(0.0, direct_ratio - 0.65) * 0.08
    probability += 0.18 if domain in PROFESSIONAL_DOMAIN_HINTS else 0.0
    probability -= subject_scores["personal_signal_score"] * 0.18
    probability -= (contact.weekend_count / max(1, contact.total_count)) * 0.08
    return clamp(probability)


def best_display_name(contact: ContactAccumulator) -> str:
    for name, _ in contact.names.most_common():
        if name and "@" not in name:
            return name
    return contact.email


def relationship_class(
    score: float, automation_probability: float, professional_probability: float = 0.0
) -> str:
    if automation_probability >= 0.65:
        return "likely_noise"
    if professional_probability >= 0.62:
        return "professional_service"
    if professional_probability >= 0.48 and score < 62:
        return "professional_service"
    if score >= 76:
        return "close"
    if score >= 56:
        return "warm"
    if score >= 30:
        return "familiar"
    return "thin"


def explanation(
    total: int,
    span_days: int,
    active_months: int,
    mutuality: float,
    direct_ratio: float,
    automation_probability: float,
    subject_scores: dict[str, float],
    reply_features: dict[str, float | int | None],
    professional_probability: float,
    off_hours_score: float,
    evidence_profile: dict[str, float],
) -> str:
    pieces = [
        f"{total} header interactions",
        f"{span_days / 365:.1f} year span",
        f"active in {active_months} months",
    ]
    if mutuality >= 0.65:
        pieces.append("balanced two-way exchange")
    elif mutuality >= 0.25:
        pieces.append("some two-way exchange")
    else:
        pieces.append("mostly one-way")
    if direct_ratio >= 0.65:
        pieces.append("mostly direct")
    elif direct_ratio <= 0.2:
        pieces.append("mostly group or list-like")
    if reply_features["reply_alternations"]:
        pieces.append(f"{reply_features['reply_alternations']} approximate thread alternations")
    if subject_scores["personal_signal_score"] >= 0.18:
        pieces.append("personal subject language")
    if off_hours_score >= 0.55:
        pieces.append("substantial weekend/evening exchange")
    elif off_hours_score <= 0.3:
        pieces.append("mostly weekday business-hours exchange")
    if evidence_profile["score_cap"] < 100:
        pieces.append("limited independent evidence for top-tier closeness")
    if evidence_profile["burst_penalty"] >= 0.18:
        pieces.append("episodic or bursty contact pattern")
    if professional_probability >= 0.55:
        pieces.append("professional/service subject pattern")
    if automation_probability >= 0.65:
        pieces.append("high automation/list probability")
    elif automation_probability <= 0.3:
        pieces.append("low automation probability")
    return "; ".join(pieces) + "."


def months_between(first: datetime, last: datetime) -> int:
    return (last.year - first.year) * 12 + (last.month - first.month)


def normalized_entropy(counter: Counter[str]) -> float:
    total = sum(counter.values())
    if total <= 1 or len(counter) <= 1:
        return 0.0
    entropy = 0.0
    for count in counter.values():
        probability = count / total
        entropy -= probability * math.log(probability)
    return clamp(entropy / math.log(len(counter)))


def top_counter(counter: Counter[str], limit: int) -> list[dict[str, object]]:
    return [{"value": value, "count": count} for value, count in counter.most_common(limit)]


def write_relationships_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys()) if rows else default_relationship_fields()
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_contact_counter_csv(
    path: Path,
    contacts: dict[str, ContactAccumulator],
    column_name: str,
    counter_getter,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["email", "display_name", column_name])
        writer.writeheader()
        for contact in sorted(contacts.values(), key=lambda item: item.total_count, reverse=True):
            writer.writerow(
                {
                    "email": contact.email,
                    "display_name": best_display_name(contact),
                    column_name: json.dumps(top_counter(counter_getter(contact), MAX_TOP_TERMS)),
                }
            )


def write_monthly_activity_csv(path: Path, contacts: dict[str, ContactAccumulator]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "email",
                "display_name",
                "month",
                "total_count",
                "inbound_count",
                "outbound_count",
                "unknown_count",
                "direct_count",
                "group_count",
            ],
        )
        writer.writeheader()
        for contact in sorted(contacts.values(), key=lambda item: item.email):
            for month, counts in sorted(contact.monthly_counts.items()):
                writer.writerow(
                    {
                        "email": contact.email,
                        "display_name": best_display_name(contact),
                        "month": month,
                        "total_count": counts["total"],
                        "inbound_count": counts["inbound"],
                        "outbound_count": counts["outbound"],
                        "unknown_count": counts["unknown"],
                        "direct_count": counts["direct"],
                        "group_count": counts["group"],
                    }
                )


def write_domain_summary_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    domains: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for row in rows:
        domain = str(row["domain"] or "")
        if not domain:
            continue
        bucket = domains[domain]
        bucket["contact_count"] += 1
        bucket["total_interactions"] += int(row["total_count"])
        bucket["relationship_strength_sum"] += float(row["relationship_strength"])
        bucket["max_relationship_strength"] = max(
            bucket["max_relationship_strength"], float(row["relationship_strength"])
        )
        bucket["likely_human_contacts"] += 1 if float(row["automation_probability"]) < 0.45 else 0
        bucket["noise_contacts"] += 1 if float(row["automation_probability"]) >= 0.65 else 0
        bucket["strong_contacts"] += 1 if row["relationship_class"] == "strong" else 0
        bucket["meaningful_contacts"] += 1 if row["relationship_class"] == "meaningful" else 0
    with path.open("w", newline="", encoding="utf-8") as handle:
        fieldnames = [
            "domain",
            "contact_count",
            "total_interactions",
            "avg_relationship_strength",
            "max_relationship_strength",
            "likely_human_contacts",
            "noise_contacts",
            "strong_contacts",
            "meaningful_contacts",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for domain, bucket in sorted(
            domains.items(),
            key=lambda item: (item[1]["total_interactions"], item[1]["max_relationship_strength"]),
            reverse=True,
        ):
            contact_count = int(bucket["contact_count"])
            writer.writerow(
                {
                    "domain": domain,
                    "contact_count": contact_count,
                    "total_interactions": int(bucket["total_interactions"]),
                    "avg_relationship_strength": round(
                        bucket["relationship_strength_sum"] / max(1, contact_count), 2
                    ),
                    "max_relationship_strength": round(bucket["max_relationship_strength"], 2),
                    "likely_human_contacts": int(bucket["likely_human_contacts"]),
                    "noise_contacts": int(bucket["noise_contacts"]),
                    "strong_contacts": int(bucket["strong_contacts"]),
                    "meaningful_contacts": int(bucket["meaningful_contacts"]),
                }
            )


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def default_relationship_fields() -> list[str]:
    return [
        "rank",
        "email",
        "display_name",
        "domain",
        "relationship_strength",
        "personal_closeness_score",
        "operational_intensity_score",
        "relationship_class",
        "feedback_label",
        "automation_probability",
        "professional_probability",
        "evidence_confidence",
        "evidence_score_cap",
        "burst_penalty",
        "off_hours_qualification",
        "qualified_off_hours_score",
        "weak_warmth_count",
        "human_probability",
        "total_count",
        "inbound_count",
        "outbound_count",
        "unknown_count",
        "mutuality",
        "first_seen",
        "last_seen",
        "span_days",
        "active_months",
        "active_years",
        "active_month_ratio",
        "max_gap_days",
        "median_gap_days",
        "direct_count",
        "group_count",
        "direct_ratio",
        "large_group_ratio",
        "distinct_subject_roots",
        "subject_entropy",
        "top_subject_roots",
        "top_subject_terms",
        "personal_warmth_count",
        "coordination_count",
        "life_event_count",
        "work_operational_count",
        "transactional_count",
        "automated_count",
        "urgency_count",
        "professional_service_count",
        "subject_affinity_score",
        "personal_signal_score",
        "weekend_count",
        "evening_count",
        "weekday_business_count",
        "weekend_ratio",
        "evening_ratio",
        "weekday_business_ratio",
        "off_hours_score",
        "reply_alternations",
        "median_response_hours_to_you",
        "median_response_hours_from_you",
        "reply_rhythm_score",
        "frequency_score",
        "longevity_score",
        "steadiness_score",
        "recency_score",
        "directness_score",
        "depth_score",
        "explanation",
    ]


def clamp(value: float, minimum: float = 0.0, maximum: float = 1.0) -> float:
    return max(minimum, min(maximum, value))


def own_email_set(account: str, aliases: Iterable[str]) -> set[str]:
    emails = {normalize_email(account)}
    emails.update(normalize_email(alias) for alias in aliases)
    return {email for email in emails if email}
