#!/bin/bash
# =============================================================================
#  rename_exports.sh — one-off cleanup companion to VOICEMEMOCLEANER.sh
#
#  What it does:
#    Renames files ALREADY exported by VOICEMEMOCLEANER.sh (in compressed/,
#    originals/, and metadata/) so the filename shows the same name Voice
#    Memos.app shows (real title, or the address it auto-named the recording
#    with, or a human date/time for untitled ones) plus the original
#    recording date — instead of the raw internal label/filename that older
#    runs (pre-v1.2.0) used, which for auto-synced/untitled recordings was an
#    ugly literal string like "2026-07-08T12_08_54Z".
#
#  Why a separate script instead of just rerunning VOICEMEMOCLEANER.sh:
#    The main script's incremental/manifest logic is about not re-exporting
#    or re-encoding — it was never designed to rename files that already
#    exist on disk. This is a pure rename pass: it queries the same
#    CloudRecordings.db, matches each existing file back to its row by the
#    rowid already embedded in the filename, and renames in place. It never
#    touches audio content, never re-encodes, never talks to Voice Memos.app.
#
#  Safe to run repeatedly — files already correctly named are left alone.
#
#  Run as:  bash rename_exports.sh
# =============================================================================
set -eo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

VM_CONTAINER="$REAL_HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared"
VM_DB="$VM_CONTAINER/Recordings/CloudRecordings.db"

CONFIG_FILE="$REAL_HOME/.config/voicememocleaner/config"
OUTPUT_ROOT=""
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
fi
if [[ -z "$OUTPUT_ROOT" || ! -d "$OUTPUT_ROOT" ]]; then
    # Fall back to the known current export location if config didn't resolve.
    for candidate in "$REAL_HOME/voicememo-exports-local" "$REAL_HOME/Documents/root/voicememo-exports"; do
        if [[ -d "$candidate" ]]; then OUTPUT_ROOT="$candidate"; break; fi
    done
fi
if [[ -z "$OUTPUT_ROOT" || ! -d "$OUTPUT_ROOT" ]]; then
    echo "Could not find your export folder automatically."
    echo "Edit OUTPUT_ROOT near the top of this script and set it to the right path, then rerun."
    exit 1
fi

echo "Export folder: $OUTPUT_ROOT"
echo "Voice Memos DB: $VM_DB"
if [[ ! -f "$VM_DB" ]]; then
    echo "ERROR: Voice Memos database not found at that path. Is Voice Memos.app set up on this account?"
    exit 1
fi

DB_TMP="/tmp/voicememorename_db_$$.db"
cp "$VM_DB" "$DB_TMP"
cleanup() { rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true; }
trap cleanup EXIT

sanitize_filename() {
    local name="$1"
    name=$(echo "$name" | sed 's/[\/:\\*?"<>|]/_/g')
    name=$(echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    printf '%s' "$name"
}

is_placeholder_label() {
    # v2: raw labels use colons as the ISO8601 time separator
    # ("2026-03-21T20:27:38Z"), not underscores — underscores only appear
    # after sanitize_filename() runs, which is AFTER this check. The
    # underscore-only version below never matched anything, which is why the
    # first run of this script reported 378 "already correct" files that
    # were, visibly, still ugly. Accept both separators, optional fractional
    # seconds, and fall back to "nothing but timestamp characters" as a
    # catch-all for any format not explicitly matched.
    local s="$1" stripped
    if [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}[:_][0-9]{2}[:_][0-9]{2}(\.[0-9]+)?Z?$ ]]; then
        return 0
    fi
    stripped="${s//[0-9TZ:_.+-]/}"
    [[ -z "$stripped" && ${#s} -ge 15 ]]
}

epoch_to_date() {
    date -r "$1" '+%Y-%m-%d' 2>/dev/null || echo "0000-00-00"
}

display_name_for() {
    # empty label -> human date/time name, matching VOICEMEMOCLEANER.sh
    local epoch="$1"
    local mon day year hr12 min ampm
    mon=$(date -r "$epoch" '+%B' 2>/dev/null)
    day=$(date -r "$epoch" '+%d' 2>/dev/null)
    year=$(date -r "$epoch" '+%Y' 2>/dev/null)
    hr12=$(date -r "$epoch" '+%I' 2>/dev/null)
    min=$(date -r "$epoch" '+%M' 2>/dev/null)
    ampm=$(date -r "$epoch" '+%p' 2>/dev/null)
    if [[ -z "$mon$day$year" ]]; then
        printf 'Untitled recording'
        return
    fi
    day=$((10#${day:-0})); hr12=$((10#${hr12:-0}))
    [[ $hr12 -eq 0 ]] && hr12=12
    printf '%s %d, %s at %d:%s %s' "$mon" "$day" "$year" "$hr12" "${min:-00}" "${ampm:-}"
}

# Detect optional columns the same way the main script does, for older DBs.
cols=$(sqlite3 "$DB_TMP" "PRAGMA table_info(ZCLOUDRECORDING);" 2>/dev/null | awk -F'|' '{print $2}')
label_expr="''"
grep -qx "ZCUSTOMLABEL" <<< "$cols" && label_expr="REPLACE(REPLACE(REPLACE(COALESCE(ZCUSTOMLABEL,''), char(10), ' '), char(13), ' '), char(9), ' ')"

# macOS ships bash 3.2 (no associative arrays, no mapfile) — same constraint
# VOICEMEMOCLEANER.sh targets. Dump the DB rows to a flat tmp file instead of
# an in-memory hash map, and look up each rowid with grep when needed. The
# DB is small (a few hundred rows at most) so this is plenty fast.
ROWS_TMP="/tmp/voicememorename_rows_$$.tsv"
sqlite3 -separator $'\t' "$DB_TMP" "
SELECT Z_PK, $label_expr, COALESCE(ZDATE,0)
FROM ZCLOUDRECORDING
WHERE Z_PK IS NOT NULL;
" 2>/dev/null > "$ROWS_TMP" || true
trap 'cleanup; rm -f "$ROWS_TMP" 2>/dev/null || true' EXIT

row_count=$(wc -l < "$ROWS_TMP" | tr -d ' ')
echo "Found $row_count recordings in the database."

# lookup_row <rowid> -> prints "label<SOH>unix_epoch", empty if not found.
# NOTE: deliberately NOT using `read -r a b <<< "$line"` to split fields —
# bash's `read` treats tab as "IFS whitespace" and collapses consecutive
# occurrences even with IFS explicitly set to just tab, which silently
# shifted every field one to the left on any row with an empty label
# (e.g. untitled recordings) and threw the date off along with it. Using a
# rare delimiter (SOH, \x01) plus parameter-expansion splitting instead of
# `read` sidesteps that entirely and is bash-3.2 safe.
lookup_row() {
    local rowid="$1" combined label mac_epoch unix_epoch
    combined=$(awk -F'\t' -v id="$rowid" '$1==id { printf "%s\x01%s", $2, $3; exit }' "$ROWS_TMP")
    [[ -z "$combined" ]] && return 1
    label="${combined%%$'\x01'*}"
    mac_epoch="${combined#*$'\x01'}"
    unix_epoch=$(( $(printf '%.0f' "${mac_epoch:-0}") + 978307200 ))
    printf '%s\x01%s' "$label" "$unix_epoch"
}

renamed=0
unchanged=0
no_match=0
collisions=0

rename_pass() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    local f
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        local base; base=$(basename "$f")
        local ext="${base##*.}"
        local stem="${base%.*}"

        # Extract trailing rowid, optionally followed by _RAW, e.g.:
        #   2026-07-08_SomeTitle_1234.mp3
        #   2026-07-08_SomeTitle_1234_RAW.qta
        local is_raw=false
        local core="$stem"
        if [[ "$core" == *_RAW ]]; then
            is_raw=true
            core="${core%_RAW}"
        fi
        local rowid="${core##*_}"
        if [[ ! "$rowid" =~ ^[0-9]+$ ]]; then
            echo "  SKIP (no rowid in filename): $base"
            (( no_match++ )) || true
            continue
        fi
        local looked_up
        if ! looked_up=$(lookup_row "$rowid"); then
            echo "  SKIP (rowid $rowid not in DB): $base"
            (( no_match++ )) || true
            continue
        fi
        local label unix_epoch
        label="${looked_up%%$'\x01'*}"
        unix_epoch="${looked_up#*$'\x01'}"

        local title="$label"
        if [[ -z "$title" ]] || is_placeholder_label "$title"; then
            title=$(display_name_for "$unix_epoch")
        fi
        title=$(sanitize_filename "$title")
        [[ -z "$title" ]] && title="Untitled_${rowid}"

        local date_prefix; date_prefix=$(epoch_to_date "$unix_epoch")
        local new_stem="${date_prefix}_${title}_${rowid}"
        $is_raw && new_stem="${new_stem}_RAW"
        local new_base="${new_stem}.${ext}"

        if [[ "$new_base" == "$base" ]]; then
            (( unchanged++ )) || true
            continue
        fi

        local new_path="$dir/$new_base"
        if [[ -e "$new_path" ]]; then
            echo "  COLLISION (leaving as-is): $base -> $new_base already exists"
            (( collisions++ )) || true
            continue
        fi

        mv -n -- "$f" "$new_path"
        echo "  RENAMED: $base"
        echo "       -> $new_base"
        (( renamed++ )) || true
    done
}

echo
echo "Renaming in compressed/ …"
rename_pass "$OUTPUT_ROOT/compressed"
echo
echo "Renaming in originals/ …"
rename_pass "$OUTPUT_ROOT/originals"
echo
echo "Renaming in metadata/ …"
rename_pass "$OUTPUT_ROOT/metadata"

echo
echo "════════════════════════════════════════"
echo "Renamed:            $renamed"
echo "Already correct:    $unchanged"
echo "No DB match/skipped:$no_match"
echo "Collisions:         $collisions"
echo "════════════════════════════════════════"
