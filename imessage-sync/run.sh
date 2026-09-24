#!/bin/bash
# iMessage Sync: nightly archive of every conversation (text + resized media) for people and AIs.
# Backstage entry point. Arguments: now (default) | status | doctor | retry-media | open | take-over | install | uninstall
#
# "now" and "doctor" hand the work to the nightly job via launchd, so they run with the
# job's Full Disk Access, and stream its output here.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || echo /usr/bin/python3)"
SYNC="$DIR/imessage_sync.py"
LABEL="com.amol.imessage-sync"
DOMAIN="gui/$(id -u)"
STATE="$HOME/Library/Application Support/imessage-sync"
JOBLOG="$HOME/Library/Logs/imessage-sync/job.log"
ARCHIVE="${IMESSAGE_SYNC_ARCHIVE:-$HOME/Documents/root/imessage-backups/archive}"

installed() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

via_job() {  # $1 = JSON request for the job
  if ! installed; then
    echo "The nightly job isn't installed on this Mac yet. Run:  $DIR/run.sh install"
    exit 1
  fi
  mkdir -p "$STATE"
  printf '%s\n' "$1" > "$STATE/request.json"
  local start_size
  start_size=$(stat -f%z "$JOBLOG" 2>/dev/null || echo 0)
  launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "Started via the nightly job (so it has Full Disk Access). Live output:"
  echo
  # Stream the job log until the job goes idle again.
  local off=$start_size size idle=0
  sleep 1
  while :; do
    size=$(stat -f%z "$JOBLOG" 2>/dev/null || echo 0)
    if (( size > off )); then tail -c +"$((off + 1))" "$JOBLOG" | head -c "$((size - off))"; off=$size; fi
    if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then idle=0
    else idle=$((idle + 1)); (( idle >= 2 )) && break; fi
    sleep 2
  done
  local code
  code=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/.*last exit code = \([0-9-]*\).*/\1/p' | head -1)
  echo
  echo "Dashboard: $ARCHIVE/_sync/status.html"
  exit "${code:-0}"
}

case "${1:-now}" in
  job)          # launchd runs a local copy of this script (see install.sh) so it can still report
                # "grant Full Disk Access" when ~/Documents is off-limits. Refresh that copy from the repo.
                if [[ -f "$DIR/.repo" ]]; then
                  REPO="$(cat "$DIR/.repo")"
                  if [[ -r "$REPO/imessage_sync.py" ]] && { ! cmp -s "$REPO/imessage_sync.py" "$DIR/imessage_sync.py" || ! cmp -s "$REPO/run.sh" "$DIR/run.sh"; }; then
                    for f in imessage_sync.py run.sh ARCHIVE_README.md; do cp "$REPO/$f" "$DIR/.$f.new" && mv -f "$DIR/.$f.new" "$DIR/$f"; done
                    echo "updated job code from $REPO"
                    exec /bin/bash "$DIR/run.sh" job
                  fi
                fi
                exec "$PY" "$SYNC" run --scheduled ;;
  now|run)      shift || true
                budget="null"; [[ "${1:-}" == "--media-budget" ]] && budget="${2:-40}"
                via_job "{\"action\": \"run\", \"media_budget\": $budget}" ;;
  doctor)       "$PY" "$SYNC" doctor; echo; echo "── same checks inside the nightly job (the context that matters) ──"
                via_job '{"action": "doctor"}' ;;
  status)       exec "$PY" "$SYNC" status ;;
  retry-media)  exec "$PY" "$SYNC" retry-media ;;
  take-over)    exec "$PY" "$SYNC" take-over ;;
  open)         open "$ARCHIVE/_sync/status.html" ;;
  install)      exec bash "$DIR/install.sh" ;;
  uninstall)    exec bash "$DIR/install.sh" --uninstall ;;
  here)         shift; exec "$PY" "$SYNC" run --force "$@" ;;       # run in this process (needs FDA here)
  *)            echo "usage: run.sh [now [--media-budget MIN] | status | doctor | retry-media | open | take-over | install | uninstall | here]"; exit 64 ;;
esac
