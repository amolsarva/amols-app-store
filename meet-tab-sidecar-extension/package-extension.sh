#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT/../downloads"
ZIP="$OUT_DIR/meet-tab-sidecar-extension.zip"

mkdir -p "$OUT_DIR"
rm -f "$ZIP"

cd "$ROOT"
zip -r "$ZIP" . \
  -x "*.DS_Store" \
  -x "README.md" \
  -x "INSTALL.md" \
  -x "package-extension.sh"

echo "Wrote $ZIP"
