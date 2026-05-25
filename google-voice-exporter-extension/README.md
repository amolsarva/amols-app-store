# Google Voice Thread Exporter

Local Chrome extension for exporting the currently open Google Voice conversation.

## Install locally

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Click **Load unpacked**.
4. Select this folder:
   `/Users/MrAnonymous/Documents/root/google-voice-exporter-extension`

## Use

1. Open `https://voice.google.com/`.
2. Open the conversation you want to export.
3. Click the extension icon.
4. Choose `JSON`, `CSV`, or `TXT`.
5. Optional: enter a filter such as `718-602-4141`.
6. Click **Export open thread**.

The extension scrolls upward until older messages stop loading, extracts visible message-like DOM nodes, dedupes them, and opens Chrome's save dialog.

## Notes

- JSON is the most reliable format because it preserves attachments and metadata.
- CSV is useful for spreadsheet filtering.
- TXT is best for quick reading or pasting into email.
- Google Voice does not expose a stable public DOM contract, so the extractor uses heuristics. If Google changes the UI, update `content.js` selectors and parsing rules.
- The `Only export messages newer than last run` option stores the last exported message ID in local Chrome extension storage for the current thread URL and filter.
