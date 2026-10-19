#!/usr/bin/env python3
"""CPU Guard: watches a short list of noisy macOS background processes.

Default mode is NOTIFY ONLY: it logs and notifies when a watched process has stayed above
the CPU limit for a long time, and kills nothing. Every 50th notification (or on demand) it
opens a popup with a report and lets you flip between Notify only and Kill routinely.

  cpu_guard.py             run the watcher (what the LaunchAgent does)
  cpu_guard.py --popup     show the report popup now
  cpu_guard.py --report    print the report + an AI-ready analysis
  cpu_guard.py --set-mode notify|kill|terminate

Note: CPU percentages are per core. 100% = one full core; on an 8-core Mac that is 1/8 of the machine.
"""
import datetime
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

try:
    import psutil
except ImportError:  # --report/--popup still work (via ps) without it
    psutil = None

WATCH = [
    "contactsd", "intelligenceservice", "IntelligencePlatformComputeService", "knowledge-agent",
    "corespotlightd", "mds", "mds_stores", "mdworker", "mdworker_shared", "calendard",
    "photolibraryd", "photosanalysisd", "bird", "cloudd", "accountsd", "biomed", "analyticsd",
    "SiriNCService",
]
WATCH_OVERRIDE = os.environ.get("CPU_GUARD_WATCH", "").strip()
if WATCH_OVERRIDE:
    WATCH = [n.strip() for n in WATCH_OVERRIDE.split(",") if n.strip()]

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

SKIP_SUBSTR = re.compile(os.environ.get("CPU_GUARD_SKIP_PATTERN", r"(claude|openai|openclaw)"), re.IGNORECASE)

CONFIG_DIR = Path.home() / ".config" / "cpu-guard"
CONFIG_PATH = CONFIG_DIR / "config.json"   # written by the popup toggle; wins over environment defaults
STATE_PATH = CONFIG_DIR / "state.json"     # notification counter
LOG_PATH = Path.home() / "Library" / "Logs" / "cpu-guard.out"

# Defaults (the installer bakes these into the LaunchAgent environment). Meaning of the defaults:
#  - limit 100%: one full core (about 1/8 of an 8-core Mac). Below that nobody notices.
#  - duration 7200s: two hours above the limit (short dips do not reset the clock). Normal indexing
#    bursts last minutes; two hours means something is really stuck.
#  - cooldown 6h: don't nag about the same process name more than 4 times a day.
DEFAULTS = {
    "action": os.environ.get("CPU_GUARD_ACTION", "notify").strip().lower(),   # notify | terminate | kill
    "cpu_limit": float(os.environ.get("CPU_GUARD_CPU_LIMIT", "100")),
    "duration": int(os.environ.get("CPU_GUARD_DURATION", "7200")),
    "action_cooldown": int(os.environ.get("CPU_GUARD_ACTION_COOLDOWN", "21600")),
    "popup_every": int(os.environ.get("CPU_GUARD_POPUP_EVERY", "50")),
}
INTERVAL = int(os.environ.get("CPU_GUARD_INTERVAL", "5"))
TERMINATE_GRACE = int(os.environ.get("CPU_GUARD_TERMINATE_GRACE", "5"))
LOG_HEARTBEAT_INTERVAL = int(os.environ.get("CPU_GUARD_LOG_HEARTBEAT_INTERVAL", "3600"))
NOTIFY = os.environ.get("CPU_GUARD_NOTIFY", "1").lower() not in ("0", "false", "no")
NOTIFY_EVENTS = {e.strip().lower() for e in os.environ.get("CPU_GUARD_NOTIFY_EVENTS", "action,error").split(",") if e.strip()}

MODE_LABEL = {"notify": "Notify only", "terminate": "Terminate politely", "kill": "Kill routinely"}


def now_stamp() -> str:
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(message: str) -> None:
    print(f"[{now_stamp()}] {message}", flush=True)


def load_settings() -> dict:
    s = dict(DEFAULTS)
    try:
        s.update(json.loads(CONFIG_PATH.read_text()))
    except (OSError, ValueError):
        pass
    if s["action"] not in MODE_LABEL:
        s["action"] = "notify"
    return s


def save_setting(key: str, value) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        cfg = json.loads(CONFIG_PATH.read_text())
    except (OSError, ValueError):
        cfg = {}
    cfg[key] = value
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2) + "\n")


def apple_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def notify(event: str, title: str, subtitle: str, message: str) -> None:
    if not NOTIFY or event not in NOTIFY_EVENTS:
        return
    script = (f'display notification "{apple_quote(message)}" with title "{apple_quote(title)}" '
              f'subtitle "{apple_quote(subtitle)}"')
    subprocess.run(["osascript", "-e", script], check=False)


# ── Report ──────────────────────────────────────────────────────────────────
LINE_RE = re.compile(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)")
ACTION_RE = re.compile(r"ACTION: ([\w-]+): (\S+) PID (\d+) at ~([\d.]+)% CPU")
START_RE = re.compile(r"started: action=(\w+), threshold=(\d+)% for (\d+)s")


def parse_log(days: int = 7):
    events, modes = [], []
    cutoff = datetime.datetime.now() - datetime.timedelta(days=days)
    try:
        lines = LOG_PATH.read_text(errors="ignore").splitlines()
    except OSError:
        return events, modes
    for line in lines:
        m = LINE_RE.match(line)
        if not m:
            continue
        ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        body = m.group(2)
        a = ACTION_RE.match(body)
        if a and ts >= cutoff:
            events.append({"ts": ts, "result": a.group(1), "name": a.group(2), "pid": int(a.group(3)),
                           "cpu": float(a.group(4))})
            continue
        s = START_RE.match(body)
        if s and ts >= cutoff:
            modes.append((ts, s.group(1), int(s.group(2)), int(s.group(3))))
    return events, modes


def top_processes(n: int = 8):
    try:
        out = subprocess.run(["ps", "-Ao", "pcpu,pid,etime,comm", "-r"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows = []
    for line in out.splitlines()[1:n + 1]:
        parts = line.split(None, 3)
        if len(parts) == 4:
            rows.append((float(parts[0]), int(parts[1]), parts[2], parts[3].split("/")[-1]))
    return rows


def hours(td) -> str:
    s = td.total_seconds()
    return f"{s / 3600:.1f}h" if s >= 5400 else f"{s / 60:.0f} min"


def build_report():
    """Returns (short_text_for_popup, full_markdown_for_ai)."""
    s = load_settings()
    ncpu = os.cpu_count() or 1
    events, modes = parse_log(7)
    by_name = {}
    for e in events:
        by_name.setdefault(e["name"], []).append(e)
    try:
        load = os.getloadavg()
    except OSError:
        load = (0, 0, 0)
    batt = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout.splitlines()[:1]
    power = batt[0].strip() if batt else "unknown"
    mode_now = MODE_LABEL[s["action"]]

    insights = []
    for name, evs in sorted(by_name.items(), key=lambda kv: -len(kv[1])):
        pids = len({e["pid"] for e in evs})
        killed = sum(1 for e in evs if e["result"] in ("killed", "terminated"))
        gaps = [(b["ts"] - a["ts"]).total_seconds() / 60 for a, b in zip(evs, evs[1:])]
        note = PROCESS_NOTES.get(name, "watched background process")
        if killed >= 5 and pids >= killed * 0.8:
            med = f"{statistics.median(gaps):.0f}" if gaps else "?"
            insights.append(
                f"{name} ({note}) was stopped {killed} times in 7 days, and macOS started it again each time "
                f"({pids} different process IDs, median {med} min apart). A service that is restarted over and over "
                f"may never finish its job, so killing it may keep it busy longer instead of ending the load.")
        elif killed:
            insights.append(f"{name} ({note}) was stopped {killed} time(s) in 7 days.")
        else:
            insights.append(f"{name} ({note}) was flagged {len(evs)} time(s) in 7 days and left running "
                            f"({pids} process ID(s)). If it is the same ID each time it is one long job; check whether it ever settles.")
    if not insights:
        insights.append("No watched process crossed the limit in the last 7 days (or the log is empty).")
    insights.append(f"Percentages are per core: this Mac has {ncpu} cores, so 100% is about {100 / ncpu:.0f}% of the whole machine.")

    top = top_processes()
    top_lines = [f"- {c:.0f}% CPU  {name}  (running {et}, pid {pid})" for c, pid, et, name in top]

    mode_hist = [f"- {ts:%Y-%m-%d %H:%M}: mode {a}, limit {lim}% for {dur}s" for ts, a, lim, dur in modes[-8:]]
    counts = [f"- {name}: {len(evs)} events, first {evs[0]['ts']:%m-%d %H:%M}, last {evs[-1]['ts']:%m-%d %H:%M}, "
              f"peak {max(e['cpu'] for e in evs):.0f}%" for name, evs in sorted(by_name.items(), key=lambda kv: -len(kv[1]))]

    settings_line = (f"mode {mode_now}; flags a process after {s['cpu_limit']:.0f}% CPU (per core) for "
                     f"{s['duration'] / 3600:.1f} hours; at most one flag per process name every {s['action_cooldown'] / 3600:.0f} hours")
    full = f"""# CPU Guard report ({now_stamp()})

## Please analyze this for me
I run a small watchdog called CPU Guard on my Mac. It watches a list of noisy macOS background processes
(Apple Intelligence, Contacts sync, Spotlight, iCloud, Photos). It has two modes: "Notify only" (log and notify, kill nothing)
and "Kill routinely" (stop the process when it stays busy, then macOS usually starts it again).
Based on the data below, tell me: (1) is this activity actually a problem for my Mac, (2) which mode I should use,
(3) whether the limit and time window should change, and (4) anything else worth checking. Keep it plain and practical.

## Current settings
{settings_line}
Machine: {ncpu} cores, load average {load[0]:.1f} / {load[1]:.1f} / {load[2]:.1f} (1/5/15 min), {power}

## Automatic observations
""" + "\n".join(f"- {i}" for i in insights) + f"""

## Events in the last 7 days ({len(events)} total)
""" + ("\n".join(counts) or "- none") + """

## Mode history (from the log)
""" + ("\n".join(mode_hist) or "- none recorded") + """

## Busiest processes right now
""" + ("\n".join(top_lines) or "- unavailable") + f"""

Log file: {LOG_PATH}
"""
    short = (f"Mode: {mode_now}\nFlags after {s['cpu_limit']:.0f}% CPU (one core) for {s['duration'] / 3600:.1f} hours.\n\n"
             f"Last 7 days: {len(events)} events"
             + (" (" + ", ".join(f"{n} x{len(e)}" for n, e in list(sorted(by_name.items(), key=lambda kv: -len(kv[1])))[:3]) + ")" if by_name else "")
             + f".\nMac: {ncpu} cores, load {load[0]:.1f}.\n\n" + insights[0])
    return short, full


def show_popup() -> None:
    while True:
        s = load_settings()
        short, full = build_report()
        other = "kill" if s["action"] == "notify" else "notify"
        switch_btn = f"Switch to {MODE_LABEL[other]}"
        script = (f'display dialog "{apple_quote(short)}" with title "CPU Guard report" '
                  f'buttons {{"Close", "{switch_btn}", "Copy analysis for AI"}} default button "Copy analysis for AI" '
                  f'with icon note giving up after 900')
        r = subprocess.run(["osascript", "-e", "with timeout of 1000 seconds", "-e", script, "-e", "end timeout"],
                           capture_output=True, text=True)
        out = r.stdout
        if "Copy analysis for AI" in out:
            subprocess.run(["pbcopy"], input=full, text=True)
            subprocess.run(["osascript", "-e", 'display notification "Paste it into your AI and ask what to change." '
                            'with title "CPU Guard" subtitle "Analysis copied"'])
            return
        if switch_btn in out:
            save_setting("action", other)
            log(f"CONFIG: mode changed to {other} from the popup")
            continue  # show again so the change is visible
        return


# ── Watcher ─────────────────────────────────────────────────────────────────
def bump_notification_counter() -> int:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        st = json.loads(STATE_PATH.read_text())
    except (OSError, ValueError):
        st = {}
    st["notify_count"] = int(st.get("notify_count", 0)) + 1
    STATE_PATH.write_text(json.dumps(st) + "\n")
    return st["notify_count"]


def act_on_process(proc, mode: str):
    try:
        if mode == "notify":
            return "reported", "notify-only mode, nothing was stopped"
        proc.terminate()
        try:
            proc.wait(timeout=TERMINATE_GRACE)
            return "terminated", f"SIGTERM succeeded within {TERMINATE_GRACE}s"
        except psutil.TimeoutExpired:
            if mode == "terminate":
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


def run_watcher() -> None:
    if psutil is None:
        sys.exit("psutil is not installed for this Python; run cpu-guard-install.sh")
    offense, acted_recently = {}, {}
    last_heartbeat = 0.0
    for p in psutil.process_iter(["pid"]):
        try:
            p.cpu_percent(None)
        except Exception:
            pass
    s = load_settings()
    log("started: action=%s, threshold=%.0f%% for %ss, interval=%ss, notify_events=%s"
        % (s["action"], s["cpu_limit"], s["duration"], INTERVAL, ",".join(sorted(NOTIFY_EVENTS)) or "none"))
    notify("start", "CPU Guard started", f"{MODE_LABEL[s['action']]} mode",
           f"Watching {len(WATCH)} known noisy background process names.")

    while True:
        now = time.time()
        s = load_settings()
        if now - last_heartbeat >= LOG_HEARTBEAT_INTERVAL:
            log(f"heartbeat: monitoring watched background processes (mode {s['action']})")
            last_heartbeat = now

        for proc in psutil.process_iter(["pid", "name"]):
            pid = None
            try:
                name = proc.info.get("name") or ""
                pid = proc.info["pid"]
                if SKIP_SUBSTR.search(name) or name not in WATCH:
                    continue
                cpu = proc.cpu_percent(None)
                if cpu > s["cpu_limit"]:
                    offense[pid] = offense.get(pid, 0) + INTERVAL
                    if offense[pid] >= s["duration"]:
                        if now - acted_recently.get(name, 0) >= s["action_cooldown"]:
                            note = PROCESS_NOTES.get(name, "watched macOS background process")
                            result, detail = act_on_process(proc, s["action"])
                            subtitle = f"{name} PID {pid} at ~{cpu:.1f}% CPU"
                            msg = (f"{note}: {name} (PID {pid}) stayed above {s['cpu_limit']:.0f}% of one core "
                                   f"for about {s['duration'] / 3600:.1f} hours. Result: {result}. {detail}.")
                            log(f"ACTION: {result}: {subtitle} - {note}; {detail}")
                            notify("action" if result not in ("error", "access-denied") else "error",
                                   f"CPU Guard: {result}", subtitle, msg)
                            acted_recently[name] = now
                            count = bump_notification_counter()
                            if s["popup_every"] and count % s["popup_every"] == 0:
                                subprocess.Popen([sys.executable, os.path.abspath(__file__), "--popup"])
                        offense[pid] = 0
                else:
                    # brief dips don't reset the clock; the count just drains slowly
                    offense[pid] = max(0, offense.get(pid, 0) - INTERVAL)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                if pid is not None:
                    offense.pop(pid, None)
            except Exception as exc:  # e.g. psutil SystemError on odd processes; never crash the watcher
                log(f"warning: skipped a process ({type(exc).__name__}: {exc})")
        time.sleep(INTERVAL)


def main() -> None:
    args = sys.argv[1:]
    if "--popup" in args:
        show_popup()
    elif "--report" in args:
        print(build_report()[1])
    elif "--set-mode" in args:
        mode = args[args.index("--set-mode") + 1]
        if mode not in MODE_LABEL:
            sys.exit("mode must be notify, terminate or kill")
        save_setting("action", mode)
        log(f"CONFIG: mode changed to {mode}")
        print(f"Mode set to {MODE_LABEL[mode]}. The running guard picks it up within {INTERVAL} seconds.")
    else:
        run_watcher()


if __name__ == "__main__":
    main()
