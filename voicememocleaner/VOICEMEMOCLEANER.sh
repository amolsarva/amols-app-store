#!/bin/bash
# =============================================================================
#  VOICEMEMOCLEANER — Voice Memos Exporter, Compressor & Metadata Cataloger
#  Version: 1.0.6
#  macOS 12+ (Monterey, Ventura, Sonoma, Sequoia)
#
#  Run as:  bash VOICEMEMOCLEANER.sh
#
#  What it does:
#    1. Reads Voice Memos' CloudRecordings.db (copied to /tmp for safety) to
#       find every recording, its title, date, and duration.
#    2. Exports a full-quality copy of every recording's original audio file
#       plus a compressed copy (MP3, configurable bitrate) into a folder you
#       choose (remembered across runs).
#    3. Reads embedded QuickTime/location metadata (via `mdls`) off each
#       source file to capture GPS coordinates + creation date when present,
#       and writes it into a per-file JSON sidecar plus one master CSV/JSONL
#       catalog so you can analyze everything (what/when/where) without
#       having to open every file.
#    4. NEVER touches or deletes anything in the Voice Memos library — this
#       is a pure read-only export. Nothing in Voice Memos.app is modified.
#    5. Logs everything to <output>/voicememocleaner.log
#
#  Safety:
#    - Read-only against the Voice Memos database and Recordings folder.
#    - Dry-run mode shows every action without writing/copying anything.
#    - Incremental: reruns skip files already exported (by source path +
#      size + mtime), so refreshing after recording more memos is fast.
#    - Every write (audio copy, compressed copy, JSON sidecar) goes to a
#      temp file first, then an atomic `mv` into place.
#
#  v1.0.1 MANIFEST BUGFIX:
#    - The incremental manifest used to record a recording as "done" the
#      moment ANY pass touched it — including a metadata-only pass (Settings
#      -> both copy types off). That meant running metadata-only first, then
#      a real export, silently skipped every recording: the real export
#      trusted the manifest and never actually copied/compressed anything,
#      even though it reported "N exported, 0 errors".
#      Fixed: manifest entries now record WHICH artifacts were written
#      (orig=0/1, comp=0/1), and a row is only skipped if everything the
#      CURRENT run is configured to produce was already produced before.
#    - Session counters (TOTAL_EXPORTED etc.) are global and used to persist
#      across menu selections in one running session — e.g. running a dry
#      run then a real export in the same session added their numbers
#      together in the summary. Now reset at the start of every do_export.
#
#  v1.0.2 CRASH FIX + AUTO VOICE/MUSIC PRESET:
#    - The v1.0.1 manifest fix introduced `prev_flags=$(manifest_lookup_flags
#      ...)` as a plain (unguarded) assignment. grep legitimately exits
#      non-zero when a key has no prior manifest entry — the normal case for
#      every recording's first-ever run — and under `set -e` that silently
#      killed the whole script one file in. Same latent issue existed in
#      mdls_get (mdls can exit non-zero on an unindexed file, and Group
#      Containers is sometimes excluded from Spotlight indexing entirely).
#      Both now always return success; a run can no longer die mid-batch
#      because one optional lookup came up empty.
#    - New "auto" preset (now the default): classifies each recording as
#      voice or music before compressing it — stereo-at-the-source or long
#      (>= a configurable minute threshold, default 10) counts as music and
#      gets a higher stereo bitrate; short mono recordings get the aggressive
#      voice-optimized bitrate. Useful if your library mixes quick voice
#      notes with full concert/live recordings, since compressing the latter
#      as if they were speech would sound bad. Threshold and manual presets
#      (voice/balanced/high, applied uniformly) are still available in
#      Settings. Classification is recorded per-file in metadata/*.json and
#      metadata/catalog.csv so you can sort/filter by it afterward.
#    - catalog.csv/catalog.jsonl are now rebuilt from metadata/*.json after
#      each run instead of appended to during it, so reruns can't leave
#      duplicate rows in the aggregate catalog.
#
#  v1.0.3 THE v1.0.2 FIX WAS STILL WRONG — REAL FIX THIS TIME:
#    - v1.0.2 tried to neutralize failing lookups (manifest_lookup_flags,
#      mdls_get) by putting a bare `return 0` on the line AFTER the risky
#      command. That does NOT work: under `set -e`, the shell can abort the
#      instant the risky command fails — execution never reaches the
#      following `return 0` line at all. It happened to test fine against a
#      modern bash (5.x) in the environment used to write this script, but
#      macOS ships bash 3.2 (frozen since ~2007 for licensing reasons), which
#      has long-documented, stricter/less consistent -e propagation into
#      functions and subshells — that's why it kept dying one file in on the
#      actual Mac despite testing clean elsewhere.
#      Real fix: `|| true` is now attached directly to the same line as
#      every risky command (grep/mdls/afinfo/sqlite3 lookups that can
#      legitimately return non-zero), which neutralizes the exit status
#      before `-e` ever evaluates it — this is basic, version-independent
#      shell semantics, not dependent on how any particular bash propagates
#      errexit into nested contexts. Also hardened get_source_channels,
#      query_recordings, and detect_schema's PRAGMA lookup the same way,
#      since they had the identical latent (if not yet triggered) issue.
#
#  Maintenance note (for future edits):
#    Any command that can legitimately fail during normal operation (a grep
#    with no match, an mdls/afinfo lookup on a file with no metadata, a
#    sqlite3 query) MUST have `|| true` attached directly on the same
#    statement, not on a following line — this script runs under `set -e`
#    and targets macOS's ancient bash 3.2, which does not reliably let later
#    lines "rescue" an earlier failing one.
#    Whenever this script changes, bump SCRIPT_VERSION below and add a line
#    under "vX.Y.Z NEW" in this header.
# =============================================================================

set -eo pipefail   # NOTE: -u intentionally omitted — macOS bash 3.2 has edge cases with it
IFS=$'\n\t'
DEBUG_LOG=false    # Set to true via --debug flag or option [d] in menu

# ── High-contrast text palette (matches other mac-scripts tools) ─────────────
RESET='\033[0m';   BOLD='\033[1m'
RED='\033[1;31m';  BRED='\033[1;31m'
GRN="$BOLD";       BGRN="$BOLD"
YLW="$BOLD";       BYLW="$BOLD"
BLU="$BOLD";       BBLU="$BOLD"
MAG='\033[1;35m';  BMAG='\033[1;35m'
CYN="$BOLD";       BCYN="$BOLD"
WHT="$BOLD";       DIM=''
ULINE='\033[4m'

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.2.1"
SCRIPT_NAME="VOICEMEMOCLEANER — Voice Memos Exporter & Compressor"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

VM_CONTAINER="$REAL_HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared"
VM_RECORDINGS_DIR="$VM_CONTAINER/Recordings"
VM_DB="$VM_RECORDINGS_DIR/CloudRecordings.db"

CONFIG_DIR="$REAL_HOME/.config/voicememocleaner"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_OUTPUT_ROOT="$REAL_HOME/Documents/root/voicememo-exports"
OUTPUT_ROOT=""   # populated by load_config / pick_output_dir

DB_TMP="/tmp/voicememocleaner_db_$$.db"
MANIFEST_FILE=""   # set once OUTPUT_ROOT is known: <output>/.manifest
LOG_FILE=""         # set once OUTPUT_ROOT is known: <output>/voicememocleaner.log

# ── Hard-skip list ────────────────────────────────────────────────────────────
# v1.1.9: some source files can make even a bare `stat`/existence check hang
# in an uninterruptible kernel I/O wait — seen repeatedly with one
# recording whose iCloud-synced data macOS's file-provider daemon
# apparently cannot resolve (likely repeat local-copy eviction under disk
# space pressure, then a stalled re-download). No userspace timeout can
# protect against that; SIGKILL doesn't affect a D-state process, and the
# hang can happen before any subprocess we could even wrap is spawned. The
# only real fix is to never touch that file's path with a filesystem call
# at all. Entries here are matched as a plain substring against each row's
# raw ZPATH — checked before any stat/cp/ffmpeg/mdls/afinfo call touches
# the file. One file is hard-coded below after it wedged multi-hour runs
# repeatedly; add more (one per line) in
# ~/.config/voicememocleaner/hard_skip_list if another file does the same.
HARD_SKIP_PATTERNS=(
    "140854-4CED1DE4"
)
HARD_SKIP_LIST_FILE="$CONFIG_DIR/hard_skip_list"

# Compression presets: name -> "bitrate_bps channels description"
PRESET_NAME="auto"     # auto | voice | balanced | high
# "auto" classifies each recording as voice or music and picks a matching
# preset per file (see classify_recording). A file counts as music if it's
# already stereo at the source, OR runs at least this many seconds — voice
# memos are almost always mono and short; concert/live recordings are
# typically long and often stereo. Tunable in Settings.
MUSIC_MIN_DURATION_SEC=600   # 10 minutes
DRY_RUN=false
SKIP_COMPRESSED=false
SKIP_ORIGINALS=true
OVERWRITE_EXISTING=false

TOTAL_EXPORTED=0
TOTAL_COMPRESSED=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
TOTAL_BYTES_ORIGINAL=0
TOTAL_BYTES_COMPRESSED=0
TOTAL_MUSIC=0
TOTAL_VOICE=0

# ── Logging ───────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(_ts)
    [[ -n "$LOG_FILE" ]] && echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()    { log "INFO " "$@"; }
log_warn()    { log "WARN " "$@"; }
log_error()   { log "ERROR" "$@"; }
log_action()  { log "ACTION" "$@"; }
log_skip()    { log "SKIP " "$@"; }
log_debug()   { $DEBUG_LOG && log "DEBUG" "$@" || true; }

# Pure-bash trim (xargs breaks on apostrophes / unbalanced quotes in titles).
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

csv_field() {
    # csv_field <value>  →  quoted, comma/quote-safe CSV field.
    local v="$1"
    v="${v//\"/\"\"}"
    printf '"%s"' "$v"
}

sanitize_filename() {
    local name="$1"
    name=$(echo "$name" | sed 's/[\/:\\*?"<>|]/_/g')
    name=$(_trim "$name")
    printf '%s' "$name"
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

section() { echo; echo -e "${BCYN}── $* ${RESET}"; }
ok()    { echo -e "  ${BGRN}✓${RESET}  $*"; }
warn()  { echo -e "  ${BYLW}⚠${RESET}  $*"; }
err()   { echo -e "  ${BRED}✗${RESET}  $*"; }
info()  { echo -e "  ${BBLU}ℹ${RESET}  $*"; }
bullet(){ echo -e "  ${DIM}•${RESET}  $*"; }

ask_yn() {
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
        printf "  ${BYLW}?${RESET}  %s [%s]: " "$prompt" "$default" >&2
    else
        printf "  ${BYLW}?${RESET}  %s: " "$prompt" >&2
    fi
    read -r result </dev/tty
    printf '%s' "${result:-$default}"
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

# ── Config (remembers output folder + compression preset across runs) ───────
load_config() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
    OUTPUT_ROOT="${SAVED_OUTPUT_ROOT:-$DEFAULT_OUTPUT_ROOT}"
    PRESET_NAME="${SAVED_PRESET_NAME:-auto}"
    MUSIC_MIN_DURATION_SEC="${SAVED_MUSIC_MIN_DURATION_SEC:-600}"
}

save_config() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    {
        echo "SAVED_OUTPUT_ROOT=$(printf '%q' "$OUTPUT_ROOT")"
        echo "SAVED_PRESET_NAME=$(printf '%q' "$PRESET_NAME")"
        echo "SAVED_MUSIC_MIN_DURATION_SEC=$(printf '%q' "$MUSIC_MIN_DURATION_SEC")"
    } > "$CONFIG_FILE" 2>/dev/null || warn "Could not save config to $CONFIG_FILE"
}

set_output_paths() {
    # Called any time OUTPUT_ROOT changes.
    mkdir -p "$OUTPUT_ROOT" 2>/dev/null || true
    MANIFEST_FILE="$OUTPUT_ROOT/.manifest"
    LOG_FILE="$OUTPUT_ROOT/voicememocleaner.log"
    touch "$LOG_FILE" 2>/dev/null || true
    touch "$MANIFEST_FILE" 2>/dev/null || true
}

pick_output_dir() {
    section "Choose output folder"
    info "This is where original + compressed audio and metadata will be written."
    [[ -n "$OUTPUT_ROOT" ]] && info "Current: ${BOLD}$OUTPUT_ROOT${RESET}"
    local chosen
    chosen=$(ask_input "Output folder" "$OUTPUT_ROOT")
    chosen="${chosen/#\~/$REAL_HOME}"
    if [[ -z "$chosen" ]]; then
        warn "No folder given — keeping current setting."
        return
    fi
    if ! mkdir -p "$chosen" 2>/dev/null; then
        err "Could not create or write to: $chosen"
        press_any_key
        return
    fi
    OUTPUT_ROOT="$chosen"
    set_output_paths
    save_config
    ok "Output folder set to: $OUTPUT_ROOT"
}

# ── Compression presets ───────────────────────────────────────────────────────
# Display-only descriptions (compress_audio resolves the real bitrate itself
# via its own case statement — see the note there on why). Channel count is
# never forced (afconvert errors on some source files if you try), so
# descriptions don't claim mono/stereo — output keeps whatever channel count
# the source file already has.
# "auto" isn't a real encoding preset — it picks between "voice" and "music"
# per file (see the per-row classification block in do_export), so it's
# handled separately wherever a single preset_params() call is needed.
preset_params() {
    case "$1" in
        voice)    echo "'Voice-optimized ~24kbps — smallest, speech stays clear'" ;;
        balanced) echo "'Balanced ~64kbps — good speech quality, small size'" ;;
        high)     echo "'High quality ~128kbps — near-original, larger files'" ;;
        music)    echo "'Music-optimized ~160kbps — for concert/live recordings'" ;;
        *)        echo "'Voice-optimized ~24kbps'" ;;
    esac
}

# ── Voice vs. music classification (used by the "auto" preset) ──────────────
_afinfo_channels_pipeline() {
    afinfo "$1" 2>/dev/null | grep -oE '[0-9]+ ch' | head -n1 | grep -oE '^[0-9]+'
}
get_source_channels() {
    # Prints the source file's channel count via afinfo, or nothing if it
    # can't be determined. Never fails the caller (see mdls_get for why this
    # matters under `set -e`).
    #
    # v1.1.4: this had no timeout, and it turned out to be the actual hang
    # point behind an export that sat wedged on one file for 9+ hours with
    # no error — the v1.1.2 timeout only wrapped the ffmpeg compression
    # step, but afinfo runs BEFORE that (for auto voice/music
    # classification) and was never protected. Best working theory: Voice
    # Memos syncs recordings via iCloud, and a large recording whose local
    # copy is an iCloud placeholder (not fully downloaded) makes afinfo
    # block waiting on the download rather than erroring — indefinitely, if
    # the download stalls. Wrapped in run_with_timeout like compress_audio
    # already was, so a single such file can no longer stall the whole run.
    run_with_timeout 15 _afinfo_channels_pipeline "$1" || true
}

classify_recording() {
    # classify_recording <duration_seconds> <channels> -> prints "music" or "voice"
    # A recording counts as music if it's already stereo at the source (voice
    # memos are almost always recorded mono; deliberately-recorded concerts
    # are often stereo), OR if it runs long (voice memos are rarely more than
    # a few minutes; concerts/live sets typically run much longer).
    local duration="${1:-0}" channels="${2:-}"
    # ZDURATION from the database is a real/decimal number of seconds (e.g.
    # "185.34") — strip any fractional part before comparing as an integer,
    # otherwise the regex below would never match and this branch would
    # silently never fire.
    local dur_int="${duration%%.*}"
    [[ "$dur_int" =~ ^[0-9]+$ ]] || dur_int=0
    if [[ -n "$channels" && "$channels" =~ ^[0-9]+$ && "$channels" -ge 2 ]]; then
        echo "music"; return
    fi
    if [[ "$dur_int" -ge "$MUSIC_MIN_DURATION_SEC" ]]; then
        echo "music"; return
    fi
    echo "voice"
}

choose_preset() {
    section "Compression preset"
    echo
    echo -e "  ${BOLD}[1]${RESET} Auto ${DIM}(recommended)${RESET}    ${DIM}detects voice memos vs. music/concert recordings per file and compresses each appropriately${RESET}"
    echo -e "  ${BOLD}[2]${RESET} Voice-optimized  ${DIM}(mono, ~24kbps — treats everything as speech, smallest files)${RESET}"
    echo -e "  ${BOLD}[3]${RESET} Balanced         ${DIM}(mono, ~64kbps — treats everything as speech, clearer)${RESET}"
    echo -e "  ${BOLD}[4]${RESET} High quality     ${DIM}(stereo, ~128kbps — treats everything the same, closest to original)${RESET}"
    echo
    local choice
    choice=$(ask_input "Pick a preset" "1")
    case "$choice" in
        1) PRESET_NAME="auto" ;;
        2) PRESET_NAME="voice" ;;
        3) PRESET_NAME="balanced" ;;
        4) PRESET_NAME="high" ;;
        *) warn "Unrecognized choice — keeping '$PRESET_NAME'" ;;
    esac
    if [[ "$PRESET_NAME" == "auto" ]]; then
        echo
        local new_thresh
        new_thresh=$(ask_input "Treat a recording as music if it runs at least this many minutes (also auto-detects stereo)" "$(( MUSIC_MIN_DURATION_SEC / 60 ))")
        if [[ "$new_thresh" =~ ^[0-9]+$ ]]; then
            MUSIC_MIN_DURATION_SEC=$(( new_thresh * 60 ))
        fi
    fi
    save_config
    ok "Preset set to: $PRESET_NAME"
}

# ── Prerequisite checks ───────────────────────────────────────────────────────
check_dependencies() {
    section "Checking dependencies"
    local missing=()
    for cmd in sqlite3 ffmpeg mdls afinfo python3 stat du bc find; do
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
        info "mdls/sqlite3/stat are built into macOS — if they're missing,"
        info "something unusual is going on with this Mac. ffmpeg/python3/bc can be"
        info "installed via: brew install ffmpeg python3 bc"
        exit 1
    fi
}

check_voicememos_access() {
    section "Checking access to Voice Memos data"
    if [[ ! -f "$VM_DB" ]]; then
        err "Cannot find Voice Memos database at:"
        bullet "$VM_DB"
        echo
        warn "This usually means either:"
        bullet "You have never recorded a Voice Memo on this Mac, or"
        bullet "Terminal needs Full Disk Access to read Group Containers."
        echo
        info "Go to: ${ULINE}System Settings → Privacy & Security → Full Disk Access${RESET}"
        info "Add Terminal (or iTerm / whatever app you're running this from) and re-run."
        exit 1
    fi
    if ! head -c 1 "$VM_DB" &>/dev/null 2>&1; then
        err "Found the database but cannot read it: $VM_DB"
        echo
        warn "macOS requires Full Disk Access for this Terminal to read Voice Memos."
        info "Go to: ${ULINE}System Settings → Privacy & Security → Full Disk Access${RESET}"
        info "Add Terminal (or iTerm / the app you're using) and re-run."
        exit 1
    fi
    ok "Voice Memos database found and readable"
}

check_voicememos_closed() {
    section "Checking Voice Memos.app status"
    if pgrep -x "Voice Memos" &>/dev/null; then
        warn "Voice Memos.app is currently open."
        info "It should be closed before we copy the database to avoid a mid-write read."
        echo
        if ask_yn "Quit Voice Memos.app now?" "y"; then
            osascript -e 'quit app "Voice Memos"' 2>/dev/null || true
            sleep 1
            ok "Voice Memos.app closed"
            log_action "Quit Voice Memos.app"
        else
            warn "Proceeding with Voice Memos.app open — database copy may be inconsistent."
            log_warn "User chose to continue with Voice Memos.app open"
        fi
    else
        ok "Voice Memos.app is not running"
    fi
}

# ── Database helpers ──────────────────────────────────────────────────────────
copy_database() {
    section "Copying Voice Memos database to a temp location"
    spinner_start "Copying CloudRecordings.db …"
    cp "$VM_DB" "$DB_TMP" 2>/dev/null
    chmod 644 "$DB_TMP" 2>/dev/null || true
    spinner_stop
    ok "Database copied to $DB_TMP"
    log_action "Copied CloudRecordings.db → $DB_TMP"
}

# Discover which optional columns actually exist in this OS version's schema
# (Apple has changed ZCLOUDRECORDING's columns across macOS releases, and some
# builds don't expose location columns at all — we degrade gracefully instead
# of hard-failing on a missing column).
HAS_COL_CUSTOMLABEL=false
HAS_COL_ENCRYPTEDTITLE=false
HAS_COL_DURATION=false
HAS_COL_LAT=false
HAS_COL_LON=false

detect_schema() {
    section "Inspecting database schema"
    local cols
    cols=$(sqlite3 "$DB_TMP" "PRAGMA table_info(ZCLOUDRECORDING);" 2>/dev/null | awk -F'|' '{print $2}') || true
    if [[ -z "$cols" ]]; then
        err "Could not read ZCLOUDRECORDING table — is this really a Voice Memos database?"
        exit 1
    fi
    grep -qx "ZCUSTOMLABEL" <<< "$cols" && HAS_COL_CUSTOMLABEL=true
    grep -qx "ZENCRYPTEDTITLE" <<< "$cols" && HAS_COL_ENCRYPTEDTITLE=true
    grep -qx "ZDURATION" <<< "$cols" && HAS_COL_DURATION=true
    grep -qix "ZLOCATIONLATITUDE" <<< "$cols" && HAS_COL_LAT=true
    grep -qix "ZLOCATIONLONGITUDE" <<< "$cols" && HAS_COL_LON=true
    ok "Schema detected ($( wc -l <<< "$cols" | tr -d ' ') columns on ZCLOUDRECORDING)"
    log_debug "columns: $(tr '\n' ',' <<< "$cols")"
}

# Returns TSV rows: rowid \t path \t label \t date_raw \t duration \t lat \t lon
query_recordings() {
    # Output is tab-separated and read back with `IFS=$'\t' read -r ...`, so
    # any tab/newline/CR that made it INTO a title (Voice Memos titles can
    # be freely typed/edited on iOS, and some evidently contain line breaks)
    # silently shifts every column after it — that's what was producing
    # garbage like "rowid=ta | source file not found" during export: the
    # real rowid/path got split across lines by an embedded newline in the
    # label, and the tail end of the label was mistaken for later columns.
    # Strip those characters at the SQL level so every field is guaranteed
    # to be a single clean line/column no matter what a user typed as a title.
    local label_expr="''"
    $HAS_COL_CUSTOMLABEL && label_expr="REPLACE(REPLACE(REPLACE(COALESCE(ZCUSTOMLABEL,''), char(10), ' '), char(13), ' '), char(9), ' ')"
    local dur_expr="0"
    $HAS_COL_DURATION && dur_expr="COALESCE(ZDURATION,0)"
    local lat_expr="''"
    $HAS_COL_LAT && lat_expr="COALESCE(ZLOCATIONLATITUDE,'')"
    local lon_expr="''"
    $HAS_COL_LON && lon_expr="COALESCE(ZLOCATIONLONGITUDE,'')"
    # v1.1.2 only stripped control chars from the label column, on the theory
    # that user-typed titles were the only plausible carrier of an embedded
    # newline — but garbled rows (rowid landing on what's clearly a
    # filename or a duration value) kept happening even after that shipped,
    # on ROWS WHOSE LABEL WAS IRRELEVANT. Some ZPATH values apparently carry
    # a stray control character too (seen consistently on newer .qta-format
    # recordings) — sqlite3 prints it verbatim, which reads as an extra line
    # break to bash's `read`, silently splitting one row into two and
    # shifting every column after it. Belt-and-suspenders: strip the same
    # three control chars from ZPATH as well, since it's a plain filename
    # and never legitimately needs any of them.
    local path_expr="REPLACE(REPLACE(REPLACE(COALESCE(ZPATH,''), char(10), ' '), char(13), ' '), char(9), ' ')"

    sqlite3 -separator $'\t' "$DB_TMP" "
SELECT
    Z_PK,
    $path_expr,
    $label_expr,
    COALESCE(ZDATE,0),
    $dur_expr,
    $lat_expr,
    $lon_expr
FROM ZCLOUDRECORDING
WHERE ZPATH IS NOT NULL AND ZPATH != ''
ORDER BY ZDATE ASC;
" 2>/dev/null || true
}

# macOS/Core Data epoch (2001-01-01) → unix epoch
mac_to_unix_epoch() { echo $(( $(printf '%.0f' "$1") + 978307200 )); }

epoch_to_date() {
    date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d' 2>/dev/null || echo "0000-00-00"
}

epoch_to_iso() {
    date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo ""
}

# v1.1.7: the "real name" a recording shows as inside Voice Memos.app — used
# so a "still incomplete" report can point at something findable in the app,
# not an internal filename the app never displays. If a custom title was set
# (ZCUSTOMLABEL), that's exactly what the app shows, verbatim. Untitled
# recordings show Apple's own default name, which is just the recording's
# date/time formatted like "August 13, 2026 at 4:51 PM" — reconstructed here
# field-by-field (rather than one strftime call) because macOS's date/BSD
# strftime doesn't reliably support the "no leading zero" %-d/%-I GNU
# extensions across macOS versions.
display_name_for() {
    local label="$1" epoch="$2"
    if [[ -n "$label" ]]; then
        printf '%s' "$label"
        return
    fi
    local mon day year hr12 min ampm
    mon=$(date -r "$epoch" '+%B' 2>/dev/null || date -d "@$epoch" '+%B' 2>/dev/null)
    day=$(date -r "$epoch" '+%d' 2>/dev/null || date -d "@$epoch" '+%d' 2>/dev/null)
    year=$(date -r "$epoch" '+%Y' 2>/dev/null || date -d "@$epoch" '+%Y' 2>/dev/null)
    hr12=$(date -r "$epoch" '+%I' 2>/dev/null || date -d "@$epoch" '+%I' 2>/dev/null)
    min=$(date -r "$epoch" '+%M' 2>/dev/null || date -d "@$epoch" '+%M' 2>/dev/null)
    ampm=$(date -r "$epoch" '+%p' 2>/dev/null || date -d "@$epoch" '+%p' 2>/dev/null)
    if [[ -z "$mon$day$year" ]]; then
        printf 'Untitled recording'
        return
    fi
    day=$((10#${day:-0})); hr12=$((10#${hr12:-0}))
    [[ $hr12 -eq 0 ]] && hr12=12
    printf '%s %d, %s at %d:%s %s' "$mon" "$day" "$year" "$hr12" "${min:-00}" "${ampm:-}"
}

# v1.1.7: human-readable duration for the "still incomplete" report —
# ZDURATION is seconds (often with a long decimal tail), shown as h/m/s.
human_duration() {
    local secs="${1%%.*}"
    [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 )) s=$(( secs % 60 ))
    if   (( h > 0 )); then printf '%dh %dm' "$h" "$m"
    elif (( m > 0 )); then printf '%dm %ds' "$m" "$s"
    else printf '%ds' "$s"
    fi
}

# v1.2.0: auto-synced/untitled recordings store a raw ISO8601-with-underscores
# placeholder in ZCUSTOMLABEL (e.g. "2026-07-08T21_42_05Z"). Voice Memos.app
# itself never shows that string — it renders those as "New Recording N".
# Exported filenames were using the raw label verbatim as the title (see
# title resolution below), producing ugly/meaningless filenames like
# "2026-07-08_2026-07-08T12_08_54Z_24.mp3". Detect the pattern so those cases
# fall through to the same human date/time name display_name_for already
# uses for genuinely-empty labels, instead of the raw placeholder.
is_placeholder_label() {
    # v1.2.1: the underscore-only pattern below matched the SANITIZED
    # (filename-safe) form of the placeholder, not the raw label as it
    # actually comes out of the database — which uses colons as the ISO8601
    # time separator (e.g. "2026-03-21T20:27:38Z"). This check runs on the
    # raw label BEFORE sanitize_filename() converts ":" to "_", so it was
    # silently never matching and every one of these ugly-named files sailed
    # straight through unrenamed. Accept both separator styles, optional
    # fractional seconds, and — as a catch-all for any timestamp format we
    # haven't specifically seen — treat a label as a placeholder if nothing
    # but digits/T/Z/:/_/./+/- remain once all of those characters are
    # stripped out (i.e. it contains no actual human-typed words).
    local s="$1" stripped
    if [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}[:_][0-9]{2}[:_][0-9]{2}(\.[0-9]+)?Z?$ ]]; then
        return 0
    fi
    stripped="${s//[0-9TZ:_.+-]/}"
    [[ -z "$stripped" && ${#s} -ge 15 ]]
}

is_hard_skipped() {
    # is_hard_skipped <raw_zpath> — pure string matching, ZERO filesystem
    # access, on purpose (see HARD_SKIP_PATTERNS comment above).
    local p="$1" pat
    for pat in "${HARD_SKIP_PATTERNS[@]}"; do
        [[ -n "$pat" && "$p" == *"$pat"* ]] && return 0
    done
    if [[ -f "$HARD_SKIP_LIST_FILE" ]]; then
        while IFS= read -r pat; do
            [[ -z "$pat" || "$pat" == \#* ]] && continue
            [[ "$p" == *"$pat"* ]] && return 0
        done < "$HARD_SKIP_LIST_FILE"
    fi
    return 1
}

resolve_recording_path() {
    # ZPATH is normally just a filename (e.g. "20240102 093015-ABCDEF.m4a")
    # relative to the Recordings folder, but be defensive about absolute paths
    # and stray leading "./".
    local raw="$1"
    if [[ "$raw" == /* ]]; then
        printf '%s' "$raw"
    else
        raw="${raw#./}"
        printf '%s' "$VM_RECORDINGS_DIR/$raw"
    fi
}

# ── Embedded file metadata (mdls) — best source for GPS + creation date ──────
# Voice Memos embeds QuickTime location metadata into the .m4a itself when the
# "Location" toggle is on at record time; mdls surfaces it as Spotlight
# attributes without us having to parse the container format by hand.
mdls_get() {
    # mdls_get <attr> <path>
    # Group Containers (where Voice Memos audio lives) is sometimes excluded
    # from Spotlight indexing, and mdls can exit non-zero for an unindexed or
    # attribute-less file. Under `set -e`, an unguarded failure here at any
    # call site would silently kill the whole export — always return success.
    # v1.1.4: also timeout-guarded now, same reasoning as get_source_channels
    # — an un-downloaded iCloud placeholder file can make mdls hang instead
    # of erroring.
    run_with_timeout 10 mdls -name "$1" -raw "$2" 2>/dev/null || true
}

get_file_location_and_date() {
    # Prints: lat \t lon \t iso_creation_date  (any field may be blank)
    local path="$1"
    local lat lon created
    lat=$(mdls_get kMDItemLatitude "$path")
    lon=$(mdls_get kMDItemLongitude "$path")
    created=$(mdls_get kMDItemContentCreationDate "$path")
    [[ "$lat" == "(null)" || -z "$lat" ]] && lat=""
    [[ "$lon" == "(null)" || -z "$lon" ]] && lon=""
    [[ "$created" == "(null)" || -z "$created" ]] && created=""
    printf '%s\t%s\t%s' "$lat" "$lon" "$created"
}

# ── Manifest (incremental exports) ────────────────────────────────────────────
# Keyed by "src_path|size|mtime" so a re-recorded/edited file with the same
# name is treated as new, but an unchanged file is skipped on reruns.
#
# Each manifest line is "<key>::orig=<0|1>|comp=<0|1>" — it records WHICH
# artifacts were actually written for that key, not just "we looked at this
# once". That distinction matters because metadata-only runs (Settings ->
# both copy types skipped) intentionally never write orig=1/comp=1, so a
# later real export still does real work instead of trusting a catalog-only
# pass as "already exported". (v1.0.0 kept a bare key with no flags, which
# meant a metadata-only run and a real export shared one undifferentiated
# "done" marker — see AGENTS.md / this file's changelog for the fix.)
manifest_key() {
    local path="$1" size="$2" mtime="$3"
    printf '%s|%s|%s' "$path" "$size" "$mtime"
}

manifest_lookup_flags() {
    # Prints the most recent "orig=.. comp=.." flags line for <key>, or
    # nothing if this key has never been recorded. grep legitimately exits
    # non-zero when there's no match (the normal case for every recording's
    # first-ever run) — under `set -e` that would kill the whole script if
    # not neutralized here, so always return success.
    local key="$1"
    grep -F "${key}::" "$MANIFEST_FILE" 2>/dev/null | tail -n1 || true
}

manifest_sufficient() {
    # manifest_sufficient <key> -> success (skip this row) only if a
    # previous run already wrote everything THIS run is configured to
    # produce. A metadata-only run never satisfies a later full export.
    local key="$1"
    local line; line=$(manifest_lookup_flags "$key")
    [[ -z "$line" ]] && return 1
    local have_orig=0 have_comp=0
    [[ "$line" == *"orig=1"* ]] && have_orig=1
    [[ "$line" == *"comp=1"* ]] && have_comp=1
    if ! $SKIP_ORIGINALS && [[ $have_orig -ne 1 ]]; then return 1; fi
    if ! $SKIP_COMPRESSED && [[ $have_comp -ne 1 ]]; then return 1; fi
    return 0
}

manifest_add() {
    # manifest_add <key> <orig_written 0|1> <comp_written 0|1>
    $DRY_RUN && return 0
    local key="$1" orig="${2:-0}" comp="${3:-0}"
    local tmp="${MANIFEST_FILE}.tmp.$$"
    grep -vF "${key}::" "$MANIFEST_FILE" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$MANIFEST_FILE"
    echo "${key}::orig=${orig}|comp=${comp}" >> "$MANIFEST_FILE"
}

# ── Portable timeout (macOS ships no `timeout`/`gtimeout` by default) ───────
run_with_timeout() {
    # run_with_timeout <seconds> <cmd...> — kills <cmd> if it's still running
    # after <seconds>. Without this, one weird/corrupt/oddly-encoded source
    # file can hang ffmpeg indefinitely and the whole export just sits there
    # forever with no error, no progress, and no way to tell it's stuck
    # short of noticing the log timestamp stopped.
    #
    # v1.1.8 CRITICAL FIX: this looked correct and passed every test except
    # the one case that mattered — a process blocked in an UNINTERRUPTIBLE
    # kernel I/O wait (D state). That happens in exactly the scenario this
    # script keeps hitting: ffmpeg calling read() on a source file whose
    # data macOS's iCloud file-provider daemon never resolves (an
    # unmaterialized placeholder, or a stalled/broken sync). `kill -9`
    # cannot terminate a D-state process — SIGKILL is only delivered once
    # the kernel call it's blocked in returns, which for a truly wedged I/O
    # provider may be never. The old code called `kill -9` and then
    # unconditionally `wait`ed on the pid — if the kill didn't actually take
    # (D state), that `wait` blocked forever too, silently un-doing the
    # entire timeout and freezing the whole script exactly like having no
    # timeout at all. This is what caused the SAME file to hang for 9+ hours
    # on iCloud output, and then again for 4+ hours after moving output to
    # local disk — the local-disk move only removed ONE contention source
    # (writing the output); reading this particular SOURCE file was always
    # the actual problem.
    #
    # Fix: after `kill -9`, wait only a short bounded grace period for the
    # process to actually die. If it hasn't, give up waiting on it (leaving
    # a harmless zombie/orphan in the background — it costs nothing but a
    # PID since it's stuck in the kernel, not spinning) and return the
    # timeout status anyway so the calling loop can move on to the next
    # file instead of hanging with it.
    local secs="$1"; shift
    "$@" &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        (( waited++ )) || true
        if (( waited >= secs )); then
            kill -9 "$pid" 2>/dev/null || true
            local grace=0
            while kill -0 "$pid" 2>/dev/null && (( grace < 5 )); do
                sleep 1
                (( grace++ )) || true
            done
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "run_with_timeout: pid $pid did not die after SIGKILL (likely stuck in uninterruptible I/O wait, e.g. an unresolved iCloud file) — abandoning it and moving on rather than hanging forever"
            fi
            disown "$pid" 2>/dev/null || true
            return 124
        fi
    done
    wait "$pid"
}

# ── Compression ────────────────────────────────────────────────────────────────
COMPRESS_TIMEOUT_SEC=180   # per-file cap; a stuck ffmpeg is killed, not waited on forever
compress_audio() {
    # compress_audio <src> <dst_tmp> <preset_name>
    # The real bug behind two prior "fixes" that both failed: this whole
    # script sets IFS=$'\n\t' near the top (no space in it), so ANY
    # space-based word-splitting — `set -- $params`, `read var1 var2 <<<
    # "$params"`, doesn't matter which — silently breaks: with no space in
    # IFS, the whole string becomes ONE word instead of splitting into
    # bitrate/channels, and afconvert gets an empty -c argument. Sidestepping
    # the whole class of bug: resolve bitrate/channels directly with a case
    # statement instead of building then re-parsing a string.
    # Switched from AAC/afconvert to MP3/ffmpeg in v1.1.0. Two reasons this
    # also happens to sidestep the afconvert AAC->AAC bug from v1.0.9 (some
    # source files threw "Couldn't open input file ('wht?')" / "Couldn't set
    # audio converter property ('!dat')" no matter how many times or how
    # they were retried): ffmpeg's own AAC decoder reads those same files
    # fine, and libmp3lame encoding doesn't share afconvert's buggy
    # compressed->compressed code path at all.
    local src="$1" dst="$2" preset="${3:-voice}"
    local bitrate
    case "$preset" in
        voice)    bitrate=24k ;;
        balanced) bitrate=64k ;;
        high)     bitrate=128k ;;
        music)    bitrate=160k ;;
        *)        bitrate=24k ;;
    esac
    # -vn strips the cover-art/thumbnail "video" stream some m4a files carry
    # (ffmpeg would otherwise try, and fail, to also transcode it). No
    # channel forcing, same reasoning as before: let output keep the
    # source's own channel count.
    # -f mp3 forces the muxer explicitly rather than letting ffmpeg guess it
    # from the destination filename's extension — the caller always writes
    # through a "<name>.mp3.part" temp path first (atomic mv into place on
    # success), and ffmpeg's format autodetection looks at ".part", not
    # ".mp3", and fails with "Unable to choose an output format" for every
    # single file otherwise.
    if ! run_with_timeout "$COMPRESS_TIMEOUT_SEC" ffmpeg -y -loglevel error -i "$src" -vn -codec:a libmp3lame -b:a "$bitrate" -f mp3 "$dst" 2>>"$LOG_FILE"; then
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            log_error "ffmpeg TIMED OUT after ${COMPRESS_TIMEOUT_SEC}s on $(basename "$src") — killed, treating as failed"
        fi
        return 1
    fi
}

# ── Catalog rebuild ────────────────────────────────────────────────────────────
rebuild_catalog() {
    # Rebuilds metadata/catalog.csv + catalog.jsonl from every metadata/*.json
    # sidecar on disk. Each sidecar is always safely overwritten (by
    # date+title+rowid) rather than appended to, so rebuilding from them
    # instead of appending during the loop means reruns can never leave
    # stale duplicate rows in the aggregate catalog.
    local meta_dir="$OUTPUT_ROOT/metadata"
    [[ -d "$meta_dir" ]] || return 0
    python3 - "$meta_dir" <<'PYEOF' 2>>"$LOG_FILE"
import json, sys, csv, glob, os

meta_dir = sys.argv[1]
csv_path = os.path.join(meta_dir, "catalog.csv")
jsonl_path = os.path.join(meta_dir, "catalog.jsonl")

rows = []
for fp in sorted(glob.glob(os.path.join(meta_dir, "*.json"))):
    try:
        with open(fp) as fh:
            rows.append(json.load(fh))
    except Exception:
        continue

with open(csv_path, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["title", "source_filename", "recorded_at", "duration_seconds",
                "latitude", "longitude", "original_bytes", "compressed_bytes",
                "original_path", "compressed_path", "compression_preset",
                "audio_classification"])
    for d in rows:
        w.writerow([
            d.get("title", ""), d.get("source_filename", ""), d.get("recorded_at", ""),
            d.get("duration_seconds", 0), d.get("latitude", ""), d.get("longitude", ""),
            d.get("original_bytes", 0), d.get("compressed_bytes", 0),
            d.get("original_path", ""), d.get("compressed_path", ""),
            d.get("compression_preset", ""), d.get("audio_classification", "n/a"),
        ])

with open(jsonl_path, "w") as fh:
    for d in rows:
        fh.write(json.dumps(d))
        fh.write("\n")

print(f"catalog_rows={len(rows)}")
PYEOF
}

# ── Main export loop ──────────────────────────────────────────────────────────
do_export() {
    # These are global counters. The menu can call do_export multiple times
    # in one session (dry run, then a real run, etc.) — reset every time so
    # a previous call's numbers never bleed into this one's summary.
    TOTAL_EXPORTED=0
    TOTAL_COMPRESSED=0
    TOTAL_SKIPPED=0
    TOTAL_ERRORS=0
    TOTAL_BYTES_ORIGINAL=0
    TOTAL_BYTES_COMPRESSED=0
    TOTAL_MUSIC=0
    TOTAL_VOICE=0

    banner
    section "Exporting Voice Memos"
    log_info "VOICEMEMOCLEANER v$SCRIPT_VERSION starting (preset=$PRESET_NAME dry_run=$DRY_RUN)"

    check_dependencies
    check_voicememos_access
    check_voicememos_closed
    copy_database
    detect_schema

    mkdir -p "$OUTPUT_ROOT/originals" "$OUTPUT_ROOT/compressed" "$OUTPUT_ROOT/metadata" 2>/dev/null

    spinner_start "Querying recordings …"
    local rows; rows=$(query_recordings)
    spinner_stop

    # v1.1.7: process smallest source files first. Requested after a run
    # sat wedged for 9+ hours on one huge file with nothing else clearing —
    # sorting by ZDATE (the old order) means one big/slow file blocks every
    # smaller one behind it. File size isn't a SQL column (it's a filesystem
    # stat, not DB metadata), so this resolves+stats every row's source file
    # up front and sorts by that. Rows whose source file is missing sort
    # last (huge sentinel size) rather than erroring here — the existing
    # not-found handling in the main loop still catches them normally.
    if [[ -n "$rows" ]]; then
        spinner_start "Sorting by file size (smallest first) …"
        rows=$(
            while IFS=$'\t' read -r _rowid _path _label _date _dur _lat _lon; do
                if is_hard_skipped "$_path"; then
                    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 999999999999 "$_rowid" "$_path" "$_label" "$_date" "$_dur" "$_lat" "$_lon"
                    continue
                fi
                local _rp; _rp=$(resolve_recording_path "$_path")
                local _sz; _sz=$(stat -f%z "$_rp" 2>/dev/null || echo 999999999999)
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_sz" "$_rowid" "$_path" "$_label" "$_date" "$_dur" "$_lat" "$_lon"
            done <<< "$rows" | sort -n -t $'\t' -k1,1 | cut -f2-
        )
        spinner_stop
    fi

    # v1.1.7: collect everything still incomplete at the end of this run —
    # not-found sources and compress failures — so the app-visible "real
    # name" of each can be printed in one findable list, instead of you
    # having to reverse-engineer internal filenames from the log to go
    # clean them up in Voice Memos.
    local incomplete_report="$OUTPUT_ROOT/.incomplete_this_run.tsv"
    : > "$incomplete_report"

    local total_rows=0
    [[ -n "$rows" ]] && total_rows=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    info "Found ${BOLD}$total_rows${RESET} recordings in the database"

    if [[ $total_rows -eq 0 ]]; then
        warn "No recordings found."
        press_any_key
        return
    fi

    if [[ "$PRESET_NAME" == "auto" ]]; then
        info "Compression preset: ${BOLD}auto${RESET} — voice memos get ~24kbps, music/concert recordings (stereo source or ≥$(( MUSIC_MIN_DURATION_SEC / 60 ))min) get ~160kbps (channel count always kept as-is)"
    else
        local preset_desc; preset_desc=$(preset_params "$PRESET_NAME" | awk -F"'" '{print $2}')
        info "Compression preset: ${BOLD}$PRESET_NAME${RESET} — $preset_desc"
    fi
    $SKIP_COMPRESSED && info "Compressed copies: ${BYLW}skipped (disabled in settings)${RESET}"
    $SKIP_ORIGINALS  && info "Original copies: ${BYLW}skipped (disabled in settings)${RESET}"
    $DRY_RUN && warn "DRY-RUN mode: no files will be written"
    echo

    # catalog.csv / catalog.jsonl are rebuilt from metadata/*.json AFTER the
    # loop (see rebuild_catalog below) rather than appended to during it —
    # each recording's own JSON sidecar is always safely overwritten by path,
    # so rebuilding from those files means reruns can never leave duplicate
    # rows in the aggregate catalog the way naive appending would.

    local count=0 rowid path label date_raw duration db_lat db_lon
    while IFS=$'\t' read -r rowid path label date_raw duration db_lat db_lon; do
        (( count++ )) || true

        local src_path; src_path=$(resolve_recording_path "$path")
        local base_name; base_name=$(basename "$src_path")
        progress_bar "$count" "$total_rows" "$(echo "$base_name" | cut -c1-30)"

        # Computed immediately (needs only fields already in hand from the
        # SQL row, no file access) so it's available for every branch below,
        # including the not-found case — this is the name you'd actually
        # find this recording under in Voice Memos.app.
        local unix_epoch; unix_epoch=$(mac_to_unix_epoch "$date_raw")
        local display_name; display_name=$(display_name_for "$label" "$unix_epoch")
        local dur_human; dur_human=$(human_duration "${duration:-0}")

        # v1.1.9: hard-skipped files (see HARD_SKIP_PATTERNS) never get a
        # bare filesystem call — not even the [[ -f ]] existence test below,
        # since that alone has been observed to hang. Per user request,
        # these are no longer skipped empty-handed: attempt ONE plain,
        # unconverted byte-for-byte copy straight into compressed/, wrapped
        # in the same timeout+abandon machinery as everything else, so
        # worst case it still gives up cleanly within COMPRESS_TIMEOUT_SEC
        # and the run finishes instead of freezing on it a fourth time.
        # Skips ffmpeg entirely — not worth encoding a file that's already
        # this much trouble, and a raw copy is far more likely to actually
        # succeed since it doesn't need to parse/demux the container at all.
        if is_hard_skipped "$path"; then
            local hs_date_prefix; hs_date_prefix=$(epoch_to_date "$unix_epoch")
            local hs_title="$label"
            if [[ -z "$hs_title" ]] || is_placeholder_label "$hs_title"; then
                hs_title=$(display_name_for "" "$unix_epoch")
            fi
            hs_title=$(sanitize_filename "$hs_title")
            [[ -z "$hs_title" ]] && hs_title="Untitled_${rowid}"
            local hs_ext="${base_name##*.}"
            local hs_dest="$OUTPUT_ROOT/compressed/${hs_date_prefix}_${hs_title}_${rowid}_RAW.${hs_ext}"
            if [[ -s "$hs_dest" ]]; then
                log_skip "rowid=$rowid | hard-skipped file already raw-copied | $src_path"
                (( TOTAL_SKIPPED++ )) || true
                continue
            fi
            log_warn "rowid=$rowid | hard-skipped (known-problematic source) — attempting raw copy only, no compression | $src_path"
            local hs_tmp="/tmp/voicememocleaner_rawcopy_$$_$(basename "$hs_dest").part"
            rm -f "$hs_tmp" 2>/dev/null || true
            if run_with_timeout "$COMPRESS_TIMEOUT_SEC" cp -p "$src_path" "$hs_tmp" 2>>"$LOG_FILE" \
                && run_with_timeout 120 mv -f "$hs_tmp" "$hs_dest" 2>>"$LOG_FILE"; then
                log_action "RAW COPY (hard-skip, no compression) | $src_path -> $hs_dest"
                (( TOTAL_EXPORTED++ )) || true
            else
                rm -f "$hs_tmp" 2>/dev/null || true
                log_error "RAW COPY FAILED (or timed out) on hard-skipped file | $src_path"
                printf '%s\t%s\t%s\n' "$display_name" "$dur_human" "hard-skipped: known-problematic source, raw copy also failed/timed out — needs manual handling in Voice Memos" >> "$incomplete_report"
                (( TOTAL_ERRORS++ )) || true
            fi
            continue
        fi

        if [[ ! -f "$src_path" ]]; then
            log_skip "rowid=$rowid | source file not found | $src_path"
            printf '%s\t%s\t%s\n' "$display_name" "$dur_human" "source file not found (already missing from Voice Memos?)" >> "$incomplete_report"
            (( TOTAL_SKIPPED++ )) || true
            continue
        fi

        local size mtime
        size=$(stat -f%z "$src_path" 2>/dev/null || echo 0)
        mtime=$(stat -f%m "$src_path" 2>/dev/null || echo 0)
        local mkey; mkey=$(manifest_key "$src_path" "$size" "$mtime")

        # ── Resolve title / date ────────────────────────────────────────────
        # Moved ahead of the skip-check (used to run after it) so the
        # destination paths below exist in time for a v1.1.6 addition: an
        # ON-DISK existence check, not just the manifest. The manifest is
        # just a text file living in OUTPUT_ROOT — if that folder is ever
        # moved by hand (as happened relocating out of iCloud Drive: a bare
        # `mv folder/* dest/` doesn't sweep dotfiles like .manifest with the
        # default shell glob), the manifest can silently go missing while
        # the actual output files are sitting right there, fine. Without
        # this, that desync makes the script redo potentially hours of
        # encoding work it doesn't need to. Now it also checks whether the
        # expected output file(s) already exist before deciding to redo one.
        # v1.2.0: use the app-visible display name (real title, or the
        # reverse-geocoded address Voice Memos stored as the label, or a
        # human date/time name for genuinely untitled/placeholder-labeled
        # recordings) instead of the raw label/filename, so exported
        # filenames read the same as what's shown in Voice Memos.app.
        local title="$label"
        if [[ -z "$title" ]] || is_placeholder_label "$title"; then
            title=$(display_name_for "" "$unix_epoch")
        fi
        title=$(sanitize_filename "$title")
        [[ -z "$title" ]] && title="Untitled_${rowid}"

        # unix_epoch already computed above (needed early for display_name)
        local date_prefix; date_prefix=$(epoch_to_date "$unix_epoch")
        local recorded_iso; recorded_iso=$(epoch_to_iso "$unix_epoch")

        local export_base="${date_prefix}_${title}_${rowid}"
        local orig_dest="$OUTPUT_ROOT/originals/${export_base}.m4a"
        local comp_dest="$OUTPUT_ROOT/compressed/${export_base}.mp3"
        local meta_dest="$OUTPUT_ROOT/metadata/${export_base}.json"

        # An output counts as already present if every artifact THIS run is
        # configured to produce already exists and is non-empty on disk —
        # same "only what we're configured to produce" logic manifest_sufficient
        # uses, just checked against the filesystem instead of the manifest.
        local output_present=true
        if ! $SKIP_ORIGINALS && { [[ ! -s "$orig_dest" ]]; }; then output_present=false; fi
        if ! $SKIP_COMPRESSED && { [[ ! -s "$comp_dest" ]]; }; then output_present=false; fi

        if ! $OVERWRITE_EXISTING && { manifest_sufficient "$mkey" || $output_present; }; then
            if $output_present && ! manifest_sufficient "$mkey"; then
                log_skip "rowid=$rowid | already exported (found on disk, manifest was missing — backfilling) | $src_path"
                local backfill_orig=0 backfill_comp=0
                $SKIP_ORIGINALS  || backfill_orig=1
                $SKIP_COMPRESSED || backfill_comp=1
                manifest_add "$mkey" "$backfill_orig" "$backfill_comp"
            else
                log_skip "rowid=$rowid | already exported (manifest) | $src_path"
            fi
            (( TOTAL_SKIPPED++ )) || true
            continue
        fi

        # Seed this row's write-flags from any previous manifest entry so an
        # artifact we're not attempting THIS run (because it's toggled off in
        # Settings) doesn't get recorded as lost if it was already written by
        # an earlier run.
        local prev_flags; prev_flags=$(manifest_lookup_flags "$mkey")
        local wrote_orig=0 wrote_comp=0
        [[ "$prev_flags" == *"orig=1"* ]] && wrote_orig=1
        [[ "$prev_flags" == *"comp=1"* ]] && wrote_comp=1

        # ── Embedded location/date (best-effort, may be blank) ─────────────
        # Avoid `read ... <<<` here too (see compress_audio) — split the
        # tab-separated fields with plain parameter expansion instead.
        local file_meta lat lon file_created
        file_meta=$(get_file_location_and_date "$src_path") || true
        lat="${file_meta%%$'\t'*}"
        local _rest="${file_meta#*$'\t'}"
        lon="${_rest%%$'\t'*}"
        file_created="${_rest#*$'\t'}"
        [[ -z "$lat" ]] && lat="$db_lat"
        [[ -z "$lon" ]] && lon="$db_lon"

        if $DRY_RUN; then
            log_info "[DRY-RUN] Would export rowid=$rowid title=\"$title\" -> $orig_dest / $comp_dest"
            (( TOTAL_EXPORTED++ )) || true
            continue
        fi

        local ok_this=true
        local comp_size=0

        # ── Pick a preset for this file (auto: voice vs. music) ──────────────
        # No process-substitution/`read` combo here on purpose (see
        # compress_audio) — plain sequential assignments only.
        local preset_pick classification
        if [[ "$PRESET_NAME" == "auto" ]]; then
            local channels; channels=$(get_source_channels "$src_path")
            classification=$(classify_recording "${duration:-0}" "$channels")
            preset_pick="$classification"
        else
            preset_pick="$PRESET_NAME"
            classification="n/a"
        fi
        preset_pick="${preset_pick:-voice}"
        [[ "$classification" == "music" ]] && (( TOTAL_MUSIC++ )) || true
        [[ "$classification" == "voice" ]] && (( TOTAL_VOICE++ )) || true

        # ── Original copy ───────────────────────────────────────────────────
        if ! $SKIP_ORIGINALS; then
            local orig_tmp="${orig_dest}.part"
            if cp -p "$src_path" "$orig_tmp" 2>>"$LOG_FILE" && mv -f "$orig_tmp" "$orig_dest" 2>>"$LOG_FILE"; then
                log_action "ORIGINAL | $src_path -> $orig_dest"
                wrote_orig=1
            else
                err "Failed to copy original: $base_name"
                log_error "ORIGINAL FAILED | $src_path -> $orig_dest"
                rm -f "$orig_tmp" 2>/dev/null
                ok_this=false
            fi
        fi

        # ── Compressed copy ─────────────────────────────────────────────────
        if ! $SKIP_COMPRESSED; then
            # v1.1.5: OUTPUT_ROOT (and therefore comp_dest) lives inside
            # iCloud Drive on this Mac (~/Documents is iCloud-synced) — that
            # turned out to be the real explanation for multi-hour stalls
            # that v1.1.4's timeouts didn't catch: ffmpeg was writing its
            # .part file directly into the iCloud-synced folder, and/or the
            # final `mv` into it, could block indefinitely on iCloud's file
            # provider (uploading the previous large file, evicting local
            # copies under storage pressure, etc.) with no error and no
            # timeout guarding either step. Now ffmpeg writes to a plain
            # /tmp path first — never inside iCloud Drive — and only the
            # final move into the synced folder touches iCloud, and THAT is
            # now timeout-guarded too instead of a bare `mv`.
            local comp_tmp="/tmp/voicememocleaner_comp_$$_$(basename "$comp_dest").part"
            rm -f "$comp_tmp" 2>/dev/null || true
            if compress_audio "$src_path" "$comp_tmp" "$preset_pick" && run_with_timeout 120 mv -f "$comp_tmp" "$comp_dest" 2>>"$LOG_FILE"; then
                comp_size=$(stat -f%z "$comp_dest" 2>/dev/null || echo 0)
                log_action "COMPRESSED ($preset_pick) | $src_path -> $comp_dest ($(human_bytes $comp_size))"
                wrote_comp=1
                (( TOTAL_COMPRESSED++ )) || true
            else
                err "Failed to compress: $base_name"
                log_error "COMPRESS FAILED | $src_path -> $comp_dest"
                rm -f "$comp_tmp" 2>/dev/null
                ok_this=false
            fi
        fi

        # ── Metadata sidecar ────────────────────────────────────────────────
        local meta_tmp="${meta_dest}.part"
        {
            echo "{"
            echo "  \"title\": $(json_string "$title"),"
            echo "  \"source_filename\": $(json_string "$base_name"),"
            echo "  \"recorded_at\": $(json_string "$recorded_iso"),"
            echo "  \"file_creation_date\": $(json_string "$file_created"),"
            echo "  \"duration_seconds\": ${duration:-0},"
            echo "  \"latitude\": $(json_string "$lat"),"
            echo "  \"longitude\": $(json_string "$lon"),"
            echo "  \"original_bytes\": ${size:-0},"
            echo "  \"compressed_bytes\": ${comp_size:-0},"
            echo "  \"original_path\": $(json_string "$orig_dest"),"
            echo "  \"compressed_path\": $(json_string "$comp_dest"),"
            echo "  \"source_path\": $(json_string "$src_path"),"
            echo "  \"compression_preset\": $(json_string "${preset_pick:-}"),"
            echo "  \"audio_classification\": $(json_string "${classification:-n/a}")"
            echo "}"
        } > "$meta_tmp" 2>/dev/null && mv -f "$meta_tmp" "$meta_dest"

        if $ok_this; then
            manifest_add "$mkey" "$wrote_orig" "$wrote_comp"
            (( TOTAL_EXPORTED++ )) || true
            (( TOTAL_BYTES_ORIGINAL += ${size:-0} )) || true
            (( TOTAL_BYTES_COMPRESSED += ${comp_size:-0} )) || true
        else
            printf '%s\t%s\t%s\n' "$display_name" "$dur_human" "compress failed (see log for reason — often a corrupted source file)" >> "$incomplete_report"
            (( TOTAL_ERRORS++ )) || true
        fi

    done <<< "$rows"

    printf "\r%${WIDTH}s\r" ""
    echo

    if ! $DRY_RUN; then
        rebuild_catalog || warn "Could not rebuild catalog.csv/catalog.jsonl (see log) — per-file metadata/*.json is still fine"
    fi

    ok "Export complete: $TOTAL_EXPORTED exported, $TOTAL_SKIPPED skipped, $TOTAL_ERRORS errors"
    echo
    HR
    echo -e "  ${BOLD}Session Summary${RESET}"
    HR
    bullet "Recordings exported : ${BGRN}$TOTAL_EXPORTED${RESET}"
    bullet "Compressed copies   : ${BGRN}$TOTAL_COMPRESSED${RESET}"
    if [[ "$PRESET_NAME" == "auto" && $(( TOTAL_MUSIC + TOTAL_VOICE )) -gt 0 ]]; then
        bullet "  ↳ classified as music: ${BCYN}$TOTAL_MUSIC${RESET}  •  voice: ${BCYN}$TOTAL_VOICE${RESET}"
    fi
    bullet "Skipped (unchanged) : ${BYLW}$TOTAL_SKIPPED${RESET}"
    bullet "Errors              : ${BRED}$TOTAL_ERRORS${RESET}"
    bullet "Original size total : ${BCYN}$(human_bytes $TOTAL_BYTES_ORIGINAL)${RESET}"
    bullet "Compressed size total: ${BCYN}$(human_bytes $TOTAL_BYTES_COMPRESSED)${RESET}"
    if [[ $TOTAL_BYTES_ORIGINAL -gt 0 && $TOTAL_BYTES_COMPRESSED -gt 0 ]]; then
        local pct; pct=$(echo "scale=1; 100 - ($TOTAL_BYTES_COMPRESSED * 100 / $TOTAL_BYTES_ORIGINAL)" | bc 2>/dev/null || echo "?")
        bullet "Space saved by compression: ${BGRN}${pct}%${RESET}"
    fi
    HR
    echo
    info "Everything is at: ${BOLD}$OUTPUT_ROOT${RESET}"
    bullet "originals/   — full-quality exact copies (for listening / archival)"
    bullet "compressed/  — smaller MP3 copies (playable everywhere)"
    bullet "metadata/    — per-recording JSON + catalog.csv + catalog.jsonl for analysis"
    log_info "Export run finished. exported=$TOTAL_EXPORTED skipped=$TOTAL_SKIPPED errors=$TOTAL_ERRORS"

    # v1.1.7: print the still-incomplete list by the name you'd actually see
    # in Voice Memos.app, so you can go find/handle these directly instead
    # of decoding internal filenames from the log.
    if [[ -s "$incomplete_report" ]]; then
        echo
        HR
        local n_incomplete; n_incomplete=$(wc -l < "$incomplete_report" | tr -d ' ')
        echo -e "  ${BOLD}${BYLW}Still incomplete (${n_incomplete}) — look for these in Voice Memos.app${RESET}"
        HR
        while IFS=$'\t' read -r inc_name inc_dur inc_reason; do
            echo -e "  ${BYLW}•${RESET} ${BOLD}${inc_name}${RESET}  ${DIM}(${inc_dur})${RESET}"
            echo -e "      ${DIM}${inc_reason}${RESET}"
        done < "$incomplete_report"
        HR
        info "This list is also saved at: ${BOLD}${OUTPUT_ROOT}/.incomplete_this_run.tsv${RESET}"
    fi

    if ask_yn "Open the output folder in Finder now?" y; then
        open "$OUTPUT_ROOT" 2>/dev/null || info "Could not open Finder (headless session?)"
    fi
    press_any_key
}

do_metadata_only() {
    banner
    section "Metadata-only catalog (no audio copies)"
    local prev_skip_c=$SKIP_COMPRESSED prev_skip_o=$SKIP_ORIGINALS
    SKIP_COMPRESSED=true
    SKIP_ORIGINALS=true
    do_export
    SKIP_COMPRESSED=$prev_skip_c
    SKIP_ORIGINALS=$prev_skip_o
}

do_dry_run() {
    banner
    section "Dry run — preview only, nothing will be written"
    local prev=$DRY_RUN
    DRY_RUN=true
    do_export
    DRY_RUN=$prev
}

view_log() {
    banner
    section "Recent log entries"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 60 "$LOG_FILE"
    else
        info "No log file yet — run an export first."
    fi
    press_any_key
}

settings_menu() {
    while true; do
        banner
        section "Settings"
        echo
        bullet "Output folder        : ${BOLD}$OUTPUT_ROOT${RESET}"
        bullet "Compression preset   : ${BOLD}$PRESET_NAME${RESET}$([[ "$PRESET_NAME" == "auto" ]] && echo "  (music threshold: ${MUSIC_MIN_DURATION_SEC}s / $(( MUSIC_MIN_DURATION_SEC / 60 ))min, or stereo)")"
        bullet "Skip original copies : ${BOLD}$SKIP_ORIGINALS${RESET}"
        bullet "Skip compressed copies: ${BOLD}$SKIP_COMPRESSED${RESET}"
        bullet "Overwrite existing   : ${BOLD}$OVERWRITE_EXISTING${RESET}"
        echo
        echo -e "  ${BOLD}[1]${RESET} Change output folder"
        echo -e "  ${BOLD}[2]${RESET} Change compression preset"
        echo -e "  ${BOLD}[3]${RESET} Toggle: skip original copies"
        echo -e "  ${BOLD}[4]${RESET} Toggle: skip compressed copies"
        echo -e "  ${BOLD}[5]${RESET} Toggle: overwrite already-exported files"
        echo -e "  ${BOLD}[b]${RESET} Back to main menu"
        echo
        local choice; choice=$(ask_input "Choose" "b")
        case "$choice" in
            1) pick_output_dir; press_any_key ;;
            2) choose_preset; press_any_key ;;
            3) $SKIP_ORIGINALS && SKIP_ORIGINALS=false || SKIP_ORIGINALS=true ;;
            4) $SKIP_COMPRESSED && SKIP_COMPRESSED=false || SKIP_COMPRESSED=true ;;
            5) $OVERWRITE_EXISTING && OVERWRITE_EXISTING=false || OVERWRITE_EXISTING=true ;;
            b|B) return ;;
            *) warn "Unrecognized choice" ;;
        esac
    done
}

# ── Main menu ──────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        banner
        echo -e "  Output folder : ${BOLD}$OUTPUT_ROOT${RESET}"
        echo -e "  Preset        : ${BOLD}$PRESET_NAME${RESET}"
        echo
        echo -e "  ${BOLD}[1]${RESET} Export & compress all Voice Memos"
        echo -e "  ${BOLD}[2]${RESET} Refresh (same as 1 — reruns skip unchanged files automatically)"
        echo -e "  ${BOLD}[3]${RESET} Metadata-only catalog (fast, no audio copies)"
        echo -e "  ${BOLD}[4]${RESET} Dry run (preview, writes nothing)"
        echo -e "  ${BOLD}[5]${RESET} Settings"
        echo -e "  ${BOLD}[6]${RESET} View recent log"
        echo -e "  ${BOLD}[7]${RESET} Open output folder in Finder"
        echo -e "  ${BOLD}[q]${RESET} Quit"
        echo
        local choice; choice=$(ask_input "Choose" "1")
        case "$choice" in
            1|2) do_export ;;
            3) do_metadata_only ;;
            4) do_dry_run ;;
            5) settings_menu ;;
            6) view_log ;;
            7) open "$OUTPUT_ROOT" 2>/dev/null || { warn "Could not open Finder"; press_any_key; } ;;
            q|Q) echo; info "Bye."; cleanup_and_exit 0 ;;
            *) warn "Unrecognized choice"; press_any_key ;;
        esac
    done
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup_and_exit() {
    local code="${1:-0}"
    spinner_stop
    rm -f "$DB_TMP" 2>/dev/null || true
    exit "$code"
}
trap 'cleanup_and_exit 130' INT TERM

# ── Entry point ────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG_LOG=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

load_config
set_output_paths

if [[ "${1:-}" == "--auto" ]]; then
    check_dependencies
    check_voicememos_access
    do_export
    cleanup_and_exit 0
fi

main_menu
cleanup_and_exit 0
