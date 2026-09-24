#!/usr/bin/env python3
"""git-privacy: some things go to GitHub, some stay on your Macs (synced by iCloud). Enforce it.

The rule is one sentence: **anything git ignores is private.** Private files live in the
working folder (so iCloud syncs them to your other Macs) but never reach a remote.

  install        on THIS Mac: add the shared private patterns to the global gitignore,
                 install a pre-commit + pre-push guard (global core.hooksPath). Run once per Mac.
  audit [ROOT]   every repo under ROOT (default ~/Documents/root): private files still tracked,
                 unpushed commits containing private files, repository corruption (fsck)
  scrub REPO     remove private files from the repo's index and from its *unpushed* commits
                 (dry run; add --apply). Pushed history is never rewritten.
  check-push     (used by the pre-push hook) exit 1 if the commits being pushed contain private files
  check-staged   (used by the pre-commit hook) exit 1 if staged changes add/modify private files

To make something private: add it to the repo's .gitignore (or to private-patterns for all repos),
then `scrub` the repo. To publish a file that matches a pattern, un-ignore it with `!path`.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PATTERNS_FILE = HERE / "private-patterns"
HOME = Path.home()
GIT_CONFIG_DIR = HOME / ".config/git"
GLOBAL_IGNORE = GIT_CONFIG_DIR / "ignore"
HOOKS = GIT_CONFIG_DIR / "hooks"
BEGIN, END = "# >>> git-privacy private patterns (managed; edit mac-scripts/git-privacy/private-patterns)", "# <<< git-privacy"
ZERO = "0" * 40


def git(repo, *args, env=None, input=None, check=False) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          env=env, input=input, check=check)


def patterns() -> list[str]:
    return [l.strip() for l in PATTERNS_FILE.read_text().splitlines() if l.strip() and not l.startswith("#")]


def ignored(repo, paths) -> list[str]:
    """Which of these paths are private (ignored by global + repo rules), even if tracked."""
    paths = [p for p in paths if p]
    if not paths:
        return []
    r = git(repo, "check-ignore", "--no-index", "--stdin", input="\n".join(paths) + "\n")
    return [l for l in r.stdout.splitlines() if l]


# ── install ──────────────────────────────────────────────────────────────────
PRE_PUSH = """#!/bin/bash
# git-privacy: refuse to push commits that contain private (git-ignored) files.
exec python3 "{script}" check-push "$@"
"""
CHECK_LINE = 'python3 "{script}" check-staged || exit 1  # git-privacy'


def cmd_install(_args) -> int:
    GIT_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    HOOKS.mkdir(parents=True, exist_ok=True)
    text = GLOBAL_IGNORE.read_text() if GLOBAL_IGNORE.exists() else ""
    if BEGIN in text:
        text = text[:text.index(BEGIN)] + text[text.index(END) + len(END):].lstrip("\n")
    text = text.rstrip("\n") + "\n\n" + BEGIN + "\n" + "\n".join(patterns()) + "\n" + END + "\n"
    GLOBAL_IGNORE.write_text(text)
    hooks_path = git(".", "config", "--global", "core.hooksPath").stdout.strip()
    if hooks_path and Path(os.path.expanduser(hooks_path)) != HOOKS:
        print(f"! core.hooksPath is {hooks_path}; installing hooks there")
    hooks = Path(os.path.expanduser(hooks_path)) if hooks_path else HOOKS
    hooks.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "config", "--global", "core.hooksPath", str(hooks)], check=True)
    if not git(".", "config", "--global", "core.excludesFile").stdout.strip():
        subprocess.run(["git", "config", "--global", "core.excludesFile", str(GLOBAL_IGNORE)], check=True)
    script = str(Path(__file__).resolve())
    (hooks / "pre-push").write_text(PRE_PUSH.format(script=script))
    (hooks / "pre-push").chmod(0o755)
    pc = hooks / "pre-commit"
    body = pc.read_text() if pc.exists() else "#!/bin/bash\nexit 0\n"
    lines = [l for l in body.splitlines() if "# git-privacy" not in l]
    lines.insert(1, CHECK_LINE.format(script=script))
    pc.write_text("\n".join(lines) + "\n")
    pc.chmod(0o755)
    marker = HERE / "installed-macs.json"  # private (gitignored): which Macs have the guard
    seen = json.loads(marker.read_text()) if marker.exists() else {}
    seen[f"{socket.gethostname().split('.')[0]}:{HOME.name}"] = time.strftime("%Y-%m-%d %H:%M")
    marker.write_text(json.dumps(seen, indent=2) + "\n")
    print(f"✓ private patterns in {GLOBAL_IGNORE}: {', '.join(patterns())}")
    print(f"✓ pre-commit + pre-push guards in {hooks}")
    print(f"✓ Macs with the guard: {', '.join(seen)}  (run this once on each Mac)")
    return 0


# ── hooks ────────────────────────────────────────────────────────────────────
def cmd_check_staged(_args) -> int:
    staged = git(".", "diff", "--cached", "--name-only", "--diff-filter=ACMR").stdout.splitlines()
    up = git(".", "rev-parse", "--abbrev-ref", "@{u}").stdout.strip()
    public = set(git(".", "ls-tree", "-r", "--name-only", up).stdout.splitlines()) if up else set()
    bad = [f for f in ignored(".", staged) if f not in public]
    if bad:
        print("\n\033[31mCommit blocked by git-privacy.\033[0m These files are private (git-ignored) but staged:")
        for b in bad:
            print(f"  {b}")
        print("They stay on your Macs (iCloud) and never go to GitHub. Unstage and untrack them:")
        print("  git rm --cached -- <file>        (the file itself is kept)")
        print("If one should be public, un-ignore it with a `!path` line in .gitignore.")
        return 1
    return 0


def cmd_check_push(_args) -> int:
    bad = set()
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if len(parts) < 4 or parts[1] == ZERO:  # deleting a remote branch
            continue
        local_sha, remote_sha = parts[1], parts[3]
        rng = [local_sha, "--not", "--remotes"] if remote_sha == ZERO else [f"{remote_sha}..{local_sha}"]
        commits = git(".", "rev-list", *rng).stdout.split()
        files = set()
        for c in commits:
            files |= set(git(".", "diff-tree", "--no-commit-id", "--name-only", "-r", "--root",
                             "--diff-filter=ACMR", c).stdout.splitlines())
        was_public = set() if remote_sha == ZERO else set(
            git(".", "ls-tree", "-r", "--name-only", remote_sha).stdout.splitlines())
        bad |= {f for f in ignored(".", sorted(files)) if f not in was_public}
    if bad:
        print("\n\033[31mPush blocked by git-privacy.\033[0m Commits being pushed contain private files:")
        for b in sorted(bad):
            print(f"  {b}")
        print(f"Fix: python3 \"{Path(__file__).resolve()}\" scrub . --apply   (rewrites only unpushed commits)")
        return 1
    return 0


# ── scrub ────────────────────────────────────────────────────────────────────
def scrub(repo: Path, apply: bool) -> dict:
    res = {"repo": str(repo), "index": [], "commits": {}, "rewrote": False, "already_public": []}
    up = git(repo, "rev-parse", "--abbrev-ref", "@{u}").stdout.strip()
    # Files already on the remote are public no matter what; hiding them now would only delete
    # them from the repo. Only never-pushed files are treated as private.
    public = set(git(repo, "ls-tree", "-r", "--name-only", up).stdout.splitlines()) if up else set()
    tracked = git(repo, "ls-files").stdout.splitlines()
    ign = ignored(repo, tracked)
    res["index"] = [f for f in ign if f not in public]
    res["already_public"] = [f for f in ign if f in public]
    if up:
        commits = git(repo, "rev-list", "--reverse", "--topo-order", f"{up}..HEAD").stdout.split()
        merges = git(repo, "rev-list", "--merges", f"{up}..HEAD").stdout.split()
        if merges:
            res["error"] = "unpushed merge commits; scrub by hand"
            return res
    else:
        commits = []
    tmp_index = Path(git(repo, "rev-parse", "--git-dir").stdout.strip())
    tmp_index = (repo / tmp_index if not tmp_index.is_absolute() else tmp_index) / "git-privacy.index"
    env = dict(os.environ, GIT_INDEX_FILE=str(tmp_index))
    # Rebuild on the commit the unpushed work actually branched from (the remote may have moved on).
    parent = git(repo, "merge-base", up, "HEAD").stdout.strip() if up else None
    changed = False
    for c in commits:
        git(repo, "read-tree", c, env=env, check=True)
        files = git(repo, "ls-files", env=env).stdout.splitlines()
        bad = [f for f in ignored(repo, files) if f not in public]
        # Only files this commit introduced or changed count against it; but every private
        # file must leave its tree, or it would reappear in the rewritten history.
        if bad:
            res["commits"][c[:8]] = bad
        if not bad and not changed:
            parent = c
            continue
        if not apply:
            parent = c
            continue
        if bad:
            git(repo, "rm", "-q", "--cached", "--", *bad, env=env, check=True)
        tree = git(repo, "write-tree", env=env, check=True).stdout.strip()
        meta = git(repo, "log", "-1", "--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%B", c).stdout.split("\x00")
        cenv = dict(os.environ, GIT_AUTHOR_NAME=meta[0], GIT_AUTHOR_EMAIL=meta[1], GIT_AUTHOR_DATE=meta[2],
                    GIT_COMMITTER_NAME=meta[3], GIT_COMMITTER_EMAIL=meta[4], GIT_COMMITTER_DATE=meta[5])
        args = ["commit-tree", tree, "-m", meta[6].rstrip("\n")] + (["-p", parent] if parent else [])
        parent = git(repo, *args, env=cenv, check=True).stdout.strip()
        changed = True
    tmp_index.unlink(missing_ok=True)
    if apply and changed:
        branch = git(repo, "symbolic-ref", "-q", "HEAD").stdout.strip()
        old = git(repo, "rev-parse", "HEAD").stdout.strip()
        git(repo, "update-ref", "-m", "git-privacy scrub", branch, parent, old, check=True)
        res["rewrote"] = True
        res["old_head"] = old
    if apply and res["index"]:
        git(repo, "rm", "-q", "-f", "--cached", "--", *res["index"], check=True)  # -f: index only; files on disk are kept
    return res


def cmd_scrub(args) -> int:
    repo = Path(args[0] if args else ".").resolve()
    apply = "--apply" in args
    r = scrub(repo, apply)
    if r.get("error"):
        print(f"✗ {repo}: {r['error']}")
        return 1
    print(f"{repo}")
    for f in r["index"]:
        print(f"  {'untracked' if apply else 'would untrack'} (file kept): {f}")
    for c, files in r["commits"].items():
        print(f"  unpushed commit {c}: {'removed' if apply else 'would remove'} {len(files)} private file(s): "
              f"{', '.join(files[:6])}{' …' if len(files) > 6 else ''}")
    if r.get("rewrote"):
        print(f"  ✓ rewrote unpushed commits (previous HEAD {r['old_head'][:10]} stays in the reflog on this Mac)")
    if not r["index"] and not r["commits"]:
        print("  ✓ clean")
    elif not apply:
        print("  (dry run; add --apply)")
    return 0


# ── audit ────────────────────────────────────────────────────────────────────
def find_repos(root: Path) -> list[Path]:
    out = []
    for dirpath, dirnames, _ in os.walk(root):
        if ".git" in dirnames or (Path(dirpath) / ".git").is_file():
            out.append(Path(dirpath))
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", ".build", ".venv", "venv", "dist")
                       and not d.startswith(".") and Path(dirpath, d).relative_to(root).parts.__len__() < 6]
    return out


def cmd_audit(args) -> int:
    root = Path(args[0]).expanduser() if args else HOME / "Documents/root"
    problems = 0
    marker = HERE / "installed-macs.json"
    print(f"git-privacy audit · {root}")
    print(f"  guard installed on: {', '.join(json.loads(marker.read_text())) if marker.exists() else 'no Mac yet (run install)'}")
    for repo in find_repos(root):
        rel = repo.relative_to(root)
        remote = git(repo, "remote", "get-url", "origin").stdout.strip() or "no remote (local only)"
        r = scrub(repo, apply=False)
        fsck = git(repo, "fsck", "--connectivity-only", "--no-dangling")
        broken = fsck.returncode != 0
        ahead = git(repo, "rev-list", "--count", "@{u}..HEAD").stdout.strip() or "-"
        flags = []
        if r["index"]:
            flags.append(f"{len(r['index'])} private file(s) still tracked")
        if r["commits"]:
            flags.append(f"{len(r['commits'])} unpushed commit(s) contain private files")
        if broken:
            flags.append("repository corrupt: " + (fsck.stderr or fsck.stdout).strip().splitlines()[0][:100])
        problems += bool(flags)
        print(f"  {'⚠️ ' if flags else '✅'} {rel}  [{remote}; {ahead} unpushed]" + ("".join(f"\n       - {f}" for f in flags)))
        if r["already_public"]:
            print(f"       ℹ️  already on the remote, so left as is: {', '.join(r['already_public'][:4])}")
    print(f"\n{'All repos clean.' if not problems else f'{problems} repo(s) need attention: scrub <repo> --apply'}")
    return 1 if problems else 0


def main() -> int:
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else "audit"), sys.argv[2:]
    fn = {"install": cmd_install, "audit": cmd_audit, "scrub": cmd_scrub,
          "check-push": cmd_check_push, "check-staged": cmd_check_staged}.get(cmd)
    if not fn:
        print(__doc__)
        return 64
    return fn(args)


if __name__ == "__main__":
    sys.exit(main())
