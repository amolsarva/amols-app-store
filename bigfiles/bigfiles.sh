#!/bin/bash

# macOS Heavy Folder Activity Scanner
# Automatically locates the biggest folders, then analyzes them.
# Beautiful colored output + error tolerance + activity heuristics.

AGE_DAYS=90
MAX_FOLDERS=30

# Color palette
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
BLUE="\033[1;34m"

divider() {
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

header() {
    divider
    printf "${BOLD}${CYAN}$1${RESET}\n"
    divider
}

# Seeds derived from your screenshot
SEED_FOLDERS=(
    "/Users/amol/Library"
    "/Users/amol/Desktop"
)

# Function to find large folders
find_large_folders() {
    header "📦 Locating Largest Folders (Top $MAX_FOLDERS)"
    for seed in "${SEED_FOLDERS[@]}"; do
        if [[ -d "$seed" ]]; then
            echo -e "${BLUE}Scanning: $seed${RESET}"
            sudo find "$seed" -type d -maxdepth 4 \
                -exec du -sh {} + 2>/dev/null \
                | sort -hr | head -n "$MAX_FOLDERS"
        else
            echo -e "${RED}Skipping missing seed folder: $seed${RESET}"
        fi
    done | tee /tmp/bigfolders.txt

    echo ""
    header "📁 Preparing folder list"
    awk '{print $2}' /tmp/bigfolders.txt | sort -u > /tmp/scanlist.txt

    echo -e "${GREEN}Found $(wc -l < /tmp/scanlist.txt) candidate heavy folders.${RESET}"
}

# Analyze a folder's recent activity
analyze_folder() {
    local folder="$1"

    divider
    echo -e "${BOLD}${YELLOW}🔍 Checking:${RESET} $folder"

    if [[ ! -d "$folder" ]]; then
        echo -e "${RED}⚠️ Not a directory.${RESET}"
        return
    fi

    # Collect file stats safely
    LAST_MOD=$(sudo find "$folder" -type f -printf "%T@\n" 2>/dev/null \
        | sort -n | tail -1)

    # Convert timestamp if possible
    if [[ -n "$LAST_MOD" ]]; then
        LAST_MOD_HUMAN=$(date -r ${LAST_MOD%.*} 2>/dev/null)
    else
        LAST_MOD_HUMAN="N/A"
    fi

    FILE_COUNT=$(sudo find "$folder" -type f 2>/dev/null | wc -l | tr -d ' ')
    RECENT_WRITES=$(sudo find "$folder" -type f -mtime -"$AGE_DAYS" 2>/dev/null | wc -l | tr -d ' ')
    RECENT_READS=$(sudo find "$folder" -type f -atime -"$AGE_DAYS" 2>/dev/null | wc -l | tr -d ' ')

    echo -e "📁 ${CYAN}Total files:${RESET} $FILE_COUNT"
    echo -e "⏱️  ${CYAN}Last modified:${RESET} $LAST_MOD_HUMAN"
    echo -e "✍️  ${CYAN}Writes in last $AGE_DAYS days:${RESET} $RECENT_WRITES"
    echo -e "👀 ${CYAN}Reads in last $AGE_DAYS days:${RESET} $RECENT_READS"

    # Verdict Engine
    if [[ "$RECENT_WRITES" -eq 0 && "$RECENT_READS" -eq 0 ]]; then
        echo -e "🟠 ${YELLOW}Verdict: PROBABLY SAFE ARCHIVE (no activity)${RESET}"
    elif [[ "$RECENT_WRITES" -lt 10 && "$RECENT_READS" -lt 20 ]]; then
        echo -e "🟡 ${YELLOW}Verdict: LOW ACTIVITY (rarely accessed)${RESET}"
    else
        echo -e "🟢 ${GREEN}Verdict: ACTIVE (system/app actually uses this)${RESET}"
    fi
}

# MAIN SCRIPT
header "🧭 Heavy Folder Activity Auditor (macOS)"

echo -e "${CYAN}This tool identifies large directories and evaluates whether they're alive or abandoned.${RESET}"
echo ""

find_large_folders

header "🧪 Activity Analysis (folder-by-folder)"

while read -r folder; do
    analyze_folder "$folder"
done < /tmp/scanlist.txt

divider
echo -e "${BOLD}${GREEN}✨ Scan complete. Review verdicts above before deleting anything.${RESET}"
divider
