#!/bin/bash
# Sunlight — native Tasmota smart-bulb controls and on-device daylight automation.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Your bulb lives in the Mac-only local-bulb.json (git-ignored). Load any setting the app doesn't have yet.
if [ -f "$DIR/local-bulb.json" ]; then
  /usr/bin/python3 - "$DIR/local-bulb.json" <<'PY'
import json, subprocess, sys
cfg = json.load(open(sys.argv[1]))
keys = {"name": "homeBulbName", "host": "bulbHost", "mac": "homeBulbMAC", "timeZone": "bulbTimeZone",
        "daylightVerifiedMAC": "daylightVerifiedMAC", "backupDirectory": "backupDirectory"}
for k, dk in keys.items():
    if cfg.get(k) and subprocess.run(["defaults", "read", "co.sarva.sunlight", dk], capture_output=True).returncode != 0:
        subprocess.run(["defaults", "write", "co.sarva.sunlight", dk, "-string", str(cfg[k])], check=True)
PY
fi
if [ ! -x "$DIR/dist/Sunlight.app/Contents/MacOS/Sunlight" ]; then
  /bin/bash "$DIR/build.sh"
fi
exec /usr/bin/open "$DIR/dist/Sunlight.app"
