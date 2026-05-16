#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║         GitHub Auto-Push Manager  v4                                    ║
# ║  — Discovers git repos in your search folders on launch                 ║
# ║  — Lets you toggle sync on/off per repo                                 ║
# ║  — Drives a background LaunchAgent that keeps synced repos up to date   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# Compatible with bash 3.2+ (macOS default)
set -uo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/github-autopush"
CONFIG_FILE="$CONFIG_DIR/config"
ROOTS_FILE="$CONFIG_DIR/search_roots.txt"   # one root per line
SYNC_FILE="$CONFIG_DIR/sync_enabled.txt"    # one repo per line = enabled for sync
HISTORY_FILE="$CONFIG_DIR/history.tsv"
LAST_RUN_FILE="$CONFIG_DIR/last_run_summary.txt"
LOCK_DIR="$CONFIG_DIR/.runner.lock"
PLIST="$HOME/Library/LaunchAgents/com.amol.github-autopush.plist"
LABEL="com.amol.github-autopush"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

RUNNER_CANDIDATES=(
  "$SCRIPT_DIR/github-autopush-runner.sh"
  "$HOME/bin/github-autopush-runner.sh"
)

mkdir -p "$CONFIG_DIR"
touch "$SYNC_FILE" "$HISTORY_FILE"

# ── Config ────────────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
INTERVAL="${INTERVAL:-300}"

# Seed default search roots file if it doesn't exist
if [[ ! -f "$ROOTS_FILE" ]]; then
  cat > "$ROOTS_FILE" <<DEFAULTS
$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/root
$HOME/Documents
DEFAULTS
fi

save_config() {
  cat > "$CONFIG_FILE" <<CFG
INTERVAL=$INTERVAL
CFG
}

# ── Helpers ───────────────────────────────────────────────────────────────────
NOW_ISO()     { date '+%Y-%m-%d %H:%M:%S'; }
clear_scr()   { printf '\033c'; }
press_enter() { printf '\nPress Enter to continue…'; read -r _; }

info() { printf '\n\033[1;32m[%s]\033[0m %s\n\n' "$(NOW_ISO)" "$*"; }
warn() { printf '\n\033[1;33mWARNING:\033[0m %s\n\n' "$*"; }
err()  { printf '\n\033[1;31mERROR:\033[0m %s\n\n' "$*"; }

normalize() {
  python3 -c "import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))" "$1" 2>/dev/null || echo "$1"
}

resolve_runner() {
  local c
  for c in "${RUNNER_CANDIDATES[@]}"; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  echo "${RUNNER_CANDIDATES[0]}"
  return 1
}
RUNNER="$(resolve_runner || true)"

# ── Repo discovery ────────────────────────────────────────────────────────────
# Writes discovered repos to a temp file; prints the path
DISCOVERED_CACHE="$CONFIG_DIR/.discovered_cache.txt"

discover_repos() {
  # Re-scan every time this is called; write to cache
  local root
  rm -f "$DISCOVERED_CACHE"
  while IFS= read -r root; do
    [[ -z "$root" || "$root" == \#* ]] && continue
    root="$(normalize "$root")"
    [[ -d "$root" ]] || continue
    # find .git dirs but skip node_modules and nested .git
    find "$root" -type d -name ".git" 2>/dev/null \
      | grep -v '/node_modules/' \
      | grep -v '/.git/.git' \
      | sed 's|/.git$||' \
      >> "$DISCOVERED_CACHE"
  done < "$ROOTS_FILE"
  # Sort + deduplicate in place
  if [[ -f "$DISCOVERED_CACHE" ]]; then
    sort -u "$DISCOVERED_CACHE" -o "$DISCOVERED_CACHE"
  else
    touch "$DISCOVERED_CACHE"
  fi
}

repo_count()   { [[ -f "$DISCOVERED_CACHE" ]] && grep -c '.' "$DISCOVERED_CACHE" 2>/dev/null || echo 0; }
synced_count() { grep -c '.' "$SYNC_FILE" 2>/dev/null || echo 0; }

# ── Sync-list helpers ─────────────────────────────────────────────────────────
is_synced() {
  local repo
  repo="$(normalize "$1")"
  grep -Fxq "$repo" "$SYNC_FILE" 2>/dev/null
}

enable_sync() {
  local repo
  repo="$(normalize "$1")"
  grep -Fxq "$repo" "$SYNC_FILE" 2>/dev/null || echo "$repo" >> "$SYNC_FILE"
  sort -u "$SYNC_FILE" -o "$SYNC_FILE"
}

disable_sync() {
  local repo
  repo="$(normalize "$1")"
  grep -Fxv "$repo" "$SYNC_FILE" > "$SYNC_FILE.tmp" 2>/dev/null || true
  mv -f "$SYNC_FILE.tmp" "$SYNC_FILE"
}

# ── Repo list display ─────────────────────────────────────────────────────────
list_repos() {
  [[ -f "$DISCOVERED_CACHE" ]] || { echo "  (not scanned yet)"; return; }
  [[ -s "$DISCOVERED_CACHE" ]] || { echo "  No git repos found under your search roots."; return; }

  local idx=1 repo name branch remote sync_mark

  printf '\n'
  printf '  \033[1m%-4s  %-6s  %-28s  %-18s  %s\033[0m\n' "#" "SYNC" "REPO" "BRANCH" "REMOTE"
  printf '  %-4s  %-6s  %-28s  %-18s  %s\n' "----" "------" "----------------------------" "------------------" "------"

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    name="$(basename "$repo")"
    branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")"
    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || echo "(no remote)")"
    # Shorten GitHub URLs for display
    remote="${remote#https://github.com/}"
    remote="${remote#git@github.com:}"
    remote="${remote%.git}"

    if is_synced "$repo"; then
      sync_mark="\033[1;32m✓ ON  \033[0m"
    else
      sync_mark="\033[0;90m  off \033[0m"
    fi

    printf "  \033[1m%-4s\033[0m  %b  %-28s  %-18s  %s\n" \
      "$idx" "$sync_mark" "${name:0:28}" "${branch:0:18}" "${remote:0:48}"
    idx=$((idx+1))
  done < "$DISCOVERED_CACHE"
  printf '\n'
}

# Returns repo path at 1-based index $1 from cache
repo_at_index() {
  local n="$1"
  [[ -f "$DISCOVERED_CACHE" ]] || return 1
  sed -n "${n}p" "$DISCOVERED_CACHE"
}

# ── Toggle menu ───────────────────────────────────────────────────────────────
toggle_sync_menu() {
  discover_repos   # fresh scan every time we enter this menu

  if [[ ! -s "$DISCOVERED_CACHE" ]]; then
    warn "No git repos found. Check your search roots (option 6)."
    press_enter
    return
  fi

  local input cmd args n repo

  while true; do
    clear_scr
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                     Select Repos to Auto-Sync                           ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    list_repos

    echo "  Commands:"
    echo "    <number>        Toggle sync for that repo (e.g.  3)"
    echo "    on  <n> [n…]    Enable sync  (e.g.  on 1 3 5)"
    echo "    off <n> [n…]    Disable sync (e.g.  off 2 4)"
    echo "    all             Enable sync for ALL repos"
    echo "    none            Disable sync for ALL repos"
    echo "    done            Back to main menu"
    printf '\n  Command: '
    read -r input || input=""

    # Split input into cmd + rest
    cmd="${input%% *}"
    args="${input#* }"
    [[ "$args" == "$cmd" ]] && args=""
    cmd="$(echo "$cmd" | tr '[:upper:]' '[:lower:]')"

    case "$cmd" in
      done|q|back|"")
        return ;;

      all)
        while IFS= read -r repo; do
          [[ -z "$repo" ]] && continue
          enable_sync "$repo"
        done < "$DISCOVERED_CACHE"
        info "Sync enabled for all repos."
        sleep 1 ;;

      none)
        while IFS= read -r repo; do
          [[ -z "$repo" ]] && continue
          disable_sync "$repo"
        done < "$DISCOVERED_CACHE"
        info "Sync disabled for all repos."
        sleep 1 ;;

      on)
        for n in $args; do
          repo="$(repo_at_index "$n")"
          if [[ -n "$repo" ]]; then
            enable_sync "$repo"
            info "Sync ON:  $(basename "$repo")"
          else
            warn "No repo at index $n"
          fi
        done
        sleep 0.8 ;;

      off)
        for n in $args; do
          repo="$(repo_at_index "$n")"
          if [[ -n "$repo" ]]; then
            disable_sync "$repo"
            info "Sync OFF: $(basename "$repo")"
          else
            warn "No repo at index $n"
          fi
        done
        sleep 0.8 ;;

      *)
        # Bare number = toggle
        if echo "$cmd" | grep -qE '^[0-9]+$'; then
          repo="$(repo_at_index "$cmd")"
          if [[ -n "$repo" ]]; then
            if is_synced "$repo"; then
              disable_sync "$repo"
              info "Sync OFF: $(basename "$repo")"
            else
              enable_sync "$repo"
              info "Sync ON:  $(basename "$repo")"
            fi
            sleep 0.6
          else
            warn "No repo at index $cmd."
            sleep 1
          fi
        else
          warn "Unknown command: $input"
          sleep 1
        fi ;;
    esac
  done
}

# ── Search roots management ───────────────────────────────────────────────────
manage_roots_menu() {
  local idx root choice n newpath

  while true; do
    clear_scr
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                         Search Roots                                    ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo
    idx=1
    while IFS= read -r root; do
      [[ -z "$root" || "$root" == \#* ]] && continue
      if [[ -d "$(normalize "$root")" ]]; then
        printf '  \033[1;32m%d)\033[0m %s\n' "$idx" "$root"
      else
        printf '  \033[1;31m%d)\033[0m %s  (not found)\n' "$idx" "$root"
      fi
      idx=$((idx+1))
    done < "$ROOTS_FILE"
    echo
    echo "  a) Add a search root"
    echo "  r) Remove a search root"
    echo "  d) Done"
    echo
    printf '  Choice: '
    read -r choice || choice=""
    choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"

    case "$choice" in
      a|add)
        printf '  Path to add: '
        read -r newpath || newpath=""
        [[ -z "$newpath" ]] && continue
        if [[ -d "$(normalize "$newpath")" ]]; then
          echo "$newpath" >> "$ROOTS_FILE"
          info "Added: $newpath"
        else
          warn "Directory not found: $newpath  (adding anyway)"
          echo "$newpath" >> "$ROOTS_FILE"
        fi
        sleep 1 ;;

      r|remove)
        printf '  Remove root number: '
        read -r n || n=""
        if echo "$n" | grep -qE '^[0-9]+$'; then
          local total_roots
          total_roots="$(grep -c '.' "$ROOTS_FILE" 2>/dev/null || echo 0)"
          if [[ "$n" -ge 1 && "$n" -le "$total_roots" ]]; then
            sed -i "" "${n}d" "$ROOTS_FILE" 2>/dev/null || sed -i "${n}d" "$ROOTS_FILE"
            info "Removed root #$n"
          else
            warn "Invalid number: $n"
          fi
        else
          warn "Please enter a number."
        fi
        sleep 1 ;;

      d|done|q|"") return ;;
      *) warn "Unknown choice" ; sleep 1 ;;
    esac
  done
}

# ── Agent management ──────────────────────────────────────────────────────────
agent_status() {
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "running" || echo "stopped"
}

install_agent() {
  if [[ ! -f "$RUNNER" ]]; then
    err "Runner not found: $RUNNER"
    return 1
  fi
  chmod +x "$RUNNER"
  save_config
  mkdir -p "$(dirname "$PLIST")"
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
    <string>$RUNNER</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/github-autopush.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/github-autopush.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && \
  launchctl kickstart -k "gui/$(id -u)/$LABEL" && \
  info "Agent installed and running (every ${INTERVAL}s)" || \
  err "Failed to load agent — check $PLIST"
}

stop_agent() {
  if launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then
    info "Agent stopped."
  else
    warn "Agent was not running."
  fi
}

set_interval() {
  printf '  New interval in seconds [current: %s]: ' "$INTERVAL"
  read -r newint || newint=""
  if echo "$newint" | grep -qE '^[0-9]+$'; then
    INTERVAL="$newint"
    save_config
    info "Interval set to ${INTERVAL}s. Reinstall agent to apply (option 2)."
  else
    err "Must be a whole number."
  fi
}

# ── Dashboard ─────────────────────────────────────────────────────────────────
read_summary() { awk -F= -v k="$1" '$1==k{print $2}' "$LAST_RUN_FILE" 2>/dev/null | tail -1; }

show_recent_history() {
  local count="${1:-10}"
  if [[ ! -s "$HISTORY_FILE" ]]; then
    echo "  No history yet."
    return
  fi
  printf '  \033[1m%-19s  %-8s  %-6s  %-22s  %s\033[0m\n' "TIME" "STATUS" "PUSHED" "DETAIL" "REPO"
  printf '  %-19s  %-8s  %-6s  %-22s  %s\n' "-------------------" "--------" "------" "----------------------" "----"
  tail -n "$count" "$HISTORY_FILE" | while IFS=$'\t' read -r ts repo branch status detail changed committed pushed _rest; do
    local short_repo pushed_icon
    short_repo="$(basename "${repo:-?}")"
    [[ "${pushed:-0}" == "1" ]] && pushed_icon="⬆ yes" || pushed_icon="  no"
    printf '  %-19s  %-8s  %-6s  %-22s  %s\n' \
      "$ts" "${status:-?}" "$pushed_icon" "${detail:0:22}" "$short_repo"
  done
}

show_dashboard() {
  local total changed committed pushed skipped errors last_ts agent_st
  total="$(read_summary total)";         total="${total:-0}"
  changed="$(read_summary changed)";     changed="${changed:-0}"
  committed="$(read_summary committed)"; committed="${committed:-0}"
  pushed="$(read_summary pushed)";       pushed="${pushed:-0}"
  skipped="$(read_summary skipped)";     skipped="${skipped:-0}"
  errors="$(read_summary errors)";       errors="${errors:-0}"
  last_ts="$(read_summary timestamp)";   last_ts="${last_ts:-never}"
  agent_st="$(agent_status)"

  clear_scr
  echo "╔══════════════════════════════════════════════════════════════════════════╗"
  echo "║                  GitHub Auto-Push Dashboard  v4                         ║"
  echo "╚══════════════════════════════════════════════════════════════════════════╝"
  echo
  echo "  Search roots:"
  while IFS= read -r root; do
    [[ -z "$root" || "$root" == \#* ]] && continue
    printf '    • %s\n' "$root"
  done < "$ROOTS_FILE"
  echo
  printf '  %-18s %s\n' "Runner:"       "$RUNNER"
  printf '  %-18s %s\n' "Agent:"        "$agent_st"
  printf '  %-18s %s\n' "Interval:"     "${INTERVAL}s"
  printf '  %-18s %s\n' "Last run:"     "$last_ts"
  printf '  %-18s %s / %s repos synced\n' "Repos:"  "$(synced_count)" "$(repo_count)"
  echo
  printf '  Total: %-5s  Changed: %-5s  Committed: %-5s  Pushed: %-5s  Errors: %-5s\n' \
    "$total" "$changed" "$committed" "$pushed" "$errors"
  echo
  echo "  Recent history:"
  show_recent_history 10
  echo
}

# ── Clear locks ───────────────────────────────────────────────────────────────
clear_locks() {
  local removed=0 skipped=0 repo lock

  echo
  echo "  ─── Clearing locks ──────────────────────────────────────────────────────"

  # Age threshold: locks older than this many seconds are considered stale
  local STALE_SECS=30

  # Helper: seconds since file was last modified (macOS stat)
  lock_age_secs() { echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0) )); }

  # 1. Runner lock
  if [[ -d "$LOCK_DIR" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      printf '  %-52s %s\n' "runner (.runner.lock)" "SKIP  (live PID $lock_pid)"
      skipped=$((skipped+1))
    else
      rm -rf "$LOCK_DIR"
      printf '  %-52s %s\n' "runner (.runner.lock)" "removed  (dead PID ${lock_pid:-unknown})"
      removed=$((removed+1))
    fi
  else
    printf '  %-52s %s\n' "runner (.runner.lock)" "clean"
  fi

  # 2. Per-repo git lock files for every synced repo
  local git_locks=("index.lock" "HEAD.lock" "COMMIT_EDITMSG.lock" "config.lock" "packed-refs.lock")
  if [[ -s "$SYNC_FILE" ]]; then
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      local lockname
      for lockname in "${git_locks[@]}"; do
        lock="$repo/.git/$lockname"
        if [[ -f "$lock" ]]; then
          local age
          age="$(lock_age_secs "$lock")"
          if [[ "$age" -lt "$STALE_SECS" ]] && pgrep -x git >/dev/null 2>&1; then
            printf '  %-52s %s\n' "$(basename "$repo")/$lockname" "SKIP  (${age}s old, git running)"
            skipped=$((skipped+1))
          else
            rm -f "$lock"
            printf '  %-52s %s\n' "$(basename "$repo")/$lockname" "removed  (${age}s old)"
            removed=$((removed+1))
          fi
        fi
      done
    done < "$SYNC_FILE"
  fi

  echo "  ─────────────────────────────────────────────────────────────────────────"
  printf '  Removed: %s   Skipped (live): %s\n\n' "$removed" "$skipped"
}

# ── Run once ──────────────────────────────────────────────────────────────────
run_now() {
  [[ -x "$RUNNER" ]] || chmod +x "$RUNNER" 2>/dev/null || true
  if [[ ! -x "$RUNNER" ]]; then
    err "Runner not executable: $RUNNER"
    press_enter
    return
  fi
  clear_locks
  echo "  Running one push cycle…"
  echo "  ─────────────────────────────────────────────────────────────────────────"
  "$RUNNER"
  echo "  ─────────────────────────────────────────────────────────────────────────"
  echo
  press_enter
}

# ── Logs ──────────────────────────────────────────────────────────────────────
show_logs() {
  echo
  echo "  ─── stdout (last 60 lines) ──────────────────────────────────────────────"
  tail -n 60 "$HOME/Library/Logs/github-autopush.out" 2>/dev/null || echo "  (no log yet)"
  echo
  echo "  ─── stderr (last 40 lines) ──────────────────────────────────────────────"
  tail -n 40 "$HOME/Library/Logs/github-autopush.err" 2>/dev/null || echo "  (no log yet)"
  echo
  press_enter
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
  save_config
  # Initial scan so dashboard shows repo count immediately
  discover_repos

  local choice
  while true; do
    show_dashboard
    echo "  ┌─ Repos ──────────────────────────────────────────────────────────────┐"
    echo "  │  1) View & toggle repo sync  (choose which repos to auto-sync)       │"
    echo "  ├─ Agent ──────────────────────────────────────────────────────────────┤"
    echo "  │  2) Install / restart background agent                               │"
    echo "  │  3) Stop background agent                                            │"
    echo "  │  4) Run one push cycle now  (clears locks first)                     │"
    echo "  │  5) Change sync interval                                             │"
    echo "  ├─ Config ─────────────────────────────────────────────────────────────┤"
    echo "  │  6) Manage search roots  (add/remove folders to scan)                │"
    echo "  ├─ Debug ──────────────────────────────────────────────────────────────┤"
    echo "  │  7) Show logs                                                        │"
    echo "  │  8) Refresh dashboard                                                │"
    echo "  │  9) Clear locks  (runner + all repo index.locks)                     │"
    echo "  │  q) Quit                                                             │"
    echo "  └──────────────────────────────────────────────────────────────────────┘"
    echo
    printf '  Choose: '
    read -r choice || choice=""
    choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"

    case "$choice" in
      1) toggle_sync_menu ;;
      2) install_agent;  press_enter ;;
      3) stop_agent;     press_enter ;;
      4) run_now ;;
      5) set_interval;   press_enter ;;
      6) manage_roots_menu ;;
      7) show_logs ;;
      8) discover_repos ;;
      9) clear_locks;    press_enter ;;
      q|quit|exit) echo; exit 0 ;;
      *) warn "Unknown choice: ${choice:-<empty>}"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
