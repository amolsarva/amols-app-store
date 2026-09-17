#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "WhatsApp Campaign Studio — installer and doctor"
echo "Folder: $DIR"

AVAILABLE_KB="$(df -Pk "$DIR" | awk 'NR==2 {print $4}')"
if (( AVAILABLE_KB < 300000 )); then
  echo "ERROR: Less than 300 MB is free. Free disk space before installing."
  exit 1
elif (( AVAILABLE_KB < 1000000 )); then
  echo "WARNING: Less than 1 GB is free. Installation can proceed, but WhatsApp's browser profile needs room to grow."
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "WARNING: this installer is designed and tested for macOS."
fi

if ! command -v node >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Node.js is missing; installing it with Homebrew…"
    brew install node
  else
    echo "ERROR: Node.js is missing and Homebrew is unavailable. Install Node 18+ from https://nodejs.org/"
    exit 1
  fi
fi

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( NODE_MAJOR < 18 )); then
  echo "ERROR: Node.js 18+ is required; found $(node --version)."
  exit 1
fi

echo "Using Node $(node --version) and npm $(npm --version)"
# Reuse the Mac's installed Chrome. This avoids a second ~300 MB browser download.
export PUPPETEER_SKIP_DOWNLOAD=true
# `npm install` is intentionally used instead of `npm ci`: it repairs interrupted
# installs (common when a Mac runs low on space) while still honoring the lockfile.
npm install

if [[ ! -f config.json ]]; then
  cp config.example.json config.json
  chmod 600 config.json
  echo "Created config.json"
fi

mkdir -p logs campaign-archive .wwebjs_auth
chmod 700 logs campaign-archive .wwebjs_auth
chmod +x run.sh install_and_test.sh

echo "Running automated tests…"
npm test
echo "Running environment doctor…"
npm run doctor

echo
echo "Installation complete. Launch with:"
echo "  $DIR/run.sh"
echo "The app will ask whether to use Dry run or Live mode."
echo
echo "The first launch displays a QR code. On your phone:"
echo "  WhatsApp → Settings → Linked Devices → Link a Device"
