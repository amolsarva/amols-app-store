#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [[ ! -d node_modules ]]; then
  echo "Dependencies are not installed. Running installer first…"
  "$DIR/install_and_test.sh"
fi

exec node src/app.js "$@"
