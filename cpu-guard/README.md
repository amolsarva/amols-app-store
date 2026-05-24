# cpu-guard

A lightweight Python watchdog that monitors noisy macOS background processes and alerts you when they hog CPU — without killing anything automatically.

## What it does

macOS background daemons (Spotlight, iCloud, Photos analysis, Siri, etc.) periodically spike CPU and slow everything down. This script watches a configurable list of those processes and sends a macOS notification if any of them sustain high CPU usage for more than 30 seconds.

**Design philosophy:** alert first, act deliberately. The script never kills processes — it just tells you when something is misbehaving so you can decide what to do.

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
DURATION  = 30     # seconds sustained above limit before alerting
INTERVAL  = 5      # seconds between checks
NOTIFY    = True   # macOS notification on/off
```

Add or remove process names from the `WATCH` list to customize what's monitored.

## Optional: shell aliases

Add to `~/.zshrc` for quick control:

```bash
alias cpuguard-start='nohup python3 ~/mac-scripts/cpu-guard/cpu_guard.py > /tmp/cpuguard.out 2>&1 & echo $! > /tmp/cpuguard.pid'
alias cpuguard-stop='pkill -f cpu_guard.py'
alias cpuguard-status='pgrep -a -f cpu_guard.py || echo "not running"'
alias cpuguard-log='tail -f /tmp/cpuguard.out'
```

See `HOWTO.md` for a full operations guide.
