#!/bin/bash
# Run this once to install Electron. After it finishes, use launcher.command as normal.
cd "$(dirname "$0")" || exit 1

echo ""
echo "  Mac Scripts — Electron setup"
echo "  ─────────────────────────────"
echo ""

# Check for node
if ! command -v node &>/dev/null; then
  echo "  ✗ Node.js not found. Install it from https://nodejs.org then run this again."
  echo ""
  read -n1 -r -p "  Press any key to close…"
  exit 1
fi

echo "  ✓ Node $(node --version) found"
echo "  Installing Electron (this takes ~30 seconds the first time)…"
echo ""

npm install --save-dev electron 2>&1 | grep -v "^npm warn" | grep -v "^$"

if [ $? -eq 0 ]; then
  echo ""
  echo "  ✓ Done! You can now double-click launcher.command to open Mac Scripts."
  echo ""
else
  echo ""
  echo "  ✗ Something went wrong. Check the output above."
  echo ""
fi

read -n1 -r -p "  Press any key to close…"
