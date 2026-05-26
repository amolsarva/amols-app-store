# CPU Guard How To

CPU Guard watches a short allowlist of noisy macOS background processes and acts when one stays above the CPU threshold long enough to matter.

## Install Or Reinstall

```bash
cd ~/Documents/root/mac-scripts/cpu-guard
bash cpu-guard-install.sh
```

The installer copies `cpu_guard.py` to `~/bin/cpu_guard.py`, writes the user LaunchAgent `~/Library/LaunchAgents/com.amol.cpu-guard.plist`, starts it immediately, and restarts it at login.

## Default Behavior

- Watches only names in `WATCH` inside `cpu_guard.py`.
- Ignores Claude, OpenAI, and OpenClaw process names.
- Acts after a watched process stays above 80% CPU for about 30 seconds.
- Sends `SIGTERM` first.
- Sends `SIGKILL` only if the process is still alive after the grace period.
- Sends notifications only for actions and errors by default.
- Logs a heartbeat once per hour instead of every polling loop.

## Check Status

```bash
launchctl print "gui/$(id -u)/com.amol.cpu-guard"
pgrep -a -f cpu_guard.py || echo "cpu_guard not running"
tail -f ~/Library/Logs/cpu-guard.out
tail -f ~/Library/Logs/cpu-guard.err
```

## Stop Or Restart

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.amol.cpu-guard.plist
bash ~/Documents/root/mac-scripts/cpu-guard/cpu-guard-install.sh
```

## Safer Tuning Modes

Use notify-only mode while testing a new threshold:

```bash
CPU_GUARD_ACTION=notify bash cpu-guard-install.sh
```

Use terminate-only mode if you want graceful exits but no forced kill:

```bash
CPU_GUARD_ACTION=terminate bash cpu-guard-install.sh
```

Return to the default decisive mode:

```bash
CPU_GUARD_ACTION=kill CPU_GUARD_NOTIFY_EVENTS=action,error bash cpu-guard-install.sh
```

## Configuration

The installer writes these values into the LaunchAgent environment:

```bash
CPU_GUARD_ACTION=kill
CPU_GUARD_NOTIFY_EVENTS=action,error
CPU_GUARD_CPU_LIMIT=80
CPU_GUARD_DURATION=30
CPU_GUARD_INTERVAL=5
CPU_GUARD_ACTION_COOLDOWN=1800
```

`CPU_GUARD_NOTIFY_EVENTS` accepts comma-separated event names. The useful values are:

- `action`: notify when CPU Guard terminates, kills, or reports a hot process.
- `error`: notify when macOS denies termination or another action error occurs.
- `start`: notify when CPU Guard starts.

Set `CPU_GUARD_NOTIFY=0` to disable notifications completely.

Set `CPU_GUARD_WATCH=name1,name2` to replace the built-in watch list for a test or a narrower local setup.

## Manual Foreground Run

```bash
python3 -u cpu_guard.py
```

Foreground mode is useful for watching log lines while tuning thresholds. Stop it with `Ctrl-C`.
