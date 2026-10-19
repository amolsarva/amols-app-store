#!/bin/bash
# Installed copies on this Mac vs. their source (LaunchAgents' copies, built .apps, git hooks…).
#   installed.sh            status of everything (see deps.py)
#   installed.sh check      exit 0 if every installed copy on this Mac is current (Backstage setup check)
#   installed.sh sync       re-install the stale ones
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(/bin/bash "$HERE/../../python-guard/pyenv.sh" find --quiet 2>/dev/null || command -v python3)"
exec "$PY" "$HERE/deps.py" "${@:-status}"
