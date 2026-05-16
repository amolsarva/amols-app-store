# abbu-to-csv

Export your Apple Contacts (`.abbu` backup file) to a CSV — without iCloud, without third-party apps, just a shell script.

## What it does

Apple's `.abbu` format is actually a directory package containing a SQLite database. This script finds that database, picks the right one if there are multiple candidates, and dumps every contact record to a clean CSV file.

No data leaves your machine. No external dependencies beyond Python 3 (which ships with macOS).

## Usage

```bash
bash abbu_to_csv.sh /path/to/Contacts.abbu
# Output: contacts_export.csv (in the current directory)

bash abbu_to_csv.sh /path/to/Contacts.abbu my_contacts.csv
# Output: my_contacts.csv
```

## How to get the .abbu file

1. Open **Contacts** on your Mac
2. `File → Export → Contacts Archive…`
3. Save the `.abbu` file anywhere

## Requirements

- macOS (any modern version)
- Python 3 (pre-installed on macOS)

## Notes

- The script walks all `.abcddb` and `.sqlite` files inside the `.abbu` package and picks the one with the most contact rows — so it handles unusual or nested Apple backup structures automatically.
- Output columns are raw SQLite columns from `ZABCDRECORD`. Phone numbers, emails, etc. are stored in related tables — this export captures the core record table. For a full join across all contact fields, open the exported DB with any SQLite browser.
- Safe to run repeatedly — each run overwrites the output CSV.
