#!/bin/bash
# python-guard / pyenv.sh — the ONE place in mac-scripts that knows how to get a working Python.
#
# Why: Homebrew's python@3.x ships without Tk (needs a separate `python-tk@3.x`), refuses
# `pip install` into itself (PEP 668), and every minor upgrade (3.13 → 3.14 → 3.15 …) leaves
# venvs pointing at an interpreter that may be gone. Scripts that call bare `python3` break
# silently each time. Everything Python-shaped in this repo goes through here instead.
#
#   pyenv.sh find [--tk] [--mod M]...          print the best python3 that has those modules
#   pyenv.sh exec [--tk] [--mod M]... -- script.py [args]
#                                               run with the best python3; self-heals (installs
#                                               python-tk for the current brew Python) if needed
#   pyenv.sh venv NAME [--pkg P[:module]]... [--restart LABEL]...
#                                               create/repair a private venv OUTSIDE iCloud for a tool,
#                                               rebuilt automatically when Homebrew's Python moves to a
#                                               new minor version; prints its python3 path
#   pyenv.sh ensure                             make this Mac healthy: brew python3 + Tk for the
#                                               current version + every registered venv current
#   pyenv.sh check                              exit 0 if healthy (Backstage New Mac setup uses this)
#   pyenv.sh doctor                             human-readable report
#   pyenv.sh install | uninstall                ensure + LaunchAgent that re-runs `ensure` whenever
#                                               Homebrew relinks python3 (i.e. after every upgrade)
# Flags anywhere: --quiet, --notify (macOS notification when something was fixed)
#
# Bash 3.2 compatible (macOS /bin/bash). No hard-coded home paths.
set -u

GUARD_HOME="${PYGUARD_HOME:-$HOME/Library/Application Support/python-guard}"
VENVS="$GUARD_HOME/venvs"
LOG="${PYGUARD_LOG:-$HOME/Library/Logs/python-guard.log}"
LABEL="com.amol.python-guard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
MIN_MINOR=8          # python 3.8+
QUIET=0; NOTIFY=0; FIXED=""

say()    { [ "$QUIET" = 1 ] || echo "$*" >&2; }
log()    { mkdir -p "$(dirname "$LOG")" 2>/dev/null; echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; say "$*"; }
fixed()  { FIXED="$FIXED$*; "; log "fixed: $*"; }
notify() { [ "$NOTIFY" = 1 ] && [ -n "$FIXED" ] && command -v osascript >/dev/null 2>&1 &&
           osascript -e "display notification \"${FIXED%; }\" with title \"Python guard\"" >/dev/null 2>&1; true; }

brew_bin() { local b; for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { echo "$b"; return 0; }; done; return 1; }
brew_python() { local b; b="$(brew_bin)" || return 1; local p; p="$(dirname "$b")/python3"; [ -x "$p" ] && echo "$p"; }
clt_ok() { [ "$(uname)" != Darwin ] || /usr/bin/xcode-select -p >/dev/null 2>&1; }   # /usr/bin/python3 is a stub that pops an installer without CLT
minor() { "$1" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null; }

# Candidate interpreters, best first: current Homebrew python3, other Homebrew pythons newest→oldest,
# python.org framework build, then Apple's Command Line Tools python (old, but has Tk).
candidates() {
  if [ -n "${PYGUARD_CANDIDATES:-}" ]; then echo "$PYGUARD_CANDIDATES" | tr ' ' '\n'; return; fi
  local p v
  for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do [ -x "$p" ] && echo "$p"; done
  for p in $(ls -d /opt/homebrew/opt/python@3.* /usr/local/opt/python@3.* 2>/dev/null | sort -t. -k2 -n -r); do
    v="${p##*@}"; [ -x "$p/bin/python$v" ] && echo "$p/bin/python$v"
  done
  p=/Library/Frameworks/Python.framework/Versions/Current/bin/python3; [ -x "$p" ] && echo "$p"
  clt_ok && [ -x /usr/bin/python3 ] && echo /usr/bin/python3
  true
}

# meets PY [module...] : python >= 3.MIN_MINOR and every module imports
meets() {
  local py="$1"; shift
  "$py" - "$@" >/dev/null 2>&1 <<PY
import importlib, sys
assert sys.version_info >= (3, $MIN_MINOR)
for m in sys.argv[1:]:
    importlib.import_module(m)
PY
}

find_py() { local c; for c in $(candidates); do meets "$c" "$@" && { echo "$c"; return 0; }; done; return 1; }

# The interpreter venvs are built from: Homebrew's current python3 if present, else the best candidate.
base_python() { local p; p="$(brew_python)" && meets "$p" && { echo "$p"; return 0; }; find_py; }

wait_for_brew() {   # don't collide with an upgrade that's still running (it relinks python3 mid-way)
  local i=0 who
  while who="$(pgrep -fl "Homebrew/brew.rb" 2>/dev/null | head -1)" && [ -n "$who" ] && [ $i -lt 30 ]; do
    [ $i -eq 0 ] && say "waiting for another Homebrew process to finish (up to 5 min): ${who:0:160}"; sleep 10; i=$((i+1))
  done
  [ $i -ge 30 ] && say "Homebrew still busy; trying anyway (brew waits for its own lock)."
  true
}

ensure_brew_python() {
  local b; b="$(brew_bin)" || { say "Homebrew not installed: can't install Python automatically (Backstage ▸ New Mac setup ▸ Homebrew)."; return 1; }
  [ -n "$(brew_python)" ] && return 0
  wait_for_brew; log "installing Homebrew python"
  "$b" install python >>"$LOG" 2>&1 && fixed "installed Homebrew Python" || { log "brew install python failed (see $LOG)"; return 1; }
}

ensure_tk() {
  local b py v; b="$(brew_bin)" || return 1; py="$(brew_python)" || return 1
  meets "$py" tkinter && return 0
  v="$(minor "$py")"; [ -n "$v" ] || return 1
  wait_for_brew; log "installing python-tk@$v (Tk for Homebrew Python $v)"
  "$b" install "python-tk@$v" >>"$LOG" 2>&1
  if meets "$py" tkinter; then fixed "installed Tk for Python $v"; return 0; fi
  log "python-tk@$v install failed (see $LOG)"; return 1
}

# ── venvs ────────────────────────────────────────────────────────────────────
spec_file() { echo "$VENVS/$1.spec"; }
spec_pkgs()     { grep '^pkg ' "$(spec_file "$1")" 2>/dev/null | cut -d' ' -f2-; }
spec_restarts() { grep '^restart ' "$(spec_file "$1")" 2>/dev/null | cut -d' ' -f2-; }
mods_of() { local p; for p in "$@"; do case "$p" in *:*) echo "${p#*:}";; *) echo "$p" | tr '-' '_';; esac; done; }
pips_of() { local p; for p in "$@"; do echo "${p%%:*}"; done; }

venv_healthy() {  # NAME BASE
  local d="$VENVS/$1" base="$2" want have
  [ -x "$d/bin/python3" ] || return 1
  have="$(minor "$d/bin/python3")"; [ -n "$have" ] || return 1
  want="$(minor "$base")"; [ "$have" = "$want" ] || return 1
  # shellcheck disable=SC2046
  meets "$d/bin/python3" $(mods_of $(spec_pkgs "$1"))
}

venv_ensure() {   # NAME → prints python path
  local name="$1" base d old pkgs l
  base="$(base_python)" || { ensure_brew_python && base="$(base_python)"; } || { log "no usable python3 for venv $name"; return 1; }
  d="$VENVS/$name"
  if venv_healthy "$name" "$base"; then echo "$d/bin/python3"; return 0; fi
  old="$(minor "$d/bin/python3" 2>/dev/null)"
  pkgs="$(spec_pkgs "$name")"
  log "building venv $name with Python $(minor "$base")${old:+ (was $old)}: ${pkgs:-no packages}"
  rm -rf "$d"; mkdir -p "$VENVS"
  "$base" -m venv "$d" >>"$LOG" 2>&1 || { log "venv creation failed for $name"; return 1; }
  # shellcheck disable=SC2046
  "$d/bin/python3" -m pip install -q --disable-pip-version-check --upgrade pip $(pips_of $pkgs) >>"$LOG" 2>&1 \
    || { log "pip install failed for $name (see $LOG)"; return 1; }
  venv_healthy "$name" "$base" || { log "venv $name still unhealthy after rebuild"; return 1; }
  fixed "venv $name → Python $(minor "$base")"
  for l in $(spec_restarts "$name"); do
    if [ "$(uname)" = Darwin ] && launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/$(id -u)/$l" >/dev/null 2>&1 && log "restarted $l"
    fi
  done
  echo "$d/bin/python3"
}

cmd_venv() {
  local name="${1:?usage: pyenv.sh venv NAME [--pkg P[:module]]... [--restart LABEL]...}"; shift
  local pkgs="" restarts=""
  while [ $# -gt 0 ]; do
    case "$1" in --pkg) pkgs="$pkgs $2"; shift 2;; --restart) restarts="$restarts $2"; shift 2;; *) shift;; esac
  done
  mkdir -p "$VENVS"
  if [ -n "$pkgs$restarts" ]; then   # (re)register what this tool needs; ensure/agent keeps it current
    { for p in $pkgs; do echo "pkg $p"; done; for r in $restarts; do echo "restart $r"; done; } > "$(spec_file "$name")"
  elif [ ! -f "$(spec_file "$name")" ]; then
    : > "$(spec_file "$name")"
  fi
  venv_ensure "$name"
}

heal_venvs() {
  local s n rc=0
  for s in "$VENVS"/*.spec; do [ -f "$s" ] || continue; n="$(basename "$s" .spec)"; venv_ensure "$n" >/dev/null || rc=1; done
  return $rc
}

# ── commands ─────────────────────────────────────────────────────────────────
parse_mods() { MODS=""; while [ $# -gt 0 ]; do case "$1" in --tk) MODS="$MODS tkinter";; --mod) MODS="$MODS $2"; shift;; --) break;; esac; shift; done; }

cmd_find() { parse_mods "$@"; # shellcheck disable=SC2086
  find_py $MODS || { case "$MODS" in *tkinter*) ensure_brew_python; ensure_tk;; esac; find_py $MODS; }; }

cmd_exec() {
  parse_mods "$@"
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || { echo "usage: pyenv.sh exec [--tk] [--mod M]... -- script.py [args]" >&2; exit 2; }
  local py
  # shellcheck disable=SC2086
  py="$(cmd_find $( for m in $MODS; do [ "$m" = tkinter ] && echo --tk || echo "--mod $m"; done ))" || {
    local msg="No Python with:${MODS}. Run: $(dirname "$SELF")/run.sh ensure"
    case "$MODS" in *tkinter*) local v; v="$(minor "$(brew_python 2>/dev/null || echo python3)")"; msg="No Python with Tk. Fix: brew install python-tk@${v:-3}";; esac
    echo "$msg" >&2
    [ "$(uname)" = Darwin ] && osascript -e "display alert \"Python guard\" message \"$msg\"" >/dev/null 2>&1
    exit 1; }
  exec "$py" "$@"
}

cmd_ensure() {
  local rc=0
  ensure_brew_python || [ -n "$(find_py)" ] || rc=1
  if brew_bin >/dev/null; then ensure_tk || rc=1; fi
  heal_venvs || rc=1
  # keep the agent's private copy (outside iCloud) identical to the repo copy
  if [ -f "$GUARD_HOME/pyenv.sh" ] && [ "$SELF" != "$GUARD_HOME/pyenv.sh" ] && ! cmp -s "$SELF" "$GUARD_HOME/pyenv.sh"; then
    cp "$SELF" "$GUARD_HOME/pyenv.sh" && log "refreshed agent copy of pyenv.sh"
  fi
  notify
  [ $rc -eq 0 ] && say "✓ Python healthy: $(base_python 2>/dev/null) ($(minor "$(base_python 2>/dev/null)" 2>/dev/null))"
  return $rc
}

cmd_check() {   # silent health check; 0 = healthy
  QUIET=1
  local base; base="$(base_python)" || return 1
  if brew_bin >/dev/null; then [ -n "$(brew_python)" ] || return 1; meets "$(brew_python)" tkinter || return 1; else find_py tkinter >/dev/null || return 1; fi
  local s; for s in "$VENVS"/*.spec; do [ -f "$s" ] || continue; venv_healthy "$(basename "$s" .spec)" "$base" || return 1; done
  if [ "$(uname)" = Darwin ]; then launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || return 1; fi
  return 0
}

cmd_doctor() {
  local c rc=0 b base
  echo "Python interpreters (best first):"
  for c in $(candidates); do
    printf "  %-62s %-6s tk=%s\n" "$c" "$(minor "$c" || echo '?')" "$(meets "$c" tkinter && echo yes || echo NO)"
  done
  if b="$(brew_bin)"; then
    local bp; bp="$(brew_python)"
    echo "Homebrew: $b · python3 → ${bp:-NOT INSTALLED} $( [ -n "$bp" ] && minor "$bp")"
    [ -n "$bp" ] && ! meets "$bp" tkinter && { echo "  ✗ Tk missing → brew install python-tk@$(minor "$bp")"; rc=1; }
  else echo "Homebrew: not installed"; fi
  base="$(base_python)" && echo "Base for venvs: $base ($(minor "$base"))" || { echo "✗ no usable python3"; rc=1; }
  echo "Tool venvs ($VENVS):"
  local s n any=0
  for s in "$VENVS"/*.spec; do [ -f "$s" ] || continue; any=1; n="$(basename "$s" .spec)"
    if venv_healthy "$n" "$base"; then echo "  ✓ $n ($(minor "$VENVS/$n/bin/python3")): $(spec_pkgs "$n" | tr '\n' ' ')"
    else echo "  ✗ $n needs a rebuild (python moved or packages missing)"; rc=1; fi
  done
  [ $any -eq 1 ] || echo "  (none registered yet)"
  if [ "$(uname)" = Darwin ]; then
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "Agent: $LABEL loaded (re-checks after every Homebrew Python change)" \
      || { echo "Agent: NOT installed → $(dirname "$SELF")/run.sh install"; rc=1; }
  fi
  echo "Log: $LOG"
  [ $rc -eq 0 ] && echo "✓ healthy" || echo "→ fix everything: $(dirname "$SELF")/run.sh ensure"
  return $rc
}

cmd_install() {
  cmd_ensure || true
  [ "$(uname)" = Darwin ] || { echo "LaunchAgent install is macOS-only" >&2; return 1; }
  mkdir -p "$GUARD_HOME" "$(dirname "$PLIST")" "$(dirname "$LOG")"
  # launchd runs a copy outside iCloud: evicted files and Documents privacy prompts break agents.
  [ "$SELF" = "$GUARD_HOME/pyenv.sh" ] || cp "$SELF" "$GUARD_HOME/pyenv.sh"
  chmod +x "$GUARD_HOME/pyenv.sh"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$GUARD_HOME/pyenv.sh</string><string>ensure</string><string>--quiet</string><string>--notify</string>
  </array>
  <!-- Homebrew relinks bin/python3 on every Python upgrade; that is the moment to re-check. -->
  <key>WatchPaths</key><array>
    <string>/opt/homebrew/bin/python3</string><string>/usr/local/bin/python3</string>
  </array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "✓ installed $LABEL (re-runs after every Homebrew Python change, and every 6h)"
}

cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  [ -f "$PLIST" ] && mv "$PLIST" "$HOME/.Trash/" 2>/dev/null
  echo "Removed $LABEL. Venvs in $VENVS were kept."
}

# global flags
ARGS=()
for a in "$@"; do case "$a" in --quiet) QUIET=1;; --notify) NOTIFY=1;; *) ARGS+=("$a");; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}
cmd="${1:-doctor}"; [ $# -gt 0 ] && shift
case "$cmd" in
  find) cmd_find "$@";;
  exec) cmd_exec "$@";;
  venv) cmd_venv "$@";;
  ensure|repair) cmd_ensure;;
  check) cmd_check;;
  doctor|status) cmd_doctor;;
  install) cmd_install;;
  uninstall) cmd_uninstall;;
  -h|--help|help) sed -n '2,24p' "$SELF";;
  *) echo "unknown command: $cmd (try: doctor, ensure, install, find, exec, venv)" >&2; exit 2;;
esac
