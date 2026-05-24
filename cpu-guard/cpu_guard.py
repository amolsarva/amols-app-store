#!/usr/bin/env python3
import datetime
import os
import re
import subprocess
import time

import psutil

WATCH = [
    "contactsd",
    "intelligenceservice",
    "IntelligencePlatformComputeService",
    "knowledge-agent",
    "corespotlightd",
    "mds",
    "mdworker",
    "mdworker_shared",
    "calendard",
    "photolibraryd",
    "photosanalysisd",
    "bird",
    "cloudd",
    "accountsd",
    "biomed",
    "analyticsd",
    "SiriNCService",
]

CPU_LIMIT = 80.0      # percent
DURATION = 30         # seconds above limit before flag
INTERVAL = 5          # seconds between checks
NOTIFY = os.environ.get("CPU_GUARD_NOTIFY", "1").lower() not in ("0", "false", "no")

# Never touch or even flag anything matching these
SKIP_SUBSTR = re.compile(r"(claude|openai|openclaw)", re.IGNORECASE)

PROCESS_NOTES = {
    "IntelligencePlatformComputeService": "Apple Intelligence / on-device ML",
    "intelligenceservice": "Apple Intelligence",
    "knowledge-agent": "Spotlight/Siri knowledge indexing",
    "corespotlightd": "Spotlight indexing",
    "mds": "Spotlight indexing",
    "mdworker": "Spotlight indexing worker",
    "mdworker_shared": "Spotlight indexing worker",
    "photolibraryd": "Photos library background work",
    "photosanalysisd": "Photos face/object analysis",
    "bird": "iCloud Drive sync",
    "cloudd": "iCloud sync",
    "contactsd": "Contacts sync",
    "calendard": "Calendar sync",
}

offense = {}
flagged_recently = {}     # pid -> last flag time (epoch)
FLAG_COOLDOWN = 900       # seconds between repeat alerts per PID

def apple_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')

def notify(title: str, subtitle: str, message: str):
    if not NOTIFY:
        return
    try:
        script = (
            f'display notification "{apple_quote(message)}" '
            f'with title "{apple_quote(title)}" '
            f'subtitle "{apple_quote(subtitle)}"'
        )
        subprocess.run([
            "osascript", "-e", script
        ], check=False)
    except Exception:
        pass

# Prime cpu_percent() so subsequent reads are meaningful
for p in psutil.process_iter(['pid']):
    try:
        p.cpu_percent(None)
    except Exception:
        pass

while True:
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{now_str}] heartbeat: monitoring (SAFE / NO-KILL mode)…", flush=True)

    for proc in psutil.process_iter(['pid', 'name']):
        try:
            name = proc.info.get('name') or ""
            pid = proc.info['pid']

            if SKIP_SUBSTR.search(name) or name not in WATCH:
                continue

            cpu = proc.cpu_percent(None)

            if cpu > CPU_LIMIT:
                offense[pid] = offense.get(pid, 0) + INTERVAL
                if offense[pid] >= DURATION:
                    now = time.time()
                    last = flagged_recently.get(pid, 0)
                    if now - last >= FLAG_COOLDOWN:
                        note = PROCESS_NOTES.get(name, "watched macOS background process")
                        msg = (
                            f"{note}: {name} (PID {pid}) has stayed above "
                            f"{CPU_LIMIT:.0f}% CPU for about {DURATION}s. "
                            "CPU Guard only reports this; it does not kill or change the process."
                        )
                        subtitle = f"{name} at ~{cpu:.1f}% CPU"
                        print(f"[{now_str}] FLAG: {subtitle} — {note}", flush=True)
                        notify("CPU Guard: high CPU", subtitle, msg)
                        flagged_recently[pid] = now
                    offense[pid] = 0
            else:
                offense[pid] = 0

        except (psutil.NoSuchProcess, psutil.AccessDenied):
            offense.pop(pid, None)
            flagged_recently.pop(pid, None)
            continue

    time.sleep(INTERVAL)
