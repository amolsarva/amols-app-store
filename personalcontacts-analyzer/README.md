# personalcontacts-analyzer

Archive your Gmail headers locally and analyze your communication patterns — who you actually talk to, how often, and when — without ever reading email bodies.

## What it does

Fetches only mail **headers** (From, To, Date, Subject) from Gmail via IMAP and stores them in a local SQLite database. Then analyzes those headers to build a relationship map of your contacts.

Everything runs locally. No email bodies or attachments are ever fetched.

**Analysis outputs:**
- `relationships.csv` — every contact ranked by communication frequency
- `likely_humans.csv` — filtered list of real humans (not mailing lists/bots)
- `contact_monthly_activity.csv` — your communication timeline per contact
- `domain_summary.csv` — breakdown by email domain
- `contact_insights_report.html` — a single self-contained HTML report with charts

## Quick Start

```bash
# Set your Google app password (not your regular password)
export PCA_GMAIL_PASSWORD="xxxx xxxx xxxx xxxx"

# Check auth
python3 pca.py auth-check --account you@gmail.com

# Scan all headers since 2000
python3 pca.py scan --account you@gmail.com --since 2000-01-01

# Export to CSV
python3 pca.py export-csv

# Build the normal and PVT-masked HTML reports
python3 pca.py report
```

## Auth setup

You need a **Google App Password** (not your regular Google password):
1. Go to [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
2. Create a new app password for "Mail"
3. Export it: `export PCA_GMAIL_PASSWORD="the 16-char password"`

If app passwords are blocked by your Workspace policy, OAuth is also supported — see the commands below.

## All commands

```bash
python3 pca.py mailboxes          # list available mailboxes
python3 pca.py auth-check         # verify credentials
python3 pca.py sample             # fetch a small test batch
python3 pca.py scan --since DATE  # full scan from DATE
python3 pca.py resume             # continue an interrupted scan
python3 pca.py export-csv         # export SQLite to CSV
python3 pca.py analyze            # run relationship analysis
python3 pca.py report             # build HTML report
```

## Requirements

```bash
pip install -e .   # installs the pca command
```

Or run directly with `python3 pca.py`.

Requires Python 3.8+. No external API calls — everything stays local.

## Data locations

By default, the tool writes to the sibling data folder:

```text
../../personalcontactsanalyzerDATA/data/
```

That path is resolved relative to this script folder, so moving `mac-scripts` and
`personalcontactsanalyzerDATA` together to a new computer keeps the app working.
If the folder is missing, commands that need local data prompt for the correct
`personalcontactsanalyzerDATA` location. You can also set it directly:

```bash
export PCA_DATA_HOME="/path/to/personalcontactsanalyzerDATA"
```

| File | Path |
|------|------|
| SQLite database | `personalcontactsanalyzerDATA/data/mail_headers.sqlite` |
| CSV export | `personalcontactsanalyzerDATA/data/exports/mail_headers.csv` |
| Analysis outputs | `personalcontactsanalyzerDATA/data/analysis/` |
| HTML report | `personalcontactsanalyzerDATA/data/report/contact_insights_report.html` |
| PVT masked HTML report | `personalcontactsanalyzerDATA/data/report/contact_insights_report_PVT.html` |
