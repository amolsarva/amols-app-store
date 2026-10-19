#!/usr/bin/env python3
"""Everything that depends on mac-scripts, and whether it is current.

Source of truth: two optional lists in each <tool>/tool.json (and in catalog/external.json for
tools that live in their own repos):

  "installs":  copies of the code that live OUTSIDE this folder on a Mac and go stale silently when
               the source changes: LaunchAgents running a copy in ~/bin or Application Support,
               .app bundles built into ~/Applications or ~/Library/Caches, git hooks …
     { "id": "cpu-guard-agent",
       "what": "LaunchAgent com.amol.cpu-guard running ~/bin/cpu_guard.py",
       "present": ["agent:com.amol.cpu-guard"],      # how to tell it is installed on THIS Mac
                                                      # (agent:<label> | path:<~/path>), any one
       "sources": ["cpu_guard.py", "cpu-guard-install.sh"],   # relative to the tool folder
       "update": "cpu-guard-install.sh",             # re-install command, relative to the tool folder
       "auto": true,                                 # false = needs a human (sudo, privacy re-grant…)
       "first_run": "record",                        # optional: first time seen on a Mac, trust the
                                                      # installed copy instead of rebuilding it (apps whose
                                                      # rebuild resets privacy permissions)
       "note": "…" }

  "artifacts": files built from the source and PUBLISHED (amolsarva.com downloads …)
     { "id": "backstage-dmg",
       "sources": ["Sources", "Package.swift", "build.sh"],
       "build": "build.sh --dmg",
       "outputs": ["dist/Backstage-*.dmg", "dist/latest.json"],   # globs, relative to the tool folder
       "site": "downloads/backstage/" }              # where they go in the amolsarva.com repo

Usage (all read-only unless they say otherwise):
  deps.py status              everything: installs on this Mac, artifacts, site copies, nested repos, git
  deps.py check               exit 1 if anything on THIS Mac is stale (Backstage New Mac setup uses it)
  deps.py published           exit 1 if anything is waiting to be published (unpushed, stale artifacts)
  deps.py sync [--dry-run]    re-install stale installs on this Mac (auto ones; prints the manual ones)
  deps.py record [ID…]        mark installs as current without re-installing (after a manual install)
  deps.py artifacts [--force] rebuild stale artifacts and copy them into the website repo
  deps.py lint                registrations (Backstage, launcher, tool.json) that point at missing files
  deps.py json                machine-readable status

State: per Mac → ~/Library/Application Support/mac-scripts/installs.json
       shared  → supporting-files/publish/.release-state.json (git-ignored; iCloud syncs it)
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SITE = Path(os.environ.get("SITE_REPO", REPO.parent / "amolsarva.com"))
MAC = platform.system() == "Darwin"
HOME = Path.home()
INSTALL_STATE = HOME / "Library/Application Support/mac-scripts/installs.json"
SHARED_STATE = REPO / "supporting-files/publish/.release-state.json"
SKIP = {".DS_Store", "__pycache__", ".build", "node_modules", ".venv", "dist", "build_tmp", ".git"}
NESTED_REPOS = ["screenshot-mover", "imessage-cleanup"]


# ── loading ──────────────────────────────────────────────────────────────────
def tools() -> list[dict]:
    out = []
    for d in sorted(REPO.iterdir()):
        f = d / "tool.json"
        if d.is_dir() and f.exists():
            t = json.loads(f.read_text(encoding="utf-8"))
            t["_dir"] = d
            out.append(t)
    ext = REPO / "supporting-files/catalog/external.json"
    for t in json.loads(ext.read_text(encoding="utf-8")):
        folder = t.get("folder") or t.get("id") or t.get("slug")
        if folder and (REPO / folder).is_dir() and (t.get("installs") or t.get("artifacts")):
            t["_dir"] = REPO / folder
            out.append(t)
    return out


def entries(kind: str):
    for t in tools():
        for e in t.get(kind) or []:
            yield t, e


# ── hashing ──────────────────────────────────────────────────────────────────
def source_hash(base: Path, sources: list[str]) -> str:
    h = hashlib.sha256()
    for s in sorted(sources):
        paths = sorted(glob.glob(str(base / s))) or [str(base / s)]
        for p in map(Path, paths):
            files = [p] if p.is_file() else sorted(x for x in p.rglob("*") if x.is_file()) if p.is_dir() else []
            for f in files:
                if any(part in SKIP for part in f.relative_to(base).parts):
                    continue
                h.update(str(f.relative_to(base)).encode())
                try:
                    h.update(f.read_bytes())
                except OSError:
                    h.update(b"<unreadable>")
            if not files:
                h.update(f"<missing {s}>".encode())
    return h.hexdigest()[:16]


def load(p: Path) -> dict:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def save(p: Path, data: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(p)


# ── installs ─────────────────────────────────────────────────────────────────
def present(e: dict) -> bool | None:
    """True/False on a Mac; None where it can't be known (Linux sandbox)."""
    checks = e.get("present") or []
    if isinstance(checks, str):
        checks = [checks]
    for c in checks:
        kind, _, val = c.partition(":")
        if kind == "path":
            if Path(os.path.expanduser(val)).exists():
                return True
        elif kind == "agent":
            if not MAC:
                return None
            r = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{val}"], capture_output=True)
            if r.returncode == 0:
                return True
    return False if MAC or any(c.startswith("path:") for c in checks) else None


def install_rows() -> list[dict]:
    state = load(INSTALL_STATE)
    rows, changed = [], False
    for t, e in entries("installs"):
        cur = source_hash(t["_dir"], e.get("sources") or [])
        p = present(e)
        rec = (state.get(e["id"]) or {}).get("hash")
        if p is None:
            st = "unknown (not on a Mac)"
        elif not p:
            st = "not installed here"
        elif rec == cur:
            st = "current"
        elif rec is None and e.get("first_run") == "record":
            st = "current (first sight: recorded, not rebuilt)"
            state[e["id"]] = {"hash": cur, "at": time.strftime("%Y-%m-%d %H:%M"), "recorded": True}
            changed = True
        elif rec is None:
            st = "stale (never verified on this Mac)"
        else:
            st = "stale (source changed)"
        rows.append({"tool": t.get("name") or t["_dir"].name, "dir": t["_dir"], "entry": e, "hash": cur,
                     "status": st, "stale": st.startswith("stale")})
    if changed and MAC:
        save(INSTALL_STATE, state)
    return rows


def run_cmd(base: Path, cmd: str, log_prefix: str = "") -> int:
    parts = shlex.split(cmd)
    script = base / parts[0]
    if not script.exists():
        print(f"  ✗ {log_prefix}{script} not found")
        return 127
    first = script.read_text(encoding="utf-8", errors="replace").splitlines()[:1]
    interp = shlex.split(first[0][2:]) if first and first[0].startswith("#!") else ["/bin/bash"]
    if interp[:1] == ["/usr/bin/env"]:
        interp = interp[1:]
    if interp and interp[0] in ("python3", "python") or (interp and interp[0].endswith("python3")):
        interp = [sys.executable]
    env = dict(os.environ, PATH="/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin"),
               HOMEBREW_NO_AUTO_UPDATE="1", MAC_SCRIPTS_NONINTERACTIVE="1")
    print(f"  $ {' '.join(interp)} {script.relative_to(REPO)} {' '.join(parts[1:])}".rstrip(), flush=True)
    return subprocess.run(interp + [str(script)] + parts[1:], cwd=base, env=env, stdin=subprocess.DEVNULL).returncode


def cmd_sync(dry: bool) -> int:
    state = load(INSTALL_STATE)
    rc = 0
    for r in install_rows():
        e = r["entry"]
        if not r["stale"]:
            continue
        if not e.get("auto", True):
            print(f"  ⚠️  {e['id']}: {r['status']} — needs you: run {r['dir'].name}/{e['update']}"
                  + (f" ({e['note']})" if e.get("note") else ""))
            rc = 1
            continue
        print(f"→ {e['id']}: {r['status']}")
        if dry:
            continue
        code = run_cmd(r["dir"], e["update"])
        if code == 0:
            state[e["id"]] = {"hash": r["hash"], "at": time.strftime("%Y-%m-%d %H:%M")}
            save(INSTALL_STATE, state)
            print(f"  ✓ {e['id']} re-installed")
        else:
            print(f"  ✗ {e['id']} update failed (exit {code})")
            rc = 1
    return rc


def cmd_record(ids: list[str]) -> int:
    state = load(INSTALL_STATE)
    for r in install_rows():
        if (not ids or r["entry"]["id"] in ids) and r["status"] != "not installed here":
            state[r["entry"]["id"]] = {"hash": r["hash"], "at": time.strftime("%Y-%m-%d %H:%M"), "recorded": True}
            print(f"  recorded {r['entry']['id']}")
    save(INSTALL_STATE, state)
    return 0


# ── artifacts ────────────────────────────────────────────────────────────────
def artifact_rows() -> list[dict]:
    shared = load(SHARED_STATE).get("artifacts", {})
    rows = []
    for t, e in entries("artifacts"):
        cur = source_hash(t["_dir"], e.get("sources") or [])
        outs = [Path(p) for g in e.get("outputs", []) for p in sorted(glob.glob(str(t["_dir"] / g)))]
        built = shared.get(e["id"], {}).get("hash") == cur and all(o.exists() for o in outs) and outs
        site_ok = None
        if e.get("site") and SITE.is_dir():
            dest = SITE / e["site"]
            site_ok = all((dest / o.name if e["site"].endswith("/") else dest).exists()
                          and filecmp(o, dest / o.name if e["site"].endswith("/") else dest) for o in outs) and bool(outs)
        rows.append({"tool": t.get("name") or t["_dir"].name, "dir": t["_dir"], "entry": e, "hash": cur,
                     "outputs": outs, "built": bool(built), "site_ok": site_ok})
    return rows


def filecmp(a: Path, b: Path) -> bool:
    try:
        return a.stat().st_size == b.stat().st_size and a.read_bytes() == b.read_bytes()
    except OSError:
        return False


def copy_to_site(row: dict) -> list[str]:
    e = row["entry"]
    if not e.get("site") or not SITE.is_dir():
        return []
    dest = SITE / e["site"]
    changed = []
    if e["site"].endswith("/"):
        dest.mkdir(parents=True, exist_ok=True)
        keep = {o.name for o in row["outputs"]}
        # retire older versions of the same artifact (e.g. Backstage-1.3.dmg once 1.4 exists)
        for g in e.get("outputs", []):
            for old in dest.glob(Path(g).name):
                if old.name not in keep:
                    old.unlink()
                    changed.append(f"removed {old.relative_to(SITE)}")
        for o in row["outputs"]:
            if not filecmp(o, dest / o.name):
                shutil.copy2(o, dest / o.name)
                changed.append(str((dest / o.name).relative_to(SITE)))
    else:
        o = row["outputs"][0]
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not filecmp(o, dest):
            shutil.copy2(o, dest)
            changed.append(str(dest.relative_to(SITE)))
    return changed


def cmd_artifacts(force: bool) -> int:
    state = load(SHARED_STATE)
    state.setdefault("artifacts", {})
    rc = 0
    for r in artifact_rows():
        e = r["entry"]
        if force or not r["built"]:
            if e.get("needs_mac", True) and not MAC:
                print(f"  ⚠️  {e['id']}: stale, but building it needs macOS")
                rc = 1
                continue
            print(f"→ building {e['id']}")
            if run_cmd(r["dir"], e["build"]) != 0:
                print(f"  ✗ {e['id']} build failed")
                rc = 1
                continue
            state["artifacts"][e["id"]] = {"hash": r["hash"], "at": time.strftime("%Y-%m-%d %H:%M")}
            save(SHARED_STATE, state)
            r = next(x for x in artifact_rows() if x["entry"]["id"] == e["id"])
        for c in copy_to_site(r):
            print(f"  ✓ site: {c}")
    return rc


# ── nested repos, git ────────────────────────────────────────────────────────
def git(cwd: Path, *args) -> str:
    r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def repo_rows() -> list[dict]:
    rows = []
    for name, path in [("amols-app-store", REPO), ("amolsarva.com", SITE)] + [(n, REPO / n) for n in NESTED_REPOS]:
        if not (path / ".git").exists():
            continue
        dirty = len([line for line in git(path, "status", "--porcelain", "--untracked-files=no").splitlines() if line])
        ahead = git(path, "rev-list", "--count", "@{u}..HEAD") or "?"
        rows.append({"repo": name, "path": path, "dirty": dirty, "ahead": ahead})
    return rows


# ── reporting ────────────────────────────────────────────────────────────────
def cmd_status(as_json: bool = False) -> int:
    inst, arts, repos = install_rows(), artifact_rows(), repo_rows()
    if as_json:
        print(json.dumps({
            "installs": [{"id": r["entry"]["id"], "tool": r["tool"], "status": r["status"]} for r in inst],
            "artifacts": [{"id": r["entry"]["id"], "built": r["built"], "site": r["site_ok"]} for r in arts],
            "repos": [{k: (str(v) if isinstance(v, Path) else v) for k, v in r.items()} for r in repos]}, indent=2))
        return 0
    print("Installed copies on this Mac")
    for r in inst:
        icon = {"current": "✅", "not installed here": "·"}.get(r["status"], "⚠️ " if r["stale"] else "?")
        manual = "" if r["entry"].get("auto", True) else " (manual)"
        print(f"  {icon} {r['entry']['id']:<28} {r['status']}{manual if r['stale'] else ''}")
    print("Published artifacts")
    for r in arts:
        site = {True: "on site", False: "site copy STALE", None: "no site repo"}[r["site_ok"]] if r["entry"].get("site") else "-"
        print(f"  {'✅' if r['built'] and r['site_ok'] is not False else '⚠️ '} {r['entry']['id']:<28} "
              f"{'built from current source' if r['built'] else 'STALE: source changed since last build'} · {site}")
    print("Repos (tracked changes / unpushed commits)")
    for r in repos:
        ok = r["dirty"] == 0 and r["ahead"] in ("0",)
        print(f"  {'✅' if ok else '⚠️ '} {r['repo']:<28} {r['dirty']} changed · {r['ahead']} unpushed")
    stale = sum(r["stale"] for r in inst) + sum((not r["built"]) or r["site_ok"] is False for r in arts) \
        + sum(not (r["dirty"] == 0 and r["ahead"] == "0") for r in repos)
    print(f"\n{'Everything current.' if not stale else f'{stale} item(s) not current → supporting-files/publish/release.sh'}")
    return 1 if stale else 0


def cmd_check() -> int:
    return 1 if any(r["stale"] for r in install_rows()) else 0


def cmd_published() -> int:
    """0 when nothing is waiting to go out: repos clean + pushed, artifacts built from current source and on the site."""
    arts_ok = all(r["built"] and r["site_ok"] is not False for r in artifact_rows())
    repos_ok = all(r["dirty"] == 0 and r["ahead"] == "0" for r in repo_rows() if r["repo"] != "amolsarva.com") \
        and all(r["ahead"] == "0" for r in repo_rows() if r["repo"] == "amolsarva.com")   # site has unrelated local edits
    return 0 if arts_ok and repos_ok else 1


# ── lint: registrations that point at things that no longer exist ───────────
def cmd_lint() -> int:
    docs = REPO.parents[1]          # …/Documents
    problems = []

    def resolve(p: str) -> Path:
        if p.startswith("~/Documents/"):
            return docs / p[len("~/Documents/"):]
        p = os.path.expanduser(p)
        return Path(p) if p.startswith("/") else docs / "root" / p

    sj = load(REPO / "backstage/scripts.json")
    for key, e in sj.items():
        path = e.get("path") or key
        if path.startswith(("~/Documents/", "Documents/")) and not resolve(path).exists():
            problems.append(f"Backstage scripts.json: {e.get('name', key)} → missing {path}")
    for item in load(REPO / "backstage/setup.json") or []:
        for part in ("check", "fix"):
            c = item.get(part) or {}
            if c.get("type") == "script" and not resolve(c["value"].split(" ")[0]).exists():
                problems.append(f"Backstage setup.json: {item['id']} {part} → missing {c['value']}")
    for t in tools():
        entry = (t.get("launcher") or {}).get("entry")
        if entry and t["_dir"].is_dir() and not (t["_dir"] / entry).exists() and (t["_dir"] / "tool.json").exists():
            problems.append(f"{t['_dir'].name}/tool.json: launcher entry {entry} does not exist")
        for kind, key in (("installs", "update"), ("artifacts", "build")):
            for e in t.get(kind) or []:
                if not (t["_dir"] / shlex.split(e[key])[0]).exists():
                    problems.append(f"{t['_dir'].name}: {kind} {e['id']} → missing {e[key]}")
    for p in problems:
        print(f"  ⚠️  {p}")
    if not problems:
        print("  ✓ Backstage registrations, launcher entries and install/build commands all resolve")
    return 1 if problems else 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    if cmd == "status":
        return cmd_status()
    if cmd == "json":
        return cmd_status(as_json=True)
    if cmd == "check":
        return cmd_check()
    if cmd == "published":
        return cmd_published()
    if cmd == "sync":
        return cmd_sync("--dry-run" in rest)
    if cmd == "record":
        return cmd_record(rest)
    if cmd == "lint":
        return cmd_lint()
    if cmd == "artifacts":
        return cmd_artifacts("--force" in rest)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
