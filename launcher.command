#!/bin/bash
# Double-click: opens the Mac Scripts launcher (supporting-files/launcher.py, Tk).
# Python comes from python-guard, which picks a python3 that has Tk and, if Homebrew upgraded
# Python and dropped Tk, installs python-tk for the new version first (2026-10-17 failure).
#   launcher.command install|repair   → python-guard ensure + its watcher agent
#   launcher.command doctor           → python-guard report
cd "$(dirname "$0")" || exit 1
case "${1:-}" in
  install|repair|--fix) exec /bin/bash python-guard/pyenv.sh install ;;
  doctor|status)        exec /bin/bash python-guard/pyenv.sh doctor ;;
esac
exec /bin/bash python-guard/pyenv.sh exec --tk -- supporting-files/launcher.py "$@"
