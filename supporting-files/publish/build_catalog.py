#!/usr/bin/env python3
"""Build every public-facing list in this repo from one source of truth.

Source of truth:
  <tool>/tool.json                         one per tool folder tracked in this repo
  supporting-files/catalog/external.json   web apps + tools that live in their own repos

Generated (never hand-edit between the markers):
  README.md                                 tool tables between <!-- catalog:start/end -->
  supporting-files/scripts.html             `apps` + `categories` between // catalog:… markers
  supporting-files/catalog/launcher.json    what the local Tk launcher shows (public + private)
  supporting-files/catalog/announcements/   a draft post for every newly public tool

A tool's "status" decides where it appears:
  public   README, amolsarva.com/scripts, launcher
  review   launcher only, plus a line in --check until Amol approves it (then set "public")
  private  launcher only, never published

Usage:
  build_catalog.py            regenerate everything
  build_catalog.py --check    report drift and problems; exit 1 if anything needs attention
"""

from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SF = REPO / "supporting-files"
CATALOG_DIR = SF / "catalog"
STORE = SF / "scripts.html"
README = REPO / "README.md"
LIVE_URL = "https://amolsarva.com/scripts"
GITHUB = "https://github.com/amolsarva/amols-app-store"
NEW_DAYS = 60
NOT_TOOLS = {"supporting-files", "downloads", "__pycache__"}

SECTION_ORDER = [
    "Web apps", "Chrome extensions", "Messages: archive & backup", "Storage & cleanup",
    "Contacts & data", "Messaging campaigns (outreach)", "Keeping the machine healthy",
    "Home & gadgets", "Creative experiments", "Other",
]
SECTION_BLURB = {
    "Web apps": "No download, no install. Click and go.",
    "Chrome extensions": "Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, pick the folder.",
    "Messages: archive & backup": "Keep every conversation, readable by you and your AIs, without Messages hoarding your disk.",
    "Messaging campaigns (outreach)": "Careful one-by-one outreach. Dry-run first, every recipient reviewed. Separate from the backup tools on purpose.",
}
CATEGORIES = [("all", "All"), ("ai", "AI"), ("web", "Web"), ("evidence", "Evidence"), ("mac-tool", "Mac Tools"),
              ("productivity", "Productivity"), ("storage", "Storage"), ("contacts", "Contacts"),
              ("migration", "Migration")]


def load_tools() -> list[dict]:
    tools = []
    for d in sorted(REPO.iterdir()):
        f = d / "tool.json"
        if d.is_dir() and f.exists():
            t = json.loads(f.read_text(encoding="utf-8"))
            t.setdefault("folder", d.name)
            t["_tracked"] = True
            tools.append(t)
    for t in json.loads((CATALOG_DIR / "external.json").read_text(encoding="utf-8")):
        t.setdefault("folder", t.get("id") or t.get("slug"))
        t["_tracked"] = False
        tools.append(t)
    today = dt.date.today()
    for t in tools:
        added = t.get("added")
        t["_new"] = bool(added and (today - dt.date.fromisoformat(added)).days <= NEW_DAYS)
    return tools


def public(tools):
    return [t for t in tools if t.get("status") == "public"]


def link(t) -> str:
    if t.get("liveUrl"):
        return t["liveUrl"]
    if t.get("repoUrl"):
        return t["repoUrl"]
    return f"./{t['folder']}/"


# ── README ───────────────────────────────────────────────────────────────────
def readme_block(tools) -> str:
    pub = public(tools)
    out = []
    new = sorted((t for t in pub if t["_new"]), key=lambda t: t.get("added", ""), reverse=True)
    if new:
        out += ["## 🆕 What's new", ""]
        out += [f"- {t['icon']} **[{t['name']}]({link(t)})** ({t['added']}): {t['summary']}" for t in new]
        out += ["", "---", ""]
    by_section: dict[str, list] = {}
    for t in pub:
        by_section.setdefault(t.get("section", "Other"), []).append(t)
    for sec in SECTION_ORDER + sorted(set(by_section) - set(SECTION_ORDER)):
        items = by_section.get(sec)
        if not items:
            continue
        out += [f"### {sec}", ""]
        if SECTION_BLURB.get(sec):
            out += [SECTION_BLURB[sec], ""]
        out += ["| Tool | What it does |", "|------|--------------|"]
        for t in sorted(items, key=lambda t: (not t.get("featured"), t["name"].lower())):
            badge = " 🆕" if t["_new"] else ""
            out.append(f"| {t['icon']} **[{t['name']}]({link(t)})**{badge} | {t['summary']} |")
        out.append("")
    out.append(f"_{len(pub)} tools · generated from each tool's `tool.json` by "
               "`supporting-files/publish/build_catalog.py`; edit those, not this table._")
    return "\n".join(out)


def replace_between(text: str, start: str, end: str, body: str) -> str:
    i, j = text.find(start), text.find(end)
    if i == -1 or j == -1:
        raise SystemExit(f"markers {start!r}/{end!r} not found")
    return text[: i + len(start)] + "\n" + body + "\n" + text[j:]


# ── Store page ───────────────────────────────────────────────────────────────
def store_apps(tools) -> list[dict]:
    apps = []
    order = sorted(public(tools), key=lambda t: (not t.get("featured"), not t["_new"],
                                                 SECTION_ORDER.index(t.get("section", "Other"))
                                                 if t.get("section") in SECTION_ORDER else 99, t["name"].lower()))
    for t in order:
        a = {"id": t.get("id") or t["folder"], "name": t["name"], "slug": t.get("slug") or t["folder"],
             "icon": t["icon"], "category": t.get("category", "mac-tool"), "tags": t.get("tags", []),
             "color": t.get("color", "#64748b"), "summary": t["summary"], "story": t.get("story") or "",
             "path": t.get("store_path") or t.get("path") or f"{t['folder']}/"}
        for k in ("repoUrl", "liveUrl", "getLabel"):
            if t.get(k):
                a[k] = t[k]
        if t.get("featured"):
            a["featured"] = True
        if t["_new"]:
            a["isNew"] = True
        apps.append(a)
    return apps


def store_block(tools) -> str:
    apps = json.dumps(store_apps(tools), indent=2, ensure_ascii=False)
    cats = json.dumps([list(c) for c in CATEGORIES], ensure_ascii=False)
    return f"    const apps = {apps};\n    const categories = {cats};"


# ── Launcher + announcements ─────────────────────────────────────────────────
def launcher_catalog(tools) -> dict:
    out = {}
    for t in tools:
        if not t["_tracked"] and not (REPO / t["folder"]).is_dir():
            continue
        l = t.get("launcher") or {}
        out[t["folder"]] = {"entry": l.get("entry", "run.sh"), "icon": t["icon"],
                            "short": l.get("short") or t["summary"][:60], "long": l.get("long") or t["summary"],
                            "status": t.get("status")}
    return out


def announcements(tools) -> list[Path]:
    ann_dir = CATALOG_DIR / "announcements"
    ann_dir.mkdir(parents=True, exist_ok=True)
    made = []
    for t in public(tools):
        if not t["_new"]:
            continue
        slug = t.get("slug") or t["folder"]
        existing = list(ann_dir.glob(f"*-{slug}.md"))
        if existing:
            continue
        p = ann_dir / f"{t['added']}-{slug}.md"
        p.write_text(f"""# Draft announcement: {t['name']}

_Status: draft. Edit, then post (LinkedIn / X / newsletter). Delete this line when posted._

**{t['icon']} New in Amol's App Store: {t['name']}**

{t['summary']}

{t.get('story') or ''}

Free, open, runs on your own Mac. Get it: {LIVE_URL} · Source: {link(t) if t.get('repoUrl') else GITHUB + '/tree/main/' + slug}

#mac #opensource #tools
""", encoding="utf-8")
        made.append(p)
    return made


# ── Checks ───────────────────────────────────────────────────────────────────
def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (App Store publish check)"})
    return urllib.request.urlopen(req, timeout=15).read().decode("utf-8", "replace")


def run(cmd, cwd=REPO):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def check(tools) -> int:
    problems = 0

    def say(level, msg):
        nonlocal problems
        print(f"  {level} {msg}")
        if level in ("❌", "⚠️"):
            problems += 1

    print("App Store check")
    folders = {t["folder"] for t in tools}
    for d in sorted(REPO.iterdir()):
        if d.is_dir() and not d.name.startswith((".", "_")) and d.name not in NOT_TOOLS and d.name not in folders:
            say("⚠️", f"{d.name}/ has no tool.json (add one so it shows up everywhere)")
    for t in tools:
        if t.get("status") == "review":
            say("⚠️", f"{t['name']}: waiting for your OK to publish. {t.get('review_note', '')}".rstrip())
        if t.get("status") == "public" and t["_tracked"]:
            if not any((REPO / t["folder"] / n).exists() for n in ("README.md", "INSTALL.md")):
                say("⚠️", f"{t['name']}: public but has no README.md")
            if run(["git", "check-ignore", "-q", t["folder"]]).returncode == 0:
                say("❌", f"{t['name']}: public but its folder is gitignored, so store links 404")
    # Generated files current?
    readme = README.read_text(encoding="utf-8")
    if readme_block(tools) not in readme:
        say("⚠️", "README.md tool tables are out of date (run build_catalog.py)")
    if store_block(tools) not in STORE.read_text(encoding="utf-8"):
        say("⚠️", "scripts.html app list is out of date (run build_catalog.py)")
    # Git: unpushed work, private files about to go public
    ahead = run(["git", "rev-list", "--count", "@{u}..HEAD"]).stdout.strip() or "?"
    dirty = len(run(["git", "status", "--porcelain"]).stdout.splitlines())
    say("ℹ️ ", f"git: {ahead} commit(s) not pushed, {dirty} changed file(s) not committed")
    leaks = private_leaks()
    for leak in leaks:
        say("❌", f"private data would be published: {leak}")
    # Live site
    try:
        live = fetch(LIVE_URL)
        live_names = set(re.findall(r'name: "([^"]+)"', live)) | set(re.findall(r'"name": "([^"]+)"', live))
        want = {a["name"] for a in store_apps(tools)}
        missing, extra = want - live_names, live_names - want
        if missing or extra:
            say("⚠️", f"{LIVE_URL} is stale: missing {sorted(missing) or '-'}; no longer listed {sorted(extra) or '-'} "
                      "(run publish.sh --go)")
        else:
            say("✅", f"{LIVE_URL} matches the catalog ({len(want)} apps)")
    except Exception as e:  # noqa: BLE001
        say("⚠️", f"could not fetch {LIVE_URL}: {e}")
    print(f"\n{'All good.' if not problems else f'{problems} item(s) need attention.'}")
    return 1 if problems else 0


PRIVATE_PATTERNS = [
    (re.compile(r"(^|/)(campaign-archive|rollback-and-name-lists|_notes|logs)/"), "personal data folder"),
    (re.compile(r"(^|/)(config\.json|\.env[^/]*|env\.keys|run-history\.json)$"), "local config/secrets"),
    (re.compile(r"\.(csv|pem|p12|sqlite|db)$"), "data file"),
]
PHONE = re.compile(r"(?<![\w.])\+?1?[ .(-]*[2-9]\d{2}[ .)-]*\d{3}[ .-]*\d{4}(?!\d)")


def private_leaks() -> list[str]:
    """Files that are committed-but-unpushed or staged and look personal."""
    files = set(run(["git", "diff", "--name-only", "@{u}..HEAD"]).stdout.split("\n"))
    files |= set(run(["git", "diff", "--name-only", "--cached"]).stdout.split("\n"))
    files |= set(run(["git", "ls-files", "--others", "--exclude-standard"]).stdout.split("\n"))
    leaks = []
    for f in sorted(x for x in files if x):
        p = REPO / f
        for rx, why in PRIVATE_PATTERNS:
            if rx.search(f):
                if p.exists() or run(["git", "cat-file", "-e", f"HEAD:{f}"]).returncode == 0:
                    leaks.append(f"{f} ({why})")
                break
    return leaks


GI_BEGIN = "# >>> catalog: tools not (yet) public stay Mac-only (generated by build_catalog.py from tool.json status)"
GI_END = "# <<< catalog"


def gitignore_private_tools(tools) -> list[str]:
    """Tools whose status isn't public are ignored, so git-privacy keeps them off GitHub."""
    folders = sorted(t["folder"] for t in tools if t["_tracked"] and t.get("status") != "public")
    gi = REPO / ".gitignore"
    text = gi.read_text(encoding="utf-8")
    if GI_BEGIN in text:
        text = text[:text.index(GI_BEGIN)].rstrip("\n") + "\n" + text[text.index(GI_END) + len(GI_END):].lstrip("\n")
    block = GI_BEGIN + "\n" + "".join(f"/{f}/\n" for f in folders) + GI_END + "\n"
    gi.write_text(text.rstrip("\n") + "\n\n" + block, encoding="utf-8")
    return folders


def main() -> int:
    tools = load_tools()
    if "--check" in sys.argv:
        return check(tools)
    if "--leaks" in sys.argv:  # used by publish.sh as a hard gate
        leaks = private_leaks()
        for leak in leaks:
            print(f"BLOCKED: {leak}")
        return 1 if leaks else 0
    if "--live" in sys.argv:  # used by publish.sh after pushing: does the live page list what we built?
        try:
            live = fetch(f"{LIVE_URL}?v={dt.datetime.now():%s}")
        except Exception:  # noqa: BLE001
            return 1
        want = {a["name"] for a in store_apps(tools)}
        return 0 if all(f'"name": "{n}"' in live or f'name: "{n}"' in live for n in want) else 1
    README.write_text(replace_between(README.read_text(encoding="utf-8"), "<!-- catalog:start -->",
                                      "<!-- catalog:end -->", readme_block(tools)), encoding="utf-8")
    STORE.write_text(replace_between(STORE.read_text(encoding="utf-8"), "// catalog:start",
                                     "    // catalog:end", store_block(tools)), encoding="utf-8")
    (CATALOG_DIR / "launcher.json").write_text(json.dumps(launcher_catalog(tools), indent=2, ensure_ascii=False) + "\n",
                                               encoding="utf-8")
    made = announcements(tools)
    hidden = gitignore_private_tools(tools)
    pub = public(tools)
    print(f"catalog: {len(pub)} public · {sum(t.get('status') == 'review' for t in tools)} awaiting review · "
          f"{sum(t.get('status') == 'private' for t in tools)} private · Mac-only folders: {', '.join(hidden)}")
    for p in made:
        print(f"new announcement draft: {p.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
