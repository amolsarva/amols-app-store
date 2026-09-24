#!/bin/bash
# git-privacy: anything git ignores stays on your Macs (iCloud) and never reaches GitHub.
# Arguments: audit (default) | install | scrub <repo> [--apply]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/git_privacy.py" "${@:-audit}"
