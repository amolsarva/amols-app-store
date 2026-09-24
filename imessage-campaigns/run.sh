#!/bin/bash
# iMessage Campaign Studio: find people by past conversations, review, then send separate texts (dry-run first).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/imessage_campaigns.py" "$@"
