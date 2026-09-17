#!/bin/bash
# Mac Scripts launcher entrypoint — hands off to the real script in this folder.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/VOICEMEMOCLEANER.sh"
