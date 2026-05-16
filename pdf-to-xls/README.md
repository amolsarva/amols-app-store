# pdf-to-xls

Convert a PDF file to an Excel spreadsheet (.xlsx) in one command — no manual copy-paste required.

## What it does

Extracts text from a PDF using `pdftotext` (from the poppler library), then converts the extracted lines into a structured Excel file using Python and pandas.

The script also auto-installs its own dependencies (Homebrew, poppler, Python packages) if they're not already present.

## Usage

```bash
bash pdftoxls.sh input.pdf output.xlsx
```

Example:

```bash
bash pdftoxls.sh invoice.pdf invoice.xlsx
```

## Requirements

The script installs everything automatically:
- [Homebrew](https://brew.sh) (macOS package manager)
- `poppler` (via Homebrew) — provides `pdftotext`
- Python 3 (pre-installed on macOS)
- `pandas` and `openpyxl` (via pip)

## Notes

- Works best on PDFs with clear tabular text content (invoices, statements, exported reports)
- PDFs that are scanned images (rather than text-based) won't extract well — consider an OCR tool like Tesseract for those
- Each line of the PDF becomes a row; each word becomes a column — you may need to clean up the output in Excel for complex layouts
