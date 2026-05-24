from __future__ import annotations

import csv
import html
import json
import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean, median
from typing import Iterable

from .paths import data_path


DEFAULT_REPORT_PATH = data_path("report/contact_insights_report.html")


@dataclass(frozen=True)
class ReportConfig:
    analysis_dir: Path
    output_path: Path
    title: str = "Contact Relationship Intelligence"
    top_contacts: int = 500
    anonymize_people: bool = False


def build_report(config: ReportConfig) -> dict[str, object]:
    analysis_dir = config.analysis_dir
    relationships = read_csv(analysis_dir / "relationships.csv")
    domains = read_csv(analysis_dir / "domain_summary.csv")
    monthly = read_csv(analysis_dir / "contact_monthly_activity.csv")
    summary = read_json(analysis_dir / "analysis_summary.json")

    payload = build_payload(relationships, domains, monthly, summary, config)
    html_text = render_html(config.title, payload, anonymized=config.anonymize_people)
    config.output_path.parent.mkdir(parents=True, exist_ok=True)
    config.output_path.write_text(html_text, encoding="utf-8")
    return {
        "output_path": str(config.output_path),
        "contacts": len(relationships),
        "domains": len(domains),
        "months": len(payload["timeline"]),
    }


def private_report_path(path: Path) -> Path:
    return path.with_name(f"{path.stem}_PVT{path.suffix}")


def build_payload(
    relationships: list[dict[str, str]],
    domains: list[dict[str, str]],
    monthly: list[dict[str, str]],
    summary: dict[str, object],
    config: ReportConfig,
) -> dict[str, object]:
    clean_rows = [normalize_relationship(row) for row in relationships]
    clean_rows.sort(key=lambda row: row["relationship_strength"], reverse=True)
    feedback_people = load_feedback_people(summary)
    person_rows = group_people(clean_rows, feedback_people)
    person_rows.sort(key=lambda row: row["relationship_strength"], reverse=True)
    top_rows = person_rows[: config.top_contacts]

    timeline = aggregate_timeline(monthly)
    yearly = aggregate_years(timeline)
    tiers = Counter(row["relationship_class"] for row in person_rows)
    strength_buckets = bucket_strengths(person_rows)
    subject_profile = aggregate_subject_profile(clean_rows)
    relationship_mix = relationship_mix_summary(person_rows)
    strongest = select_rows(
        person_rows,
        lambda row: row["automation_probability"] < 0.45
        and row["professional_probability"] < 0.48,
        20,
    )
    balanced = select_rows(
        person_rows,
        lambda row: row["mutuality"] >= 0.75
        and row["direct_ratio"] >= 0.5
        and row["total_count"] >= 25
        and row["automation_probability"] < 0.45
        and row["professional_probability"] < 0.48,
        16,
    )
    durable = select_rows(
        sorted(person_rows, key=lambda row: (row["active_months"], row["span_days"]), reverse=True),
        lambda row: row["automation_probability"] < 0.45
        and row["professional_probability"] < 0.48
        and row["total_count"] >= 20,
        16,
    )
    dormant = select_rows(
        sorted(person_rows, key=lambda row: (row["relationship_strength"], row["span_days"]), reverse=True),
        lambda row: row["automation_probability"] < 0.45
        and row["professional_probability"] < 0.48
        and months_since(row["last_seen"]) >= 18,
        16,
    )
    current = select_rows(
        sorted(person_rows, key=lambda row: (row["recency_score"], row["relationship_strength"]), reverse=True),
        lambda row: row["automation_probability"] < 0.45
        and row["professional_probability"] < 0.48
        and row["total_count"] >= 10,
        16,
    )
    top_domains = [normalize_domain(row) for row in domains[:30]]
    scatter = [
        {
            "name": row["display_name"],
            "email": row["email"],
            "score": row["relationship_strength"],
            "count": row["total_count"],
            "mutuality": row["mutuality"],
            "direct": row["direct_ratio"],
            "months": row["active_months"],
            "class": row["relationship_class"],
        }
        for row in clean_rows[:500]
        if row["automation_probability"] < 0.65 and row["professional_probability"] < 0.70
    ]
    notable = derive_notable_insights(person_rows, timeline, top_domains)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "summary": summary,
        "kpis": {
            "headers_processed": int(summary.get("headers_processed", 0)),
            "contacts_scored": int(summary.get("contacts_scored", len(clean_rows))),
            "people_scored": len(person_rows),
            "likely_humans": int(summary.get("likely_humans", 0)),
            "noise_senders": int(summary.get("noise_senders", 0)),
            "date_start": timeline[0]["month"] if timeline else "",
            "date_end": timeline[-1]["month"] if timeline else "",
            "strong_relationships": tiers.get("inner_circle", 0) + tiers.get("close", 0),
            "meaningful_relationships": tiers.get("warm", 0),
            "median_strength": round(median([row["relationship_strength"] for row in clean_rows]), 2)
            if clean_rows
            else 0,
        },
        "timeline": timeline,
        "yearly": yearly,
        "tiers": dict(tiers),
        "strength_buckets": strength_buckets,
        "subject_profile": subject_profile,
        "relationship_mix": relationship_mix,
        "top_relationships": strongest,
        "balanced": balanced,
        "durable": durable,
        "dormant": dormant,
        "current": current,
        "domains": top_domains,
        "scatter": scatter,
        "notable": notable,
        "top_table": top_rows,
    }
    if config.anonymize_people:
        anonymize_payload(payload)
    return payload


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_relationship(row: dict[str, str]) -> dict[str, object]:
    normalized = dict(row)
    numeric_fields = {
        "relationship_strength": float,
        "personal_closeness_score": float,
        "operational_intensity_score": float,
        "automation_probability": float,
        "professional_probability": float,
        "evidence_confidence": float,
        "evidence_score_cap": float,
        "burst_penalty": float,
        "off_hours_qualification": float,
        "qualified_off_hours_score": float,
        "human_probability": float,
        "mutuality": float,
        "active_month_ratio": float,
        "max_gap_days": float,
        "median_gap_days": float,
        "direct_ratio": float,
        "large_group_ratio": float,
        "subject_entropy": float,
        "subject_affinity_score": float,
        "reply_rhythm_score": float,
        "frequency_score": float,
        "longevity_score": float,
        "steadiness_score": float,
        "recency_score": float,
        "directness_score": float,
        "depth_score": float,
        "personal_signal_score": float,
        "weekend_ratio": float,
        "evening_ratio": float,
        "weekday_business_ratio": float,
        "off_hours_score": float,
    }
    integer_fields = {
        "rank",
        "total_count",
        "inbound_count",
        "outbound_count",
        "unknown_count",
        "span_days",
        "active_months",
        "active_years",
        "direct_count",
        "group_count",
        "distinct_subject_roots",
        "personal_warmth_count",
        "coordination_count",
        "life_event_count",
        "work_operational_count",
        "transactional_count",
        "automated_count",
        "urgency_count",
        "professional_service_count",
        "weak_warmth_count",
        "weekend_count",
        "evening_count",
        "weekday_business_count",
        "reply_alternations",
    }
    for field, caster in numeric_fields.items():
        normalized[field] = safe_cast(row.get(field), caster, 0.0)
    for field in integer_fields:
        normalized[field] = int(safe_cast(row.get(field), float, 0))
    for field in ("top_subject_roots", "top_subject_terms"):
        try:
            normalized[field] = json.loads(str(row.get(field, "[]")))
        except json.JSONDecodeError:
            normalized[field] = []
    return normalized


def load_feedback_people(summary: dict[str, object]) -> dict[str, dict[str, object]]:
    path_text = str(summary.get("feedback_path") or "")
    if not path_text:
        return {}
    path = Path(path_text)
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    people: dict[str, dict[str, object]] = {}
    for person in payload.get("people", []):
        if not isinstance(person, dict):
            continue
        for email in person.get("emails", []):
            people[normalize_email(str(email))] = person
    return people


def group_people(
    rows: list[dict[str, object]],
    feedback_people: dict[str, dict[str, object]],
) -> list[dict[str, object]]:
    groups: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        key = person_group_key(row, feedback_people)
        groups[key].append(row)

    people = [rollup_person(group_rows, feedback_people) for group_rows in groups.values()]
    people.sort(key=lambda row: row["relationship_strength"], reverse=True)
    for index, row in enumerate(people, 1):
        row["rank"] = index
    return people


def person_group_key(row: dict[str, object], feedback_people: dict[str, dict[str, object]]) -> str:
    email = normalize_email(str(row.get("email", "")))
    feedback = feedback_people.get(email)
    if feedback:
        return f"feedback:{normalize_name(str(feedback.get('name', email)))}"

    if is_automated_address(row):
        return f"email:{email}"

    name = normalize_name(str(row.get("display_name", "")))
    if name and not looks_like_email(name):
        return f"name:{name}"

    local = email.split("@", 1)[0] if "@" in email else email
    local = re.sub(r"\+.*$", "", local)
    local = re.sub(r"[^a-z0-9]+", "", local)
    domain = str(row.get("domain", ""))
    if local and len(local) >= 5:
        return f"local:{local}@{domain}"
    return f"email:{email}"


def rollup_person(
    rows: list[dict[str, object]],
    feedback_people: dict[str, dict[str, object]],
) -> dict[str, object]:
    rows = sorted(rows, key=lambda row: row["relationship_strength"], reverse=True)
    best = rows[0]
    total_count = sum_int(rows, "total_count")
    inbound = sum_int(rows, "inbound_count")
    outbound = sum_int(rows, "outbound_count")
    direct = sum_int(rows, "direct_count")
    group = sum_int(rows, "group_count")
    weight = max(total_count, 1)
    feedback = feedback_people.get(normalize_email(str(best.get("email", ""))))

    rolled = dict(best)
    rolled["display_name"] = str(feedback.get("name")) if feedback and feedback.get("name") else best["display_name"]
    rolled["email"] = primary_email(rows)
    rolled["domain"] = primary_domain(rows)
    rolled["rank"] = 0
    rolled["total_count"] = total_count
    rolled["inbound_count"] = inbound
    rolled["outbound_count"] = outbound
    rolled["direct_count"] = direct
    rolled["group_count"] = group
    rolled["active_months"] = max_int(rows, "active_months")
    rolled["active_years"] = max_int(rows, "active_years")
    rolled["span_days"] = max_int(rows, "span_days")
    rolled["first_seen"] = min_text(rows, "first_seen")
    rolled["last_seen"] = max_text(rows, "last_seen")
    rolled["mutuality"] = min(inbound, outbound) / max(inbound, outbound) if max(inbound, outbound) else 0.0
    rolled["direct_ratio"] = direct / max(total_count, 1)
    rolled["large_group_ratio"] = group / max(total_count, 1)
    rolled["automation_probability"] = weighted_mean(rows, "automation_probability", total_count)
    rolled["professional_probability"] = weighted_mean(rows, "professional_probability", total_count)
    rolled["human_probability"] = weighted_mean(rows, "human_probability", total_count)
    for field in (
        "weekend_count",
        "evening_count",
        "weekday_business_count",
        "personal_warmth_count",
        "coordination_count",
        "life_event_count",
        "work_operational_count",
        "transactional_count",
        "automated_count",
        "urgency_count",
        "professional_service_count",
        "reply_alternations",
        "distinct_subject_roots",
    ):
        rolled[field] = sum_int(rows, field)
    rolled["weekend_ratio"] = rolled["weekend_count"] / max(total_count, 1)
    rolled["evening_ratio"] = rolled["evening_count"] / max(total_count, 1)
    rolled["weekday_business_ratio"] = rolled["weekday_business_count"] / max(total_count, 1)
    rolled["off_hours_score"] = weighted_mean(rows, "off_hours_score", total_count)
    rolled["operational_intensity_score"] = max_float(rows, "operational_intensity_score")
    rolled["relationship_strength"] = max_float(rows, "relationship_strength")
    rolled["personal_closeness_score"] = rolled["relationship_strength"]
    rolled["feedback_label"] = best.get("feedback_label", "")
    rolled["email_count"] = len({normalize_email(str(row.get("email", ""))) for row in rows})
    if rolled["email_count"] > 1:
        rolled["explanation"] = (
            f"Person-level rollup across {rolled['email_count']} email addresses. "
            f"Strongest signal: {best.get('explanation', '')}"
        )
    return rolled


def weighted_mean(rows: list[dict[str, object]], field: str, fallback_total: int) -> float:
    total_weight = sum_int(rows, "total_count")
    if total_weight <= 0:
        return sum(float(row.get(field, 0) or 0) for row in rows) / max(len(rows), 1)
    return sum(float(row.get(field, 0) or 0) * int(row.get("total_count", 0) or 0) for row in rows) / total_weight


def sum_int(rows: list[dict[str, object]], field: str) -> int:
    return sum(int(row.get(field, 0) or 0) for row in rows)


def max_int(rows: list[dict[str, object]], field: str) -> int:
    return max((int(row.get(field, 0) or 0) for row in rows), default=0)


def max_float(rows: list[dict[str, object]], field: str) -> float:
    return round(max((float(row.get(field, 0) or 0) for row in rows), default=0.0), 2)


def min_text(rows: list[dict[str, object]], field: str) -> str:
    values = [str(row.get(field, "")) for row in rows if row.get(field)]
    return min(values) if values else ""


def max_text(rows: list[dict[str, object]], field: str) -> str:
    values = [str(row.get(field, "")) for row in rows if row.get(field)]
    return max(values) if values else ""


def primary_email(rows: list[dict[str, object]]) -> str:
    human_rows = [row for row in rows if not is_automated_address(row)]
    candidates = human_rows or rows
    return str(max(candidates, key=lambda row: int(row.get("total_count", 0) or 0)).get("email", ""))


def primary_domain(rows: list[dict[str, object]]) -> str:
    return str(max(rows, key=lambda row: int(row.get("total_count", 0) or 0)).get("domain", ""))


def normalize_email(value: str) -> str:
    return value.strip().lower()


def normalize_name(value: str) -> str:
    value = value.lower().strip()
    value = re.sub(r"\s+on knotable$", "", value)
    value = re.sub(r"\([^)]*\)", "", value)
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return re.sub(r"\s+", " ", value).strip()


def looks_like_email(value: str) -> bool:
    return "@" in value or "." in value and " " not in value


def is_automated_address(row: dict[str, object]) -> bool:
    email = normalize_email(str(row.get("email", "")))
    local = email.split("@", 1)[0] if "@" in email else email
    return (
        float(row.get("automation_probability", 0) or 0) >= 0.55
        or "noreply" in local
        or "no-reply" in local
        or "notification" in local
        or "mailer" in local
    )


def normalize_domain(row: dict[str, str]) -> dict[str, object]:
    return {
        "domain": row.get("domain", ""),
        "contact_count": int(safe_cast(row.get("contact_count"), float, 0)),
        "total_interactions": int(safe_cast(row.get("total_interactions"), float, 0)),
        "avg_relationship_strength": safe_cast(row.get("avg_relationship_strength"), float, 0.0),
        "max_relationship_strength": safe_cast(row.get("max_relationship_strength"), float, 0.0),
        "likely_human_contacts": int(safe_cast(row.get("likely_human_contacts"), float, 0)),
        "noise_contacts": int(safe_cast(row.get("noise_contacts"), float, 0)),
        "strong_contacts": int(safe_cast(row.get("strong_contacts"), float, 0)),
        "meaningful_contacts": int(safe_cast(row.get("meaningful_contacts"), float, 0)),
    }


def safe_cast(value: object, caster, default):
    try:
        if value in (None, ""):
            return default
        return caster(value)
    except (TypeError, ValueError):
        return default


def aggregate_timeline(monthly_rows: list[dict[str, str]]) -> list[dict[str, object]]:
    buckets: dict[str, Counter[str]] = defaultdict(Counter)
    for row in monthly_rows:
        month = row.get("month", "")
        if not month:
            continue
        buckets[month]["total"] += int(safe_cast(row.get("total_count"), float, 0))
        buckets[month]["inbound"] += int(safe_cast(row.get("inbound_count"), float, 0))
        buckets[month]["outbound"] += int(safe_cast(row.get("outbound_count"), float, 0))
        buckets[month]["direct"] += int(safe_cast(row.get("direct_count"), float, 0))
        buckets[month]["group"] += int(safe_cast(row.get("group_count"), float, 0))
        buckets[month]["contacts"] += 1
    return [
        {
            "month": month,
            "total": counts["total"],
            "inbound": counts["inbound"],
            "outbound": counts["outbound"],
            "direct": counts["direct"],
            "group": counts["group"],
            "contacts": counts["contacts"],
        }
        for month, counts in sorted(buckets.items())
    ]


def aggregate_years(timeline: list[dict[str, object]]) -> list[dict[str, object]]:
    buckets: dict[str, Counter[str]] = defaultdict(Counter)
    for row in timeline:
        year = str(row["month"])[:4]
        for key in ("total", "inbound", "outbound", "direct", "group", "contacts"):
            buckets[year][key] += int(row[key])
    return [{"year": year, **dict(counts)} for year, counts in sorted(buckets.items())]


def bucket_strengths(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    labels = [(0, 20), (20, 40), (40, 60), (60, 80), (80, 101)]
    buckets = []
    for start, end in labels:
        count = sum(1 for row in rows if start <= float(row["relationship_strength"]) < end)
        buckets.append({"label": f"{start}-{end if end < 101 else 100}", "count": count})
    return buckets


def aggregate_subject_profile(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    keys = [
        ("personal_warmth_count", "Warmth"),
        ("coordination_count", "Coordination"),
        ("life_event_count", "Life events"),
        ("work_operational_count", "Work"),
        ("professional_service_count", "Professional/service"),
        ("transactional_count", "Transactional"),
        ("automated_count", "Automated"),
        ("urgency_count", "Urgency"),
    ]
    return [{"label": label, "value": sum(int(row[key]) for row in rows)} for key, label in keys]


def relationship_mix_summary(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    return [
        {
            "label": "Balanced",
            "value": sum(
                1
                for row in rows
                if row["mutuality"] >= 0.7 and row["automation_probability"] < 0.45
            ),
        },
        {
            "label": "Mostly inbound",
            "value": sum(
                1
                for row in rows
                if row["inbound_count"] > row["outbound_count"] * 3 and row["automation_probability"] < 0.65
            ),
        },
        {
            "label": "Mostly outbound",
            "value": sum(
                1
                for row in rows
                if row["outbound_count"] > row["inbound_count"] * 3 and row["automation_probability"] < 0.65
            ),
        },
        {
            "label": "Professional/service",
            "value": sum(1 for row in rows if row.get("professional_probability", 0) >= 0.62),
        },
        {
            "label": "Likely automated",
            "value": sum(1 for row in rows if row["automation_probability"] >= 0.65),
        },
    ]


def select_rows(rows: Iterable[dict[str, object]], predicate, limit: int) -> list[dict[str, object]]:
    selected = []
    for row in rows:
        if predicate(row):
            selected.append(report_row(row))
        if len(selected) >= limit:
            break
    return selected


def report_row(row: dict[str, object]) -> dict[str, object]:
    return {
        "rank": row["rank"],
        "name": row["display_name"],
        "email": row["email"],
        "domain": row["domain"],
        "score": row["relationship_strength"],
        "operational": row.get("operational_intensity_score", 0),
        "class": row["relationship_class"],
        "count": row["total_count"],
        "inbound": row["inbound_count"],
        "outbound": row["outbound_count"],
        "mutuality": row["mutuality"],
        "direct": row["direct_ratio"],
        "active_months": row["active_months"],
        "email_count": row.get("email_count", 1),
        "off_hours": row.get("off_hours_score", 0),
        "professional": row.get("professional_probability", 0),
        "feedback_label": row.get("feedback_label", ""),
        "first_seen": short_date(row["first_seen"]),
        "last_seen": short_date(row["last_seen"]),
        "explanation": row["explanation"],
    }


def anonymize_payload(payload: dict[str, object]) -> None:
    for key in ("top_relationships", "balanced", "durable", "dormant", "current"):
        for row in payload.get(key, []):
            if isinstance(row, dict):
                anonymize_report_row(row)
    for index, row in enumerate(payload.get("top_table", []), 1):
        if isinstance(row, dict):
            anonymize_table_row(row, index)
    for index, row in enumerate(payload.get("scatter", []), 1):
        if isinstance(row, dict):
            row["name"] = anonymize_name(str(row.get("name", ""))) or f"C... #{index}"
            row["email"] = anonymize_email(str(row.get("email", "")))
    for row in payload.get("domains", []):
        if isinstance(row, dict):
            row["domain"] = anonymize_domain(str(row.get("domain", "")))
    for row in payload.get("notable", []):
        if isinstance(row, dict):
            row["body"] = scrub_personal_text(str(row.get("body", "")))


def anonymize_report_row(row: dict[str, object]) -> None:
    row["name"] = anonymize_name(str(row.get("name", ""))) or "C..."
    row["email"] = anonymize_email(str(row.get("email", "")))
    row["domain"] = anonymize_domain(str(row.get("domain", "")))
    row["feedback_label"] = "calibrated" if row.get("feedback_label") else ""
    row["explanation"] = "People, email addresses, domains, and subject examples are masked in this PVT version."


def anonymize_table_row(row: dict[str, object], fallback_rank: int) -> None:
    row["display_name"] = anonymize_name(str(row.get("display_name", ""))) or f"C... #{fallback_rank}"
    row["email"] = anonymize_email(str(row.get("email", "")))
    row["domain"] = anonymize_domain(str(row.get("domain", "")))
    row["feedback_label"] = "calibrated" if row.get("feedback_label") else ""
    row["top_subject_roots"] = []
    row["top_subject_terms"] = []
    row["explanation"] = "People, email addresses, domains, and subject examples are masked in this PVT version."


def anonymize_name(value: str) -> str:
    parts = re.findall(r"[A-Za-z0-9]+", value)
    if not parts:
        return ""
    if len(parts) == 1 and "@" in value:
        return mask_word(parts[0], dot_count=4)
    return " ".join(mask_word(part, dot_count=4) for part in parts[:4])


def anonymize_email(value: str) -> str:
    email_match = re.search(r"([A-Za-z0-9._%+\-]+)@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})", value)
    if not email_match:
        parts = re.findall(r"[A-Za-z0-9]+", value)
        return ".".join(mask_word(part, dot_count=3) for part in parts[:2]) or "r..."
    local, domain = email_match.groups()
    local_parts = [part for part in re.split(r"[._%+\-]+", local) if part]
    masked_local = ".".join(mask_word(part, dot_count=3) for part in local_parts) or "r..."
    return f"{masked_local}@{anonymize_domain(domain)}"


def anonymize_domain(value: str) -> str:
    domain = normalize_email(value).split("@")[-1]
    parts = [part for part in domain.split(".") if part]
    if not parts:
        return "d..."
    masked_parts = [
        part.lower() if index == len(parts) - 1 and len(part) <= 3 else mask_word(part, dot_count=5)
        for index, part in enumerate(parts)
    ]
    return ".".join(masked_parts)


def mask_word(value: str, dot_count: int = 3) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9]", "", value)
    if not cleaned:
        return ""
    dots = "." * dot_count
    return f"{cleaned[0]}{dots}"


def scrub_personal_text(value: str) -> str:
    def replace_email(match: re.Match[str]) -> str:
        return anonymize_email(match.group(0))

    text = re.sub(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", replace_email, value)
    text = re.sub(
        r"\b([A-Za-z0-9\-]+\.)+[A-Za-z]{2,}\b",
        lambda match: anonymize_domain(match.group(0)),
        text,
    )
    return text


def derive_notable_insights(
    rows: list[dict[str, object]],
    timeline: list[dict[str, object]],
    domains: list[dict[str, object]],
) -> list[dict[str, str]]:
    humans = [row for row in rows if row["automation_probability"] < 0.45]
    strong = [row for row in humans if row["relationship_strength"] >= 70]
    balanced = [row for row in humans if row["mutuality"] >= 0.75 and row["total_count"] >= 25]
    direct = [row for row in humans if row["direct_ratio"] >= 0.75 and row["total_count"] >= 10]
    recent_months = timeline[-12:]
    prior_months = timeline[-24:-12]
    recent_total = sum(int(row["total"]) for row in recent_months)
    prior_total = sum(int(row["total"]) for row in prior_months)
    change = ((recent_total - prior_total) / prior_total * 100) if prior_total else 0
    top_domain = domains[0] if domains else {"domain": "", "total_interactions": 0}
    return [
        {
            "title": "Relationship core",
            "body": f"{len(strong):,} contacts score as close personal relationships, with {len(balanced):,} showing balanced two-way exchange.",
        },
        {
            "title": "Direct channel",
            "body": f"{len(direct):,} likely-human contacts are mostly direct one-to-one or near-direct exchanges.",
        },
        {
            "title": "Recent tempo",
            "body": f"The last 12 months contain {recent_total:,} header interactions, {change:+.1f}% versus the prior 12 months.",
        },
        {
            "title": "Largest domain",
            "body": f"{top_domain['domain']} is the largest domain by interaction volume with {int(top_domain['total_interactions']):,} interactions.",
        },
    ]


def months_since(date_text: object) -> int:
    dt = parse_dt(str(date_text))
    if dt is None:
        return 999
    now = datetime.now(timezone.utc)
    return (now.year - dt.year) * 12 + (now.month - dt.month)


def short_date(value: object) -> str:
    text = str(value or "")
    return text[:10]


def parse_dt(value: str) -> datetime | None:
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def render_html(title: str, payload: dict[str, object], anonymized: bool = False) -> str:
    data_json = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    safe_title = html.escape(title)
    eyebrow = "PVT anonymized report" if anonymized else "Private local report"
    privacy_note = (
        "This PVT version masks person names, email addresses, personal domains, subject examples, and per-person explanations while preserving aggregate patterns and readable initials."
        if anonymized
        else "A static relationship intelligence report generated from Gmail headers only: From, To, Date, and Subject. It contains personal contact data; publish only after reviewing what you want exposed."
    )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{safe_title}</title>
  <style>
    :root {{
      --ink: #14211f;
      --muted: #5d6b66;
      --line: #dbe4df;
      --paper: #fbfcfa;
      --panel: #ffffff;
      --green: #2e7d64;
      --blue: #315d9f;
      --gold: #b27a2c;
      --coral: #bd5a4a;
      --violet: #7557a5;
      --slate: #34435e;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--paper);
      color: var(--ink);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0;
    }}
    header {{
      padding: 34px 40px 22px;
      border-bottom: 1px solid var(--line);
      background: #f4f7f3;
    }}
    .eyebrow {{
      color: var(--green);
      font-weight: 700;
      text-transform: uppercase;
      font-size: 12px;
    }}
    h1 {{
      margin: 6px 0 8px;
      font-size: clamp(30px, 4vw, 56px);
      line-height: 1.02;
      font-weight: 760;
      letter-spacing: 0;
    }}
    .subhead {{
      color: var(--muted);
      max-width: 980px;
      font-size: 16px;
    }}
    nav {{
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 24px;
    }}
    nav a {{
      color: var(--ink);
      text-decoration: none;
      border: 1px solid var(--line);
      padding: 7px 10px;
      border-radius: 8px;
      background: var(--panel);
      font-size: 13px;
    }}
    main {{ padding: 28px 40px 48px; }}
    section {{ margin: 0 0 34px; }}
    h2 {{ font-size: 22px; margin: 0 0 14px; letter-spacing: 0; }}
    h3 {{ font-size: 15px; margin: 0 0 10px; letter-spacing: 0; }}
    .grid {{ display: grid; gap: 14px; }}
    .kpis {{ grid-template-columns: repeat(4, minmax(0, 1fr)); }}
    .two {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
    .three {{ grid-template-columns: repeat(3, minmax(0, 1fr)); }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      min-width: 0;
    }}
    .metric-label {{ color: var(--muted); font-size: 12px; text-transform: uppercase; font-weight: 700; }}
    .metric-value {{ font-size: 28px; font-weight: 770; margin-top: 5px; }}
    .metric-note {{ color: var(--muted); font-size: 12px; margin-top: 4px; }}
    .chart {{ width: 100%; height: 280px; display: block; overflow: visible; }}
    .chart.tall {{ height: 380px; }}
    .insights {{ grid-template-columns: repeat(4, minmax(0, 1fr)); }}
    .insight-title {{ font-weight: 760; margin-bottom: 6px; }}
    .insight-body {{ color: var(--muted); }}
    .method {{
      display: grid;
      grid-template-columns: minmax(0, 1.2fr) minmax(280px, .8fr);
      gap: 18px;
      align-items: start;
    }}
    .method p {{ margin: 0 0 10px; color: var(--muted); }}
    .method ul {{ margin: 8px 0 0; padding-left: 18px; color: var(--muted); }}
    .method li {{ margin: 5px 0; }}
    .weight-list {{
      display: grid;
      gap: 8px;
    }}
    .weight-item {{
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 10px;
      border-bottom: 1px solid var(--line);
      padding-bottom: 7px;
    }}
    .weight-item strong {{ font-weight: 760; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ text-align: left; border-bottom: 1px solid var(--line); padding: 9px 8px; vertical-align: top; }}
    th {{ font-size: 12px; color: var(--muted); text-transform: uppercase; }}
    td.num, th.num {{ text-align: right; }}
    .pill {{ display: inline-block; padding: 3px 7px; border-radius: 8px; background: #edf3ef; font-size: 12px; }}
    .table-wrap {{ overflow-x: auto; }}
    .small {{ color: var(--muted); font-size: 12px; }}
    .legend {{ display: flex; gap: 12px; flex-wrap: wrap; color: var(--muted); font-size: 12px; margin-top: 8px; }}
    .swatch {{ width: 10px; height: 10px; display: inline-block; border-radius: 2px; margin-right: 5px; }}
    .list {{ display: grid; gap: 8px; }}
    .person-row {{ display: grid; grid-template-columns: 1fr auto; gap: 10px; border-bottom: 1px solid var(--line); padding: 8px 0; }}
    .person-name {{ font-weight: 700; }}
    .person-meta {{ color: var(--muted); font-size: 12px; }}
    .detail-grid {{ display: grid; gap: 10px; grid-template-columns: repeat(2, minmax(0, 1fr)); margin-top: 14px; }}
    .detail-card {{ border: 1px solid var(--line); border-radius: 8px; padding: 12px; background: #fff; }}
    .detail-title {{ display: flex; justify-content: space-between; gap: 10px; font-weight: 760; }}
    .detail-stats {{ display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; margin: 10px 0; color: var(--muted); font-size: 12px; }}
    .detail-stat strong {{ display: block; color: var(--ink); font-size: 14px; }}
    footer {{ color: var(--muted); border-top: 1px solid var(--line); padding: 20px 40px 36px; }}
    @media (max-width: 980px) {{
      header, main, footer {{ padding-left: 20px; padding-right: 20px; }}
      .kpis, .two, .three, .insights {{ grid-template-columns: 1fr; }}
      .method {{ grid-template-columns: 1fr; }}
      .detail-grid {{ grid-template-columns: 1fr; }}
      .chart {{ height: 240px; }}
    }}
  </style>
</head>
<body>
  <header>
    <div class="eyebrow">{html.escape(eyebrow)}</div>
    <h1>{safe_title}</h1>
    <div class="subhead">{html.escape(privacy_note)}</div>
    <nav>
      <a href="#overview">Overview</a>
      <a href="#method">Method</a>
      <a href="#timeline">Timeline</a>
      <a href="#relationships">Relationships</a>
      <a href="#domains">Domains</a>
      <a href="#tables">Data tables</a>
    </nav>
  </header>
  <main>
    <section id="overview">
      <div class="grid kpis" id="kpis"></div>
    </section>
    <section id="method">
      <h2>How This Ranking Was Learned</h2>
      <div class="panel method">
        <div>
          <p>This report is built from mailbox headers only. It never uses email bodies or attachments. Each row starts as a header-derived contact profile: direction, date, directness, subject line features, relationship duration, active months, weekend/evening timing, and whether the contact looks like a person, an automated sender, a service provider, or a professional/institutional relationship.</p>
          <p>The scoring moved through an iterative correction loop. The first version overvalued raw interaction volume and mutual replies. The next version added personal-closeness signals, weekend/evening activity, professional/service penalties, and local calibration for known examples. The current version adds evidence confidence: a contact must have enough independent evidence before it can rank as a truly close relationship.</p>
          <p>The important lesson was that friendship is not just frequency. Strong relationships tend to show durable, varied, direct, reciprocal communication over many months or years. False positives often show a short burst, a single recurring topic, property/service language, school/institutional context, or work/project vocabulary.</p>
          <ul>
            <li>High scores require enough evidence: substantial message count, active months, relationship span, and diverse subject roots.</li>
            <li>Weekend and evening messages help only when the relationship is otherwise sustained and non-service-like.</li>
            <li>Professional, tenant/property, engineering, institutional, transactional, and automated patterns are pushed away from the personal-closeness ranking.</li>
            <li>Generic warmth words such as hello, thanks, and checking in are weak evidence unless paired with richer personal/life/social signals.</li>
            <li>User feedback is treated as calibration data for cases headers cannot infer, such as family obligation, dormant friendship, business-friend overlap, or known inner-circle relationships.</li>
          </ul>
        </div>
        <div>
          <h3>Highest-Weight Positive Signals</h3>
          <div class="weight-list">
            <div class="weight-item"><strong>Evidence confidence</strong><span>gatekeeper</span></div>
            <div class="weight-item"><strong>Subject diversity</strong><span>high</span></div>
            <div class="weight-item"><strong>Active months</strong><span>high</span></div>
            <div class="weight-item"><strong>Long relationship span</strong><span>high</span></div>
            <div class="weight-item"><strong>Balanced two-way exchange</strong><span>high</span></div>
            <div class="weight-item"><strong>Direct one-to-one exchange</strong><span>medium-high</span></div>
            <div class="weight-item"><strong>Personal/life/social subject language</strong><span>medium-high</span></div>
            <div class="weight-item"><strong>Qualified weekend/evening exchange</strong><span>medium</span></div>
          </div>
          <h3 style="margin-top:16px">Strongest Negative Signals</h3>
          <div class="weight-list">
            <div class="weight-item"><strong>Service/property language</strong><span>very high</span></div>
            <div class="weight-item"><strong>Work/project vocabulary</strong><span>high</span></div>
            <div class="weight-item"><strong>Short burst pattern</strong><span>high</span></div>
            <div class="weight-item"><strong>Low subject diversity</strong><span>high</span></div>
            <div class="weight-item"><strong>Automated/list behavior</strong><span>very high</span></div>
          </div>
        </div>
      </div>
    </section>
    <section>
      <h2>What Stands Out</h2>
      <div class="grid insights" id="insights"></div>
    </section>
    <section id="timeline">
      <h2>Communication Timeline</h2>
      <div class="grid two">
        <div class="panel">
          <h3>Monthly interaction volume</h3>
          <svg class="chart tall" id="timelineChart" role="img"></svg>
          <div class="legend"><span><i class="swatch" style="background: var(--blue)"></i>Inbound</span><span><i class="swatch" style="background: var(--green)"></i>Outbound</span></div>
        </div>
        <div class="panel">
          <h3>Yearly direct vs group pattern</h3>
          <svg class="chart tall" id="yearChart" role="img"></svg>
          <div class="legend"><span><i class="swatch" style="background: var(--gold)"></i>Direct</span><span><i class="swatch" style="background: var(--slate)"></i>Group</span></div>
        </div>
      </div>
    </section>
    <section id="relationships">
      <h2>Relationship Structure</h2>
      <div class="grid three">
        <div class="panel">
          <h3>Relationship classes</h3>
          <svg class="chart" id="tierChart" role="img"></svg>
        </div>
        <div class="panel">
          <h3>Personal closeness distribution</h3>
          <svg class="chart" id="strengthChart" role="img"></svg>
        </div>
        <div class="panel">
          <h3>Subject-language profile</h3>
          <svg class="chart" id="subjectChart" role="img"></svg>
        </div>
      </div>
      <div class="grid two" style="margin-top:14px">
        <div class="panel">
          <h3>Personal closeness vs volume</h3>
          <svg class="chart tall" id="scatterChart" role="img"></svg>
          <div class="small">Top 500 non-noise contacts. Bubble size reflects active months.</div>
        </div>
        <div class="panel">
          <h3>Most balanced direct relationships</h3>
          <div class="list" id="balancedList"></div>
        </div>
      </div>
    </section>
    <section id="domains">
      <h2>Domains and Organizations</h2>
      <div class="grid two">
        <div class="panel">
          <h3>Top domains by interaction volume</h3>
          <svg class="chart tall" id="domainChart" role="img"></svg>
        </div>
        <div class="panel">
          <h3>Long-running relationships</h3>
          <div class="list" id="durableList"></div>
        </div>
      </div>
    </section>
    <section>
      <h2>Relationship Cohorts</h2>
      <div class="grid three">
        <div class="panel"><h3>Strongest relationships</h3><div class="list" id="strongList"></div></div>
        <div class="panel"><h3>Recently active</h3><div class="list" id="currentList"></div></div>
        <div class="panel"><h3>Dormant but important</h3><div class="list" id="dormantList"></div></div>
      </div>
    </section>
    <section id="tables">
      <h2>Top Relationship Rows</h2>
      <div class="panel table-wrap">
        <table id="topTable"></table>
      </div>
      <h2 style="margin-top:28px">Top 500 Contact Detail</h2>
      <div class="detail-grid" id="top500Details"></div>
    </section>
  </main>
  <footer>
    Generated <span id="generatedAt"></span>. Static report: no external scripts, no remote assets.
  </footer>
  <script>
    const DATA = {data_json};
  </script>
  <script>
    const palette = ["#315d9f", "#2e7d64", "#b27a2c", "#bd5a4a", "#7557a5", "#34435e"];
    const fmt = new Intl.NumberFormat("en-US");
    const pct = value => `${{Math.round(value * 100)}}%`;
    const $ = id => document.getElementById(id);

    function init() {{
      renderKpis();
      renderInsights();
      renderTimeline();
      renderYearChart();
      renderTierChart();
      renderStrengthChart();
      renderSubjectChart();
      renderScatter();
      renderDomainChart();
      renderPersonList("balancedList", DATA.balanced);
      renderPersonList("durableList", DATA.durable);
      renderPersonList("strongList", DATA.top_relationships.slice(0, 10));
      renderPersonList("currentList", DATA.current.slice(0, 10));
      renderPersonList("dormantList", DATA.dormant.slice(0, 10));
      renderTopTable();
      renderTop500Details();
      $("generatedAt").textContent = DATA.generated_at;
    }}

    function renderKpis() {{
      const k = DATA.kpis;
      const items = [
        ["Archived headers", fmt.format(k.headers_processed), `${{k.date_start}} to ${{k.date_end}}`],
        ["People scored", fmt.format(k.people_scored), `${{fmt.format(k.contacts_scored)}} email rows`],
        ["Close personal ties", fmt.format(k.strong_relationships), `${{fmt.format(k.meaningful_relationships)}} warm`],
        ["Median score", k.median_strength, `${{fmt.format(k.noise_senders)}} likely automated/noise`],
      ];
      $("kpis").innerHTML = items.map(([label, value, note]) => `<div class="panel"><div class="metric-label">${{esc(label)}}</div><div class="metric-value">${{esc(value)}}</div><div class="metric-note">${{esc(note)}}</div></div>`).join("");
    }}

    function renderInsights() {{
      $("insights").innerHTML = DATA.notable.map(item => `<div class="panel"><div class="insight-title">${{esc(item.title)}}</div><div class="insight-body">${{esc(item.body)}}</div></div>`).join("");
    }}

    function renderTimeline() {{
      const data = DATA.timeline;
      drawStackedBars("timelineChart", data, ["inbound", "outbound"], ["#315d9f", "#2e7d64"], d => d.month.slice(2));
    }}

    function renderYearChart() {{
      drawStackedBars("yearChart", DATA.yearly, ["direct", "group"], ["#b27a2c", "#34435e"], d => d.year);
    }}

    function renderTierChart() {{
      const data = Object.entries(DATA.tiers).map(([label, value]) => ({{ label, value }}));
      drawDonut("tierChart", data);
    }}

    function renderStrengthChart() {{
      drawBars("strengthChart", DATA.strength_buckets, "label", "count", "#2e7d64");
    }}

    function renderSubjectChart() {{
      drawBars("subjectChart", DATA.subject_profile, "label", "value", "#7557a5");
    }}

    function renderDomainChart() {{
      drawBars("domainChart", DATA.domains.slice(0, 18), "domain", "total_interactions", "#315d9f", true);
    }}

    function renderScatter() {{
      const svg = $("scatterChart");
      const w = svg.clientWidth || 700, h = svg.clientHeight || 380;
      const pad = {{ l: 48, r: 16, t: 18, b: 40 }};
      const data = DATA.scatter;
      const maxCount = Math.max(...data.map(d => Math.log10(d.count + 1)), 1);
      const maxMonths = Math.max(...data.map(d => d.months), 1);
      svg.setAttribute("viewBox", `0 0 ${{w}} ${{h}}`);
      const x = d => pad.l + (Math.log10(d.count + 1) / maxCount) * (w - pad.l - pad.r);
      const y = d => pad.t + (1 - d.score / 100) * (h - pad.t - pad.b);
      const r = d => 2.5 + Math.sqrt(d.months / maxMonths) * 8;
      const axes = scoreTicks(w, h, pad) + `<line x1="${{pad.l}}" y1="${{h-pad.b}}" x2="${{w-pad.r}}" y2="${{h-pad.b}}" stroke="#9aa7a2"/><line x1="${{pad.l}}" y1="${{pad.t}}" x2="${{pad.l}}" y2="${{h-pad.b}}" stroke="#9aa7a2"/><text x="${{pad.l}}" y="${{h-10}}" fill="#5d6b66" font-size="11">volume, log scale</text><text x="8" y="${{pad.t-2}}" fill="#5d6b66" font-size="11">score</text>`;
      const dots = data.map(d => `<circle cx="${{x(d).toFixed(1)}}" cy="${{y(d).toFixed(1)}}" r="${{r(d).toFixed(1)}}" fill="${{["inner_circle","close"].includes(d.class) ? "#2e7d64" : "#315d9f"}}" opacity="0.42"><title>${{esc(d.name)}} — score ${{d.score}}, ${{fmt.format(d.count)}} interactions</title></circle>`).join("");
      svg.innerHTML = axes + dots;
    }}

    function drawStackedBars(id, data, keys, colors, labelFn) {{
      const svg = $(id);
      const w = svg.clientWidth || 700, h = svg.clientHeight || 380;
      const pad = {{ l: 44, r: 12, t: 16, b: 38 }};
      const max = Math.max(...data.map(d => keys.reduce((sum, key) => sum + Number(d[key] || 0), 0)), 1);
      const bw = Math.max(2, (w - pad.l - pad.r) / data.length * 0.76);
      svg.setAttribute("viewBox", `0 0 ${{w}} ${{h}}`);
      let parts = valueTicks(w, h, pad, max) + `<line x1="${{pad.l}}" y1="${{h-pad.b}}" x2="${{w-pad.r}}" y2="${{h-pad.b}}" stroke="#9aa7a2"/>`;
      data.forEach((d, i) => {{
        const x = pad.l + i * ((w - pad.l - pad.r) / data.length);
        let yBase = h - pad.b;
        keys.forEach((key, ki) => {{
          const bh = Number(d[key] || 0) / max * (h - pad.t - pad.b);
          yBase -= bh;
          parts += `<rect x="${{x.toFixed(1)}}" y="${{yBase.toFixed(1)}}" width="${{bw.toFixed(1)}}" height="${{Math.max(0,bh).toFixed(1)}}" fill="${{colors[ki]}}" opacity="0.86"><title>${{esc(labelFn(d))}} ${{key}}: ${{fmt.format(d[key] || 0)}}</title></rect>`;
        }});
        if (i % Math.ceil(data.length / 8) === 0) parts += `<text x="${{x.toFixed(1)}}" y="${{h-14}}" font-size="10" fill="#5d6b66" transform="rotate(45 ${{x.toFixed(1)}} ${{h-14}})">${{esc(labelFn(d))}}</text>`;
      }});
      svg.innerHTML = parts;
    }}

    function drawBars(id, data, labelKey, valueKey, color, horizontal=false) {{
      const svg = $(id);
      const w = svg.clientWidth || 600, h = svg.clientHeight || 280;
      const pad = horizontal ? {{ l: 125, r: 16, t: 12, b: 18 }} : {{ l: 42, r: 10, t: 12, b: 48 }};
      const max = Math.max(...data.map(d => Number(d[valueKey] || 0)), 1);
      svg.setAttribute("viewBox", `0 0 ${{w}} ${{h}}`);
      let parts = "";
      if (horizontal) {{
        const rowH = (h - pad.t - pad.b) / data.length;
        data.forEach((d, i) => {{
          const y = pad.t + i * rowH;
          const bw = Number(d[valueKey] || 0) / max * (w - pad.l - pad.r);
          parts += `<text x="6" y="${{(y + rowH * .62).toFixed(1)}}" font-size="11" fill="#34435e">${{esc(shorten(d[labelKey], 18))}}</text><rect x="${{pad.l}}" y="${{(y+2).toFixed(1)}}" width="${{bw.toFixed(1)}}" height="${{Math.max(2,rowH-4).toFixed(1)}}" fill="${{color}}" opacity="0.84"><title>${{esc(d[labelKey])}}: ${{fmt.format(d[valueKey])}}</title></rect>`;
        }});
      }} else {{
        parts += valueTicks(w, h, pad, max);
        const bw = (w - pad.l - pad.r) / data.length * 0.62;
        data.forEach((d, i) => {{
          const x = pad.l + i * ((w - pad.l - pad.r) / data.length);
          const bh = Number(d[valueKey] || 0) / max * (h - pad.t - pad.b);
          const y = h - pad.b - bh;
          parts += `<rect x="${{x.toFixed(1)}}" y="${{y.toFixed(1)}}" width="${{bw.toFixed(1)}}" height="${{bh.toFixed(1)}}" fill="${{color}}" opacity="0.86"><title>${{esc(d[labelKey])}}: ${{fmt.format(d[valueKey])}}</title></rect><text x="${{x.toFixed(1)}}" y="${{h-15}}" font-size="10" fill="#5d6b66" transform="rotate(45 ${{x.toFixed(1)}} ${{h-15}})">${{esc(shorten(d[labelKey], 13))}}</text>`;
        }});
      }}
      svg.innerHTML = parts;
    }}

    function drawDonut(id, data) {{
      const svg = $(id);
      const w = svg.clientWidth || 360, h = svg.clientHeight || 280;
      const cx = w * 0.45, cy = h * 0.52, r = Math.min(w, h) * 0.32, inner = r * 0.58;
      const total = data.reduce((sum, d) => sum + d.value, 0) || 1;
      let angle = -Math.PI / 2, parts = "";
      data.forEach((d, i) => {{
        const next = angle + (d.value / total) * Math.PI * 2;
        parts += `<path d="${{arcPath(cx, cy, r, inner, angle, next)}}" fill="${{palette[i % palette.length]}}" opacity="0.9"><title>${{esc(d.label)}}: ${{fmt.format(d.value)}}</title></path>`;
        angle = next;
      }});
      parts += data.map((d, i) => `<text x="${{w * .73}}" y="${{38 + i * 18}}" font-size="11" fill="#34435e"><tspan fill="${{palette[i % palette.length]}}">■</tspan> ${{esc(d.label)}} ${{fmt.format(d.value)}}</text>`).join("");
      svg.setAttribute("viewBox", `0 0 ${{w}} ${{h}}`);
      svg.innerHTML = parts;
    }}

    function arcPath(cx, cy, r, inner, a0, a1) {{
      const large = a1 - a0 > Math.PI ? 1 : 0;
      const p0 = polar(cx, cy, r, a0), p1 = polar(cx, cy, r, a1), p2 = polar(cx, cy, inner, a1), p3 = polar(cx, cy, inner, a0);
      return `M ${{p0.x}} ${{p0.y}} A ${{r}} ${{r}} 0 ${{large}} 1 ${{p1.x}} ${{p1.y}} L ${{p2.x}} ${{p2.y}} A ${{inner}} ${{inner}} 0 ${{large}} 0 ${{p3.x}} ${{p3.y}} Z`;
    }}

    function polar(cx, cy, r, a) {{ return {{ x: (cx + Math.cos(a) * r).toFixed(2), y: (cy + Math.sin(a) * r).toFixed(2) }}; }}

    function renderPersonList(id, rows) {{
      $(id).innerHTML = rows.map(row => `<div class="person-row"><div><div class="person-name">${{esc(row.name)}}</div><div class="person-meta">${{esc(row.email)}} · ${{fmt.format(row.count)}} interactions · ${{row.active_months}} active months${{row.email_count > 1 ? " · " + row.email_count + " emails" : ""}}</div></div><div><span class="pill">${{row.score}}</span></div></div>`).join("");
    }}

    function renderTopTable() {{
      const rows = DATA.top_table.slice(0, 500);
      const head = ["Rank", "Name", "Primary email", "Emails", "Closeness", "Operational", "Class", "Feedback", "Count", "Mutuality", "Off-hours", "Professional"];
      const body = rows.map(row => `<tr><td class="num">${{row.rank}}</td><td>${{esc(row.display_name)}}</td><td>${{esc(row.email)}}</td><td class="num">${{row.email_count || 1}}</td><td class="num">${{row.relationship_strength}}</td><td class="num">${{row.operational_intensity_score}}</td><td>${{esc(row.relationship_class)}}</td><td>${{esc(row.feedback_label || "")}}</td><td class="num">${{fmt.format(row.total_count)}}</td><td class="num">${{pct(row.mutuality)}}</td><td class="num">${{pct(row.off_hours_score)}}</td><td class="num">${{pct(row.professional_probability)}}</td></tr>`).join("");
      $("topTable").innerHTML = `<thead><tr>${{head.map(h => `<th${{["Rank","Closeness","Operational","Count","Mutuality","Off-hours","Professional"].includes(h) ? ' class="num"' : ""}}>${{esc(h)}}</th>`).join("")}}</tr></thead><tbody>${{body}}</tbody>`;
    }}

    function renderTop500Details() {{
      $("top500Details").innerHTML = DATA.top_table.slice(0, 500).map(row => `
        <div class="detail-card">
          <div class="detail-title"><span>#${{row.rank}} ${{esc(row.display_name)}}</span><span class="pill">${{row.relationship_strength}}</span></div>
          <div class="person-meta">${{esc(row.email)}} · ${{esc(row.domain)}} · ${{esc(row.relationship_class)}}${{row.email_count > 1 ? " · " + row.email_count + " emails" : ""}}${{row.feedback_label ? " · " + esc(row.feedback_label) : ""}}</div>
          <div class="detail-stats">
            <div class="detail-stat"><strong>${{fmt.format(row.total_count)}}</strong>messages</div>
            <div class="detail-stat"><strong>${{row.active_months}}</strong>active months</div>
            <div class="detail-stat"><strong>${{pct(row.off_hours_score)}}</strong>off-hours</div>
            <div class="detail-stat"><strong>${{pct(row.professional_probability)}}</strong>professional</div>
          </div>
          <div class="small">${{esc(row.explanation)}}</div>
        </div>`).join("");
    }}

    function valueTicks(w, h, pad, max) {{
      let parts = "";
      for (let i = 0; i <= 4; i++) {{
        const value = Math.round(max * i / 4);
        const y = h - pad.b - (value / max) * (h - pad.t - pad.b);
        parts += `<line x1="${{pad.l}}" y1="${{y.toFixed(1)}}" x2="${{w-pad.r}}" y2="${{y.toFixed(1)}}" stroke="#edf1ee"/><text x="5" y="${{(y+4).toFixed(1)}}" font-size="10" fill="#5d6b66">${{compact(value)}}</text>`;
      }}
      return parts;
    }}

    function scoreTicks(w, h, pad) {{
      return [0,25,50,75,100].map(value => {{
        const y = pad.t + (1 - value / 100) * (h - pad.t - pad.b);
        return `<line x1="${{pad.l}}" y1="${{y.toFixed(1)}}" x2="${{w-pad.r}}" y2="${{y.toFixed(1)}}" stroke="#edf1ee"/><text x="8" y="${{(y+4).toFixed(1)}}" fill="#5d6b66" font-size="11">${{value}}</text>`;
      }}).join("");
    }}

    function esc(value) {{
      return String(value ?? "").replace(/[&<>"']/g, ch => ({{"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}}[ch]));
    }}
    function compact(value) {{ return value >= 1000 ? `${{Math.round(value/1000)}}k` : String(value); }}
    function shorten(value, n) {{ const s = String(value || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s; }}
    init();
  </script>
</body>
</html>
"""
