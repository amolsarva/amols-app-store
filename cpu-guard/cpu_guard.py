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
    "mds_stores",
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
WATCH_OVERRIDE = os.environ.get("CPU_GUARD_WATCH", "").strip()
if WATCH_OVERRIDE:
    WATCH = [name.strip() for name in WATCH_OVERRIDE.split(",") if name.strip()]

CPU_LIMIT = float(os.environ.get("CPU_GUARD_CPU_LIMIT", "80"))      # percent
DURATION = int(os.environ.get("CPU_GUARD_DURATION", "30"))          # seconds above limit before action
INTERVAL = int(os.environ.get("CPU_GUARD_INTERVAL", "5"))           # seconds between checks
ACTION = os.environ.get("CPU_GUARD_ACTION", "kill").strip().lower() # kill, terminate, or notify
TERMINATE_GRACE = int(os.environ.get("CPU_GUARD_TERMINATE_GRACE", "5"))
ACTION_COOLDOWN = int(os.environ.get("CPU_GUARD_ACTION_COOLDOWN", "1800"))
LOG_HEARTBEAT_INTERVAL = int(os.environ.get("CPU_GUARD_LOG_HEARTBEAT_INTERVAL", "3600"))

NOTIFY = os.environ.get("CPU_GUARD_NOTIFY", "1").lower() not in ("0", "false", "no")
NOTIFY_EVENTS = {
    event.strip().lower()
    for event in os.environ.get("CPU_GUARD_NOTIFY_EVENTS", "action,error").split(",")
    if event.strip()
}

# Never touch or even flag anything matching these.
SKIP_SUBSTR = re.compile(
    os.environ.get("CPU_GUARD_SKIP_PATTERN", r"(claude|openai|openclaw)"),
    re.IGNORECASE,
)

PROCESS_NOTES = {
    "IntelligencePlatformComputeService": "Apple Intelligence / on-device ML",
    "intelligenceservice": "Apple Intelligence",
    "knowledge-agent": "Spotlight/Siri knowledge indexing",
    "corespotlightd": "Spotlight indexing",
    "mds": "Spotlight indexing",
    "mds_stores": "Spotlight metadata store",
    "mdworker": "Spotlight indexing worker",
    "mdworker_shared": "Spotlight indexing worker",
    "photolibraryd": "Photos library background work",
    "photosanalysisd": "Photos face/object analysis",
    "bird": "iCloud Drive sync",
    "cloudd": "iCloud sync",
    "contactsd": "Contacts sync",
    "calendard": "Calendar sync",
}

offense = {}              # pid -> seconds above threshold
acted_recently = {}       # process name -> last action time (epoch)
last_heartbeat = 0

def apple_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')

def now_stamp() -> str:
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def notify(event: str, title: str, subtitle: str, message: str):
    if not NOTIFY or event not in NOTIFY_EVENTS:
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

def log(message: str):
    print(f"[{now_stamp()}] {message}", flush=True)

def act_on_process(proc: psutil.Process, name: str, pid: int):
    try:
        if ACTION == "notify":
            return "reported", "notify-only mode"

        proc.terminate()
        try:
            proc.wait(timeout=TERMINATE_GRACE)
            return "terminated", f"SIGTERM succeeded within {TERMINATE_GRACE}s"
        except psutil.TimeoutExpired:
            if ACTION == "terminate":
                return "still-running", f"SIGTERM timed out after {TERMINATE_GRACE}s"
            proc.kill()
            try:
                proc.wait(timeout=TERMINATE_GRACE)
                return "killed", "SIGKILL was required after SIGTERM timed out"
            except psutil.TimeoutExpired:
                return "still-running", "SIGKILL sent but process still appears alive"
    except psutil.NoSuchProcess:
        return "already-exited", "process exited before CPU Guard acted"
    except psutil.AccessDenied:
        return "access-denied", "macOS denied permission to terminate the process"
    except Exception as exc:
        return "error", f"{type(exc).__name__}: {exc}"

# Prime cpu_percent() so subsequent reads are meaningful
for p in psutil.process_iter(['pid']):
    try:
        p.cpu_percent(None)
    except Exception:
        pass

log(
    "started: action=%s, threshold=%.0f%% for %ss, interval=%ss, notify_events=%s"
    % (ACTION, CPU_LIMIT, DURATION, INTERVAL, ",".join(sorted(NOTIFY_EVENTS)) or "none")
)
notify(
    "start",
    "CPU Guard started",
    f"{ACTION} mode",
    f"Watching {len(WATCH)} known noisy background process names.",
)

while True:
    now = time.time()
    if LOG_HEARTBEAT_INTERVAL and now - last_heartbeat >= LOG_HEARTBEAT_INTERVAL:
        log("heartbeat: monitoring watched background processes")
        last_heartbeat = now

    for proc in psutil.process_iter(['pid', 'name']):
        pid = None
        try:
            name = proc.info.get('name') or ""
            pid = proc.info['pid']

            if SKIP_SUBSTR.search(name) or name not in WATCH:
                continue

            cpu = proc.cpu_percent(None)

            if cpu > CPU_LIMIT:
                offense[pid] = offense.get(pid, 0) + INTERVAL
                if offense[pid] >= DURATION:
                    last = acted_recently.get(name, 0)
                    if now - last >= ACTION_COOLDOWN:
                        note = PROCESS_NOTES.get(name, "watched macOS background process")
                        result, detail = act_on_process(proc, name, pid)
                        subtitle = f"{name} PID {pid} at ~{cpu:.1f}% CPU"
                        msg = (
                            f"{note}: {name} (PID {pid}) stayed above "
                            f"{CPU_LIMIT:.0f}% CPU for about {DURATION}s. "
                            f"Action result: {result}. {detail}."
                        )
                        log(f"ACTION: {result}: {subtitle} - {note}; {detail}")
                        notify("action" if result not in ("error", "access-denied") else "error",
                               f"CPU Guard: {result}", subtitle, msg)
                        acted_recently[name] = now
                    offense[pid] = 0
            else:
                offense[pid] = 0

        except (psutil.NoSuchProcess, psutil.AccessDenied):
            if pid is not None:
                offense.pop(pid, None)
            continue

    time.sleep(INTERVAL)
