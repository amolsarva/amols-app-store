# 🐍 Python Guard

Keeps Python working on a Mac through every Homebrew upgrade.

**The problem.** Homebrew's `python@3.x` ships **without Tk** (that's a separate `python-tk@3.x`
formula), refuses `pip install` into itself (PEP 668), and every minor upgrade (3.13 → 3.14 → …)
leaves virtual environments pointing at an interpreter that may be gone. Scripts that call plain
`python3` break silently, usually weeks later.

**What it does.**

- `run.sh` / `run.sh doctor`: lists every Python on the Mac, which ones have Tk, the tool environments it manages, and whether the watcher is installed.
- `run.sh ensure`: fixes it now. It installs Homebrew Python if missing, installs `python-tk@<current version>`, and rebuilds any tool environment whose Python moved or lost a package.
- `run.sh install`: does `ensure`, then adds a small LaunchAgent that re-runs it **whenever Homebrew relinks `python3`** (that is, right after an upgrade) and every 6 hours.

**For script authors** (how the other tools in this collection use it):

```bash
G="$(dirname "$0")/../python-guard/pyenv.sh"
/bin/bash "$G" exec --tk -- my_tk_app.py "$@"          # best python3 that has Tk (installs Tk if needed)
PY="$(/bin/bash "$G" venv mytool --pkg pandas --pkg openpyxl)"   # private venv, kept current
"$PY" my_script.py
```

Tool environments live in `~/Library/Application Support/python-guard/venvs/`, outside iCloud,
so they never get evicted and each Mac builds its own. Log: `~/Library/Logs/python-guard.log`.

Requires macOS + Homebrew for automatic installs. Without Homebrew it still finds the best
available Python (python.org or Apple's Command Line Tools).
