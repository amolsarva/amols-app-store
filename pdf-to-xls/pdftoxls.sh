#!/bin/bash

# Check if Homebrew is installed
if ! command -v brew &>/dev/null; then
    echo "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install pdftotext (from poppler)
if ! command -v pdftotext &>/dev/null; then
    echo "Installing poppler..."
    brew install poppler
fi

# Check if Python3 is installed
if ! command -v python3 &>/dev/null; then
    echo "Installing Python3..."
    brew install python
fi

# Install required Python packages
python3 -m pip install --user pandas openpyxl

# Check input arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 input.pdf output.xlsx"
    exit 1
fi

INPUT_PDF=$1
OUTPUT_XLSX=$2

# Extract text from PDF
pdftotext "$INPUT_PDF" temp.txt

# Convert text to XLSX using Python
python3 - <<EOF
import pandas as pd

# Read extracted text
with open("temp.txt", "r", encoding="utf-8") as f:
    lines = [line.strip().split() for line in f.readlines() if line.strip()]

# Convert to DataFrame
df = pd.DataFrame(lines)

# Save to Excel
df.to_excel("$OUTPUT_XLSX", index=False, header=False)

print(f"Converted {INPUT_PDF} to {OUTPUT_XLSX}")
EOF

# Cleanup
rm temp.txt

