#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 /path/to/Contacts.abbu [output.csv]"
  exit 1
fi

ABBU_PATH="$1"
OUTCSV="${2:-contacts_export.csv}"

python3 - "$ABBU_PATH" "$OUTCSV" <<'PY'
import os, sys, sqlite3, csv

abbu = sys.argv[1]
out_csv = sys.argv[2]

if not os.path.isdir(abbu):
    sys.stderr.write(f"Error: {abbu} is not a directory-like .abbu package.\n")
    sys.exit(1)

# --- 1. Locate ALL candidate DB files ---
candidates = []
for root, _, files in os.walk(abbu):
    for f in files:
        if f.endswith(".abcddb") or f.endswith(".sqlite"):
            candidates.append(os.path.join(root, f))

if not candidates:
    sys.stderr.write("No SQLite or ABCDDB files found inside the .abbu.\n")
    sys.exit(1)

sys.stderr.write("Found candidate DBs:\n")
for c in candidates:
    sys.stderr.write(f"  - {c}\n")


# --- 2. Pick the one containing actual contact rows ---
def count_records(db_path):
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM ZABCDRECORD")
        count = cur.fetchone()[0]
        conn.close()
        return count
    except Exception:
        return 0

db_scores = [(db, count_records(db)) for db in candidates]
db_scores.sort(key=lambda x: x[1], reverse=True)

best_db, best_count = db_scores[0]

sys.stderr.write(f"\nChosen DB: {best_db}\n")
sys.stderr.write(f"ZABCDRECORD count: {best_count}\n\n")

if best_count == 0:
    sys.stderr.write("No contacts found in any DB. Wrong dump or new schema version.\n")
    sys.exit(1)

# --- 3. Dump ALL fields to avoid join loss ---
conn = sqlite3.connect(best_db)
cur = conn.cursor()

# Get complete table list
tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]

# Many tables → correct DB
if "ZABCDRECORD" not in tables:
    sys.stderr.write("DB does not contain ZABCDRECORD – unexpected schema.\n")
    sys.exit(1)

# Get *all* columns from the record table (no joins)
cur.execute("PRAGMA table_info(ZABCDRECORD)")
columns = [row[1] for row in cur.fetchall()]

sql = f"SELECT {', '.join(columns)} FROM ZABCDRECORD"

sys.stderr.write(f"Exporting {best_count} contacts...\n")

cur.execute(sql)

with open(out_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(columns)
    for row in cur:
        writer.writerow(row)

conn.close()
sys.stderr.write(f"Done → {out_csv}\n")
PY