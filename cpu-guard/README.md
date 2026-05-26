# cpu-guard

A lightweight Python watchdog that stops noisy macOS background processes when they sustain high CPU.

## What it does

macOS background daemons (Spotlight, iCloud, Photos analysis, Siri, etc.) periodically spike CPU and slow everything down. This script watches a configurable list of those processes and acts only when one of them sustains high CPU usage for more than 30 seconds.

Default behavior is practical and quiet: try `SIGTERM` first, wait briefly, then use `SIGKILL` only if the process refuses to exit. Notifications are sent only for actions and errors by default, not every threshold crossing.

AI-related processes (Claude, OpenAI tools, OpenClaw) are explicitly excluded from flagging.

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
pip install psutil
```

Python 3.7+ (pre-installed on macOS).

## Configuration

Edit the top of `cpu_guard.py`:

```python
CPU_LIMIT = 80.0   # percent — threshold to start counting
DURATION  = 30     # seconds sustained above limit before acting
INTERVAL  = 5      # seconds between checks
ACTION    = "kill" # kill, terminate, or notify
```

The LaunchAgent can be tuned with environment variables before running the installer:

```bash
CPU_GUARD_ACTION=terminate CPU_GUARD_NOTIFY_EVENTS=action,error bash cpu-guard-install.sh
```

Useful variables:

- `CPU_GUARD_ACTION`: `kill` (default), `terminate`, or `notify`
- `CPU_GUARD_NOTIFY_EVENTS`: comma-separated events; default is `action,error`
- `CPU_GUARD_CPU_LIMIT`: CPU percentage threshold; default is `80`
- `CPU_GUARD_DURATION`: sustained seconds above threshold; default is `30`
- `CPU_GUARD_ACTION_COOLDOWN`: seconds before acting again on the same process name; default is `1800`
- `CPU_GUARD_WATCH`: optional comma-separated replacement for the built-in watched process list

Add or remove process names from the `WATCH` list to customize what can be acted on.

## Optional: shell aliases

Add to `~/.zshrc` for quick control:

```bash
alias cpuguard-start='nohup python3 ~/mac-scripts/cpu-guard/cpu_guard.py > /tmp/cpuguard.out 2>&1 & echo $! > /tmp/cpuguard.pid'
alias cpuguard-stop='pkill -f cpu_guard.py'
alias cpuguard-status='pgrep -a -f cpu_guard.py || echo "not running"'
alias cpuguard-log='tail -f /tmp/cpuguard.out'
```

See `HOWTO.md` for a full operations guide.
