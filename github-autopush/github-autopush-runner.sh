#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║         GitHub Auto-Push Runner  v4                                     ║
# ║  — Called by the LaunchAgent on every interval tick                     ║
# ║  — Only syncs repos listed in sync_enabled.txt                          ║
# ║  — Compatible with bash 3.2+ (macOS default)                            ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/github-autopush"
CONFIG_FILE="$CONFIG_DIR/config"
SYNC_FILE="$CONFIG_DIR/sync_enabled.txt"
HISTORY_FILE="$CONFIG_DIR/history.tsv"
LAST_RUN_FILE="$CONFIG_DIR/last_run_summary.txt"
LOCK_DIR="$CONFIG_DIR/.runner.lock"

mkdir -p "$CONFIG_DIR"
touch "$SYNC_FILE" "$HISTORY_FILE"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
INTERVAL="${INTERVAL:-300}"

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
export LC_ALL=C

# ── Logging ───────────────────────────────────────────────────────────────────
NOW_ISO() { date '+%Y-%m-%d %H:%M:%S'; }
log()     { printf '[%s] %s\n'         "$(NOW_ISO)" "$*"; }
log_err() { printf '[%s] ERROR: %s\n'  "$(NOW_ISO)" "$*" >&2; }

# ── Utilities ─────────────────────────────────────────────────────────────────
normalize() {
  python3 -c "import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))" "$1" 2>/dev/null || echo "$1"
}

# Run a command with a timeout (seconds); exits 124 on timeout
with_timeout() {
  local secs="$1"; shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys
secs = int(sys.argv[1])
cmd  = sys.argv[2:]
try:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=secs)
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    sys.exit(p.returncode)
except subprocess.TimeoutExpired as e:
    sys.stdout.write(e.stdout or "")
    sys.stderr.write(e.stderr or "")
    sys.stderr.write(f"\nTIMEOUT after {secs}s: {' '.join(cmd)}\n")
    sys.exit(124)
PY
}

git_q()    { git -C "$1" "${@:2}"; }                 # instant ops, no timeout
git_safe() { with_timeout 60 git -C "$1" "${@:2}"; } # network ops get 60s

# ── State checks ──────────────────────────────────────────────────────────────
current_branch() { git_q "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true; }
upstream_ref()   { git_q "$1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true; }

safe_repo_state() {
  local r="$1"
  [[ -d "$r/.git" ]]                  || { echo "not_git_dir";        return 1; }
  [[ -n "$(current_branch "$r")" ]]   || { echo "detached_head";      return 1; }
  [[ ! -f "$r/.git/MERGE_HEAD" ]]     || { echo "merge_in_progress";  return 1; }
  [[ ! -d "$r/.git/rebase-apply" ]]   || { echo "rebase_apply";       return 1; }
  [[ ! -d "$r/.git/rebase-merge" ]]   || { echo "rebase_merge";       return 1; }
  [[ ! -f "$r/.git/CHERRY_PICK_HEAD" ]] || { echo "cherry_pick";      return 1; }
  echo "ok"
}

# ── History ───────────────────────────────────────────────────────────────────
# Fields: timestamp repo branch status detail changed committed pushed
append_history() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(NOW_ISO)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$HISTORY_FILE"
}

# ── Core: push one repo ───────────────────────────────────────────────────────
push_repo() {
  local repo="$1"
  repo="$(normalize "$repo")"

  local branch upstream state detail
  local changed=0 committed=0 pushed=0

  # ── Safety checks ─────────────────────────────────────────────────────────
  if [[ ! -d "$repo" ]]; then
    log "SKIP  $repo  [directory_missing]"
    append_history "$repo" "-" "skipped" "directory_missing" 0 0 0
    return 0
  fi

  state="$(safe_repo_state "$repo")" || {
    log "SKIP  $repo  [$state]"
    append_history "$repo" "-" "skipped" "$state" 0 0 0
    return 0
  }

  branch="$(current_branch "$repo")"

  if ! git_q "$repo" remote get-url origin >/dev/null 2>&1; then
    log "SKIP  $repo [$branch]  [no_origin]"
    append_history "$repo" "$branch" "skipped" "no_origin" 0 0 0
    return 0
  fi

  upstream="$(upstream_ref "$repo")"

  # ── Clear stale git lock files before operating on this repo ─────────────
  local git_lock lock_age
  for git_lock in index.lock HEAD.lock COMMIT_EDITMSG.lock config.lock packed-refs.lock; do
    if [[ -f "$repo/.git/$git_lock" ]]; then
      lock_age=$(( $(date +%s) - $(stat -f %m "$repo/.git/$git_lock" 2>/dev/null || echo 0) ))
      if [[ "$lock_age" -lt 30 ]] && pgrep -x git >/dev/null 2>&1; then
        log "SKIP  $(basename "$repo") [$branch]  [${git_lock}_${lock_age}s_git_running]"
        append_history "$repo" "$branch" "skipped" "lock_${git_lock}" 0 0 0
        return 0
      else
        rm -f "$repo/.git/$git_lock"
        log "INFO  Removed stale $git_lock in $(basename "$repo") (${lock_age}s old)"
      fi
    fi
  done

  # ── Stage uncommitted changes ──────────────────────────────────────────────
  local porcelain
  porcelain="$(git_q "$repo" status --porcelain 2>/dev/null || true)"

  if [[ -n "$porcelain" ]]; then
    changed=1
    if ! git_safe "$repo" add -A >/dev/null 2>/tmp/gap-add.err; then
      # If add failed due to lock contention, skip gracefully this cycle
      if grep -qi 'index.lock\|lock.*exists\|could not lock' /tmp/gap-add.err 2>/dev/null; then
        log "SKIP  $(basename "$repo") [$branch]  [lock_contention_on_add]"
        append_history "$repo" "$branch" "skipped" "lock_contention" 1 0 0
        return 0
      fi
      log_err "git add failed — $repo: $(cat /tmp/gap-add.err)"
      append_history "$repo" "$branch" "error" "git_add_failed" 1 0 0
      return 1
    fi

    # Confirm something is actually staged before committing
    if git_q "$repo" diff --cached --quiet 2>/dev/null; then
      changed=0   # only untrackable changes (e.g. mode bits) — nothing to commit
    else
      local msg="auto: sync $(date '+%Y-%m-%d %H:%M:%S')"
      if git_safe "$repo" commit -m "$msg" >/dev/null 2>/tmp/gap-commit.err; then
        committed=1
      else
        if grep -qi 'nothing to commit' /tmp/gap-commit.err 2>/dev/null; then
          committed=0
        else
          log_err "git commit failed — $repo: $(cat /tmp/gap-commit.err)"
          append_history "$repo" "$branch" "error" "git_commit_failed" "$changed" 0 0
          return 1
        fi
      fi
    fi
  fi

  # ── Pull remote changes first (rebase) so we can push without rejection ──────
  if [[ -n "$upstream" ]]; then
    if ! git_safe "$repo" pull --rebase --autostash >/dev/null 2>/tmp/gap-pull.err; then
      if grep -qi 'index.lock\|lock.*exists\|could not lock' /tmp/gap-pull.err 2>/dev/null; then
        log "SKIP  $(basename "$repo") [$branch]  [lock_contention_on_pull]"
        append_history "$repo" "$branch" "skipped" "lock_contention" "$changed" "$committed" 0
        return 0
      fi
      log_err "git pull --rebase failed — $repo: $(cat /tmp/gap-pull.err)"
      append_history "$repo" "$branch" "error" "pull_rebase_failed" "$changed" "$committed" 0
      return 1
    fi
  fi

  # ── Convert HTTPS remote to SSH (HTTPS is blocked by GIT_TERMINAL_PROMPT=0) ──
  local remote_url
  remote_url="$(git_q "$repo" remote get-url origin 2>/dev/null || true)"
  if [[ "$remote_url" == https://github.com/* ]]; then
    local ssh_url
    ssh_url="$(echo "$remote_url" | sed 's|https://github.com/|git@github.com:|')"
    git_q "$repo" remote set-url origin "$ssh_url"
    log "INFO  Converted HTTPS→SSH for $(basename "$repo"): $ssh_url"
  fi

  # ── Push ──────────────────────────────────────────────────────────────────
  local push_rc
  if [[ -z "$upstream" ]]; then
    # No upstream set — push and set tracking
    git_safe "$repo" push -u origin "$branch" >/dev/null 2>/tmp/gap-push.err
    push_rc=$?
    detail="set_upstream_and_push"
  else
    git_safe "$repo" push >/dev/null 2>/tmp/gap-push.err
    push_rc=$?
    if [[ "$changed" -eq 0 && "$committed" -eq 0 ]]; then
      detail="already_up_to_date"
    else
      detail="changes_pushed"
    fi
  fi

  if [[ "$push_rc" -eq 0 ]]; then
    pushed=1
  else
    if grep -Eqi 'Everything up-to-date|up to date' /tmp/gap-push.err 2>/dev/null; then
      detail="already_up_to_date"
      pushed=0
    else
      log_err "git push failed — $repo [$branch]: $(cat /tmp/gap-push.err)"
      append_history "$repo" "$branch" "error" "push_failed" "$changed" "$committed" 0
      return 1
    fi
  fi

  log "OK    $(basename "$repo") [$branch]  $detail"
  append_history "$repo" "$branch" "ok" "$detail" "$changed" "$committed" "$pushed"
  return 0
}

# ── Summary ───────────────────────────────────────────────────────────────────
write_summary() {
  # args: total changed committed pushed skipped errors
  cat > "$LAST_RUN_FILE" <<SUM
timestamp=$(NOW_ISO)
total=$1
changed=$2
committed=$3
pushed=$4
skipped=$5
errors=$6
SUM
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  # Prevent overlapping runs via a PID-based lock directory (atomic mkdir on all POSIX systems)
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Lock exists — check whether the owning process is still alive
    local lock_pid
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      log "SKIP  another runner instance is active (PID $lock_pid)"
      exit 0
    else
      # Stale lock — process is gone; clean up and proceed
      log "INFO  Stale lock removed (PID ${lock_pid:-unknown} no longer running)"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || { log "SKIP  could not acquire lock after stale removal"; exit 0; }
    fi
  fi
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

  if [[ ! -s "$SYNC_FILE" ]]; then
    log "INFO  No repos enabled for sync. Use the manager to select repos."
    write_summary 0 0 0 0 0 0
    exit 0
  fi

  local total=0 changed=0 committed=0 pushed=0 skipped=0 errors=0
  local repo last_line status h_changed h_committed h_pushed

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    total=$((total+1))

    if push_repo "$repo"; then
      # Tally from the last history line
      last_line="$(tail -n 1 "$HISTORY_FILE" 2>/dev/null || true)"
      IFS=$'\t' read -r _ _ _ status _ h_changed h_committed h_pushed <<< "$last_line"
      case "${status:-}" in
        skipped|ignored) skipped=$((skipped+1)) ;;
      esac
      [[ "${h_changed:-0}"   == "1" ]] && changed=$((changed+1))
      [[ "${h_committed:-0}" == "1" ]] && committed=$((committed+1))
      [[ "${h_pushed:-0}"    == "1" ]] && pushed=$((pushed+1))
    else
      errors=$((errors+1))
    fi
  done < "$SYNC_FILE"

  write_summary "$total" "$changed" "$committed" "$pushed" "$skipped" "$errors"
  log "DONE  total=$total changed=$changed committed=$committed pushed=$pushed skipped=$skipped errors=$errors"
}

main "$@"
