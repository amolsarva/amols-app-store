# WhatsApp Campaign Studio

A local terminal app for finding private WhatsApp conversations containing a word
or phrase, reviewing every recipient and matching context, composing one message,
sending it separately, archiving the campaign, detecting replies, and preparing a
bump for people who did not reply.

## Install and verify

```bash
./install_and_test.sh
```

The installer checks Node.js, installs pinned dependencies, reuses system Chrome,
creates private local folders, runs tests, and performs an environment doctor.

## Run

```bash
./run.sh             # asks: Dry run or Live mode
./run.sh --dry-run   # optionally bypass the launch prompt
./run.sh --live      # optionally bypass the launch prompt
```

On first launch, scan the terminal QR code from **WhatsApp → Settings → Linked
Devices → Link a Device**. The session remains in `.wwebjs_auth/` and is never
committed. Searches are limited to history made available to WhatsApp Web; very old
phone-only history may not be available to any linked-device tool.

On macOS, discovery primarily reads the native WhatsApp app's `ChatStorage.sqlite`
in read-only mode. This provides much deeper history than the Web linked-device
cache. WhatsApp Web is used as the authenticated sending transport. If the native
database is absent or unreadable, the app falls back to its Web history scan.
The app never trusts WhatsApp's partial global search count. Every search also scans
all messages currently available in every private chat and merges/deduplicates the
results. `fallbackMessagesPerChat` is `0` for all available messages; set a positive
number only if you deliberately want a faster, shallower scan.
Group chats are searched too, but groups are never recipients: only the individual
author of a matching group message is offered as a separate private recipient. Your
own matching group messages are ignored because they do not identify another person.

## Safety and records

- Group chats, communities, channels, and status/broadcast IDs are excluded.
- Every private recipient is selected and reviewable before composition.
- Every launch asks whether the session should be Dry run or Live mode, unless a
  mode flag was supplied explicitly.
- Dry-run never calls `sendMessage`.
- Before each recipient, the exact destination and message are shown. Choose
  `y` (yes), `n` (skip), `a` (yes to this and all remaining), or `q` (stop).
- Live sends are sequential with randomized delays configured in `config.json`.
- Campaign JSON lives in `campaign-archive/` (mode `0700`, records `0600`).
- Operational JSONL logs live in `logs/whatsapp-campaign-studio.jsonl`.
- Logs contain search terms, recipient IDs, status, and a message hash—not message bodies.

## Important limitation

This uses the unofficial `whatsapp-web.js` library. It is not endorsed by WhatsApp,
and its own maintainers warn that unofficial clients can be blocked. Use it only for
people you already know and expect to hear from you; do not use purchased lists,
scraping, or unsolicited bulk messaging. The official Business/Cloud API is the
right choice for a consent-based commercial program, but it does not provide the
personal-history discovery workflow this tool needs.
