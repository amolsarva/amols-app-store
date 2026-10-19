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

# Python + pandas/openpyxl: a private venv managed by python-guard (Homebrew's Python refuses
# `pip install --user`, and the venv is rebuilt automatically after Python upgrades).
PY="$(/bin/bash "$(cd "$(dirname "$0")" && pwd)/../python-guard/pyenv.sh" venv pdf-to-xls --pkg pandas --pkg openpyxl)" || {
  echo "Could not set up Python (see ../python-guard/run.sh doctor)"; exit 1; }

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
"$PY" - <<EOF
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

