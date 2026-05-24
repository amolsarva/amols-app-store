#!/bin/bash
# GitHub Auto-Push Manager v5
# A local TUI for the auto-discovering GitHub sync runner.
# Compatible with macOS bash 3.2.
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/github-autopush"
CONFIG_FILE="$CONFIG_DIR/config"
ROOTS_FILE="$CONFIG_DIR/search_roots.txt"
IGNORE_FILE="$CONFIG_DIR/ignore.txt"
LEGACY_SYNC_FILE="$CONFIG_DIR/sync_enabled.txt"
DISCOVERED_FILE="$CONFIG_DIR/last_scan.txt"
HISTORY_FILE="$CONFIG_DIR/history.tsv"
LAST_RUN_FILE="$CONFIG_DIR/last_run_summary.txt"
LOCK_DIR="$CONFIG_DIR/.runner.lock"
LOOP_PID_FILE="$CONFIG_DIR/session-loop.pid"
PLIST="$HOME/Library/LaunchAgents/com.amol.github-autopush.plist"
LABEL="com.amol.github-autopush"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/github-autopush-runner.sh"
INSTALL_DIR="$HOME/bin"
INSTALL_RUNNER="$INSTALL_DIR/github-autopush-runner.sh"
INSTALL_LOOP="$INSTALL_DIR/github-autopush-loop.sh"

mkdir -p "$CONFIG_DIR"
touch "$IGNORE_FILE" "$LEGACY_SYNC_FILE" "$HISTORY_FILE"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
INTERVAL="${INTERVAL:-300}"
SEARCH_MAX_DEPTH="${SEARCH_MAX_DEPTH:-8}"
PULL_BEFORE_PUSH="${PULL_BEFORE_PUSH:-1}"
AUTO_CONVERT_HTTPS="${AUTO_CONVERT_HTTPS:-1}"
AUTO_CREATE_UPSTREAM="${AUTO_CREATE_UPSTREAM:-1}"
COMMIT_PREFIX="${COMMIT_PREFIX:-auto: sync}"

if [[ ! -f "$ROOTS_FILE" ]]; then
  cat > "$ROOTS_FILE" <<DEFAULTS
$HOME/Documents/root
$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/root
DEFAULTS
fi

NOW_ISO() { date '+%Y-%m-%d %H:%M:%S'; }
clear_scr() { printf '\033c'; }
press_enter() { printf '\nPress Enter to continue...'; read -r _; }
info() { printf '\n\033[1;32m[%s]\033[0m %s\n' "$(NOW_ISO)" "$*"; }
warn() { printf '\n\033[1;33mWARNING:\033[0m %s\n' "$*"; }
err() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*"; }

normalize() {
  python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1" 2>/dev/null || echo "$1"
}

save_config() {
  cat > "$CONFIG_FILE" <<CFG
INTERVAL=$INTERVAL
SEARCH_MAX_DEPTH=$SEARCH_MAX_DEPTH
PULL_BEFORE_PUSH=$PULL_BEFORE_PUSH
AUTO_CONVERT_HTTPS=$AUTO_CONVERT_HTTPS
AUTO_CREATE_UPSTREAM=$AUTO_CREATE_UPSTREAM
COMMIT_PREFIX="$COMMIT_PREFIX"
CFG
}

is_github_url() {
  case "$1" in
    git@github.com:*|ssh://git@github.com/*|https://github.com/*|http://github.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

short_remote() {
  local url="$1"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  url="${url#git@github.com:}"
  url="${url#ssh://git@github.com/}"
  url="${url%.git}"
  echo "$url"
}

is_ignored() {
  local repo needle
  repo="$(normalize "$1")"
  grep -Fxq "$repo" "$IGNORE_FILE" 2>/dev/null && return 0
  while IFS= read -r needle; do
    [[ -z "$needle" || "$needle" == \#* ]] && continue
    case "$repo" in *"$needle"*) return 0 ;; esac
  done < "$IGNORE_FILE"
  return 1
}

ignore_repo() {
  local repo
  repo="$(normalize "$1")"
  grep -Fxq "$repo" "$IGNORE_FILE" 2>/dev/null || echo "$repo" >> "$IGNORE_FILE"
  sort -u "$IGNORE_FILE" -o "$IGNORE_FILE"
}

unignore_repo() {
  local repo tmp
  repo="$(normalize "$1")"
  tmp="$CONFIG_DIR/.ignore.$$"
  grep -Fxv "$repo" "$IGNORE_FILE" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$IGNORE_FILE"
}

discover_all_repos() {
  local tmp root repo remote git_entry
  tmp="$CONFIG_DIR/.manager_scan.$$"
  : > "$tmp"
  while IFS= read -r root; do
    [[ -z "$root" || "$root" == \#* ]] && continue
    root="$(normalize "$root")"
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth "$SEARCH_MAX_DEPTH" \
      \( -name node_modules -o -name .venv -o -name venv -o -name env -o -name __pycache__ -o -name .tox -o -name .mypy_cache -o -name .pytest_cache -o -name dist -o -name build -o -name Library -o -name Movies -o -name Music -o -name Pictures \) -type d -prune -o \
      \( -name .git -print \) 2>/dev/null |
    while IFS= read -r git_entry; do
      if [[ -d "$git_entry" ]]; then repo="${git_entry%/.git}"; else repo="$(dirname "$git_entry")"; fi
      repo="$(normalize "$repo")"
      remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
      [[ -n "$remote" ]] && is_github_url "$remote" && printf '%s\n' "$repo" >> "$tmp"
    done
  done < "$ROOTS_FILE"
  sort -u "$tmp" > "$DISCOVERED_FILE"
  rm -f "$tmp"
}

repo_count() { grep -c '.' "$DISCOVERED_FILE" 2>/dev/null || echo 0; }
managed_count() {
  local count=0 repo
  [[ -f "$DISCOVERED_FILE" ]] || { echo 0; return; }
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    is_ignored "$repo" || count=$((count+1))
  done < "$DISCOVERED_FILE"
  echo "$count"
}

repo_at_index() { sed -n "${1}p" "$DISCOVERED_FILE" 2>/dev/null; }

agent_status() {
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "running" || echo "stopped"
}

install_agent() {
  if [[ ! -f "$RUNNER" ]]; then
    err "Runner not found: $RUNNER"
    return 1
  fi
  chmod +x "$RUNNER"
  mkdir -p "$INSTALL_DIR" "$HOME/Library/Logs" "$(dirname "$PLIST")"
  install -m 755 "$RUNNER" "$INSTALL_RUNNER"
  write_loop_script
  save_config
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-l</string>
    <string>$INSTALL_RUNNER</string>
  </array>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>XDG_CONFIG_HOME</key><string>$HOME/.config</string>
  </dict>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/github-autopush.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/github-autopush.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" && launchctl kickstart -k "gui/$(id -u)/$LABEL"; then
    info "Agent installed and running every ${INTERVAL}s."
  else
    err "Failed to load agent. Check $PLIST and ~/Library/Logs/github-autopush.err."
    return 1
  fi
}

write_loop_script() {
  cat > "$INSTALL_LOOP" <<LOOP
#!/bin/bash
set -uo pipefail
CONFIG_DIR="\${XDG_CONFIG_HOME:-\$HOME/.config}/github-autopush"
CONFIG_FILE="\$CONFIG_DIR/config"
RUNNER="$INSTALL_RUNNER"
LOG="\$HOME/Library/Logs/github-autopush.session-loop.out"
ERR="\$HOME/Library/Logs/github-autopush.session-loop.err"
mkdir -p "\$CONFIG_DIR" "\$HOME/Library/Logs"
while true; do
  [[ -f "\$CONFIG_FILE" ]] && source "\$CONFIG_FILE"
  INTERVAL="\${INTERVAL:-300}"
  /bin/bash -l "\$RUNNER" >> "\$LOG" 2>> "\$ERR"
  sleep "\$INTERVAL"
done
LOOP
  chmod +x "$INSTALL_LOOP"
}

loop_status() {
  local pid
  pid="$(cat "$LOOP_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "running (PID $pid)"
  else
    echo "stopped"
  fi
}

start_loop() {
  local pid
  write_loop_script
  pid="$(cat "$LOOP_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    info "Session loop already running (PID $pid)."
    return 0
  fi
  python3 - "$INSTALL_LOOP" "$LOOP_PID_FILE" <<'PY'
import os, subprocess, sys
script, pid_file = sys.argv[1], sys.argv[2]
if os.fork():
    sys.exit(0)
os.setsid()
if os.fork():
    sys.exit(0)
devnull = open(os.devnull, "rb")
outnull = open(os.devnull, "ab")
p = subprocess.Popen([script], stdin=devnull, stdout=outnull, stderr=outnull, start_new_session=True)
with open(pid_file, "w") as f:
    f.write(str(p.pid) + "\n")
PY
  sleep 0.5
  pid="$(cat "$LOOP_PID_FILE" 2>/dev/null || true)"
  info "Session loop started (PID ${pid:-unknown})."
}

stop_loop() {
  local pid
  pid="$(cat "$LOOP_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    rm -f "$LOOP_PID_FILE"
    info "Session loop stopped."
  else
    warn "Session loop was not running."
  fi
}

stop_agent() {
  if launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then
    info "Agent stopped."
  else
    warn "Agent was not running."
  fi
}

read_summary() { awk -F= -v k="$1" '$1==k{print $2}' "$LAST_RUN_FILE" 2>/dev/null | tail -1; }

show_recent_history() {
  local count="${1:-12}"
  if [[ ! -s "$HISTORY_FILE" ]]; then
    echo "  No history yet."
    return
  fi
  printf '  \033[1m%-19s  %-8s  %-6s  %-24s  %s\033[0m\n' "TIME" "STATUS" "PUSH" "DETAIL" "REPO"
  printf '  %-19s  %-8s  %-6s  %-24s  %s\n' "-------------------" "--------" "------" "------------------------" "----"
  tail -n "$count" "$HISTORY_FILE" | while IFS=$'\t' read -r ts repo branch status detail changed committed pushed _rest; do
    [[ "${pushed:-0}" == "1" ]] && pushed="yes" || pushed="no"
    printf '  %-19s  %-8s  %-6s  %-24s  %s\n' "$ts" "${status:-?}" "$pushed" "${detail:0:24}" "$(basename "${repo:-?}")"
  done
}

list_repos() {
  local idx=1 repo name branch remote mark dirty
  [[ -f "$DISCOVERED_FILE" ]] || discover_all_repos
  [[ -s "$DISCOVERED_FILE" ]] || { echo "  No GitHub repos discovered."; return; }
  printf '\n  \033[1m%-4s %-9s %-28s %-16s %-5s %s\033[0m\n' "#" "STATE" "REPO" "BRANCH" "DIRTY" "REMOTE"
  printf '  %-4s %-9s %-28s %-16s %-5s %s\n' "----" "---------" "----------------------------" "----------------" "-----" "------"
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    name="$(basename "$repo")"
    branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached")"
    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || echo "?")"
    if is_ignored "$repo"; then mark="ignored"; else mark="AUTO"; fi
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]]; then dirty="yes"; else dirty="no"; fi
    printf '  \033[1m%-4s\033[0m %-9s %-28s %-16s %-5s %s\n' \
      "$idx" "$mark" "${name:0:28}" "${branch:0:16}" "$dirty" "$(short_remote "$remote" | cut -c1-56)"
    idx=$((idx+1))
  done < "$DISCOVERED_FILE"
}

manage_repos_menu() {
  local input cmd args n repo
  discover_all_repos
  while true; do
    clear_scr
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                     GitHub Repos: AUTO unless ignored                   ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    list_repos
    echo
    echo "  Commands:"
    echo "    <number>         Toggle AUTO/ignored"
    echo "    ignore <n> [n..] Ignore repos"
    echo "    auto <n> [n..]   Manage repos automatically"
    echo "    all              Manage all discovered GitHub repos"
    echo "    scan             Rescan roots"
    echo "    done             Back"
    printf '\n  Command: '
    read -r input || input=""
    cmd="${input%% *}"
    args="${input#* }"; [[ "$args" == "$cmd" ]] && args=""
    cmd="$(echo "$cmd" | tr '[:upper:]' '[:lower:]')"
    case "$cmd" in
      done|q|back|"") return ;;
      scan) discover_all_repos; info "Scan complete."; sleep 1 ;;
      all)
        while IFS= read -r repo; do [[ -n "$repo" ]] && unignore_repo "$repo"; done < "$DISCOVERED_FILE"
        info "All discovered GitHub repos set to AUTO."; sleep 1 ;;
      ignore)
        for n in $args; do repo="$(repo_at_index "$n")"; [[ -n "$repo" ]] && ignore_repo "$repo"; done
        info "Ignore list updated."; sleep 1 ;;
      auto|on|enable)
        for n in $args; do repo="$(repo_at_index "$n")"; [[ -n "$repo" ]] && unignore_repo "$repo"; done
        info "Auto list updated."; sleep 1 ;;
      *)
        if echo "$cmd" | grep -qE '^[0-9]+$'; then
          repo="$(repo_at_index "$cmd")"
          if [[ -n "$repo" ]]; then
            if is_ignored "$repo"; then unignore_repo "$repo"; info "AUTO: $(basename "$repo")"; else ignore_repo "$repo"; info "Ignored: $(basename "$repo")"; fi
            sleep 0.7
          else
            warn "No repo at index $cmd."; sleep 1
          fi
        else
          warn "Unknown command: $input"; sleep 1
        fi ;;
    esac
  done
}

manage_roots_menu() {
  local idx root choice n newpath tmp
  while true; do
    clear_scr
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                              Search Roots                               ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo
    idx=1
    while IFS= read -r root; do
      [[ -z "$root" || "$root" == \#* ]] && continue
      if [[ -d "$(normalize "$root")" ]]; then
        printf '  \033[1;32m%d)\033[0m %s\n' "$idx" "$root"
      else
        printf '  \033[1;31m%d)\033[0m %s (not found)\n' "$idx" "$root"
      fi
      idx=$((idx+1))
    done < "$ROOTS_FILE"
    echo
    echo "  a) Add root"
    echo "  r) Remove root"
    echo "  d) Done"
    printf '\n  Choice: '
    read -r choice || choice=""
    choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"
    case "$choice" in
      a|add)
        printf '  Path to add: '; read -r newpath || newpath=""
        [[ -z "$newpath" ]] && continue
        echo "$newpath" >> "$ROOTS_FILE"
        sort -u "$ROOTS_FILE" -o "$ROOTS_FILE"
        info "Added: $newpath"; sleep 1 ;;
      r|remove)
        printf '  Remove root number: '; read -r n || n=""
        if echo "$n" | grep -qE '^[0-9]+$'; then
          tmp="$CONFIG_DIR/.roots.$$"
          awk -v drop="$n" 'BEGIN{i=0} /^[[:space:]]*($|#)/{print; next} {i++; if(i!=drop) print}' "$ROOTS_FILE" > "$tmp"
          mv -f "$tmp" "$ROOTS_FILE"
          info "Removed root #$n"
        else
          warn "Enter a number."
        fi
        sleep 1 ;;
      d|done|q|"") return ;;
      *) warn "Unknown choice."; sleep 1 ;;
    esac
  done
}

settings_menu() {
  local choice value
  while true; do
    clear_scr
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                Settings                                 ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo
    printf '  1) Interval seconds          %s\n' "$INTERVAL"
    printf '  2) Search max depth          %s\n' "$SEARCH_MAX_DEPTH"
    printf '  3) Pull/rebase before push   %s\n' "$PULL_BEFORE_PUSH"
    printf '  4) Convert HTTPS to SSH      %s\n' "$AUTO_CONVERT_HTTPS"
    printf '  5) Create missing upstreams  %s\n' "$AUTO_CREATE_UPSTREAM"
    printf '  6) Commit message prefix     %s\n' "$COMMIT_PREFIX"
    echo "  d) Done"
    printf '\n  Choice: '
    read -r choice || choice=""
    case "$choice" in
      1) printf '  New interval: '; read -r value; echo "$value" | grep -qE '^[0-9]+$' && INTERVAL="$value" ;;
      2) printf '  New max depth: '; read -r value; echo "$value" | grep -qE '^[0-9]+$' && SEARCH_MAX_DEPTH="$value" ;;
      3) [[ "$PULL_BEFORE_PUSH" == "1" ]] && PULL_BEFORE_PUSH=0 || PULL_BEFORE_PUSH=1 ;;
      4) [[ "$AUTO_CONVERT_HTTPS" == "1" ]] && AUTO_CONVERT_HTTPS=0 || AUTO_CONVERT_HTTPS=1 ;;
      5) [[ "$AUTO_CREATE_UPSTREAM" == "1" ]] && AUTO_CREATE_UPSTREAM=0 || AUTO_CREATE_UPSTREAM=1 ;;
      6) printf '  New prefix: '; read -r value; [[ -n "$value" ]] && COMMIT_PREFIX="$value" ;;
      d|done|q|"") save_config; return ;;
      *) warn "Unknown choice."; sleep 1 ;;
    esac
    save_config
  done
}

clear_locks() {
  local removed=0 lock_pid repo git_dir lock age
  if [[ -d "$LOCK_DIR" ]]; then
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -z "$lock_pid" ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"; removed=$((removed+1)); echo "  removed runner lock"
    else
      echo "  runner lock is live (PID $lock_pid)"
    fi
  fi
  discover_all_repos
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    git_dir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null || true)"
    [[ -n "$git_dir" ]] || continue
    case "$git_dir" in /*) ;; *) git_dir="$repo/$git_dir" ;; esac
    for lock in index.lock HEAD.lock COMMIT_EDITMSG.lock config.lock packed-refs.lock shallow.lock; do
      [[ -f "$git_dir/$lock" ]] || continue
      age=$(( $(date +%s) - $(stat -f %m "$git_dir/$lock" 2>/dev/null || echo 0) ))
      if [[ "$age" -gt 45 ]]; then rm -f "$git_dir/$lock"; removed=$((removed+1)); echo "  removed $(basename "$repo")/$lock"; fi
    done
  done < "$DISCOVERED_FILE"
  echo "  Removed $removed stale locks."
}

run_now() {
  chmod +x "$RUNNER" 2>/dev/null || true
  clear_locks
  echo
  echo "  Running one full sync cycle..."
  echo "  ────────────────────────────────────────────────────────────────────────"
  "$RUNNER"
  echo "  ────────────────────────────────────────────────────────────────────────"
  press_enter
}

show_dashboard() {
  local total changed committed pushed skipped errors discovered last_ts agent_st
  discover_all_repos
  total="$(read_summary total)"; total="${total:-0}"
  changed="$(read_summary changed)"; changed="${changed:-0}"
  committed="$(read_summary committed)"; committed="${committed:-0}"
  pushed="$(read_summary pushed)"; pushed="${pushed:-0}"
  skipped="$(read_summary skipped)"; skipped="${skipped:-0}"
  errors="$(read_summary errors)"; errors="${errors:-0}"
  discovered="$(read_summary discovered)"; discovered="${discovered:-$(repo_count)}"
  last_ts="$(read_summary timestamp)"; last_ts="${last_ts:-never}"
  agent_st="$(agent_status)"
  clear_scr
  echo "╔══════════════════════════════════════════════════════════════════════════╗"
  echo "║                    GitHub Auto-Push Dashboard v5                        ║"
  echo "╚══════════════════════════════════════════════════════════════════════════╝"
  echo
  printf '  %-22s %s\n' "Agent:" "$agent_st"
  printf '  %-22s %s\n' "Session loop:" "$(loop_status)"
  printf '  %-22s %s\n' "Interval:" "${INTERVAL}s"
  printf '  %-22s %s\n' "Runner:" "$INSTALL_RUNNER"
  printf '  %-22s %s\n' "Last run:" "$last_ts"
  printf '  %-22s %s managed / %s discovered\n' "Repos:" "$(managed_count)" "$(repo_count)"
  printf '  %-22s total=%s changed=%s committed=%s pushed=%s skipped=%s errors=%s\n' "Last cycle:" "$total" "$changed" "$committed" "$pushed" "$skipped" "$errors"
  echo
  echo "  Roots:"
  while IFS= read -r root; do [[ -n "$root" && "$root" != \#* ]] && printf '    - %s\n' "$root"; done < "$ROOTS_FILE"
  echo
  echo "  Recent history:"
  show_recent_history 10
  echo
}

main_menu() {
  local choice
  while true; do
    show_dashboard
    echo "  1) Repos: auto/ignore"
    echo "  2) Install or restart persistent agent"
    echo "  3) Stop persistent agent"
    echo "  4) Run sync now"
    echo "  5) Search roots"
    echo "  6) Settings"
    echo "  7) Clear stale locks"
    echo "  8) Start session loop fallback"
    echo "  9) Stop session loop fallback"
    echo "  s) Show discovered repos"
    echo "  q) Quit"
    printf '\n  Choice: '
    read -r choice || choice=""
    case "$choice" in
      1) manage_repos_menu ;;
      2) install_agent; sleep 1 ;;
      3) stop_agent; sleep 1 ;;
      4) run_now ;;
      5) manage_roots_menu ;;
      6) settings_menu ;;
      7) clear_locks; press_enter ;;
      8) start_loop; sleep 1 ;;
      9) stop_loop; sleep 1 ;;
      s) list_repos; press_enter ;;
      q|quit|exit) clear_scr; exit 0 ;;
      *) warn "Unknown choice."; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  install) install_agent ;;
  stop) stop_agent ;;
  loop-start) start_loop ;;
  loop-stop) stop_loop ;;
  once|run) run_now ;;
  scan) discover_all_repos; list_repos ;;
  *) main_menu ;;
esac
