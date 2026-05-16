#!/bin/bash
# =============================================================================
#  iMessage Attachment Extractor & iCloud Storage Cleaner
#  Version: 2.6.0
#  macOS 12+ (Monterey, Ventura, Sonoma, Sequoia)
#
#  Run as:  sudo bash imessage_cleanup.sh
#
#  What it does:
#    1. Reads ~/Library/Messages/chat.db (copied to /tmp for safety)
#    2. Resolves sender names via chat.db handles + Contacts AddressBook
#    3. Copies all images/videos from ~/Library/Messages/Attachments/
#       into ~/Desktop/iMessage_Attachments/<SenderName>/<date>_<file>
#    4. (Optionally) deletes attachments from the local Messages store
#       so iCloud re-claims the space
#    5. Logs everything to ~/Desktop/iMessage_Attachments/cleanup.log
#
#  v2.1.0:
#    6. Browse contacts TUI [menu 8]: lists every iMessage handle ranked by
#       recency, shows contact name when available (or phone/email + a snippet
#       of the last message as a prompt when not), lets you pick one or more,
#       and for each pick produces a per-person folder containing:
#         - a per-contact SQLite db (chat_<slug>.db) with just their messages
#         - a readable .txt transcript (messages_<slug>.txt)
#         - an attachments/ subfolder with every available image/video/file
#         - a metadata.json with stats + handle list
#
#  v2.2.0:
#    7. Per-contact exports now write OUTSIDE the script's folder, into a
#       user-chosen "backup root" with a tiny built-in folder navigator:
#         - Default: ~/Documents/root/imessage-backups
#         - Remembered across runs in ~/.config/imessage_cleanup/config
#         - Navigator: pick from common locations, ls into subfolders,
#           type any absolute path, or create a new folder on the spot.
#
#  v2.2.1 PERF FIX:
#    - Roster build replaced a correlated subquery with a single CTE
#      (window-function ROW_NUMBER) so large chat.db files (thousands of
#      handles) finish in seconds instead of stalling for many minutes.
#    - AddressBook is prefetched once into bash arrays; in-memory lookup
#      replaces per-handle sqlite queries.
#    - Added a 30s sqlite .timeout and progress logging during roster build.
#
#  v2.4.0 ROBUSTNESS:
#    - Menu [8] roster merge is Bash 3.2 compatible again (no associative
#      arrays), with clearer labels for merged / unsaved contacts.
#    - Per-contact exports are restartable: DB/transcript writes are atomic,
#      attachment copies use a per-contact manifest, and reruns repair partial
#      folders instead of duplicating already-copied files.
#    - Added SQL/input validation, visible export error files, safer JSON
#      escaping, and clearer status messages for partial success/failure.
#
#  v2.5.0 REFRESH MEMORY + ACCESSIBILITY:
#    - Menu [8] remembers previous per-contact exports from .export_status
#      files and asks whether to refresh those same people before browsing.
#    - TUI colors now use a high-contrast palette that avoids green/cyan/dim
#      text for core menu labels, so it is readable on light and dark themes.
#
#  v2.6.0 GROUPED CONTACTS:
#    - Previous exports can now declare export_format=grouped_contact_v1.
#      Refresh uses the stored combined handle_rowids and output folder, so
#      manually grouped identities (e.g. one person with several phones/email)
#      stay together on future updates.
#
#  Safety:
#    - Never modifies anything without explicit confirmation
#    - Creates a full SQLite backup before any DB writes
#    - Dry-run mode shows every action without touching the filesystem
#    - Detailed log for every copy/delete
#
#  Maintenance note (for future edits):
#    Whenever this script changes, ALSO update:
#      - mac-scripts/imessage-cleanup/README.md  (features + usage)
#      - mac-scripts/scripts.html  (the imessage-cleanup card text)
#      - Bump SCRIPT_VERSION below and add a line under "vX.Y.Z NEW" above.
# =============================================================================

set -eo pipefail   # NOTE: -u (unbound var) intentionally omitted — macOS bash 3.2 has edge cases
IFS=$'\n\t'
DEBUG_LOG=false    # Set to true via --debug flag or option [d] in menu

# ── High-contrast text palette ────────────────────────────────────────────────
# Keep the TUI readable on both black and white terminal backgrounds. Green,
# cyan, yellow, and dim text are unreliable on common light themes, so the core
# interface uses bold/underline plus red only for hard warnings/errors.
RESET='\033[0m';   BOLD='\033[1m'
RED='\033[1;31m';  BRED='\033[1;31m'
GRN="$BOLD";       BGRN="$BOLD"
YLW="$BOLD";       BYLW="$BOLD"
BLU="$BOLD";       BBLU="$BOLD"
MAG='\033[1;35m';  BMAG='\033[1;35m'
CYN="$BOLD";       BCYN="$BOLD"
WHT="$BOLD";       DIM=''
BLINK='\033[5m';   ULINE='\033[4m'

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_VERSION="2.6.0"
SCRIPT_NAME="iMessage Attachment Extractor & iCloud Cleaner"

# Paths – resolved relative to the real user's home (handles sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

MESSAGES_DB="$REAL_HOME/Library/Messages/chat.db"
ATTACHMENTS_DIR="$REAL_HOME/Library/Messages/Attachments"
ADDRESSBOOK_DB="$REAL_HOME/Library/Application Support/AddressBook/AddressBook-v22.abcddb"

DESKTOP="$REAL_HOME/Desktop"
OUTPUT_ROOT="$DESKTOP/iMessage_Attachments"
LOG_FILE="$OUTPUT_ROOT/cleanup.log"
DB_TMP="/tmp/imessage_chat_$$.db"       # Scratch copy of chat.db
ADDRESSBOOK_TMP="/tmp/imessage_ab_$$.db"
MANIFEST_FILE="$OUTPUT_ROOT/.manifest"   # Tracks att_ids already copied (for incremental runs)

# ── Per-contact backup root (v2.2.0) ──────────────────────────────────────────
# Per-person exports live OUTSIDE this script's folder. Default is the user's
# Documents/root/imessage-backups (see README). User's choice is remembered
# across runs in CONFIG_FILE so they're not asked every time.
CONFIG_DIR="$REAL_HOME/.config/imessage_cleanup"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_BACKUP_ROOT="$REAL_HOME/Documents/root/imessage-backups"
BACKUP_ROOT=""   # populated by load_config / pick_backup_dir

# Runtime options (changed by menu)
DRY_RUN=false
SKIP_VIDEOS=false
SKIP_IMAGES=false
SKIP_OTHER=false
MIN_SIZE_KB=0          # Skip files smaller than this (0 = no filter)
MAX_AGE_DAYS=0         # Only process attachments newer than N days (0 = all)
DELETE_AFTER_COPY=false
OVERWRITE_EXISTING=false
SENDER_FILTER=""       # Empty = all senders

TOTAL_COPIED=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
TOTAL_DELETED=0
TOTAL_BYTES_COPIED=0
TOTAL_BYTES_FREED=0

# ── Logging ───────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(_ts)
    # File log (no colour)
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()    { log "INFO " "$@"; }
log_warn()    { log "WARN " "$@"; }
log_error()   { log "ERROR" "$@"; }
log_action()  { log "ACTION" "$@"; }
log_skip()    { log "SKIP " "$@"; }
log_debug()   { $DEBUG_LOG && log "DEBUG" "$@" || true; }

# Pure-bash trim (xargs breaks on apostrophes / unbalanced quotes in names).
_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done
    printf '%s' "$s"
}

json_string() {
    # json_string <value>  →  prints a quoted JSON string.
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""'
}

safe_sql_id_list() {
    # Accept only comma-separated integer ROWIDs before interpolating into SQL.
    [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

unique_dest_path() {
    # unique_dest_path <desired_path>
    local desired="$1"
    if [[ ! -e "$desired" ]]; then
        printf '%s' "$desired"
        return
    fi

    local dir base stem ext n candidate
    dir=$(dirname "$desired")
    base=$(basename "$desired")
    if [[ "$base" == *.* ]]; then
        stem="${base%.*}"
        ext=".${base##*.}"
    else
        stem="$base"
        ext=""
    fi
    n=1
    while true; do
        candidate="$dir/${stem}_${n}${ext}"
        if [[ ! -e "$candidate" ]]; then
            printf '%s' "$candidate"
            return
        fi
        n=$(( n + 1 ))
    done
}

# Print debug line to screen + log when DEBUG_LOG=true
dbg() {
    $DEBUG_LOG || return 0
    echo -e "  ${DIM}[dbg] $*${RESET}" >&2
    log "DEBUG" "$@"
}

# ── Terminal helpers ──────────────────────────────────────────────────────────
WIDTH=80
HR() { printf '%0.s─' $(seq 1 $WIDTH); echo; }
HR2() { printf '%0.s═' $(seq 1 $WIDTH); echo; }

banner() {
    clear
    echo
    echo -e "${BBLU}$(HR2)${RESET}"
    printf "${BBLU}║${RESET}${BOLD}%*s${RESET}${BBLU}║${RESET}\n" $((WIDTH-2)) ""
    printf "${BBLU}║${RESET}${BOLD}%*s%-*s${RESET}${BBLU}║${RESET}\n" \
        $(( (WIDTH-2 - ${#SCRIPT_NAME}) / 2 )) "" $((WIDTH-2)) "$SCRIPT_NAME"
    printf "${BBLU}║${RESET}${DIM}%*s%-*s${RESET}${BBLU}║${RESET}\n" \
        $(( (WIDTH-2 - 9) / 2 )) "" $((WIDTH-2)) "v$SCRIPT_VERSION"
    printf "${BBLU}║${RESET}${BOLD}%*s${RESET}${BBLU}║${RESET}\n" $((WIDTH-2)) ""
    echo -e "${BBLU}$(HR2)${RESET}"
    echo
}

section() {
    echo
    echo -e "${BCYN}── $* ${RESET}"
}

ok()    { echo -e "  ${BGRN}✓${RESET}  $*"; }
warn()  { echo -e "  ${BYLW}⚠${RESET}  $*"; }
err()   { echo -e "  ${BRED}✗${RESET}  $*"; }
info()  { echo -e "  ${BBLU}ℹ${RESET}  $*"; }
bullet(){ echo -e "  ${DIM}•${RESET}  $*"; }

ask_yn() {
    # ask_yn "Question?" [default: y|n]  →  returns 0 (yes) or 1 (no)
    local question="$1"
    local default="${2:-n}"
    local prompt
    if [[ "$default" == "y" ]]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
    while true; do
        printf "  ${BYLW}?${RESET}  %s %s " "$question" "$prompt"
        read -r answer </dev/tty
        answer="${answer:-$default}"
        answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "Please answer y or n." ;;
        esac
    done
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local result
    if [[ -n "$default" ]]; then
        printf "  ${BYLW}?${RESET}  %s [%s]: " "$prompt" "$default"
    else
        printf "  ${BYLW}?${RESET}  %s: " "$prompt"
    fi
    read -r result </dev/tty
    echo "${result:-$default}"
}

press_any_key() {
    printf "\n  ${DIM}Press any key to continue...${RESET}"
    read -rn1 </dev/tty
    echo
}

spinner_start() {
    local msg="$1"
    printf "  ${BBLU}⟳${RESET}  %s " "$msg"
    (
        local i=0
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        while true; do
            printf "\r  ${BBLU}%s${RESET}  %s " "${frames[$((i % ${#frames[@]}))]}" "$msg"
            sleep 0.1
            i=$(( i + 1 ))
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r"
    fi
}

progress_bar() {
    local current="$1"
    local total="$2"
    local label="${3:-}"
    local bar_width=40
    local pct=0
    [[ $total -gt 0 ]] && pct=$(( current * 100 / total ))
    local filled=$(( current * bar_width / (total > 0 ? total : 1) ))
    local empty=$(( bar_width - filled ))
    local bar; bar=$(printf '%0.s█' $(seq 1 $filled) 2>/dev/null || printf '%*s' "$filled" '' | tr ' ' '█')
    local space; space=$(printf '%*s' "$empty" '')
    printf "\r  ${BBLU}[${RESET}${BGRN}%s${RESET}${DIM}%s${RESET}${BBLU}]${RESET} %3d%%  %d/%d  %s  " \
        "$bar" "$space" "$pct" "$current" "$total" "$label"
}

human_bytes() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif (( bytes >= 1048576 ));    then printf "%.1f MB" "$(echo "scale=1; $bytes/1048576" | bc)"
    elif (( bytes >= 1024 ));       then printf "%.1f KB" "$(echo "scale=1; $bytes/1024" | bc)"
    else echo "${bytes} B"
    fi
}

# ── Prerequisite checks ───────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        info "Run:  sudo bash $0"
        exit 1
    fi
}

check_dependencies() {
    section "Checking dependencies"
    local missing=()
    for cmd in sqlite3 rsync python3 bc find; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found"
        else
            err "$cmd missing"
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo
        warn "Missing tools: ${missing[*]}"
        info "Install via Homebrew:  brew install sqlite3 rsync"
        exit 1
    fi
}

check_full_disk_access() {
    section "Checking Full Disk Access"
    # On macOS 10.15+ the Messages DB requires FDA.
    # The easiest test is trying to read the first byte of chat.db.
    if ! head -c 1 "$MESSAGES_DB" &>/dev/null 2>&1; then
        err "Cannot read $MESSAGES_DB"
        echo
        warn "macOS requires Full Disk Access for this Terminal."
        info "Go to: ${ULINE}System Settings → Privacy & Security → Full Disk Access${RESET}"
        info "Add Terminal (or iTerm / the app you're using) and re-run."
        exit 1
    fi
    ok "Full Disk Access confirmed"
}

check_messages_closed() {
    section "Checking Messages.app status"
    if pgrep -x "Messages" &>/dev/null; then
        warn "Messages.app is currently open."
        info "It should be closed before we copy the database to avoid corruption."
        echo
        if ask_yn "Quit Messages.app now?" "y"; then
            osascript -e 'quit app "Messages"' 2>/dev/null || true
            sleep 2
            ok "Messages.app closed"
            log_action "Quit Messages.app"
        else
            warn "Proceeding with Messages.app open – database copy may be inconsistent."
            log_warn "User chose to continue with Messages.app open"
        fi
    else
        ok "Messages.app is not running"
    fi
}

# ── Database helpers ──────────────────────────────────────────────────────────
copy_databases() {
    section "Copying databases to temp location"
    spinner_start "Copying chat.db …"
    cp "$MESSAGES_DB" "$DB_TMP"
    chmod 644 "$DB_TMP"
    spinner_stop
    ok "chat.db copied to $DB_TMP"
    log_action "Copied chat.db → $DB_TMP"

    if [[ -f "$ADDRESSBOOK_DB" ]]; then
        spinner_start "Copying AddressBook …"
        cp "$ADDRESSBOOK_DB" "$ADDRESSBOOK_TMP" 2>/dev/null || true
        chmod 644 "$ADDRESSBOOK_TMP" 2>/dev/null || true
        spinner_stop
        ok "AddressBook copied"
        log_action "Copied AddressBook → $ADDRESSBOOK_TMP"
    else
        warn "AddressBook database not found – will use handle IDs as names"
        ADDRESSBOOK_TMP=""
    fi
}

db_query() {
    # db_query <db_path> <sql>
    sqlite3 -separator $'\t' "$1" "$2" 2>/dev/null
}

# ── Contact resolution ────────────────────────────────────────────────────────
# Cache: file-based key=value store (bash 3.2 compatible, no declare -A)
CONTACT_CACHE_FILE="/tmp/imessage_contact_cache_$$.txt"
touch "$CONTACT_CACHE_FILE"

cache_get() {
    # cache_get <key>  →  prints value or empty string
    grep -m1 "^${1}=" "$CONTACT_CACHE_FILE" 2>/dev/null | cut -d= -f2- || true
}

cache_set() {
    # cache_set <key> <value>
    # Remove old entry if any, then append
    local tmp; tmp=$(grep -v "^${1}=" "$CONTACT_CACHE_FILE" 2>/dev/null || true)
    echo "$tmp" > "$CONTACT_CACHE_FILE"
    echo "${1}=${2}" >> "$CONTACT_CACHE_FILE"
}

# Normalize a phone number to digits only (last 10 digits for US)
normalize_phone() {
    local raw="$1"
    # Strip everything except digits
    local digits; digits=$(echo "$raw" | tr -cd '0-9')
    # Return last 10 digits
    echo "${digits: -10}"
}

lookup_contact_name() {
    local handle_id="$1"
    local handle_raw="$2"   # e.g. "+15551234567" or "user@example.com"

    # Already cached?
    local cached; cached=$(cache_get "$handle_id")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return
    fi

    local name=""

    if [[ -n "$ADDRESSBOOK_TMP" && -f "$ADDRESSBOOK_TMP" ]]; then
        # Is it an email?
        if [[ "$handle_raw" == *"@"* ]]; then
            name=$(sqlite3 "$ADDRESSBOOK_TMP" \
                "SELECT COALESCE(r.ZFIRSTNAME,'') || ' ' || COALESCE(r.ZLASTNAME,'')
                 FROM ZABCDRECORD r
                 JOIN ZABCDEMAILADDRESS e ON r.Z_PK = e.ZOWNER
                 WHERE LOWER(e.ZADDRESS) = LOWER('${handle_raw//\'/\'\'}')
                 LIMIT 1;" 2>/dev/null)
            name=$(_trim "$name")
        else
            # Phone number lookup – normalize both sides
            local norm_handle; norm_handle=$(normalize_phone "$handle_raw")
            if [[ -n "$norm_handle" ]]; then
                # Fetch all phone numbers from contacts and compare last-10-digits
                while IFS=$'\t' read -r first last fullnum; do
                    local norm_contact; norm_contact=$(normalize_phone "$fullnum")
                    if [[ "$norm_contact" == "$norm_handle" ]]; then
                        name="$first $last"
                        break
                    fi
                done < <(sqlite3 -separator $'\t' "$ADDRESSBOOK_TMP" \
                    "SELECT COALESCE(r.ZFIRSTNAME,''), COALESCE(r.ZLASTNAME,''),
                            COALESCE(p.ZFULLNUMBER,'')
                     FROM ZABCDRECORD r
                     JOIN ZABCDPHONENUMBER p ON r.Z_PK = p.ZOWNER
                     WHERE p.ZFULLNUMBER IS NOT NULL;" 2>/dev/null)
            fi
        fi
    fi

    # Fall back to the raw handle
    [[ -z "$name" || "$name" == " " ]] && name="$handle_raw"

    # Sanitize for use as a directory name
    name=$(echo "$name" | sed 's/[\/:\\*?"<>|]/_/g')
    name=$(_trim "$name")
    [[ -z "$name" ]] && name="Unknown_${handle_id}"

    cache_set "$handle_id" "$name"
    echo "$name"
}

# ── Attachment discovery ──────────────────────────────────────────────────────
# Returns TSV rows: attachment_id \t filename_in_db \t mime_type \t transfer_name \t handle_id \t handle_raw \t is_from_me \t date_epoch
query_attachments() {
    sqlite3 -separator $'\t' "$DB_TMP" "
SELECT
    a.ROWID,
    COALESCE(a.filename, ''),
    COALESCE(a.mime_type, 'application/octet-stream'),
    COALESCE(a.transfer_name, ''),
    COALESCE(m.handle_id, 0),
    COALESCE(h.id, ''),
    COALESCE(m.is_from_me, 0),
    COALESCE(a.created_date, 0)
FROM attachment a
JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
JOIN message m                   ON maj.message_id = m.ROWID
LEFT JOIN handle h               ON m.handle_id = h.ROWID
WHERE a.filename IS NOT NULL
  AND a.filename != ''
ORDER BY a.created_date ASC;
" 2>/dev/null
}

# macOS epoch → unix epoch
mac_to_unix_epoch() {
    echo $(( $1 + 978307200 ))
}

epoch_to_date() {
    # epoch_to_date <epoch_seconds> → YYYY-MM-DD
    date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d' 2>/dev/null || echo "0000-00-00"
}

resolve_attachment_path() {
    # The filename in DB is like ~/Library/Messages/Attachments/xx/yy/filename.jpg
    # Replace leading ~ with real home
    local raw_path="$1"
    local resolved="${raw_path/#\~/$REAL_HOME}"
    echo "$resolved"
}

mime_category() {
    local mime="$1"
    case "$mime" in
        image/*)        echo "image" ;;
        video/*)        echo "video" ;;
        audio/*)        echo "audio" ;;
        application/pdf) echo "document" ;;
        *)              echo "other" ;;
    esac
}

# ── Dry-run / progress display ────────────────────────────────────────────────
show_summary_so_far() {
    echo
    HR
    echo -e "  ${BOLD}Session Summary${RESET}"
    HR
    bullet "Files copied  : ${BGRN}$TOTAL_COPIED${RESET}"
    bullet "Files skipped : ${BYLW}$TOTAL_SKIPPED${RESET}"
    bullet "Files errored : ${BRED}$TOTAL_ERRORS${RESET}"
    bullet "Files deleted : ${BMAG}$TOTAL_DELETED${RESET}"
    bullet "Data copied   : ${BCYN}$(human_bytes $TOTAL_BYTES_COPIED)${RESET}"
    [[ $DELETE_AFTER_COPY == true ]] && \
    bullet "Space freed   : ${BGRN}$(human_bytes $TOTAL_BYTES_FREED)${RESET}"
    HR
}

# ── Main extraction loop ──────────────────────────────────────────────────────
do_extraction() {
    section "Discovering attachments"

    spinner_start "Querying chat.db …"
    local rows
    rows=$(query_attachments)
    spinner_stop

    local total_rows
    if [[ -n "$rows" ]]; then
        total_rows=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    else
        total_rows=0
    fi

    info "Found ${BOLD}$total_rows${RESET} attachment records in database"

    if [[ $total_rows -eq 0 ]]; then
        warn "No attachments found in the database."
        return
    fi

    # Load manifest of already-copied attachment IDs into a temp lookup file
    local SEEN_FILE="/tmp/imessage_seen_$$.txt"
    if [[ -f "$MANIFEST_FILE" ]]; then
        cp "$MANIFEST_FILE" "$SEEN_FILE"
        local already_done; already_done=$(wc -l < "$SEEN_FILE" | tr -d ' ')
        info "Manifest found: ${BOLD}$already_done${RESET} attachments already copied — skipping those"
    else
        touch "$SEEN_FILE"
        info "No manifest yet — this is a fresh run"
    fi

    seen_check() { grep -qx "$1" "$SEEN_FILE" 2>/dev/null; }
    seen_add()   {
        if ! $DRY_RUN; then
            echo "$1" >> "$SEEN_FILE"
            echo "$1" >> "$MANIFEST_FILE"
        fi
    }

    echo
    info "Starting extraction…  (log: $LOG_FILE)"
    $DRY_RUN && warn "DRY-RUN mode: no files will be moved or deleted"
    echo

    local count=0
    local sender_name sender_dir dest_path src_path file_size att_date
    local att_id att_filename att_mime att_transfer_name handle_id handle_raw is_from_me att_date_raw

    # Array to track files that need post-loop deletion
    declare -a TO_DELETE=()

    while IFS=$'\t' read -r att_id att_filename att_mime att_transfer_name handle_id handle_raw is_from_me att_date_raw; do
        (( count++ )) || true
        progress_bar "$count" "$total_rows" "$(basename "$att_filename" 2>/dev/null | cut -c1-30)"

        # ── Resolve source path ───────────────────────────────────────────
        src_path=$(resolve_attachment_path "$att_filename")

        if [[ ! -f "$src_path" ]]; then
            log_skip "att_id=$att_id | NOT FOUND locally (may be iCloud-only) | $src_path"
            (( TOTAL_SKIPPED++ )) || true
            continue
        fi

        # ── Size filter ───────────────────────────────────────────────────
        file_size=$(stat -f%z "$src_path" 2>/dev/null || stat -c%s "$src_path" 2>/dev/null || echo 0)
        if [[ $MIN_SIZE_KB -gt 0 && $file_size -lt $(( MIN_SIZE_KB * 1024 )) ]]; then
            log_skip "att_id=$att_id | Too small ($(human_bytes $file_size) < ${MIN_SIZE_KB}KB) | $src_path"
            (( TOTAL_SKIPPED++ )) || true
            continue
        fi

        # ── Age filter ────────────────────────────────────────────────────
        if [[ $MAX_AGE_DAYS -gt 0 ]]; then
            local unix_epoch
            if [[ $att_date_raw -gt 0 ]]; then
                unix_epoch=$(mac_to_unix_epoch "$att_date_raw")
            else
                unix_epoch=$(stat -f%m "$src_path" 2>/dev/null || echo 0)
            fi
            local cutoff; cutoff=$(( $(date +%s) - MAX_AGE_DAYS * 86400 ))
            if [[ $unix_epoch -lt $cutoff ]]; then
                log_skip "att_id=$att_id | Too old | $src_path"
                (( TOTAL_SKIPPED++ )) || true
                continue
            fi
        fi

        # ── MIME type filter ──────────────────────────────────────────────
        local cat; cat=$(mime_category "$att_mime")
        if { $SKIP_IMAGES && [[ "$cat" == "image" ]]; } || \
           { $SKIP_VIDEOS && [[ "$cat" == "video" ]]; } || \
           { $SKIP_OTHER  && [[ "$cat" != "image" && "$cat" != "video" ]]; }; then
            log_skip "att_id=$att_id | Filtered by type ($cat) | $src_path"
            (( TOTAL_SKIPPED++ )) || true
            continue
        fi

        # ── Sender name ───────────────────────────────────────────────────
        if [[ "$is_from_me" == "1" ]]; then
            sender_name="Me (Sent)"
        else
            sender_name=$(lookup_contact_name "$handle_id" "$handle_raw")
        fi

        # ── Sender filter ─────────────────────────────────────────────────
        if [[ -n "$SENDER_FILTER" ]]; then
            if ! echo "$sender_name" | grep -qi "$SENDER_FILTER"; then
                (( TOTAL_SKIPPED++ )) || true
                continue
            fi
        fi

        # ── Date prefix ───────────────────────────────────────────────────
        if [[ $att_date_raw -gt 0 ]]; then
            local unix_ts; unix_ts=$(mac_to_unix_epoch "$att_date_raw")
            att_date=$(epoch_to_date "$unix_ts")
        else
            att_date=$(stat -f%Sm -t '%Y-%m-%d' "$src_path" 2>/dev/null || echo "0000-00-00")
        fi

        # ── Build destination path ────────────────────────────────────────
        sender_dir="$OUTPUT_ROOT/$sender_name"
        local base_name; base_name=$(basename "$src_path")
        # Prefix with date for chronological sort
        local dest_name="${att_date}_${base_name}"
        dest_path="$sender_dir/$dest_name"

        # ── Incremental: skip if already recorded in manifest ────────────
        if seen_check "$att_id"; then
            log_skip "att_id=$att_id | Already in manifest (incremental skip)"
            (( TOTAL_SKIPPED++ )) || true
            continue
        fi

        # Handle duplicate filenames (shouldn't happen often since we key by att_id, but be safe)
        if [[ -f "$dest_path" ]] && ! $OVERWRITE_EXISTING; then
            local n=1
            while [[ -f "${dest_path%.*}_${n}.${dest_path##*.}" ]]; do (( n++ )) || true; done
            dest_path="${dest_path%.*}_${n}.${dest_path##*.}"
        fi

        # ── DRY RUN ───────────────────────────────────────────────────────
        if $DRY_RUN; then
            log_info "[DRY-RUN] Would copy att_id=$att_id: $src_path → $dest_path ($(human_bytes $file_size))"
            (( TOTAL_COPIED++ )) || true
            (( TOTAL_BYTES_COPIED += file_size )) || true
            continue
        fi

        # ── Actually copy ─────────────────────────────────────────────────
        mkdir -p "$sender_dir"
        if cp -p "$src_path" "$dest_path" 2>/dev/null; then
            (( TOTAL_COPIED++ )) || true
            (( TOTAL_BYTES_COPIED += file_size )) || true
            log_action "COPY | $src_path → $dest_path | $(human_bytes $file_size)"
            seen_add "$att_id"
            # Queue for deletion
            $DELETE_AFTER_COPY && TO_DELETE+=("$src_path")
        else
            (( TOTAL_ERRORS++ )) || true
            log_error "COPY FAILED | $src_path → $dest_path"
            err "Failed to copy: $base_name"
        fi

    done <<< "$rows"

    printf "\r%${WIDTH}s\r" ""   # Clear progress bar line
    echo
    ok "Extraction complete: $TOTAL_COPIED copied, $TOTAL_SKIPPED skipped, $TOTAL_ERRORS errors"

    # ── Post-copy deletion phase ──────────────────────────────────────────────
    if $DELETE_AFTER_COPY && [[ ${#TO_DELETE[@]} -gt 0 ]]; then
        echo
        section "Deletion phase"
        warn "About to delete ${#TO_DELETE[@]} attachment files from:"
        bullet "$ATTACHMENTS_DIR"
        echo
        warn "${BOLD}${BRED}THIS IS IRREVERSIBLE.${RESET} Your copies are in:"
        bullet "$OUTPUT_ROOT"
        echo
        if ask_yn "Proceed with deletion of ${#TO_DELETE[@]} files?" "n"; then
            echo
            local del_count=0
            local del_total=${#TO_DELETE[@]}
            for src in "${TO_DELETE[@]}"; do
                (( del_count++ )) || true
                progress_bar "$del_count" "$del_total" "$(basename "$src" | cut -c1-30)"
                local sz; sz=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo 0)
                if rm -f "$src" 2>/dev/null; then
                    (( TOTAL_DELETED++ )) || true
                    (( TOTAL_BYTES_FREED += sz )) || true
                    log_action "DELETE | $src | $(human_bytes $sz)"
                else
                    log_error "DELETE FAILED | $src"
                    (( TOTAL_ERRORS++ )) || true
                fi
            done
            printf "\r%${WIDTH}s\r" ""
            echo
            ok "Deleted $TOTAL_DELETED files, freed $(human_bytes $TOTAL_BYTES_FREED)"

            # Nudge Messages to notice the deletions
            echo
            info "Tip: Open System Settings → Apple ID → iCloud → Manage → Messages"
            info "     to confirm iCloud space has been reclaimed."
        else
            info "Deletion cancelled. Your copies remain in $OUTPUT_ROOT"
        fi
    fi
}

# ── iCloud space measurement ──────────────────────────────────────────────────
# Uses `du` on the known local iCloud Messages cache paths.
# Also tries the brctl (CloudDocs control) tool where available.

icloud_messages_local_bytes() {
    # Sum up every path that holds iMessage iCloud-synced data locally
    local total=0
    local p sz

    # 1. The main Attachments folder
    if [[ -d "$ATTACHMENTS_DIR" ]]; then
        sz=$(du -sk "$ATTACHMENTS_DIR" 2>/dev/null | awk '{print $1}')
        total=$(( total + ${sz:-0} * 1024 ))
    fi

    # 2. CloudDocs container for Messages
    for p in \
        "$REAL_HOME/Library/Mobile Documents/com~apple~MobileSMS" \
        "$REAL_HOME/Library/Mobile Documents/iCloud~com~apple~iChat" \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.MobileSMS" \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.iChat" \
        "$REAL_HOME/Library/Messages/NanoDB" \
        "$REAL_HOME/Library/Messages/Caches" ; do
        if [[ -d "$p" ]]; then
            sz=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
            total=$(( total + ${sz:-0} * 1024 ))
        fi
    done

    echo "$total"
}

icloud_quota_used() {
    # Try to read iCloud quota via brctl (available macOS 10.12+)
    # Returns bytes used by Messages in iCloud, or "?" if unavailable
    local out
    out=$(brctl status 2>/dev/null | grep -i "messages\|iChat\|MobileSMS" | head -5) || true
    if [[ -n "$out" ]]; then
        echo "$out"
    else
        echo ""
    fi
}

show_icloud_status() {
    # Print a live snapshot of iCloud Messages storage
    local label="${1:-Current}"
    echo
    echo -e "  ${BOLD}${label} iCloud / Local Messages Storage${RESET}"
    HR

    # Local attachments folder
    local att_bytes=0
    if [[ -d "$ATTACHMENTS_DIR" ]]; then
        att_bytes=$(du -sk "$ATTACHMENTS_DIR" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
        bullet "Local Attachments folder : $(human_bytes $att_bytes)  ${DIM}($ATTACHMENTS_DIR)${RESET}"
    else
        bullet "Local Attachments folder : ${DIM}(not found)${RESET}"
    fi

    # NanoDB (message index used by iCloud sync)
    local nano_bytes=0
    if [[ -d "$REAL_HOME/Library/Messages/NanoDB" ]]; then
        nano_bytes=$(du -sk "$REAL_HOME/Library/Messages/NanoDB" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
        bullet "Messages NanoDB          : $(human_bytes $nano_bytes)"
    fi

    # CloudKit caches
    for ckpath in \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.MobileSMS" \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.iChat" ; do
        if [[ -d "$ckpath" ]]; then
            local ck_bytes; ck_bytes=$(du -sk "$ckpath" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
            bullet "CloudKit cache $(basename $ckpath | cut -c1-30) : $(human_bytes $ck_bytes)"
        fi
    done

    # Mobile Documents / iCloud Drive containers
    for mdpath in \
        "$REAL_HOME/Library/Mobile Documents/com~apple~MobileSMS" \
        "$REAL_HOME/Library/Mobile Documents/iCloud~com~apple~iChat" ; do
        if [[ -d "$mdpath" ]]; then
            local md_bytes; md_bytes=$(du -sk "$mdpath" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
            bullet "iCloud Mobile Docs $(basename $mdpath | cut -c1-20) : $(human_bytes $md_bytes)"
        fi
    done

    # Total local footprint
    local total_local; total_local=$(icloud_messages_local_bytes)
    echo
    bullet "${BOLD}Total local Messages footprint : $(human_bytes $total_local)${RESET}"

    # brctl / CloudDocs quota info
    local bctl_out; bctl_out=$(icloud_quota_used)
    if [[ -n "$bctl_out" ]]; then
        echo
        echo -e "  ${DIM}brctl status (iCloud daemon view):${RESET}"
        echo "$bctl_out" | while IFS= read -r line; do
            bullet "${DIM}$line${RESET}"
        done
    fi

    # Try `df` on iCloud Drive mount if available
    if [[ -d "$REAL_HOME/Library/Mobile Documents" ]]; then
        local df_out; df_out=$(df -h "$REAL_HOME/Library/Mobile Documents" 2>/dev/null | tail -1) || true
        [[ -n "$df_out" ]] && bullet "iCloud Drive volume: ${DIM}$df_out${RESET}"
    fi
}

# ── iCloud cleanup steps ───────────────────────────────────────────────────────
do_icloud_cleanup() {
    banner
    section "iCloud Messages Storage Cleanup"
    dbg "do_icloud_cleanup entered. REAL_USER=$REAL_USER REAL_HOME=$REAL_HOME"
    dbg "MANIFEST_FILE=$MANIFEST_FILE"
    dbg "ATTACHMENTS_DIR=$ATTACHMENTS_DIR"
    dbg "OUTPUT_ROOT=$OUTPUT_ROOT"

    # ── Pre-flight: must have copied attachments first ────────────────────────
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "No manifest found — you haven't run an extraction yet."
        info "Run option [1] first to copy your attachments to the Desktop folder,"
        info "then come back here to clean up iCloud."
        press_any_key
        return
    fi
    local manifest_count; manifest_count=$(wc -l < "$MANIFEST_FILE" | tr -d ' ')
    ok "Manifest found: ${BOLD}$manifest_count${RESET} attachments previously exported"

    # ── Snapshot BEFORE ───────────────────────────────────────────────────────
    local bytes_before; bytes_before=$(icloud_messages_local_bytes)
    show_icloud_status "BEFORE cleanup"
    log_info "iCloud cleanup start. Local footprint BEFORE: $(human_bytes $bytes_before)"

    echo
    HR
    echo -e "  ${BOLD}What this will do:${RESET}"
    HR
    bullet "Step 1  Delete all files in ${BOLD}~/Library/Messages/Attachments/${RESET}"
    bullet "        (your copies are safe in $OUTPUT_ROOT)"
    bullet "Step 2  Clear CloudKit caches for Messages (forces re-evaluation)"
    bullet "Step 3  Restart the iCloud sync daemon (bird) to flush accounting"
    bullet "Step 4  Disable Messages in iCloud sync, wait, re-enable"
    bullet "        (this is what actually removes attachments from iCloud quota)"
    bullet "Step 5  Measure space again and show you the difference"
    echo
    warn "${BRED}${BOLD}IRREVERSIBLE:${RESET}${BYLW} Steps 1–4 cannot be undone. Your Desktop copies are your only backup.${RESET}"
    echo
    info "Verify your Desktop folder looks right before proceeding:"
    bullet "$OUTPUT_ROOT  ($(du -sh "$OUTPUT_ROOT" 2>/dev/null | cut -f1 || echo '?') on disk)"
    echo

    if ! ask_yn "Proceed with iCloud cleanup?" "n"; then
        info "Cancelled — nothing changed."
        press_any_key
        return
    fi

    # ── Step 1: Delete local attachments ─────────────────────────────────────
    echo
    section "Step 1/4 — Deleting local attachment files"

    if [[ -d "$ATTACHMENTS_DIR" ]]; then
        local att_count; att_count=$(find "$ATTACHMENTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        local att_bytes; att_bytes=$(du -sk "$ATTACHMENTS_DIR" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
        info "Found ${BOLD}$att_count${RESET} files totalling ${BOLD}$(human_bytes $att_bytes)${RESET} in Attachments folder"

        spinner_start "Removing attachment files…"
        local del_ok=0 del_fail=0
        while IFS= read -r f; do
            if rm -f "$f" 2>/dev/null; then
                (( del_ok++ )) || true
            else
                (( del_fail++ )) || true
                log_error "Could not delete: $f"
            fi
        done < <(find "$ATTACHMENTS_DIR" -type f 2>/dev/null)
        # Remove empty subdirectories
        find "$ATTACHMENTS_DIR" -type d -empty -delete 2>/dev/null || true
        spinner_stop
        ok "Deleted $del_ok files  (${del_fail} failures)"
        log_action "STEP1: Deleted $del_ok attachment files, $del_fail failures"
    else
        warn "Attachments folder not found — already empty or never existed"
    fi

    dbg "Step 1 complete. del_ok=$del_ok del_fail=$del_fail"

    # ── Step 2: Clear CloudKit caches ─────────────────────────────────────────
    echo
    section "Step 2/4 — Clearing CloudKit caches for Messages"
    dbg "Step 2 starting"

    local ck_cleared=0
    for ckpath in \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.MobileSMS" \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.iChat" \
        "$REAL_HOME/Library/Caches/CloudKit/com.apple.messages.usernamevalidation" ; do
        if [[ -d "$ckpath" ]]; then
            spinner_start "Clearing $(basename $ckpath)…"
            rm -rf "$ckpath" 2>/dev/null && (( ck_cleared++ )) || true
            spinner_stop
            ok "Cleared: $ckpath"
            log_action "STEP2: Cleared CloudKit cache $ckpath"
        fi
    done
    [[ $ck_cleared -eq 0 ]] && info "No CloudKit caches found (may have been cleared already)"
    dbg "Step 2 complete. ck_cleared=$ck_cleared"

    # ── Step 3: Restart iCloud sync daemons ───────────────────────────────────
    echo
    section "Step 3/4 — Restarting iCloud sync daemons"
    dbg "Step 3 starting"

    # Helper: kill a named process if it's running, log the result
    kill_if_running() {
        local pname="${1:-}"
        local wait_secs="${2:-1}"
        [[ -z "$pname" ]] && return 0
        dbg "kill_if_running: checking $pname"
        if pgrep -x "$pname" >/dev/null 2>&1; then
            spinner_start "Restarting $pname…"
            killall "$pname" 2>/dev/null || true
            sleep "$wait_secs"
            spinner_stop
            ok "$pname restarted"
            log_action "STEP3: Killed $pname"
            dbg "kill_if_running: $pname killed"
        else
            dbg "kill_if_running: $pname not running, skipping"
            info "$pname not running — skipping"
        fi
    }

    kill_if_running "bird"        2
    kill_if_running "cloudd"      1
    kill_if_running "cloudphotod" 1
    kill_if_running "itunescloudd" 1

    dbg "Step 3 complete"

    # ── Step 4: Toggle iCloud Messages sync off/on ────────────────────────────
    echo
    section "Step 4/4 — Toggling Messages in iCloud sync"
    dbg "Step 4 starting"
    info "Turning off iCloud Messages sync tells Apple's servers to release"
    info "the attachment data from your iCloud quota."
    echo

    # Read current state
    local cur_state
    cur_state=$(defaults read com.apple.messages.iCloud iMessageSyncEnabled 2>/dev/null || echo "1")

    spinner_start "Disabling Messages in iCloud…"
    defaults write com.apple.messages.iCloud iMessageSyncEnabled -bool false 2>/dev/null || true
    # Bounce the Messages sync agent
    launchctl stop com.apple.imagent 2>/dev/null || true
    killall imagent 2>/dev/null || true
    sleep 3
    spinner_stop
    ok "iCloud Messages sync disabled"
    log_action "STEP4: Disabled iMessageSyncEnabled"

    # Brief pause to let iCloud process the change
    spinner_start "Waiting 8 seconds for iCloud to process…"
    sleep 8
    spinner_stop
    ok "Wait complete"

    # Re-enable (so your messages still sync going forward, just without the old attachments)
    spinner_start "Re-enabling Messages in iCloud…"
    defaults write com.apple.messages.iCloud iMessageSyncEnabled -bool true 2>/dev/null || true
    launchctl start com.apple.imagent 2>/dev/null || true
    sleep 3
    spinner_stop
    ok "iCloud Messages sync re-enabled"
    log_action "STEP4: Re-enabled iMessageSyncEnabled"

    # ── Verification ──────────────────────────────────────────────────────────
    echo
    section "Verification"
    info "Measuring storage after cleanup…"
    echo

    # Give the system 5 more seconds to settle
    spinner_start "Letting daemons settle (5s)…"
    sleep 5
    spinner_stop

    local bytes_after; bytes_after=$(icloud_messages_local_bytes)
    show_icloud_status "AFTER cleanup"

    echo
    HR
    echo -e "  ${BOLD}Before / After Comparison${RESET}"
    HR
    bullet "Local footprint BEFORE : ${BYLW}$(human_bytes $bytes_before)${RESET}"
    bullet "Local footprint AFTER  : ${BGRN}$(human_bytes $bytes_after)${RESET}"

    local saved=$(( bytes_before - bytes_after ))
    if [[ $saved -gt 0 ]]; then
        bullet "${BOLD}Local space reclaimed  : ${BGRN}$(human_bytes $saved)${RESET}"
        ok "Local cleanup confirmed successful"
        log_action "VERIFY: Saved $(human_bytes $saved) locally"
    elif [[ $saved -eq 0 ]]; then
        warn "Local footprint unchanged — the Attachments folder may have been empty already"
        log_warn "VERIFY: No local space change detected"
    else
        warn "Footprint appears larger — daemons may still be syncing. Check again in a few minutes."
        log_warn "VERIFY: Footprint appears larger after cleanup (may be transient)"
    fi

    echo
    HR
    echo -e "  ${BOLD}What happens next${RESET}"
    HR
    info "iCloud quota updates take ${BOLD}5–30 minutes${RESET} on Apple's servers."
    bullet "Use ${BOLD}[7] Check iCloud Status${RESET} from the main menu to:"
    bullet "  • Watch a countdown timer and auto-recheck when it finishes"
    bullet "  • Open iCloud System Settings or iCloud.com directly"
    bullet "  • Force-retry the sync toggle if quota hasn't dropped"
    echo

    log_action "iCloud cleanup phase complete. Before=$(human_bytes $bytes_before) After=$(human_bytes $bytes_after)"

    if ask_yn "Go to iCloud Status checker now?" "y"; then
        do_icloud_verify
    else
        press_any_key
    fi
}

# ── Countdown timer ───────────────────────────────────────────────────────────
# countdown_timer <seconds> <label>
# Displays a live countdown bar. User can press any key to skip.
countdown_timer() {
    local total="${1:-60}"
    local label="${2:-Waiting}"
    local elapsed=0
    local bar_width=40
    local skipped=false

    # Put terminal in non-blocking read mode
    local old_stty; old_stty=$(stty -g </dev/tty 2>/dev/null || echo "")
    stty -echo -icanon min 0 time 0 </dev/tty 2>/dev/null || true

    echo
    while [[ $elapsed -lt $total ]]; do
        local remaining=$(( total - elapsed ))
        local filled=$(( elapsed * bar_width / total ))
        local empty=$(( bar_width - filled ))
        local pct=$(( elapsed * 100 / total ))
        local bar; bar=$(printf '█%.0s' $(seq 1 $filled) 2>/dev/null || printf '%*s' "$filled" '' | tr ' ' '█')
        local space; space=$(printf '%*s' "$empty" '')
        local mins=$(( remaining / 60 ))
        local secs=$(( remaining % 60 ))
        printf "\r  ${BBLU}[${RESET}${BGRN}%s${RESET}${DIM}%s${RESET}${BBLU}]${RESET} %3d%%  %s  ${DIM}%02d:%02d remaining  (any key to skip)${RESET}  " \
            "$bar" "$space" "$pct" "$label" "$mins" "$secs"

        # Non-blocking key check
        local key; key=$(dd bs=1 count=1 </dev/tty 2>/dev/null || echo "")
        if [[ -n "$key" ]]; then
            skipped=true
            break
        fi

        sleep 1
        (( elapsed++ )) || true
    done

    # Restore terminal
    [[ -n "$old_stty" ]] && stty "$old_stty" </dev/tty 2>/dev/null || true

    printf "\r%${WIDTH}s\r" ""  # clear line
    if $skipped; then
        warn "Timer skipped by user"
    else
        ok "$label complete"
    fi
    echo
}

# ── iCloud quota snapshot via plist ───────────────────────────────────────────
# Reads the iCloud storage plist Apple writes locally.
# Returns a human summary, or empty string if unavailable.
read_icloud_plist_quota() {
    local plist="$REAL_HOME/Library/Preferences/MobileMeAccounts.plist"
    if [[ ! -f "$plist" ]]; then
        echo ""
        return
    fi
    # Extract quota values using PlistBuddy
    local used avail total
    used=$(   /usr/libexec/PlistBuddy -c "Print :Accounts:0:iCloudInfo:com.apple.Dataclass.CloudKit:StorageUsed"  "$plist" 2>/dev/null || echo "")
    avail=$(  /usr/libexec/PlistBuddy -c "Print :Accounts:0:iCloudInfo:com.apple.Dataclass.CloudKit:StorageFree"  "$plist" 2>/dev/null || echo "")
    total=$(  /usr/libexec/PlistBuddy -c "Print :Accounts:0:iCloudInfo:com.apple.Dataclass.CloudKit:StorageTotal" "$plist" 2>/dev/null || echo "")
    if [[ -n "$used" && -n "$total" ]]; then
        echo "Used=$(human_bytes ${used:-0})  Free=$(human_bytes ${avail:-0})  Total=$(human_bytes ${total:-0})"
    else
        echo ""
    fi
}

# Read overall iCloud quota from a different plist path (Sonoma+)
read_icloud_quota_sonoma() {
    local plist="$REAL_HOME/Library/Preferences/com.apple.iCloud.plist"
    [[ ! -f "$plist" ]] && echo "" && return
    local used; used=$(/usr/libexec/PlistBuddy -c "Print :iCloudQuotaUsed" "$plist" 2>/dev/null || echo "")
    local total; total=$(/usr/libexec/PlistBuddy -c "Print :iCloudQuotaTotal" "$plist" 2>/dev/null || echo "")
    if [[ -n "$used" && -n "$total" ]]; then
        echo "iCloud used $(human_bytes ${used:-0}) of $(human_bytes ${total:-0})"
    else
        echo ""
    fi
}

# ── iCloud verification + retry screen ────────────────────────────────────────
do_icloud_verify() {
    banner
    section "iCloud Cleanup Verification & Status"

    # ── Snapshot current local state ─────────────────────────────────────────
    local att_bytes=0
    if [[ -d "$ATTACHMENTS_DIR" ]]; then
        att_bytes=$(du -sk "$ATTACHMENTS_DIR" 2>/dev/null | awk '{print $1*1024}' || echo 0)
    fi

    local total_local; total_local=$(icloud_messages_local_bytes)

    echo
    echo -e "  ${BOLD}Current Local Storage${RESET}"
    HR
    if [[ "$att_bytes" -eq 0 ]]; then
        ok "Local Attachments folder is empty (${BOLD}0 B${RESET}) — local deletion confirmed"
    else
        warn "Local Attachments folder still has $(human_bytes $att_bytes) — may need cleanup"
    fi
    bullet "Total local Messages footprint : ${BOLD}$(human_bytes $total_local)${RESET}"

    # ── Try to read iCloud quota from plists ─────────────────────────────────
    echo
    echo -e "  ${BOLD}iCloud Quota (cached local copy — may be stale)${RESET}"
    HR
    local quota_str; quota_str=$(read_icloud_plist_quota)
    local quota_sonoma; quota_sonoma=$(read_icloud_quota_sonoma)
    if [[ -n "$quota_str" ]]; then
        bullet "CloudKit quota  : ${BCYN}$quota_str${RESET}"
    fi
    if [[ -n "$quota_sonoma" ]]; then
        bullet "iCloud total    : ${BCYN}$quota_sonoma${RESET}"
    fi
    if [[ -z "$quota_str" && -z "$quota_sonoma" ]]; then
        bullet "${DIM}Local quota cache not readable — use the UI links below to check${RESET}"
    fi

    # ── brctl status ─────────────────────────────────────────────────────────
    local brctl_msgs; brctl_msgs=$(brctl status 2>/dev/null | grep -i "message\|iChat\|MobileSMS" | head -8 || echo "")
    if [[ -n "$brctl_msgs" ]]; then
        echo
        echo -e "  ${BOLD}iCloud Daemon Status (brctl)${RESET}"
        HR
        echo "$brctl_msgs" | while IFS= read -r line; do
            bullet "${DIM}$line${RESET}"
        done
    fi

    # ── Open macOS UI shortcuts ───────────────────────────────────────────────
    echo
    echo -e "  ${BOLD}Open macOS UI to check iCloud storage${RESET}"
    HR
    echo -e "  ${BBLU}[a]${RESET}  Open iCloud Storage settings  ${DIM}(System Settings → iCloud → Manage)${RESET}"
    echo -e "  ${BBLU}[b]${RESET}  Open iCloud.com in browser    ${DIM}(shows live server quota)${RESET}"
    echo -e "  ${BBLU}[c]${RESET}  Open Messages app             ${DIM}(check if attachments gone)${RESET}"
    echo -e "  ${BBLU}[d]${RESET}  Open your export folder       ${DIM}($OUTPUT_ROOT)${RESET}"
    echo

    # ── Wait timer ────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}Wait & Recheck${RESET}"
    HR
    info "iCloud quota updates take ${BOLD}5–30 minutes${RESET} on Apple's servers."
    info "Use the timer below to wait, then re-read the local quota cache."
    echo
    echo -e "  ${BBLU}[w]${RESET}  Wait with countdown (you choose duration), then recheck"
    echo -e "  ${BBLU}[r]${RESET}  Re-run iCloud cleanup (Steps 1–4 again)"
    echo -e "  ${BBLU}[f]${RESET}  Force iCloud sync refresh now"
    echo -e "  ${BBLU}[0]${RESET}  Back to main menu"
    echo
    printf "  Select: "
    read -r vchoice </dev/tty

    case "$vchoice" in
        a|A)
            info "Opening iCloud Storage settings…"
            # Works on macOS 13+ Ventura/Sonoma
            open "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud" 2>/dev/null || \
            open "/System/Library/PreferencePanes/iCloudPref.prefPane" 2>/dev/null || \
            open "x-apple.systempreferences:" 2>/dev/null || true
            log_action "Opened iCloud System Settings"
            ok "Opened System Settings"
            press_any_key
            do_icloud_verify
            ;;
        b|B)
            info "Opening iCloud.com…"
            open "https://www.icloud.com/settings/" 2>/dev/null || true
            log_action "Opened iCloud.com/settings"
            ok "Opened browser"
            press_any_key
            do_icloud_verify
            ;;
        c|C)
            info "Opening Messages.app…"
            open -a Messages 2>/dev/null || true
            log_action "Opened Messages.app"
            ok "Opening Messages — look for cloud download icons on old messages"
            press_any_key
            do_icloud_verify
            ;;
        d|D)
            info "Opening export folder…"
            open "$OUTPUT_ROOT" 2>/dev/null || true
            do_icloud_verify
            ;;
        w|W)
            echo
            local wait_mins; wait_mins=$(ask_input "How many minutes to wait before rechecking?" "15")
            local wait_secs=$(( wait_mins * 60 ))
            echo
            info "Starting ${BOLD}${wait_mins}-minute${RESET} countdown. Press any key to skip."
            countdown_timer "$wait_secs" "Waiting for iCloud to update…"
            log_action "VERIFY: Waited ${wait_mins} minutes"

            # After timer: refresh local plist cache by poking iCloud
            spinner_start "Poking iCloud to refresh local quota cache…"
            killall bird 2>/dev/null || true
            sleep 3
            spinner_stop
            ok "iCloud daemon restarted — quota cache should refresh in ~60s"

            # Re-enter verify screen to show updated numbers
            press_any_key
            do_icloud_verify
            ;;
        r|R)
            echo
            warn "This will re-run Steps 1–4 of the iCloud cleanup."
            if ask_yn "Re-run iCloud cleanup now?" "n"; then
                do_icloud_cleanup
            else
                do_icloud_verify
            fi
            ;;
        f|F)
            echo
            section "Force iCloud sync refresh"
            spinner_start "Disabling Messages in iCloud…"
            defaults write com.apple.messages.iCloud iMessageSyncEnabled -bool false 2>/dev/null || true
            killall imagent 2>/dev/null || true
            sleep 4
            spinner_stop
            ok "Sync disabled"

            spinner_start "Killing bird to flush cache…"
            killall bird 2>/dev/null || true
            sleep 3
            spinner_stop
            ok "bird restarted"

            spinner_start "Re-enabling Messages in iCloud…"
            defaults write com.apple.messages.iCloud iMessageSyncEnabled -bool true 2>/dev/null || true
            launchctl start com.apple.imagent 2>/dev/null || true
            sleep 3
            spinner_stop
            ok "Sync re-enabled"

            log_action "VERIFY: Force-refreshed iCloud sync"
            info "Give iCloud 5–10 minutes to update, then use ${BOLD}[w]${RESET} to wait and recheck."
            press_any_key
            do_icloud_verify
            ;;
        0|q|Q)
            return
            ;;
        *)
            do_icloud_verify
            ;;
    esac
}

# ── Stats screen ──────────────────────────────────────────────────────────────
show_stats_screen() {
    banner
    section "Database Statistics"
    spinner_start "Reading stats from chat.db …"

    local total_msgs total_attachments total_images total_videos
    local db_size attachments_dir_size

    total_msgs=$(db_query "$DB_TMP" "SELECT COUNT(*) FROM message;" 2>/dev/null || echo "?")
    total_attachments=$(db_query "$DB_TMP" "SELECT COUNT(*) FROM attachment WHERE filename IS NOT NULL;" 2>/dev/null || echo "?")
    total_images=$(db_query "$DB_TMP" "SELECT COUNT(*) FROM attachment WHERE mime_type LIKE 'image/%';" 2>/dev/null || echo "?")
    total_videos=$(db_query "$DB_TMP" "SELECT COUNT(*) FROM attachment WHERE mime_type LIKE 'video/%';" 2>/dev/null || echo "?")
    db_size=$(stat -f%z "$MESSAGES_DB" 2>/dev/null || stat -c%s "$MESSAGES_DB" 2>/dev/null || echo 0)
    attachments_dir_size=$(du -sb "$ATTACHMENTS_DIR" 2>/dev/null | cut -f1 || echo 0)

    spinner_stop

    echo
    echo -e "  ${BOLD}Messages.app Storage${RESET}"
    HR
    bullet "chat.db size         : $(human_bytes $db_size)"
    bullet "Attachments folder   : $(human_bytes $attachments_dir_size)"
    echo
    echo -e "  ${BOLD}Message Counts${RESET}"
    HR
    bullet "Total messages       : $total_msgs"
    bullet "Total attachments    : $total_attachments"
    bullet "Images               : $total_images"
    bullet "Videos               : $total_videos"
    echo
    echo -e "  ${BOLD}Top Senders (by attachment count)${RESET}"
    HR
    sqlite3 -separator ' → ' "$DB_TMP" "
        SELECT COALESCE(h.id, '(me)'), COUNT(a.ROWID) as cnt
        FROM attachment a
        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
        JOIN message m ON maj.message_id = m.ROWID
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE a.filename IS NOT NULL
        GROUP BY h.id
        ORDER BY cnt DESC
        LIMIT 15;
    " 2>/dev/null | while IFS=$'\n' read -r line; do
        bullet "$line"
    done
    echo

    press_any_key
}

# ── Options menu ──────────────────────────────────────────────────────────────
show_options_menu() {
    while true; do
        banner
        section "Options"
        echo
        printf "  ${BBLU}[1]${RESET}  Dry-run mode          : "
        $DRY_RUN   && echo -e "${BGRN}ON${RESET}"  || echo -e "${DIM}off${RESET}"

        printf "  ${BBLU}[2]${RESET}  Delete after copy     : "
        $DELETE_AFTER_COPY && echo -e "${BRED}YES (files will be deleted!)${RESET}" || echo -e "${DIM}no${RESET}"

        printf "  ${BBLU}[3]${RESET}  Skip images           : "
        $SKIP_IMAGES && echo -e "${BYLW}YES${RESET}" || echo -e "${DIM}no${RESET}"

        printf "  ${BBLU}[4]${RESET}  Skip videos           : "
        $SKIP_VIDEOS && echo -e "${BYLW}YES${RESET}" || echo -e "${DIM}no${RESET}"

        printf "  ${BBLU}[5]${RESET}  Skip other files      : "
        $SKIP_OTHER && echo -e "${BYLW}YES${RESET}" || echo -e "${DIM}no${RESET}"

        printf "  ${BBLU}[6]${RESET}  Minimum file size     : "
        [[ $MIN_SIZE_KB -gt 0 ]] && echo -e "${BCYN}${MIN_SIZE_KB} KB${RESET}" || echo -e "${DIM}none${RESET}"

        printf "  ${BBLU}[7]${RESET}  Max age (days)        : "
        [[ $MAX_AGE_DAYS -gt 0 ]] && echo -e "${BCYN}${MAX_AGE_DAYS} days${RESET}" || echo -e "${DIM}all time${RESET}"

        printf "  ${BBLU}[8]${RESET}  Overwrite existing    : "
        $OVERWRITE_EXISTING && echo -e "${BYLW}YES${RESET}" || echo -e "${DIM}no (auto-rename)${RESET}"

        printf "  ${BBLU}[9]${RESET}  Filter by sender      : "
        [[ -n "$SENDER_FILTER" ]] && echo -e "${BCYN}$SENDER_FILTER${RESET}" || echo -e "${DIM}all senders${RESET}"

        printf "  ${BBLU}[10]${RESET} Output folder         : ${BCYN}$OUTPUT_ROOT${RESET}\n"

        printf "  ${BBLU}[d]${RESET}  Debug logging         : "
        $DEBUG_LOG && echo -e "${BGRN}ON (verbose trace to log + screen)${RESET}" || echo -e "${DIM}off${RESET}"

        printf "  ${BBLU}[r]${RESET}  Reset manifest        : "
        if [[ -f "$MANIFEST_FILE" ]]; then
            local mc; mc=$(wc -l < "$MANIFEST_FILE" | tr -d ' ')
            echo -e "${BYLW}$mc entries recorded — reset to re-copy all${RESET}"
        else
            echo -e "${DIM}no manifest yet (first run)${RESET}"
        fi

        echo
        echo -e "  ${BBLU}[0]${RESET}  Back to main menu"
        echo
        printf "  Select option: "
        read -r opt </dev/tty

        case "$opt" in
            1)  $DRY_RUN && DRY_RUN=false || DRY_RUN=true ;;
            2)
                if ! $DELETE_AFTER_COPY; then
                    warn "Enabling 'Delete after copy' will PERMANENTLY remove source attachments."
                    ask_yn "Are you sure?" "n" && DELETE_AFTER_COPY=true || true
                else
                    DELETE_AFTER_COPY=false
                fi
                ;;
            3)  $SKIP_IMAGES && SKIP_IMAGES=false || SKIP_IMAGES=true ;;
            4)  $SKIP_VIDEOS && SKIP_VIDEOS=false || SKIP_VIDEOS=true ;;
            5)  $SKIP_OTHER  && SKIP_OTHER=false  || SKIP_OTHER=true  ;;
            6)  MIN_SIZE_KB=$(ask_input "Minimum file size in KB (0 = no filter)" "$MIN_SIZE_KB") ;;
            7)  MAX_AGE_DAYS=$(ask_input "Only process attachments from last N days (0 = all)" "$MAX_AGE_DAYS") ;;
            8)  $OVERWRITE_EXISTING && OVERWRITE_EXISTING=false || OVERWRITE_EXISTING=true ;;
            9)  SENDER_FILTER=$(ask_input "Filter by sender name/handle (empty = all)" "$SENDER_FILTER") ;;
            10) OUTPUT_ROOT=$(ask_input "Output folder" "$OUTPUT_ROOT")
                LOG_FILE="$OUTPUT_ROOT/cleanup.log"
                ;;
            d|D) $DEBUG_LOG && DEBUG_LOG=false || DEBUG_LOG=true ;;
            r|R)
                if [[ -f "$MANIFEST_FILE" ]]; then
                    if ask_yn "Delete manifest? Next run will re-copy everything." "n"; then
                        rm -f "$MANIFEST_FILE"
                        ok "Manifest deleted — next run starts fresh"
                        sleep 1
                    fi
                else
                    info "No manifest file exists yet."
                    sleep 1
                fi
                ;;
            0)  return ;;
            *)  warn "Invalid option" ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# ── Per-contact browse & export (v2.1.0) ─────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
#
# Workflow:
#   1. Build a "contact roster" by joining chat.db's handle table to the
#      latest message per handle, sorted by recency.
#   2. For each row, resolve a display name via Contacts AddressBook (same
#      lookup_contact_name() used elsewhere). When the contact has no
#      AddressBook match, fall back to the phone/email handle and present
#      a snippet of the last message as the prompt to help the user
#      remember who this is.
#   3. Let the user select one or more handles (comma-separated or "all").
#   4. For each selection, build a self-contained per-person folder:
#        <OUTPUT_ROOT>/contacts/<slug>/
#          chat_<slug>.db        — SQLite copy with only that handle's messages
#          messages_<slug>.txt   — readable transcript
#          attachments/          — every available media file
#          metadata.json         — stats, handles, date range
# ─────────────────────────────────────────────────────────────────────────────

# PER_CONTACT_ROOT is now derived from BACKUP_ROOT at export time (v2.2.0+),
# not hardcoded under OUTPUT_ROOT — so exports land in the user-chosen
# backup folder (default: ~/Documents/root/imessage-backups) rather than
# alongside the sender-grouped attachment dump on the Desktop.
PER_CONTACT_ROOT=""   # set by do_per_contact_export()

# ── Config: persist the user's chosen backup root across runs ────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
    # If still empty after sourcing, fall back to default.
    [[ -z "$BACKUP_ROOT" ]] && BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
}

save_config() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    # Re-chown if we ran with sudo so the user owns their own config
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER" "$CONFIG_DIR" 2>/dev/null || true
    fi
    cat > "$CONFIG_FILE" <<EOF
# imessage_cleanup config — auto-generated, safe to edit
BACKUP_ROOT="$BACKUP_ROOT"
EOF
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$CONFIG_FILE" 2>/dev/null || true
}

# ── Folder navigator: lets the user pick / type / create a backup folder ─────
# Returns 0 with $BACKUP_ROOT set if user confirms, 1 if cancelled.
pick_backup_dir() {
    while true; do
        banner
        section "Choose where to store per-contact exports"
        echo
        echo -e "  ${BOLD}Current:${RESET}  ${BCYN}$BACKUP_ROOT${RESET}"
        if [[ -d "$BACKUP_ROOT" ]]; then
            local sz; sz=$(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}')
            local n;  n=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  ${DIM}Exists — $sz on disk, $n subfolder(s)${RESET}"
        else
            echo -e "  ${DIM}Does not exist yet — will be created on first export${RESET}"
        fi
        echo
        echo -e "  ${BBLU}[1]${RESET}  Use current location (above)"
        echo -e "  ${BBLU}[2]${RESET}  Default: ${DIM}$DEFAULT_BACKUP_ROOT${RESET}"
        echo -e "  ${BBLU}[3]${RESET}  Documents:  ${DIM}$REAL_HOME/Documents${RESET}"
        echo -e "  ${BBLU}[4]${RESET}  Desktop:    ${DIM}$REAL_HOME/Desktop${RESET}"
        echo -e "  ${BBLU}[5]${RESET}  Type a custom path"
        echo -e "  ${BBLU}[6]${RESET}  Browse — list folders in current location and pick"
        echo -e "  ${BBLU}[7]${RESET}  Create new subfolder inside current location"
        echo -e "  ${BBLU}[0]${RESET}  Cancel"
        echo
        printf "  Select: "
        read -r choice </dev/tty

        case "$choice" in
            1)
                if mkdir -p "$BACKUP_ROOT" 2>/dev/null; then
                    save_config
                    ok "Backup root set to: $BACKUP_ROOT"
                    return 0
                else
                    err "Cannot create $BACKUP_ROOT"
                    sleep 1
                fi
                ;;
            2) BACKUP_ROOT="$DEFAULT_BACKUP_ROOT" ;;
            3) BACKUP_ROOT="$REAL_HOME/Documents/imessage-backups" ;;
            4) BACKUP_ROOT="$REAL_HOME/Desktop/imessage-backups" ;;
            5)
                local typed
                typed=$(ask_input "Enter absolute path" "$BACKUP_ROOT")
                # Expand ~
                typed="${typed/#\~/$REAL_HOME}"
                if [[ "$typed" != /* ]]; then
                    warn "Path must be absolute (start with / or ~)"
                    sleep 1
                else
                    BACKUP_ROOT="$typed"
                fi
                ;;
            6)
                browse_subfolders
                ;;
            7)
                local subname
                subname=$(ask_input "New folder name (will be created inside $BACKUP_ROOT)" "")
                if [[ -n "$subname" ]]; then
                    BACKUP_ROOT="$BACKUP_ROOT/$subname"
                fi
                ;;
            0|q|Q) return 1 ;;
            *) warn "Invalid"; sleep 1 ;;
        esac
    done
}

# ── Tiny ls-style browser for the "Browse" option above ──────────────────────
browse_subfolders() {
    local start="$BACKUP_ROOT"
    [[ ! -d "$start" ]] && start="$REAL_HOME"

    while true; do
        banner
        section "Browse: $start"
        echo
        # List parent + subfolders
        local -a entries=()
        entries+=("..")
        local d
        while IFS= read -r -d '' d; do
            entries+=("$(basename "$d")")
        done < <(find "$start" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print0 2>/dev/null | sort -zf)

        local i=0
        for d in "${entries[@]}"; do
            i=$(( i + 1 ))
            printf "  ${BCYN}%-4s${RESET}  %s\n" "$i" "$d"
        done

        echo
        echo -e "  ${BBLU}[s]${RESET}  Select THIS folder ($start)"
        echo -e "  ${BBLU}[0]${RESET}  Back"
        echo
        printf "  Pick a number to enter, [s] to select, [0] to go back: "
        read -r b </dev/tty

        case "$b" in
            0|q|Q) return ;;
            s|S)
                BACKUP_ROOT="$start"
                return
                ;;
            *)
                if [[ "$b" =~ ^[0-9]+$ ]] && (( b >= 1 && b <= ${#entries[@]} )); then
                    local picked="${entries[$((b-1))]}"
                    if [[ "$picked" == ".." ]]; then
                        start=$(dirname "$start")
                    else
                        start="$start/$picked"
                    fi
                else
                    warn "Invalid"; sleep 1
                fi
                ;;
        esac
    done
}

# Slugify a string for safe use as a folder/filename.
slugify() {
    local s="$1"
    echo "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g' | cut -c1-60
}

# Return TSV rows: handle_rowid \t handle_id_string \t service \t last_msg_epoch \t msg_count
#
# v2.2.4 portability + perf:
#   - Window functions removed (some sqlite builds reject them when called
#     from the command-line form).
#   - Dot-commands removed (sqlite silently ignores them in that mode).
#   - The expensive "last message text per handle" is deferred — we no longer
#     fetch it during roster build. The roster builds in seconds from just
#     COUNT + MAX(date). The last-message preview is fetched on demand by
#     fetch_last_text() only when we actually render a row, AND only for
#     handles the user can see (rows on the current page).
roster_query_handles() {
    local sql_err="/tmp/imessage_roster_err_$$.txt"
    sqlite3 -separator $'\t' "$DB_TMP" "
SELECT
    h.ROWID,
    h.id,
    COALESCE(h.service,''),
    COALESCE(MAX(m.date), 0)   AS last_date,
    COUNT(m.ROWID)             AS n_msgs
FROM handle h
JOIN message m ON m.handle_id = h.ROWID
GROUP BY h.ROWID
ORDER BY last_date DESC;
" 2>"$sql_err"
    local rc=$?
    if [[ -s "$sql_err" ]]; then
        log_error "roster SQL stderr: $(tr '\n' ' ' < "$sql_err")"
    fi
    rm -f "$sql_err"
    return $rc
}

# Fetch (and cache) the last non-empty message text for a (possibly merged)
# contact. Takes a comma-separated list of handle ROWIDs (v2.3.0).
declare -a LAST_TEXT_CACHE_KEYS=()
declare -a LAST_TEXT_CACHE_VALS=()
fetch_last_text() {
    local id_list="$1"
    local i
    for (( i=0; i<${#LAST_TEXT_CACHE_KEYS[@]}; i++ )); do
        if [[ "${LAST_TEXT_CACHE_KEYS[$i]}" == "$id_list" ]]; then
            printf '%s' "${LAST_TEXT_CACHE_VALS[$i]}"
            return
        fi
    done
    local txt
    txt=$(sqlite3 "$DB_TMP" "
SELECT SUBSTR(COALESCE(text,''),1,80)
FROM message
WHERE handle_id IN ($id_list) AND text IS NOT NULL AND text != ''
ORDER BY date DESC LIMIT 1;" 2>/dev/null)
    LAST_TEXT_CACHE_KEYS+=("$id_list")
    LAST_TEXT_CACHE_VALS+=("$txt")
    printf '%s' "$txt"
}

# ── AddressBook prefetch (v2.2.1) ─────────────────────────────────────────────
# Slurp every (normalized-phone | email)  →  "First Last" pair from the
# AddressBook once, into bash arrays. Then resolve_handle_name() does an
# in-memory lookup instead of running a sqlite query per handle.
AB_PHONE_KEYS=()
AB_PHONE_NAMES=()
AB_EMAIL_KEYS=()
AB_EMAIL_NAMES=()

prefetch_address_book() {
    AB_PHONE_KEYS=(); AB_PHONE_NAMES=()
    AB_EMAIL_KEYS=(); AB_EMAIL_NAMES=()

    [[ -z "$ADDRESSBOOK_TMP" || ! -f "$ADDRESSBOOK_TMP" ]] && return 0

    # Phones: get all (phone, first, last) and normalize phone to last-10 digits.
    local first last fullnum norm n
    while IFS=$'\t' read -r first last fullnum; do
        [[ -z "$fullnum" ]] && continue
        norm=$(printf '%s' "$fullnum" | tr -cd '0-9')
        norm="${norm: -10}"
        [[ -z "$norm" ]] && continue
        n=$(_trim "$first $last")
        [[ -z "$n" ]] && continue
        AB_PHONE_KEYS+=("$norm")
        AB_PHONE_NAMES+=("$n")
    done < <(sqlite3 -separator $'\t' "$ADDRESSBOOK_TMP" "
SELECT COALESCE(r.ZFIRSTNAME,''),
       COALESCE(r.ZLASTNAME,''),
       COALESCE(p.ZFULLNUMBER,'')
FROM ZABCDRECORD r
JOIN ZABCDPHONENUMBER p ON r.Z_PK = p.ZOWNER
WHERE p.ZFULLNUMBER IS NOT NULL;" 2>/dev/null)

    # Emails
    local addr k
    while IFS=$'\t' read -r first last addr; do
        [[ -z "$addr" ]] && continue
        k=$(printf '%s' "$addr" | tr '[:upper:]' '[:lower:]')
        n=$(_trim "$first $last")
        [[ -z "$n" ]] && continue
        AB_EMAIL_KEYS+=("$k")
        AB_EMAIL_NAMES+=("$n")
    done < <(sqlite3 -separator $'\t' "$ADDRESSBOOK_TMP" "
SELECT COALESCE(r.ZFIRSTNAME,''),
       COALESCE(r.ZLASTNAME,''),
       COALESCE(e.ZADDRESS,'')
FROM ZABCDRECORD r
JOIN ZABCDEMAILADDRESS e ON r.Z_PK = e.ZOWNER
WHERE e.ZADDRESS IS NOT NULL;" 2>/dev/null)
}

# Fast in-memory lookup against prefetched AddressBook.
resolve_handle_name() {
    local hid="$1"
    local i
    if [[ "$hid" == *"@"* ]]; then
        local k; k=$(echo "$hid" | tr '[:upper:]' '[:lower:]')
        for (( i=0; i<${#AB_EMAIL_KEYS[@]}; i++ )); do
            if [[ "${AB_EMAIL_KEYS[$i]}" == "$k" ]]; then
                echo "${AB_EMAIL_NAMES[$i]}"; return
            fi
        done
    else
        local norm; norm=$(echo "$hid" | tr -cd '0-9')
        norm="${norm: -10}"
        [[ -z "$norm" ]] && { echo "$hid"; return; }
        for (( i=0; i<${#AB_PHONE_KEYS[@]}; i++ )); do
            if [[ "${AB_PHONE_KEYS[$i]}" == "$norm" ]]; then
                echo "${AB_PHONE_NAMES[$i]}"; return
            fi
        done
    fi
    echo "$hid"
}

# Build & cache the roster array; populates global arrays ROSTER_*.
build_roster() {
    ROSTER_HANDLE_ROWID=()
    ROSTER_HANDLE_RAW=()
    ROSTER_DISPLAY_NAME=()
    ROSTER_LAST_TEXT=()
    ROSTER_LAST_DATE=()
    ROSTER_MSG_COUNT=()
    ROSTER_SERVICE=()
    ROSTER_HAS_CONTACT=()
    ROSTER_EXPORT_DIR_OVERRIDE=()
    ROSTER_EXPORT_FORMAT=()

    log_action "roster: prefetching AddressBook"
    info "Prefetching AddressBook …"
    prefetch_address_book
    info "Loaded ${#AB_PHONE_KEYS[@]} phone(s) and ${#AB_EMAIL_KEYS[@]} email(s) from Contacts."
    log_action "roster: AddressBook ready (${#AB_PHONE_KEYS[@]} phones, ${#AB_EMAIL_KEYS[@]} emails)"

    # v2.3.1: hard pre-flight on chat.db. If Full Disk Access isn't granted
    # the cp earlier may have silently produced an unreadable file. Catch
    # that here with a real query instead of getting back a confusing
    # "No handles found" later.
    local db_msg_count db_msg_err
    db_msg_count=$(sqlite3 "$DB_TMP" "SELECT COUNT(*) FROM message;" 2>/tmp/imessage_db_check_$$.err)
    db_msg_err=$(cat /tmp/imessage_db_check_$$.err 2>/dev/null)
    rm -f /tmp/imessage_db_check_$$.err
    log_action "roster: chat.db pre-flight COUNT(*)=$db_msg_count err=\"$db_msg_err\""
    if [[ -z "$db_msg_count" ]] || ! [[ "$db_msg_count" =~ ^[0-9]+$ ]] || [[ "$db_msg_count" -eq 0 ]]; then
        err "chat.db pre-flight failed — got count=\"$db_msg_count\" err=\"$db_msg_err\""
        warn "This almost always means the Terminal running this script does not"
        warn "have ${BOLD}Full Disk Access${RESET}, so cp produced an unreadable copy of chat.db."
        echo
        echo -e "  ${BOLD}Fix:${RESET}"
        bullet "System Settings → Privacy & Security → Full Disk Access"
        bullet "Toggle ${BOLD}Terminal${RESET} ON (or off then on if already on)"
        bullet "Fully quit Terminal (${BOLD}Cmd-Q${RESET}) and reopen"
        bullet "Re-run: ${DIM}sudo bash imessage_cleanup.sh${RESET}"
        echo
        return 1
    fi
    info "chat.db pre-flight: $db_msg_count message rows visible — good."

    log_action "roster: running single-pass chat.db query"
    spinner_start "Building contact roster from chat.db (single-pass) …"
    local rows
    rows=$(roster_query_handles 2>/dev/null) || rows=""
    spinner_stop
    # Count rows without using grep -c (which exits 1 on no-match and trips pipefail)
    local nrows=0
    if [[ -n "$rows" ]]; then
        nrows=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    fi
    log_action "roster: query returned $nrows handles"

    if [[ -z "$rows" ]]; then
        warn "No handles found in chat.db."
        return 1
    fi

    # v2.3.0: read all rows first, then merge same-person handles.
    #
    # Merge rule (in order of precedence):
    #   1. If display name resolved from AddressBook → merge by name.
    #   2. Else if handle is a phone → merge by normalized last-10 digits.
    #   3. Else (email with no contact) → keep distinct.
    #
    # For each merged group we sum message counts, take MAX(last_date),
    # collect every raw handle, and store a comma-separated ROWID list
    # so SQL exports can use `WHERE handle_id IN (...)`.
    local -a GRP_KEYS=()               # idx -> merge key
    local -a GRP_HANDLES=()            # idx -> "rowid1,rowid2,..."
    local -a GRP_RAW_LIST=()           # idx -> "hid1 | hid2"
    local rowid hid svc last_epoch nmsgs key name display has_contact
    local next_idx=0

    while IFS=$'\t' read -r rowid hid svc last_epoch nmsgs; do
        [[ -z "$rowid" ]] && continue
        name=$(resolve_handle_name "$hid")
        if [[ "$name" == "$hid" ]]; then
            display="$hid"
            has_contact=0
            # No contact match — key by normalized phone if it looks like one,
            # otherwise key by raw handle (so different emails stay separate).
            if [[ "$hid" == *"@"* ]]; then
                key="email:$(echo "$hid" | tr '[:upper:]' '[:lower:]')"
            else
                local norm; norm=$(printf '%s' "$hid" | tr -cd '0-9')
                norm="${norm: -10}"
                if [[ -n "$norm" ]]; then
                    key="phone:$norm"
                else
                    key="raw:$hid"
                fi
            fi
        else
            display="$name"
            has_contact=1
            key="name:$(echo "$name" | tr '[:upper:]' '[:lower:]')"
        fi
        display=$(echo "$display" | sed 's/[\/:\\*?"<>|]/_/g')

        local found_idx="" gi
        for (( gi=0; gi<${#GRP_KEYS[@]}; gi++ )); do
            if [[ "${GRP_KEYS[$gi]}" == "$key" ]]; then
                found_idx="$gi"
                break
            fi
        done

        if [[ -n "$found_idx" ]]; then
            local i="$found_idx"
            # Sum counts, keep max last_date, append handle.
            ROSTER_MSG_COUNT[$i]=$(( ${ROSTER_MSG_COUNT[$i]} + nmsgs ))
            if [[ "$last_epoch" =~ ^[0-9]+$ ]] && [[ "$last_epoch" -gt "${ROSTER_LAST_DATE[$i]}" ]]; then
                ROSTER_LAST_DATE[$i]="$last_epoch"
            fi
            GRP_HANDLES[$i]="${GRP_HANDLES[$i]},$rowid"
            # Append the raw handle to the visible list (deduped)
            if [[ "${GRP_RAW_LIST[$i]}" != *"$hid"* ]]; then
                GRP_RAW_LIST[$i]="${GRP_RAW_LIST[$i]} | $hid"
                ROSTER_HANDLE_RAW[$i]="${GRP_RAW_LIST[$i]}"
            fi
            if [[ "$has_contact" == "1" ]]; then
                ROSTER_HAS_CONTACT[$i]=1
                ROSTER_DISPLAY_NAME[$i]="$display"
            fi
        else
            GRP_KEYS[$next_idx]="$key"
            GRP_HANDLES[$next_idx]="$rowid"
            GRP_RAW_LIST[$next_idx]="$hid"
            ROSTER_HANDLE_ROWID+=("$rowid")   # primary rowid (first seen)
            ROSTER_HANDLE_RAW+=("$hid")
            ROSTER_DISPLAY_NAME+=("$display")
            ROSTER_LAST_TEXT+=("")
            ROSTER_LAST_DATE+=("$last_epoch")
            ROSTER_MSG_COUNT+=("$nmsgs")
            ROSTER_SERVICE+=("$svc")
            ROSTER_HAS_CONTACT+=("$has_contact")
            next_idx=$(( next_idx + 1 ))
        fi
    done <<< "$rows"

    # Promote merged handle lists into a global parallel array for SQL use.
    ROSTER_HANDLE_IDS=()
    local k
    for (( k=0; k<next_idx; k++ )); do
        ROSTER_HANDLE_IDS+=("${GRP_HANDLES[$k]}")
    done

    # ── Sort by message count descending ──────────────────────────────────
    local total=${#ROSTER_HANDLE_ROWID[@]}
    if (( total > 1 )); then
        # Bubble in via a sort-key-prefixed line: "<count>\t<index>"
        local sort_input=""
        local i
        for (( i=0; i<total; i++ )); do
            sort_input+="${ROSTER_MSG_COUNT[$i]}\t$i"$'\n'
        done
        local sorted_order
        sorted_order=$(printf '%b' "$sort_input" | sort -t $'\t' -k1,1 -nr | awk -F'\t' '{print $2}')

        # Build new arrays in sorted order
        local -a NEW_ROWID NEW_RAW NEW_DISP NEW_TEXT NEW_DATE NEW_COUNT NEW_SVC NEW_IDS NEW_HAS_CONTACT
        while IFS= read -r i; do
            [[ -z "$i" ]] && continue
            NEW_ROWID+=("${ROSTER_HANDLE_ROWID[$i]}")
            NEW_RAW+=("${ROSTER_HANDLE_RAW[$i]}")
            NEW_DISP+=("${ROSTER_DISPLAY_NAME[$i]}")
            NEW_TEXT+=("${ROSTER_LAST_TEXT[$i]}")
            NEW_DATE+=("${ROSTER_LAST_DATE[$i]}")
            NEW_COUNT+=("${ROSTER_MSG_COUNT[$i]}")
            NEW_SVC+=("${ROSTER_SERVICE[$i]}")
            NEW_IDS+=("${ROSTER_HANDLE_IDS[$i]}")
            NEW_HAS_CONTACT+=("${ROSTER_HAS_CONTACT[$i]}")
        done <<< "$sorted_order"
        ROSTER_HANDLE_ROWID=("${NEW_ROWID[@]}")
        ROSTER_HANDLE_RAW=("${NEW_RAW[@]}")
        ROSTER_DISPLAY_NAME=("${NEW_DISP[@]}")
        ROSTER_LAST_TEXT=("${NEW_TEXT[@]}")
        ROSTER_LAST_DATE=("${NEW_DATE[@]}")
        ROSTER_MSG_COUNT=("${NEW_COUNT[@]}")
        ROSTER_SERVICE=("${NEW_SVC[@]}")
        ROSTER_HANDLE_IDS=("${NEW_IDS[@]}")
        ROSTER_HAS_CONTACT=("${NEW_HAS_CONTACT[@]}")
    fi

    log_action "roster: merged into ${#ROSTER_HANDLE_ROWID[@]} unique contact(s), sorted by msg count desc"
    return 0
}

# Render the roster as a numbered table, paginated.
render_roster_page() {
    local page="$1" page_size="$2"
    local total=${#ROSTER_HANDLE_ROWID[@]}
    local start=$(( page * page_size ))
    local end=$(( start + page_size ))
    [[ $end -gt $total ]] && end=$total

    HR
    printf "  ${BOLD}%-4s  %-28s  %-30s  %7s  %-30s${RESET}\n" \
        "#" "Contact" "Handle(s)" "Msgs ↓" "Last message (preview)"
    HR
    local i
    for (( i=start; i<end; i++ )); do
        local idx=$(( i + 1 ))
        local name="${ROSTER_DISPLAY_NAME[$i]}"
        local hid="${ROSTER_HANDLE_RAW[$i]}"
        local n="${ROSTER_MSG_COUNT[$i]}"
        local prev="${ROSTER_LAST_TEXT[$i]}"
        # Lazy-load preview the first time we render this row.
        if [[ -z "$prev" ]]; then
            prev=$(fetch_last_text "${ROSTER_HANDLE_IDS[$i]}")
            ROSTER_LAST_TEXT[$i]="$prev"
        fi
        local date_epoch="${ROSTER_LAST_DATE[$i]}"
        local last_d=""
        if [[ "$date_epoch" =~ ^[0-9]+$ ]] && [[ $date_epoch -gt 0 ]]; then
            local unix_ts; unix_ts=$(mac_to_unix_epoch $(( date_epoch / 1000000000 )))
            last_d=$(epoch_to_date "$unix_ts")
        fi
        # If Contacts did not resolve this row, show "(no contact)" and lean
        # on the handle + preview as the memory prompt.
        local name_col="$name"
        if [[ "${ROSTER_HAS_CONTACT[$i]:-0}" != "1" ]]; then
            name_col="${DIM}(no contact)${RESET}"
        fi
        # Truncate handle list + preview to fit
        local hid_show="${hid:0:30}"
        local preview="${prev:0:30}"
        printf "  ${BCYN}%-4s${RESET}  %-28b  ${DIM}%-30s${RESET}  %7s  %-30s ${DIM}%s${RESET}\n" \
            "$idx" "$name_col" "$hid_show" "$n" "$preview" "$last_d"
    done
    HR
    echo -e "  ${DIM}Showing $(( start + 1 ))–${end} of $total handles${RESET}"
}

PREV_EXPORT_DIRS=()
PREV_EXPORT_NAMES=()
PREV_EXPORT_HANDLES=()
PREV_EXPORT_ROWIDS=()
PREV_EXPORT_STATUS=()
PREV_EXPORT_FINISHED=()
PREV_EXPORT_FORMAT=()

status_value() {
    # status_value <file> <key>  →  value from key=value .export_status files.
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null
}

scan_previous_exports() {
    PREV_EXPORT_DIRS=()
    PREV_EXPORT_NAMES=()
    PREV_EXPORT_HANDLES=()
    PREV_EXPORT_ROWIDS=()
    PREV_EXPORT_STATUS=()
    PREV_EXPORT_FINISHED=()
    PREV_EXPORT_FORMAT=()

    [[ -z "$PER_CONTACT_ROOT" || ! -d "$PER_CONTACT_ROOT" ]] && return 0

    local status_file dir name handles ids status finished format meta
    while IFS= read -r status_file; do
        [[ -z "$status_file" ]] && continue
        dir=$(dirname "$status_file")
        name=$(status_value "$status_file" "contact")
        handles=$(status_value "$status_file" "handles")
        ids=$(status_value "$status_file" "handle_rowids")
        status=$(status_value "$status_file" "status")
        finished=$(status_value "$status_file" "finished_at")
        format=$(status_value "$status_file" "export_format")

        # Fallback for folders that only have metadata.json from an interrupted
        # run or a future-compatible export.
        meta="$dir/metadata.json"
        if [[ -z "$ids" && -f "$meta" ]]; then
            ids=$(python3 - "$meta" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("handle_rowids", ""))
except Exception:
    pass
PY
)
        fi
        if [[ -z "$name" && -f "$meta" ]]; then
            name=$(python3 - "$meta" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("contact_name", ""))
except Exception:
    pass
PY
)
        fi
        if [[ -z "$handles" && -f "$meta" ]]; then
            handles=$(python3 - "$meta" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("handles", data.get("handle", "")))
except Exception:
    pass
PY
)
        fi

        [[ -z "$ids" ]] && continue
        safe_sql_id_list "$ids" || continue
        [[ -z "$name" ]] && name=$(basename "$dir")
        [[ -z "$status" ]] && status="unknown"
        [[ -z "$finished" ]] && finished="not recorded"
        [[ -z "$format" ]] && format="single_contact_v1"

        PREV_EXPORT_DIRS+=("$dir")
        PREV_EXPORT_NAMES+=("$name")
        PREV_EXPORT_HANDLES+=("$handles")
        PREV_EXPORT_ROWIDS+=("$ids")
        PREV_EXPORT_STATUS+=("$status")
        PREV_EXPORT_FINISHED+=("$finished")
        PREV_EXPORT_FORMAT+=("$format")
    done < <(find "$PER_CONTACT_ROOT" -mindepth 2 -maxdepth 2 -type f -name ".export_status" 2>/dev/null | sort)
}

find_roster_picks_by_ids() {
    # Returns current 1-based roster picks that overlap a prior id list.
    local old_ids="$1"
    local total=${#ROSTER_HANDLE_IDS[@]}
    local i id
    IFS=',' read -r -a old_parts <<< "$old_ids"
    for (( i=0; i<total; i++ )); do
        local current=",${ROSTER_HANDLE_IDS[$i]},"
        for id in "${old_parts[@]}"; do
            [[ -z "$id" ]] && continue
            if [[ "$current" == *",$id,"* ]]; then
                echo $(( i + 1 ))
                break
            fi
        done
    done
}

append_unique_pick() {
    # append_unique_pick <pick> <existing picks...>
    local new_pick="$1"; shift
    local p
    for p in "$@"; do
        [[ "$p" == "$new_pick" ]] && return 1
    done
    return 0
}

refresh_previous_exports_prompt() {
    scan_previous_exports
    local total_prev=${#PREV_EXPORT_ROWIDS[@]}
    [[ $total_prev -eq 0 ]] && return 0

    while true; do
        banner
        section "Want to refresh these previous exports?"
        echo
        echo -e "  Found ${BOLD}$total_prev${RESET} prior per-contact export(s) in:"
        echo -e "  ${BOLD}$PER_CONTACT_ROOT${RESET}"
        echo
        HR
        printf "  ${BOLD}%-4s  %-28s  %-31s  %-9s  %-19s${RESET}\n" \
            "#" "Contact" "Handle(s)" "Format" "Last refreshed"
        HR

        local i
        for (( i=0; i<total_prev; i++ )); do
            printf "  ${BOLD}%-4s${RESET}  %-28s  %-31s  %-9s  %-19s\n" \
                "$(( i + 1 ))" \
                "${PREV_EXPORT_NAMES[$i]:0:28}" \
                "${PREV_EXPORT_HANDLES[$i]:0:31}" \
                "${PREV_EXPORT_FORMAT[$i]:0:9}" \
                "${PREV_EXPORT_FINISHED[$i]:0:19}"
        done
        HR
        echo
        echo -e "  ${BOLD}[Enter]${RESET}/${BOLD}a${RESET} refresh all listed contacts"
        echo -e "  ${BOLD}1,3,5${RESET}     refresh selected contacts"
        echo -e "  ${BOLD}s${RESET}         skip and browse normally"
        echo
        printf "  Selection: "
        local choice
        read -r choice </dev/tty
        choice="${choice:-a}"

        case "$choice" in
            s|S|0|q|Q)
                return 0
                ;;
            a|A|all|ALL)
                local -a picks=()
                for (( i=0; i<total_prev; i++ )); do
                    if [[ "${PREV_EXPORT_FORMAT[$i]}" == "grouped_contact_v1" ]]; then
                        export_contact_id_list \
                            "${PREV_EXPORT_ROWIDS[$i]}" \
                            "${PREV_EXPORT_HANDLES[$i]}" \
                            "${PREV_EXPORT_NAMES[$i]}" \
                            "${PREV_EXPORT_DIRS[$i]}"
                    else
                        local pick matched_any=false
                        while IFS= read -r pick; do
                            [[ -z "$pick" ]] && continue
                            matched_any=true
                            if append_unique_pick "$pick" "${picks[@]}"; then
                                picks+=("$pick")
                            fi
                        done < <(find_roster_picks_by_ids "${PREV_EXPORT_ROWIDS[$i]}")
                        if ! $matched_any; then
                            warn "No current Messages handle matched: ${PREV_EXPORT_NAMES[$i]}"
                        fi
                    fi
                done
                if (( ${#picks[@]} > 0 )); then
                    export_selected_contacts "${picks[@]}"
                fi
                press_any_key
                return 0
                ;;
            *)
                local -a picks=()
                local -a raw_picks=()
                local p prev_idx pick refreshed_group=false
                IFS=',' read -r -a raw_picks <<< "$choice"
                for p in "${raw_picks[@]}"; do
                    p=$(echo "$p" | tr -d ' ')
                    [[ -z "$p" ]] && continue
                    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= total_prev )); then
                        prev_idx=$(( p - 1 ))
                        if [[ "${PREV_EXPORT_FORMAT[$prev_idx]}" == "grouped_contact_v1" ]]; then
                            export_contact_id_list \
                                "${PREV_EXPORT_ROWIDS[$prev_idx]}" \
                                "${PREV_EXPORT_HANDLES[$prev_idx]}" \
                                "${PREV_EXPORT_NAMES[$prev_idx]}" \
                                "${PREV_EXPORT_DIRS[$prev_idx]}"
                            refreshed_group=true
                        else
                            local matched_any=false
                            while IFS= read -r pick; do
                                [[ -z "$pick" ]] && continue
                                matched_any=true
                                if append_unique_pick "$pick" "${picks[@]}"; then
                                    picks+=("$pick")
                                fi
                            done < <(find_roster_picks_by_ids "${PREV_EXPORT_ROWIDS[$prev_idx]}")
                            if ! $matched_any; then
                                warn "No current Messages handle matched: ${PREV_EXPORT_NAMES[$prev_idx]}"
                            fi
                        fi
                    else
                        warn "Skipping invalid pick: $p"
                    fi
                done
                if (( ${#picks[@]} == 0 )); then
                    if ! $refreshed_group; then
                        warn "No valid refresh selections."
                        sleep 1
                        continue
                    fi
                else
                    export_selected_contacts "${picks[@]}"
                fi
                press_any_key
                return 0
                ;;
        esac
    done
}

# Prompt for a selection: number(s) like "3", "1,4,9", "all", or "n"/"p" for paging, "/" to search.
do_per_contact_export() {
    # Defensive: never let pipefail bring down the whole script from here.
    set +e
    section "Browse contacts & export per-person archive"

    # v2.2.0: ask where to put the exports (remembered across runs)
    load_config
    if ! pick_backup_dir; then
        info "Cancelled."
        return 0
    fi
    PER_CONTACT_ROOT="$BACKUP_ROOT"
    info "Per-contact exports will be written to: ${BCYN}$PER_CONTACT_ROOT${RESET}"
    echo

    if ! build_roster; then
        warn "Could not build roster — see $LOG_FILE for details."
        press_any_key
        return 0
    fi

    if [[ ${#ROSTER_HANDLE_ROWID[@]} -eq 0 ]]; then
        warn "Roster is empty (no handles with messages found)."
        press_any_key
        return 0
    fi

    local total=${#ROSTER_HANDLE_ROWID[@]}
    info "Loaded ${BOLD}$total${RESET} unique contact(s) — merged across linked handles, sorted by message count."
    echo

    refresh_previous_exports_prompt

    local page=0
    local page_size=100
    local filter=""

    while true; do
        banner
        section "Contacts (highest message counts first)"
        if [[ -n "$filter" ]]; then
            echo -e "  ${DIM}Filter: ${BCYN}$filter${RESET}${DIM} (clear with /)${RESET}"
        fi
        if [[ -n "$filter" ]]; then
            # Re-render only matches
            local i count_shown=0
            HR
            printf "  ${BOLD}%-4s  %-28s  %-30s  %7s  %-30s${RESET}\n" \
                "#" "Contact" "Handle(s)" "Msgs ↓" "Last message (preview)"
            HR
            for (( i=0; i<total; i++ )); do
                # Filter against name + handle first; only fetch preview if
                # that didn't match, so we don't pull the whole table.
                local hay_basic="${ROSTER_DISPLAY_NAME[$i]} ${ROSTER_HANDLE_RAW[$i]}"
                local matched=false
                if echo "$hay_basic" | grep -qi "$filter"; then
                    matched=true
                else
                    # Lazy-load preview once and check it too.
                    local prev_chk="${ROSTER_LAST_TEXT[$i]}"
                    if [[ -z "$prev_chk" ]]; then
                        prev_chk=$(fetch_last_text "${ROSTER_HANDLE_IDS[$i]}")
                        ROSTER_LAST_TEXT[$i]="$prev_chk"
                    fi
                    if echo "$prev_chk" | grep -qi "$filter"; then
                        matched=true
                    fi
                fi
                if $matched; then
                    local idx=$(( i + 1 ))
                    local name_col="${ROSTER_DISPLAY_NAME[$i]}"
                    [[ "${ROSTER_HAS_CONTACT[$i]:-0}" != "1" ]] && name_col="${DIM}(no contact)${RESET}"
                    local prev_show="${ROSTER_LAST_TEXT[$i]}"
                    if [[ -z "$prev_show" ]]; then
                        prev_show=$(fetch_last_text "${ROSTER_HANDLE_IDS[$i]}")
                        ROSTER_LAST_TEXT[$i]="$prev_show"
                    fi
                    printf "  ${BCYN}%-4s${RESET}  %-28b  ${DIM}%-30s${RESET}  %7s  %-30s\n" \
                        "$idx" "$name_col" "${ROSTER_HANDLE_RAW[$i]:0:30}" \
                        "${ROSTER_MSG_COUNT[$i]}" "${prev_show:0:30}"
                    count_shown=$(( count_shown + 1 ))
                fi
            done
            HR
            echo -e "  ${DIM}$count_shown matches for \"$filter\"${RESET}"
        else
            render_roster_page "$page" "$page_size"
        fi

        echo
        echo -e "  Enter a number to export (e.g. ${BCYN}3${RESET}),"
        echo -e "  multiple numbers (${BCYN}1,4,9${RESET}),"
        echo -e "  ${BCYN}all${RESET} to export every contact,"
        echo -e "  ${BCYN}/text${RESET} to search by name/handle/last-message,"
        echo -e "  ${BCYN}n${RESET}/${BCYN}p${RESET} for next/prev page,"
        echo -e "  ${BCYN}0${RESET} to go back."
        echo
        printf "  Selection: "
        read -r sel </dev/tty
        [[ -z "$sel" ]] && continue

        case "$sel" in
            0|q|Q) return ;;
            n|N)
                if [[ -z "$filter" ]]; then
                    local max_page=$(( (total - 1) / page_size ))
                    if (( page < max_page )); then
                        page=$(( page + 1 ))
                    else
                        warn "Last page"
                    fi
                fi
                ;;
            p|P)
                (( page > 0 )) && (( page-- )) || warn "First page"
                ;;
            /*)
                filter="${sel#/}"
                page=0
                ;;
            /) filter="" ;;
            all|ALL)
                if ask_yn "Export ALL $total contacts? This may be slow." "n"; then
                    export_selected_contacts $(seq 1 $total)
                    press_any_key
                fi
                ;;
            *)
                # Comma-separated numbers
                local -a picks=()
                IFS=',' read -r -a raw_picks <<< "$sel"
                local p
                for p in "${raw_picks[@]}"; do
                    p=$(echo "$p" | tr -d ' ')
                    [[ -z "$p" ]] && continue
                    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= total )); then
                        picks+=("$p")
                    else
                        warn "Skipping invalid pick: $p"
                    fi
                done
                if (( ${#picks[@]} == 0 )); then
                    warn "No valid selections."
                    sleep 1
                    continue
                fi
                export_selected_contacts "${picks[@]}"
                press_any_key
                ;;
        esac
    done
}

# Export each picked contact: writes per-contact DB, transcript, and copies attachments.
export_contact_id_list() {
    # export_contact_id_list <id_list> <handles> <display_name> <outdir>
    # Used by grouped_contact_v1 refresh rows. It injects a temporary roster
    # row so the normal restartable exporter writes to the pinned group folder.
    local id_list="$1"
    local handles="$2"
    local display_name="$3"
    local outdir="$4"

    if ! safe_sql_id_list "$id_list"; then
        err "Refusing invalid grouped handle id list: $id_list"
        log_error "grouped export: invalid id list ids=$id_list"
        return 1
    fi
    [[ -z "$display_name" ]] && display_name=$(basename "$outdir")
    [[ -z "$handles" ]] && handles="$id_list"

    local nmsgs
    nmsgs=$(sqlite3 "$DB_TMP" "
SELECT COUNT(*) FROM message
WHERE handle_id IN ($id_list) OR ROWID IN
    (SELECT message_id FROM chat_message_join WHERE chat_id IN
        (SELECT chat_id FROM chat_handle_join WHERE handle_id IN ($id_list)));
" 2>/dev/null)
    [[ "$nmsgs" =~ ^[0-9]+$ ]] || nmsgs=0

    local synthetic=$(( ${#ROSTER_HANDLE_ROWID[@]} + 1 ))
    local primary="${id_list%%,*}"
    ROSTER_HANDLE_ROWID+=("$primary")
    ROSTER_HANDLE_IDS+=("$id_list")
    ROSTER_HANDLE_RAW+=("$handles")
    ROSTER_DISPLAY_NAME+=("$display_name")
    ROSTER_LAST_TEXT+=("")
    ROSTER_LAST_DATE+=("0")
    ROSTER_MSG_COUNT+=("$nmsgs")
    ROSTER_SERVICE+=("grouped")
    ROSTER_HAS_CONTACT+=("1")
    ROSTER_EXPORT_DIR_OVERRIDE[$(( synthetic - 1 ))]="$outdir"
    ROSTER_EXPORT_FORMAT[$(( synthetic - 1 ))]="grouped_contact_v1"

    export_selected_contacts "$synthetic"
}

export_selected_contacts() {
    if [[ -z "$PER_CONTACT_ROOT" ]]; then
        err "Internal error: backup root not set. Re-enter menu [8] and pick a folder."
        return 1
    fi
    local picks=("$@")
    section "Exporting ${#picks[@]} contact(s) → $PER_CONTACT_ROOT"
    if ! mkdir -p "$PER_CONTACT_ROOT"; then
        err "Cannot create backup root: $PER_CONTACT_ROOT"
        log_error "per-contact: cannot create backup root $PER_CONTACT_ROOT"
        return 1
    fi
    # If running under sudo, make sure the user owns their own backup tree.
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER" "$PER_CONTACT_ROOT" 2>/dev/null || true
    fi

    local pick i failures=0
    for pick in "${picks[@]}"; do
        i=$(( pick - 1 ))
        local rowid="${ROSTER_HANDLE_ROWID[$i]}"          # primary rowid (first seen)
        local id_list="${ROSTER_HANDLE_IDS[$i]:-$rowid}"  # all merged rowids (v2.3.0)
        local hid="${ROSTER_HANDLE_RAW[$i]}"
        local name="${ROSTER_DISPLAY_NAME[$i]}"
        local nmsgs="${ROSTER_MSG_COUNT[$i]}"

        if ! safe_sql_id_list "$id_list"; then
            err "Refusing invalid handle id list for contact #$pick: $id_list"
            log_error "per-contact: invalid id list pick=$pick ids=$id_list"
            failures=$(( failures + 1 ))
            continue
        fi

        # Slug: prefer name, fallback to handle
        local slug
        if [[ "${ROSTER_HAS_CONTACT[$i]:-0}" != "1" ]]; then
            slug=$(slugify "$hid")
        else
            slug=$(slugify "$name")
        fi
        [[ -z "$slug" ]] && slug="handle_${rowid}"

        local export_format="${ROSTER_EXPORT_FORMAT[$i]:-single_contact_v1}"
        local outdir_override="${ROSTER_EXPORT_DIR_OVERRIDE[$i]:-}"
        local outdir="$PER_CONTACT_ROOT/$slug"
        if [[ -n "$outdir_override" ]]; then
            outdir="$outdir_override"
            slug=$(basename "$outdir")
        fi
        local out_db="$outdir/chat_${slug}.db"
        local out_txt="$outdir/messages_${slug}.txt"
        local out_att="$outdir/attachments"
        local out_meta="$outdir/metadata.json"
        local status_file="$outdir/.export_status"
        local complete_file="$outdir/.complete"
        local err_file="$outdir/export_errors.log"
        local att_manifest="$outdir/attachments_manifest.tsv"

        info "[$pick] ${BOLD}$name${RESET}  ($hid)  — $nmsgs messages → $outdir"

        if $DRY_RUN; then
            log_info "[DRY-RUN] Would export contact #$pick to $outdir"
            continue
        fi

        if ! mkdir -p "$outdir" "$out_att"; then
            err "Cannot create export folder: $outdir"
            log_error "per-contact: mkdir failed $outdir"
            failures=$(( failures + 1 ))
            continue
        fi
        : > "$err_file"
        cat > "$status_file" <<EOF
status=running
started_at=$(_ts)
script_version=$SCRIPT_VERSION
export_format=$export_format
contact=$(printf '%s' "$name")
handles=$(printf '%s' "$hid")
handle_rowids=$id_list
EOF
        rm -f "$complete_file"
        touch "$att_manifest"

        # Hand ownership back to the user if we were sudo'd
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown -R "$SUDO_USER" "$outdir" 2>/dev/null || true
        fi

        # 1) Per-contact SQLite db: build by attaching the temp chat.db and copying
        # only this handle's messages + the related chat & attachment rows.
        local out_db_tmp="$out_db.tmp.$$"
        local sql_err="$outdir/sqlite_export.err"
        info "Building SQLite export atomically …"
        rm -f "$out_db_tmp" "$sql_err"
        sqlite3 "$out_db_tmp" <<SQL 2>"$sql_err"
ATTACH DATABASE '$DB_TMP' AS src;

CREATE TABLE handle      AS SELECT * FROM src.handle      WHERE ROWID IN ($id_list);
CREATE TABLE message     AS SELECT * FROM src.message     WHERE handle_id IN ($id_list) OR ROWID IN
    (SELECT message_id FROM src.chat_message_join WHERE chat_id IN
        (SELECT chat_id FROM src.chat_handle_join WHERE handle_id IN ($id_list)));
CREATE TABLE chat        AS SELECT * FROM src.chat        WHERE ROWID IN
    (SELECT chat_id FROM src.chat_handle_join WHERE handle_id IN ($id_list));
CREATE TABLE chat_handle_join  AS SELECT * FROM src.chat_handle_join  WHERE handle_id IN ($id_list);
CREATE TABLE chat_message_join AS SELECT * FROM src.chat_message_join WHERE message_id IN
    (SELECT ROWID FROM message);
CREATE TABLE message_attachment_join AS SELECT * FROM src.message_attachment_join WHERE message_id IN
    (SELECT ROWID FROM message);
CREATE TABLE attachment AS SELECT * FROM src.attachment WHERE ROWID IN
    (SELECT attachment_id FROM message_attachment_join);

DETACH DATABASE src;
SQL
        local sqlite_rc=$?
        local integrity db_msg_count
        integrity=$(sqlite3 "$out_db_tmp" "PRAGMA integrity_check;" 2>>"$sql_err" || echo "failed")
        db_msg_count=$(sqlite3 "$out_db_tmp" "SELECT COUNT(*) FROM message;" 2>>"$sql_err" || echo "0")
        if [[ $sqlite_rc -ne 0 || ! -s "$out_db_tmp" || "$integrity" != "ok" || ! "$db_msg_count" =~ ^[0-9]+$ || "$db_msg_count" -eq 0 ]]; then
            err "SQLite export failed for $name. Details: $sql_err"
            {
                echo "SQLite export failed at $(_ts)"
                echo "sqlite_rc=$sqlite_rc integrity=$integrity db_msg_count=$db_msg_count"
                [[ -s "$sql_err" ]] && cat "$sql_err"
            } >> "$err_file"
            log_error "per-contact: sqlite export failed contact=$name rc=$sqlite_rc integrity=$integrity db_msg_count=$db_msg_count"
            rm -f "$out_db_tmp"
            failures=$(( failures + 1 ))
            (( TOTAL_ERRORS++ )) || true
            continue
        fi
        mv -f "$out_db_tmp" "$out_db"
        rm -f "$sql_err"
        ok "Wrote $(human_bytes $(stat -f%z "$out_db" 2>/dev/null || stat -c%s "$out_db"))  →  $out_db"

        # 2) Readable text transcript
        local out_txt_tmp="$out_txt.tmp.$$"
        info "Writing transcript atomically …"
        {
            echo "# iMessage transcript export"
            echo "# Contact     : $name"
            echo "# Handle(s)   : $hid"
            echo "# Service     : ${ROSTER_SERVICE[$i]}"
            echo "# Message count: $nmsgs"
            echo "# Exported    : $(_ts)"
            echo "# Source      : $MESSAGES_DB"
            echo "# ---"
            sqlite3 -separator $'\t' "$out_db" "
SELECT
    datetime((date/1000000000) + strftime('%s','2001-01-01'), 'unixepoch', 'localtime'),
    CASE WHEN is_from_me=1 THEN 'me' ELSE 'them' END,
    COALESCE(text,'')
FROM message
ORDER BY date ASC;" 2>/dev/null | awk -F'\t' '{ printf "[%s] %-4s | %s\n", $1, $2, $3 }'
        } > "$out_txt_tmp"
        local txt_rc=$?
        if [[ $txt_rc -ne 0 || ! -s "$out_txt_tmp" ]]; then
            err "Transcript export failed for $name"
            echo "Transcript export failed at $(_ts) rc=$txt_rc" >> "$err_file"
            rm -f "$out_txt_tmp"
            failures=$(( failures + 1 ))
            (( TOTAL_ERRORS++ )) || true
            continue
        fi
        mv -f "$out_txt_tmp" "$out_txt"
        ok "Wrote $out_txt"

        # 3) Copy attachments for this contact
        local att_rows
        att_rows=$(sqlite3 -separator $'\t' "$out_db" "
SELECT a.ROWID, COALESCE(a.filename,''), COALESCE(a.transfer_name,''),
       COALESCE(a.created_date,0)
FROM attachment a
WHERE a.filename IS NOT NULL AND a.filename != '';" 2>/dev/null)

        local copied=0 already=0 skipped=0 copy_errors=0
        if [[ -n "$att_rows" ]]; then
            local aid afn atrn ad
            while IFS=$'\t' read -r aid afn atrn ad; do
                [[ -z "$afn" ]] && continue
                local src; src=$(resolve_attachment_path "$afn")
                local existing_dst
                existing_dst=$(awk -v id="$aid" 'BEGIN{FS="\t"} $1 == id {print $2; exit}' "$att_manifest" 2>/dev/null)
                if [[ -n "$existing_dst" && -f "$existing_dst" ]]; then
                    already=$(( already + 1 ))
                    continue
                fi

                if [[ -f "$src" ]]; then
                    local prefix=""
                    if [[ "$ad" =~ ^[0-9]+$ ]] && [[ $ad -gt 0 ]]; then
                        local u; u=$(mac_to_unix_epoch $(( ad / 1000000000 )))
                        prefix=$(epoch_to_date "$u")_
                    fi
                    local base; base=$(basename "$src")
                    local desired="$out_att/${prefix}${base}"
                    local dst="$existing_dst"
                    if [[ -z "$dst" ]]; then
                        if [[ -f "$desired" ]]; then
                            local src_sz dst_sz
                            src_sz=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo 0)
                            dst_sz=$(stat -f%z "$desired" 2>/dev/null || stat -c%s "$desired" 2>/dev/null || echo -1)
                            if [[ "$src_sz" == "$dst_sz" ]]; then
                                printf '%s\t%s\t%s\n' "$aid" "$desired" "$src" >> "$att_manifest"
                                already=$(( already + 1 ))
                                continue
                            fi
                        fi
                        dst=$(unique_dest_path "$desired")
                    fi
                    mkdir -p "$(dirname "$dst")"
                    if cp -p "$src" "$dst" 2>/dev/null; then
                        if ! awk -v id="$aid" 'BEGIN{FS="\t"; found=0} $1 == id {found=1} END{exit found ? 0 : 1}' "$att_manifest" 2>/dev/null; then
                            printf '%s\t%s\t%s\n' "$aid" "$dst" "$src" >> "$att_manifest"
                        fi
                        copied=$(( copied + 1 ))
                    else
                        copy_errors=$(( copy_errors + 1 ))
                        echo "COPY FAILED: attachment_id=$aid src=$src dst=$dst" >> "$err_file"
                        log_error "per-contact: attachment copy failed id=$aid src=$src dst=$dst"
                    fi
                else
                    skipped=$(( skipped + 1 ))
                fi
            done <<< "$att_rows"
        fi
        bullet "Attachments: ${BGRN}$copied${RESET} copied, ${BCYN}$already${RESET} already present, ${BYLW}$skipped${RESET} missing/iCloud-only, ${BRED}$copy_errors${RESET} copy error(s)"
        if [[ $copy_errors -gt 0 ]]; then
            failures=$(( failures + 1 ))
            (( TOTAL_ERRORS += copy_errors )) || true
        fi

        # 4) metadata.json
        local first_date last_date
        first_date=$(sqlite3 "$out_db" "SELECT datetime((MIN(date)/1000000000) + strftime('%s','2001-01-01'), 'unixepoch', 'localtime') FROM message;" 2>/dev/null)
        last_date=$(sqlite3  "$out_db" "SELECT datetime((MAX(date)/1000000000) + strftime('%s','2001-01-01'), 'unixepoch', 'localtime') FROM message;" 2>/dev/null)
        cat > "$out_meta" <<JSON
{
  "contact_name": $(json_string "$name"),
  "handles": $(json_string "$hid"),
  "handle_rowids": $(json_string "$id_list"),
  "service": $(json_string "${ROSTER_SERVICE[$i]}"),
  "message_count": $nmsgs,
  "attachments_copied": $copied,
  "attachments_already_present": $already,
  "attachments_missing": $skipped,
  "attachment_copy_errors": $copy_errors,
  "first_message": $(json_string "$first_date"),
  "last_message": $(json_string "$last_date"),
  "exported_at": $(json_string "$(_ts)"),
  "source_db": $(json_string "$MESSAGES_DB"),
  "script_version": $(json_string "$SCRIPT_VERSION"),
  "export_format": $(json_string "$export_format"),
  "status": $(json_string "$([[ $copy_errors -eq 0 ]] && echo complete || echo partial)")
}
JSON
        ok "Wrote $out_meta"
        cat > "$status_file" <<EOF
status=$([[ $copy_errors -eq 0 ]] && echo complete || echo partial)
finished_at=$(_ts)
script_version=$SCRIPT_VERSION
export_format=$export_format
contact=$(printf '%s' "$name")
handles=$(printf '%s' "$hid")
handle_rowids=$id_list
messages=$db_msg_count
attachments_copied=$copied
attachments_already_present=$already
attachments_missing=$skipped
attachment_copy_errors=$copy_errors
EOF
        if [[ $copy_errors -eq 0 ]]; then
            : > "$complete_file"
        fi
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown -R "$SUDO_USER" "$outdir" 2>/dev/null || true
        fi
        echo
    done

    if [[ $failures -eq 0 ]]; then
        ok "Per-contact export complete. Open: $PER_CONTACT_ROOT"
    else
        warn "Per-contact export finished with $failures issue(s). Re-run the same selection to resume/repair partial folders."
        warn "Details are in each contact folder's export_errors.log."
    fi
    return 0
}

# ── Cleanup temp files ────────────────────────────────────────────────────────
cleanup_temp() {
    rm -f "$DB_TMP" "$ADDRESSBOOK_TMP" "$CONTACT_CACHE_FILE" "/tmp/imessage_seen_$$.txt" 2>/dev/null || true
}

trap cleanup_temp EXIT INT TERM

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        banner
        echo -e "  ${DIM}User home : $REAL_HOME${RESET}"
        echo -e "  ${DIM}Output    : $OUTPUT_ROOT${RESET}"
        echo -e "  ${DIM}Log       : $LOG_FILE${RESET}"
        $DRY_RUN && echo -e "  ${BYLW}★ DRY-RUN MODE ACTIVE – nothing will be written${RESET}"
        $DELETE_AFTER_COPY && echo -e "  ${BRED}★ DELETE AFTER COPY IS ENABLED${RESET}"
        $DEBUG_LOG && echo -e "  ${BCYN}★ DEBUG LOGGING ON – verbose trace active${RESET}"
        echo

        # Live storage snapshot in header
        local _att_sz=0
        [[ -d "$ATTACHMENTS_DIR" ]] && _att_sz=$(du -sk "$ATTACHMENTS_DIR" 2>/dev/null | awk '{print $1*1024}' || echo 0)
        local _out_sz=0
        [[ -d "$OUTPUT_ROOT" ]] && _out_sz=$(du -sk "$OUTPUT_ROOT" 2>/dev/null | awk '{print $1*1024}' || echo 0)
        local _manifest_n=0
        [[ -f "$MANIFEST_FILE" ]] && _manifest_n=$(wc -l < "$MANIFEST_FILE" | tr -d ' ')
        echo -e "  ${DIM}iMessage Attachments folder : $(human_bytes $_att_sz)${RESET}"
        echo -e "  ${DIM}Desktop export folder       : $(human_bytes $_out_sz)  ($_manifest_n files exported)${RESET}"
        echo

        echo -e "  ${BBLU}[1]${RESET}  Run extraction       ${DIM}(copy attachments → Desktop folder)${RESET}"
        echo -e "  ${BBLU}[2]${RESET}  Show statistics      ${DIM}(message counts, top senders, storage)${RESET}"
        echo -e "  ${BBLU}[3]${RESET}  Options              ${DIM}(filters, dry-run, delete mode, output path)${RESET}"
        echo -e "  ${BBLU}[4]${RESET}  Open output folder in Finder"
        echo -e "  ${BBLU}[5]${RESET}  View log file"
        echo -e "  ${BBLU}[6]${RESET}  ${BMAG}iCloud Cleanup & Verify${RESET}  ${DIM}(delete local + clear iCloud quota)${RESET}"
        echo -e "  ${BBLU}[7]${RESET}  ${BOLD}Check iCloud Status${RESET}        ${DIM}(verify, wait timer, open UI, retry)${RESET}"
        echo -e "  ${BBLU}[8]${RESET}  ${BOLD}Browse contacts & export per-person archive${RESET}  ${DIM}(v2.5 — refresh previous exports)${RESET}"
        echo -e "  ${BBLU}[q]${RESET}  Quit"
        echo
        printf "  Select option: "
        read -r choice </dev/tty

        case "$choice" in
            1)
                banner
                mkdir -p "$OUTPUT_ROOT"
                log_info "======== Session start ========"
                log_info "User=$REAL_USER  dry_run=$DRY_RUN  delete=$DELETE_AFTER_COPY"
                do_extraction
                show_summary_so_far
                press_any_key
                ;;
            2)
                show_stats_screen
                ;;
            3)
                show_options_menu
                ;;
            4)
                open "$OUTPUT_ROOT" 2>/dev/null || info "Could not open Finder (are you on a headless session?)"
                ;;
            5)
                if [[ -f "$LOG_FILE" ]]; then
                    less +G "$LOG_FILE" </dev/tty || tail -100 "$LOG_FILE"
                else
                    warn "No log file yet."
                    press_any_key
                fi
                ;;
            6)
                do_icloud_cleanup
                ;;
            7)
                do_icloud_verify
                ;;
            8)
                # v2.2.2: locally disable -e for this call so any non-zero
                # pipe inside the per-contact flow can't kill the whole script.
                # The function still reports its own errors via warn/err.
                set +e
                do_per_contact_export
                local _rc=$?
                set -e
                if [[ $_rc -ne 0 ]]; then
                    warn "Per-contact export returned exit code $_rc — returning to menu."
                    press_any_key
                fi
                ;;
            q|Q)
                echo
                info "Goodbye. Log saved to: $LOG_FILE"
                echo
                exit 0
                ;;
            *)
                warn "Invalid option – press 1-8 or q"
                sleep 1
                ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --debug|-d) DEBUG_LOG=true ;;
        esac
    done

    # Ensure output dir exists for logging early
    mkdir -p "$OUTPUT_ROOT" 2>/dev/null || true

    banner
    section "Startup checks"

    check_root
    check_dependencies
    check_full_disk_access
    check_messages_closed
    copy_databases

    ok "All checks passed"
    press_any_key

    main_menu
}

main "$@"
