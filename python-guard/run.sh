#!/bin/bash
# Python guard: keeps a working Python 3 (with Tk) and every tool's private venv current on this Mac.
# No argument = doctor. See pyenv.sh for all commands (find, exec, venv, ensure, check, install).
exec /bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pyenv.sh" "${@:-doctor}"
