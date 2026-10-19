#!/bin/bash
# CPU guard report. No arguments: popup with the report and the Notify-only / Kill-routinely toggle.
#   --report   print the report + AI-ready analysis   --set-mode notify|kill|terminate
DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PY="$(/bin/bash "$DIR/../python-guard/pyenv.sh" venv cpu-guard --pkg psutil --restart com.amol.cpu-guard)" || PY=python3
if [[ $# -eq 0 ]]; then exec "$PY" "$DIR/cpu_guard.py" --popup; fi
exec "$PY" "$DIR/cpu_guard.py" "$@"
