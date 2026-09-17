<div align="center">

# 🗂️ Amol's App Store

**Field notes turned into little apps.**

A shelf of things I built to solve my own real problems — preserve the record, clean the cloud attic, keep repos moving, and stop runaway daemons — now shared so you can use them too.

[![Browse the App Store](https://img.shields.io/badge/Browse-amolsarva.com%2Fscripts-2d6a4f?style=for-the-badge)](https://amolsarva.com/scripts)
[![GitHub](https://img.shields.io/badge/Source-github.com%2Famolsarva-171717?style=for-the-badge&logo=github)](https://github.com/amolsarva)

</div>

---

## 👋 New here? Start with this

There are three kinds of things in this collection, and each one is "installed" differently. Find the type you want below — you don't need to be a programmer for any of them.

| If it's a… | You get going by… | Skill needed |
|------------|-------------------|--------------|
| 🌐 **Web app** | Just clicking a link and using it in your browser | None |
| 🧩 **Chrome extension** | Adding it to Chrome once, then it lives in your toolbar | A little |
| 🖥️ **Mac script** | Downloading a file and double-clicking (or pasting one line into Terminal) | A little |

If a tool looks useful but the steps feel intimidating, the easiest path is always to open [amolsarva.com/scripts](https://amolsarva.com/scripts) — every tool there has a "Get" button that takes you straight to the right place.

---

## 🌐 Web apps — just open them

No download, no install. Click and go.

| App | What it does |
|-----|--------------|
| 🎙️ **[DadsBot](https://dadsbot.vercel.app)** | A warm, biographer-style interview app for recording someone's life story — records, transcribes, asks good follow-up questions, and remembers past sessions. |
| 💤 **[OpenSnoRE](https://amolsarva.github.io/OpenSNORE/)** | A playful sleep-audio lab: fake snores for boring moments, plus real guided exercises for quieter nights. |
| 🕵️ **[OpenSore](https://github.com/amolsarva/opensore)** | AI-assisted workplace-evidence investigator for lawyers, HR, and compliance — turns scattered emails and chats into source-backed timelines. |

---

## 🧩 Chrome extensions — add once, use forever

Each folder has a README, but the short version: open `chrome://extensions`, turn on **Developer mode** (top-right toggle), click **Load unpacked**, and pick the extension's folder. That's it.

| Extension | What it does |
|-----------|--------------|
| ☎️ **[google-voice-exporter-extension](./google-voice-exporter-extension/)** | Exports the Google Voice conversation you have open as JSON, CSV, or TXT — so your texts aren't trapped behind someone else's interface. |
| 📎 **[gmail-attachment-wingman-extension](./gmail-attachment-wingman-extension/)** | Grabs attachments out of Gmail in bulk so you're not saving them one click at a time. |
| 🟢 **[meet-tab-sidecar-extension](./meet-tab-sidecar-extension/)** | Join a Google Meet while a second browser tab handles the audio, intro, or presentation work. |

---

## 🖥️ Mac scripts — small tools that keep the machine clean

These are short, readable scripts. Each folder has a README with exact steps. None of them delete anything without asking first.

### Storage & cleanup

| Tool | What it does |
|------|--------------|
| ☁️ **[cleanicloud](./cleanicloud/)** | Finds iCloud duplicates and suspiciously large files, then asks before removing anything. |
| 📦 **[bigfiles](./bigfiles/)** | Shows you the biggest folders on your Mac and whether they're still in use — a map before you clean. |
| 💿 **[drive-dedup](./drive-dedup/)** | Scans an external drive for duplicates and plans a clean, consolidated folder structure. |
| 💬 **[imessage-cleanup](./imessage-cleanup/)** | Turns Messages chaos into tidy per-person archives (transcript, media, database, manifest) and frees up iCloud. |
| 📸 **[screenshot-tidy](./screenshot-tidy/)** | Auto-moves screenshots off your Desktop into a real Screenshots folder. |

### Contacts & data

| Tool | What it does |
|------|--------------|
| 📇 **[abbu-to-csv](./abbu-to-csv/)** | Turns an Apple Contacts `.abbu` backup into a readable CSV. |
| 📊 **[personalcontacts-analyzer](./personalcontacts-analyzer/)** | Archives Gmail headers locally and builds relationship/activity reports — without touching message bodies. |
| 📄 **[pdf-to-xls](./pdf-to-xls/)** | Converts a PDF into a rough Excel spreadsheet for table recovery. |

### Messaging & people

| Tool | What it does |
|------|--------------|
| 💬 **[iMessage Campaign Studio](./send-birthday-invites/)** | Searches private iMessage history by phrase, reviews recipients, sends separately, archives campaigns, and prepares reply-aware bumps. |
| 🟢 **[WhatsApp Campaign Studio](./whatsapp-campaigns/)** | Searches available private WhatsApp Web history, reviews recipients and context, simulates or sends separately, archives results, and bumps unanswered recipients. |
| 🌉 **[codex-openclaw-simulator](./codex-openclaw-simulator/)** | A careful local CLI bridge for sending messages via iMessage or WhatsApp — every recipient must be allowlisted, sends are confirmed by default, and everything is logged. |

### Keeping the machine healthy

| Tool | What it does |
|------|--------------|
| 🔥 **[cpu-guard](./cpu-guard/)** | Quietly stops noisy macOS background processes when they sustain high CPU. |
| ↻ **[github-autopush](./github-autopush/)** | Auto-pushes your local git repos to GitHub in the background, so good experiments don't live on one laptop. |
| 🖥️ **[mac-migrator](./mac-migrator/)** | Bundles your Mac's config, LaunchAgents, and automation for a clean move to a new machine. |
| 🚀 **[mac-scripts-launcher](./mac-scripts-launcher/)** | A native-feeling little app to browse and launch everything in this collection from one window. |

---

## 🎨 Creative experiments

For the odder, more fun corners of the shelf.

| Tool | What it does |
|------|--------------|
| 🎧 **[repo2audiobook](./repo2audiobook/)** | Turns any GitHub repository into a narrated audiobook/podcast — ingests the code, writes chapters, and renders speech. |

---

## 🚀 How to run a Mac script (step by step)

Never used a script before? Here's the whole thing, slowly:

1. **Download the tool.** On [amolsarva.com/scripts](https://amolsarva.com/scripts), find the tool and click **Get** — or click the folder above and download the `.sh`/`.command` file.
2. **Read what it does.** Every folder has a README. These scripts are short on purpose so you (or a friend) can actually read them before running.
3. **Run it.** Many are `.command` files — just **double-click** them and Terminal opens and runs it. For `.sh` files, open Terminal, type `bash ` (with a space), drag the file in, and press Return.
4. **Nothing is deleted without asking.** Every cleanup tool shows you the mess first and waits for your "yes."

> 💡 The first time you double-click a downloaded script, macOS may say it "can't be opened because it's from an unidentified developer." Right-click the file → **Open** → **Open** to get past that one time.

---

## 🧭 For developers

```bash
git clone https://github.com/amolsarva/amols-app-store.git
cd amols-app-store/<tool-name>
bash run.sh   # or: python3 <script>.py — check the folder's README
```

Everything runs on a standard macOS setup with no exotic dependencies. Scripts use dry-run modes and copy-before-change wherever possible.

---

## 🛠️ Philosophy

These are practical tools, not polished products. They're built to:

- Run on a normal Mac with no weird setup
- **Ask before deleting** anything
- Leave your data intact (copies before changes, dry-runs where possible)
- Stay **readable** — short enough to audit before you run them

---

<div align="center">

Built in the spirit of field notes: observe the mess, make the tool, put it where people can try it.

**[amolsarva.com](https://amolsarva.com)** · **[github.com/amolsarva](https://github.com/amolsarva)**

</div>
