#!/usr/bin/env python3
import psutil, time, datetime, subprocess, re

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
NOTIFY = True         # macOS notification toggle

# Never touch or even flag anything matching these
SKIP_SUBSTR = re.compile(r"(claude|openai|openclaw)", re.IGNORECASE)

offense = {}
flagged_recently = {}     # pid -> last flag time (epoch)
FLAG_COOLDOWN = 120       # seconds between repeat alerts per PID

def notify(title: str, message: str):
    if not NOTIFY:
        return
    try:
        subprocess.run([
            "osascript", "-e",
            f'display notification "{message}" with title "{title}"'
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
                        msg = f"{name} (PID {pid}) sustained ~{cpu:.1f}% CPU"
                        print(f"[{now_str}] FLAG: {msg}", flush=True)
                        notify("CPU Guard (Safe)", msg)
                        flagged_recently[pid] = now
                    offense[pid] = 0
            else:
                offense[pid] = 0

        except (psutil.NoSuchProcess, psutil.AccessDenied):
            offense.pop(pid, None)
            flagged_recently.pop(pid, None)
            continue

    time.sleep(INTERVAL)
