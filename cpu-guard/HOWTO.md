Here’s a clean, sane HOW TO guide you can save alongside your new script. This assumes you’ve put cpu_guard.py in a stable location like ~/bin/cpu_guard.py and you’re using your ~/cpuguard-env virtualenv.

Save this as:
~/docs/automation/HOWTO_CPU_GUARD.md

⸻

CPU Guard (Safe Mode) — How To

A lightweight watchdog to monitor misbehaving macOS background processes and alert you when they hog CPU. This version is designed for human-in-the-loop control: observe first, intervene deliberately.

Location & Assumptions
	•	Script: ~/bin/cpu_guard.py
	•	Python venv: ~/cpuguard-env
	•	macOS Terminal (zsh)

Adjust paths if you placed files elsewhere.

⸻

Start

Run in the foreground (best for first use):

~/cpuguard-env/bin/python ~/bin/cpu_guard.py

Run in the background and keep logs:

nohup ~/cpuguard-env/bin/python ~/bin/cpu_guard.py > /tmp/cpuguard.out 2>&1 &
echo $! > /tmp/cpuguard.pid

Tail logs:

tail -f /tmp/cpuguard.out


⸻

Check if It’s Running

Find the process:

pgrep -a -f cpu_guard.py

Or:

ps aux | grep -i cpu_guard | grep -v grep

If you used the background method:

cat /tmp/cpuguard.pid


⸻

Pause / Resume (without killing)

Pause the process:

kill -STOP <PID>

Resume:

kill -CONT <PID>

List background jobs (if launched in same Terminal session):

jobs

Bring a suspended job back:

fg


⸻

Stop

Graceful stop:

kill <PID>

One-line stop (if you used the pid file):

kill "$(cat /tmp/cpuguard.pid)"

Emergency stop (find and kill by name):

pkill -f cpu_guard.py


⸻

Verify Nothing Is Running

pgrep -a -f cpu_guard.py || echo "cpu_guard not running"


⸻

Safety Defaults
	•	Keep the script in monitor-only mode while tuning thresholds.
	•	Avoid running from iCloud Drive. Sync + executables + background loops is a chaos triangle.
	•	Prefer foreground runs first; background only after you’ve seen a few hours of normal behavior.

⸻

Common Tweaks

Change thresholds inside cpu_guard.py:
	•	CPU_LIMIT: percentage considered “hogging”
	•	DURATION: how long it must sustain high CPU before being flagged
	•	INTERVAL: sampling cadence

After editing:

pkill -f cpu_guard.py
~/cpuguard-env/bin/python ~/bin/cpu_guard.py


⸻

Make It Easy to Control (Optional Shell Aliases)

Add to ~/.zshrc:

alias cpuguard-start='nohup ~/cpuguard-env/bin/python ~/bin/cpu_guard.py > /tmp/cpuguard.out 2>&1 & echo $! > /tmp/cpuguard.pid'
alias cpuguard-stop='pkill -f cpu_guard.py'
alias cpuguard-status='pgrep -a -f cpu_guard.py || echo "cpu_guard not running"'
alias cpuguard-log='tail -f /tmp/cpuguard.out'

Reload:

source ~/.zshrc

Then:

cpuguard-start
cpuguard-status
cpuguard-log
cpuguard-stop


⸻

Debugging

If nothing prints CPU:

pip show psutil

Reinstall if needed:

source ~/cpuguard-env/bin/activate
pip install -U psutil
deactivate

If the script exits instantly:

python -u ~/bin/cpu_guard.py

The -u forces unbuffered output so crashes are visible.

⸻

Philosophy (short, practical)

Treat watchdogs like a smoke alarm, not an automatic fire suppressant. Alerts preserve data; reflexive SIGKILL vaporizes it. The fastest system is the one that’s still intact tomorrow.

⸻

If you want, paste your current cpu_guard.py and I’ll align this HOWTO precisely to the flags and modes you’re using.
