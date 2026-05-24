#!/bin/bash
# GitHub Auto-Push Runner v5
# Auto-discovers GitHub working copies and keeps them in sync.
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

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}"
export LC_ALL=C

NOW_ISO() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(NOW_ISO)" "$*"; }
log_err() { printf '[%s] ERROR: %s\n' "$(NOW_ISO)" "$*" >&2; }

normalize() {
  python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1" 2>/dev/null || echo "$1"
}

with_timeout() {
  local secs="$1"; shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys
secs = int(sys.argv[1])
cmd = sys.argv[2:]
try:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=secs)
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    sys.exit(p.returncode)
except subprocess.TimeoutExpired as e:
    sys.stdout.write((e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""))
    sys.stderr.write((e.stderr or b"").decode() if isinstance(e.stderr, bytes) else (e.stderr or ""))
    sys.stderr.write("\nTIMEOUT after %ss: %s\n" % (secs, " ".join(cmd)))
    sys.exit(124)
PY
}

git_q() { git -C "$1" "${@:2}"; }
git_safe() { with_timeout 90 git -C "$1" "${@:2}"; }

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
    case "$repo" in
      *"$needle"*) return 0 ;;
    esac
  done < "$IGNORE_FILE"
  return 1
}

discover_repos() {
  local tmp root repo remote
  tmp="$CONFIG_DIR/.last_scan.$$"
  : > "$tmp"

  while IFS= read -r root; do
    [[ -z "$root" || "$root" == \#* ]] && continue
    root="$(normalize "$root")"
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth "$SEARCH_MAX_DEPTH" \
      \( -name node_modules -o -name .venv -o -name venv -o -name env -o -name __pycache__ -o -name .tox -o -name .mypy_cache -o -name .pytest_cache -o -name dist -o -name build -o -name Library -o -name Movies -o -name Music -o -name Pictures \) -type d -prune -o \
      \( -name .git -print \) 2>/dev/null |
    while IFS= read -r git_entry; do
      if [[ -d "$git_entry" ]]; then
        repo="${git_entry%/.git}"
      else
        repo="$(dirname "$git_entry")"
      fi
      repo="$(normalize "$repo")"
      [[ -d "$repo" ]] || continue
      remote="$(git_q "$repo" remote get-url origin 2>/dev/null || true)"
      [[ -n "$remote" ]] || continue
      is_github_url "$remote" || continue
      is_ignored "$repo" && continue
      printf '%s\n' "$repo" >> "$tmp"
    done
  done < "$ROOTS_FILE"

  if [[ -s "$LEGACY_SYNC_FILE" ]]; then
    while IFS= read -r repo; do
      [[ -z "$repo" || "$repo" == \#* ]] && continue
      repo="$(normalize "$repo")"
      [[ -d "$repo" ]] || continue
      remote="$(git_q "$repo" remote get-url origin 2>/dev/null || true)"
      [[ -n "$remote" ]] && is_github_url "$remote" && ! is_ignored "$repo" && printf '%s\n' "$repo" >> "$tmp"
    done < "$LEGACY_SYNC_FILE"
  fi

  sort -u "$tmp" > "$DISCOVERED_FILE"
  rm -f "$tmp"
}

current_branch() { git_q "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true; }
upstream_ref() { git_q "$1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true; }

safe_repo_state() {
  local repo="$1" git_dir
  git_q "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not_work_tree"; return 1; }
  [[ -n "$(current_branch "$repo")" ]] || { echo "detached_head"; return 1; }
  git_dir="$(git_q "$repo" rev-parse --git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || { echo "no_git_dir"; return 1; }
  case "$git_dir" in /*) ;; *) git_dir="$repo/$git_dir" ;; esac
  [[ ! -f "$git_dir/MERGE_HEAD" ]] || { echo "merge_in_progress"; return 1; }
  [[ ! -d "$git_dir/rebase-apply" ]] || { echo "rebase_apply"; return 1; }
  [[ ! -d "$git_dir/rebase-merge" ]] || { echo "rebase_merge"; return 1; }
  [[ ! -f "$git_dir/CHERRY_PICK_HEAD" ]] || { echo "cherry_pick"; return 1; }
  echo "ok"
}

clear_stale_locks() {
  local repo="$1" git_dir lock age
  git_dir="$(git_q "$repo" rev-parse --git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || return 0
  case "$git_dir" in /*) ;; *) git_dir="$repo/$git_dir" ;; esac
  for lock in index.lock HEAD.lock COMMIT_EDITMSG.lock config.lock packed-refs.lock shallow.lock; do
    [[ -f "$git_dir/$lock" ]] || continue
    age=$(( $(date +%s) - $(stat -f %m "$git_dir/$lock" 2>/dev/null || echo 0) ))
    if [[ "$age" -lt 45 ]] && pgrep -x git >/dev/null 2>&1; then
      echo "live_lock_$lock"
      return 1
    fi
    rm -f "$git_dir/$lock"
    log "INFO  Removed stale $lock in $(basename "$repo") (${age}s old)"
  done
  return 0
}

append_history() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(NOW_ISO)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$HISTORY_FILE"
}

write_summary() {
  cat > "$LAST_RUN_FILE" <<SUM
timestamp=$(NOW_ISO)
total=$1
changed=$2
committed=$3
pushed=$4
skipped=$5
errors=$6
discovered=$7
SUM
}

convert_https_remote() {
  local repo="$1" remote="$2" ssh_url
  [[ "$AUTO_CONVERT_HTTPS" == "1" ]] || return 0
  case "$remote" in
    https://github.com/*)
      ssh_url="$(echo "$remote" | sed 's|https://github.com/|git@github.com:|')"
      git_q "$repo" remote set-url origin "$ssh_url" >/dev/null 2>&1 || return 0
      log "INFO  Converted origin to SSH for $(basename "$repo"): $(short_remote "$ssh_url")"
      ;;
  esac
}

push_repo() {
  local repo="$1" branch upstream state remote detail porcelain
  local changed=0 committed=0 pushed=0

  repo="$(normalize "$repo")"
  if [[ ! -d "$repo" ]]; then
    log "SKIP  $repo [directory_missing]"
    append_history "$repo" "-" "skipped" "directory_missing" 0 0 0
    return 0
  fi

  state="$(safe_repo_state "$repo")" || {
    log "SKIP  $repo [$state]"
    append_history "$repo" "-" "skipped" "$state" 0 0 0
    return 0
  }

  branch="$(current_branch "$repo")"
  remote="$(git_q "$repo" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote" ]] || ! is_github_url "$remote"; then
    log "SKIP  $(basename "$repo") [$branch] [not_github_origin]"
    append_history "$repo" "$branch" "skipped" "not_github_origin" 0 0 0
    return 0
  fi

  local lock_state
  lock_state="$(clear_stale_locks "$repo")" || {
    log "SKIP  $(basename "$repo") [$branch] [$lock_state]"
    append_history "$repo" "$branch" "skipped" "$lock_state" 0 0 0
    return 0
  }

  convert_https_remote "$repo" "$remote"
  upstream="$(upstream_ref "$repo")"

  if [[ "$PULL_BEFORE_PUSH" == "1" && -n "$upstream" ]]; then
    if ! git_safe "$repo" pull --rebase --autostash >/dev/null 2>/tmp/github-autopush-pull.err; then
      log_err "pull --rebase failed -- $repo [$branch]: $(tr '\n' ' ' </tmp/github-autopush-pull.err)"
      append_history "$repo" "$branch" "error" "pull_rebase_failed" 0 0 0
      return 1
    fi
  fi

  porcelain="$(git_q "$repo" status --porcelain 2>/dev/null || true)"
  if [[ -n "$porcelain" ]]; then
    changed=1
    if ! git_safe "$repo" add -A >/dev/null 2>/tmp/github-autopush-add.err; then
      log_err "git add failed -- $repo: $(tr '\n' ' ' </tmp/github-autopush-add.err)"
      append_history "$repo" "$branch" "error" "git_add_failed" 1 0 0
      return 1
    fi
    if ! git_q "$repo" diff --cached --quiet 2>/dev/null; then
      if git_safe "$repo" commit -m "$COMMIT_PREFIX $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>/tmp/github-autopush-commit.err; then
        committed=1
      elif grep -qi 'nothing to commit' /tmp/github-autopush-commit.err 2>/dev/null; then
        committed=0
      else
        log_err "git commit failed -- $repo: $(tr '\n' ' ' </tmp/github-autopush-commit.err)"
        append_history "$repo" "$branch" "error" "git_commit_failed" "$changed" 0 0
        return 1
      fi
    fi
  fi

  upstream="$(upstream_ref "$repo")"
  if [[ -z "$upstream" && "$AUTO_CREATE_UPSTREAM" != "1" ]]; then
    log "SKIP  $(basename "$repo") [$branch] [no_upstream]"
    append_history "$repo" "$branch" "skipped" "no_upstream" "$changed" "$committed" 0
    return 0
  fi

  if [[ -z "$upstream" ]]; then
    git_safe "$repo" push -u origin "$branch" >/dev/null 2>/tmp/github-autopush-push.err
    detail="set_upstream_and_push"
  else
    git_safe "$repo" push >/dev/null 2>/tmp/github-autopush-push.err
    if [[ "$changed" == "1" || "$committed" == "1" ]]; then
      detail="changes_pushed"
    else
      detail="already_up_to_date"
    fi
  fi
  local push_rc=$?

  if [[ "$push_rc" -eq 0 ]]; then
    [[ "$detail" != "already_up_to_date" ]] && pushed=1
  elif grep -Eqi 'Everything up-to-date|up to date' /tmp/github-autopush-push.err 2>/dev/null; then
    detail="already_up_to_date"
  else
    log_err "git push failed -- $repo [$branch]: $(tr '\n' ' ' </tmp/github-autopush-push.err)"
    append_history "$repo" "$branch" "error" "push_failed" "$changed" "$committed" 0
    return 1
  fi

  log "OK    $(basename "$repo") [$branch] $(short_remote "$(git_q "$repo" remote get-url origin 2>/dev/null || echo "$remote")") $detail"
  append_history "$repo" "$branch" "ok" "$detail" "$changed" "$committed" "$pushed"
  return 0
}

main() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local lock_pid
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      log "SKIP  another runner is active (PID $lock_pid)"
      exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || { log "SKIP  could not acquire runner lock"; exit 0; }
  fi
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

  discover_repos
  local discovered total changed committed pushed skipped errors repo last_line status h_changed h_committed h_pushed
  discovered="$(grep -c '.' "$DISCOVERED_FILE" 2>/dev/null || echo 0)"
  total=0; changed=0; committed=0; pushed=0; skipped=0; errors=0

  if [[ ! -s "$DISCOVERED_FILE" ]]; then
    log "INFO  no GitHub repos discovered under configured roots"
    write_summary 0 0 0 0 0 0 0
    exit 0
  fi

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    total=$((total+1))
    if push_repo "$repo"; then
      last_line="$(tail -n 1 "$HISTORY_FILE" 2>/dev/null || true)"
      IFS=$'\t' read -r _ _ _ status _ h_changed h_committed h_pushed <<< "$last_line"
      [[ "${status:-}" == "skipped" ]] && skipped=$((skipped+1))
      [[ "${h_changed:-0}" == "1" ]] && changed=$((changed+1))
      [[ "${h_committed:-0}" == "1" ]] && committed=$((committed+1))
      [[ "${h_pushed:-0}" == "1" ]] && pushed=$((pushed+1))
    else
      errors=$((errors+1))
    fi
  done < "$DISCOVERED_FILE"

  write_summary "$total" "$changed" "$committed" "$pushed" "$skipped" "$errors" "$discovered"
  log "DONE  discovered=$discovered total=$total changed=$changed committed=$committed pushed=$pushed skipped=$skipped errors=$errors"
}

main "$@"
