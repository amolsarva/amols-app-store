#!/bin/bash

set -euo pipefail

ICLOUD_ROOT="$HOME/Library/Mobile Documents"
LARGE_THRESHOLD_MB=200   # adjust this, e.g., 200MB+
WINDOW_MINUTES=30        # similar time-window for grouping large files

echo "Scanning iCloud for files…"
TMP_ALL=$(mktemp)
find "$ICLOUD_ROOT" -type f -not -path "*/.Trash/*" > "$TMP_ALL"

###############################################################################
# PART 1: Duplicate detection by hashing
###############################################################################
echo
echo ">>> Detecting duplicates (hashing)…"
HASHES=$(mktemp)

while IFS= read -r FILE; do
    SIZE=$(stat -f%z "$FILE")
    if [ "$SIZE" -lt 4096 ]; then
        continue
    fi
    HASH=$(shasum -a 256 "$FILE" | awk '{print $1}')
    printf "%s\t%s\n" "$HASH" "$FILE" >> "$HASHES"
done < "$TMP_ALL"

sort "$HASHES" | uniq -w 64 -D > "$HASHES.dupes"

process_duplicate_group() {
    FILES=()
    while IFS= read -r FILE; do
        [ -n "$FILE" ] && FILES+=("$FILE")
    done

    if [ "${#FILES[@]}" -le 1 ]; then
        return
    fi

    echo "-------------------------------------------"
    echo "Duplicate group:"
    echo

    # sort by size desc + date desc
    SORTED=$(for f in "${FILES[@]}"; do
        SIZE=$(stat -f%z "$f")
        MTIME=$(stat -f%m "$f")
        printf "%s\t%s\t%s\n" "$SIZE" "$MTIME" "$f"
    done | sort -nr)

    KEEP=$(echo "$SORTED" | head -n 1 | awk -F'\t' '{print $3}')

    echo "Keeping:"
    stat -f " PATH: %N%n SIZE: %z bytes%n DATE: %Sm" "$KEEP"
    echo

    echo "Other copies:"
    echo

    echo "$SORTED" | tail -n +2 | while IFS=$'\t' read -r SIZE MTIME FILE; do
        echo "Path: $FILE"
        echo "Size: $SIZE bytes"
        echo "Modified: $(stat -f%Sm "$FILE")"
        echo
        read -p "Delete this file? (y/n) " ANS
        if [ "$ANS" = "y" ]; then
            rm "$FILE"
            echo "Deleted."
        else
            echo "Skipped."
        fi
        echo
    done
}

CURRENT=""
BUFFER=""

while IFS=$'\t' read -r HASH FILE; do
    if [ "$HASH" != "$CURRENT" ] && [ -n "$BUFFER" ]; then
        printf "%s" "$BUFFER" | process_duplicate_group
        BUFFER=""
    fi
    CURRENT="$HASH"
    BUFFER="$BUFFER$FILE"$'\n'
done < "$HASHES.dupes"

[ -n "$BUFFER" ] && printf "%s" "$BUFFER" | process_duplicate_group

###############################################################################
# PART 2: Large-file detection + smart grouping
###############################################################################
echo
echo ">>> Detecting large iCloud files…"
LARGE=$(mktemp)

while IFS= read -r FILE; do
    SIZE=$(stat -f%z "$FILE")
    if [ "$SIZE" -ge $((LARGE_THRESHOLD_MB * 1024 * 1024)) ]; then
        MTIME=$(stat -f%m "$FILE")
        EXT="${FILE##*.}"
        printf "%s\t%s\t%s\t%s\n" "$SIZE" "$MTIME" "$EXT" "$FILE" >> "$LARGE"
    fi
done < "$TMP_ALL"

if [ ! -s "$LARGE" ]; then
    echo "No large files found."
    exit 0
fi

# Sort by extension and mod-time
SORTED_LARGE=$(mktemp)
sort -k3,3 -k2,2 "$LARGE" > "$SORTED_LARGE"

echo
echo ">>> Grouping similar large files…"
echo "(extension + modtime within $WINDOW_MINUTES minutes)"

PREV_EXT=""
PREV_TIME=0
GROUP=""

flush_large_group() {
    COUNT=$(printf "%s" "$GROUP" | grep -c .)
    if [ "$COUNT" -le 1 ]; then
        GROUP=""
        return
    fi

    echo
    echo "-------------------------------------------"
    echo "Large-file cluster:"
    FILES_LIST=$(echo "$GROUP" | awk -F'\t' '{print $4}')
    echo "$FILES_LIST" | nl

    echo
    read -p "Delete ALL these files? (y/n) " ALLANS
    if [ "$ALLANS" = "y" ]; then
        echo "$FILES_LIST" | while read -r F; do
            rm "$F"
            echo "Deleted $F"
        done
    else
        echo
        echo "Review individually:"
        echo "$GROUP" | while IFS=$'\t' read -r SIZE MTIME EXT FILE; do
            echo "Path: $FILE"
            echo "Size: $SIZE bytes"
            echo "Modified: $(stat -f%Sm "$FILE")"
            echo
            read -p "Delete? (y/n) " ANS
            [ "$ANS" = "y" ] && rm "$FILE" && echo "Deleted."
            echo
        done
    fi

    GROUP=""
}

while IFS=$'\t' read -r SIZE MTIME EXT FILE; do
    if [ "$EXT" != "$PREV_EXT" ]; then
        flush_large_group
        GROUP="$SIZE\t$MTIME\t$EXT\t$FILE\n"
        PREV_EXT="$EXT"
        PREV_TIME="$MTIME"
        continue
    fi

    DIFF=$((MTIME - PREV_TIME))
    if [ "$DIFF" -le $((WINDOW_MINUTES * 60)) ]; then
        GROUP="${GROUP}$SIZE\t$MTIME\t$EXT\t$FILE\n"
    else
        flush_large_group
        GROUP="$SIZE\t$MTIME\t$EXT\t$FILE\n"
    fi

    PREV_TIME="$MTIME"
done < "$SORTED_LARGE"

flush_large_group

echo
echo "All done."