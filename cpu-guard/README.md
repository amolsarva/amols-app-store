# cpu-guard

A lightweight Python watchdog that stops noisy macOS background processes when they sustain high CPU.

## What it does

macOS background daemons (Spotlight, iCloud, Photos analysis, Siri, Apple Intelligence, etc.) periodically use a lot of CPU. This script watches a configurable list of those processes and reacts only when one stays above the CPU limit for a long time.

**Default is Notify only: it logs and notifies, and kills nothing.** Every 50th notification (or on demand) it opens a popup with a report, an AI-ready analysis you can paste into an AI, and a toggle between *Notify only*, *Terminate politely* (SIGTERM) and *Kill routinely* (SIGTERM, then SIGKILL if the process refuses to exit).

Defaults: limit 100% (one full core; percentages are per core), sustained for 2 hours (7200s), at most one reaction per process name every 6 hours. Normal indexing bursts last minutes, so two hours means something is really stuck.

AI-related processes (Claude, OpenAI tools, OpenClaw) are explicitly excluded.

## Usage

```bash
# Foreground (see output in terminal)
python3 cpu_guard.py

# Background with logging
nohup python3 cpu_guard.py > /tmp/cpuguard.out 2>&1 &
echo $! > /tmp/cpuguard.pid

# Check logs
tail -f /tmp/cpuguard.out

# Stop it
kill "$(cat /tmp/cpuguard.pid)"
```

## Launch at login

```bash
bash cpu-guard-install.sh
```

This installs the user LaunchAgent `com.amol.cpu-guard`, starts it immediately,
and restarts it automatically at login.

## Requirements

```bash
Installed automatically through python-guard (`bash cpu-guard-install.sh`); no manual pip needed.
```

Never run bare `pip` here: Homebrew Python refuses it (PEP 668).

## Configuration

The mode and thresholds are normally changed from the popup (stored in `~/.config/cpu-guard/config.json`, which wins over the defaults below) or with:

```bash
python3 cpu_guard.py --popup                       # show the report popup now
python3 cpu_guard.py --report                      # print the report and the AI-ready analysis
python3 cpu_guard.py --set-mode notify|terminate|kill
```

Defaults live in the `DEFAULTS` block of `cpu_guard.py`; the installer bakes environment overrides into the LaunchAgent:

```bash
CPU_GUARD_ACTION=terminate CPU_GUARD_DURATION=3600 bash cpu-guard-install.sh
```

- `CPU_GUARD_ACTION`: `notify` (default), `terminate`, or `kill`
- `CPU_GUARD_CPU_LIMIT`: CPU percentage threshold; default `100`
- `CPU_GUARD_DURATION`: sustained seconds above the threshold; default `7200`
- `CPU_GUARD_ACTION_COOLDOWN`: seconds before reacting again to the same process name; default `21600`
- `CPU_GUARD_POPUP_EVERY`: show the report popup every N notifications; default `50`
- `CPU_GUARD_NOTIFY_EVENTS`: comma-separated events to notify on; default `action,error`
- `CPU_GUARD_WATCH`: optional comma-separated replacement for the built-in watched process list

Add or remove process names in the `WATCH` list to customize what is watched.

## Optional: shell aliases

Add to `~/.zshrc` for quick control:

```bash
alias cpuguard-start='nohup python3 ~/mac-scripts/cpu-guard/cpu_guard.py > /tmp/cpuguard.out 2>&1 & echo $! > /tmp/cpuguard.pid'
alias cpuguard-stop='pkill -f cpu_guard.py'
alias cpuguard-status='pgrep -a -f cpu_guard.py || echo "not running"'
alias cpuguard-log='tail -f /tmp/cpuguard.out'
```

See `HOWTO.md` for a full operations guide.
