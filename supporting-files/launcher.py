#!/usr/bin/env python3
"""Mac Scripts Launcher

A small desktop launcher for the personal scripts one level up, in
mac-scripts/ (this file itself lives in mac-scripts/supporting-files/ —
see AGENTS.md at the repo root for why). Clicking "Launch" opens Terminal.app
and runs the script there in a real interactive shell — so prompts, progress,
and output all work normally.
"""

import shlex
import subprocess
import tkinter as tk
import tkinter.font as tkfont
from pathlib import Path

# This file lives in mac-scripts/supporting-files/launcher.py — the actual
# tool folders (imessage-cleanup/, voicememocleaner/, etc.) are one level up.
SCRIPTS_DIR = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------
# For each script we define:
#   entry   – the primary file to run, relative to the folder (None = no run)
#   short   – a one-line tagline
#   long    – a fuller description
#   icon    – an emoji glyph for the card
#
# Folders not listed here are hidden from the launcher (Chrome extensions,
# stray duplicates, the empty "downloads" staging folder, node_modules, etc.).

CATALOG = {
    "sunlight": {
        "entry": "run.sh",
        "icon": "☀️",
        "short": "Native Sengled light controls",
        "long": "Sunlight: power, brightness, colors, dedicated white, warm startup and on-device daylight automation, with private recovery backups.",
    },
    "imessage-cleanup": {
        "entry": "imessage_cleanup.sh",
        "icon": "💬",
        "short": "Export & archive iMessage attachments",
        "long": (
            "Extracts photos, videos, and files from your iMessage history, organized by "
            "sender. Exports full per-contact archives (SQLite DB + transcript + media), "
            "refreshes previous exports to pick up new messages, and can delete local copies "
            "to free up iCloud storage."
        ),
    },
    "rescue-hq": {
        "entry": "rescue.sh",
        "icon": "🛟",
        "short": "Google Photos Space Rescue HQ",
        "long": (
            "Everything for a Google Takeout photo rescue in one place. Checks and installs "
            "dependencies, merges a multi-part zip set, sorts the result into PHOTOS/ (one flat "
            "folder to drag-upload) and VIDEOS/<year>/ (flat, for stitching), and repairs common "
            "Takeout damage — Live Photo motion clips, duplicates, screenshots, JSON sidecars, "
            "and files whose extension lies about their contents. Dry-runs every stage and "
            "deletes nothing."
        ),
    },
    "send-birthday-invites": {
        "entry": "run.sh",
        "icon": "🎂",
        "short": "Send birthday invites via Messages",
        "long": (
            "Sends (and follows up on) birthday invites through Messages.app, with a dry-run "
            "mode to preview before anything goes out. Keeps its own sent-log in this folder."
        ),
    },
    "whatsapp-campaigns": {
        "entry": "run.sh",
        "icon": "🟢",
        "short": "Search and message WhatsApp contacts",
        "long": (
            "Finds private chats where a phrase appeared, lets you review each person and "
            "matching context, then simulates or sends a separate message to each. Archives "
            "campaigns, checks replies, and prepares bumps for people who did not respond. "
            "Dry-run is always the default."
        ),
    },
    "voicememocleaner": {
        "entry": "VOICEMEMOCLEANER.sh",
        "icon": "🎙️",
        "short": "Export & compress Voice Memos",
        "long": (
            "Exports every Voice Memo — full-quality original plus a smaller compressed copy — "
            "into one folder, along with title, date, duration, and GPS location metadata where "
            "available. Read-only against Voice Memos itself; nothing in the app is touched. "
            "Reruns are incremental, so refreshing after new recordings is fast."
        ),
    },
    "abbu-to-csv": {
        "entry": "abbu_to_csv.sh",
        "icon": "📇",
        "short": "Export Apple Contacts to CSV",
        "long": (
            "Converts the .abbu backup that Apple Contacts creates into a plain CSV "
            "spreadsheet — readable in Excel, importable anywhere, and not locked inside "
            "Apple's format."
        ),
    },
    "bigfiles": {
        "entry": "bigfiles.sh",
        "icon": "🗂️",
        "short": "Find disk hogs",
        "long": (
            "Scans your Mac and lists the largest folders and files by size, so you can see "
            "where the disk space actually went — old simulators, unused VMs, forgotten videos."
        ),
    },
    "cleanicloud": {
        "entry": "cleanicloud.sh",
        "icon": "☁️",
        "short": "Clean up iCloud Drive",
        "long": (
            "Finds duplicate and large files in your iCloud Drive and walks you through "
            "deleting them interactively — useful when iCloud is full and Manage Storage "
            "isn't telling the whole story."
        ),
    },
    "cpu-guard": {
        "entry": "cpu-guard-install.sh",
        "icon": "🛡️",
        "short": "Stop runaway background processes",
        "long": (
            "Installs a background watcher that throttles macOS background processes when they "
            "stay hot too long, using quiet action-only notifications instead of repeated alerts."
        ),
    },
    "drive-dedup": {
        "entry": "run.sh",
        "icon": "💽",
        "short": "Deduplicate an external drive",
        "long": (
            "Scans an external drive for duplicates and consolidates everything into a clean "
            "folder structure. Runs in two phases: first it maps what's there, then it moves "
            "things around."
        ),
    },
    "github-autopush": {
        "entry": "github-autopush-manager.sh",
        "icon": "🐙",
        "short": "Auto-push git repos to GitHub",
        "long": (
            "Installs a background LaunchAgent that automatically commits and pushes your git "
            "repos to GitHub on a schedule. Set it up once and your projects stay synced "
            "without you remembering to push."
        ),
    },
    "mac-migrator": {
        "entry": "mac_background_migrator.sh",
        "icon": "📦",
        "short": "Pack up your Mac for migration",
        "long": (
            "Bundles your Mac's configuration — shell settings, LaunchAgents, background tasks, "
            "dotfiles — into a portable archive you can restore on a new machine. Saves hours "
            "of reconfiguring from scratch."
        ),
    },
    "pdf-to-xls": {
        "entry": "pdftoxls.sh",
        "icon": "📄",
        "short": "Convert PDF tables to Excel",
        "long": (
            "Pulls tabular data out of a PDF and writes it to a spreadsheet — handy for "
            "statements, reports, and invoices that only come as PDFs."
        ),
    },
    "personalcontacts-analyzer": {
        "entry": "pca.py",
        "icon": "🔍",
        "short": "Analyze your contacts & relationships",
        "long": (
            "Reads your Contacts database and produces stats about your network — who you have "
            "info on, gaps in your address book, duplicates, and missing emails or phone numbers."
        ),
    },
    "screenshot-tidy": {
        "entry": "screenshot-tidy-install.sh",
        "icon": "📸",
        "short": "Auto-organize screenshots",
        "long": (
            "Installs a background watcher that moves new Desktop screenshots into dated folders "
            "automatically, so they never pile up on your Desktop."
        ),
    },
    "repo2audiobook": {
        "entry": "setup.sh",
        "icon": "🎧",
        "short": "Turn a GitHub repo into a narrated audiobook",
        "long": (
            "Converts a GitHub repository into a narrated audiobook/podcast using OpenAI TTS, "
            "with modes like investor diligence, technical deep-dive, and beginner. Run setup "
            "once to install dependencies, then run repo2audiobook.py with a repo URL."
        ),
    },
}

# The catalog is generated from each tool's tool.json by publish/build_catalog.py.
# The dict above is only a fallback if that file is missing.
try:
    import json as _json
    CATALOG = _json.loads((Path(__file__).resolve().parent / "catalog" / "launcher.json").read_text())
except Exception:
    pass

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
BG          = "#ececee"
CARD_BG     = "#ffffff"
CARD_HOVER  = "#fbfbfd"
CARD_BORDER = "#dcdce1"
HEAD_BG     = "#ffffff"
ACCENT      = "#0a84ff"      # macOS system blue
ACCENT_DK   = "#0060df"
ACCENT_TXT  = "#ffffff"
TEXT        = "#1d1d1f"
SUBTEXT     = "#3c3c43"
DIMTEXT     = "#86868b"
ICON_BG     = "#f1f1f4"


def _font(size, weight="normal"):
    fams = set(tkfont.families())
    for cand in ("SF Pro Text", "Helvetica Neue", "Helvetica", "Arial"):
        if cand in fams:
            return (cand, size, weight)
    return ("TkDefaultFont", size, weight)


# ---------------------------------------------------------------------------
# Running scripts in Terminal.app
# ---------------------------------------------------------------------------
def run_in_terminal(folder: Path, entry: str):
    """Open Terminal.app and run the entry script in the folder."""
    script_path = folder / entry
    if not script_path.exists():
        subprocess.Popen(["open", str(folder)])
        return

    ext = script_path.suffix.lower()
    if ext == ".py":
        runner = f"python3 {shlex.quote(str(script_path))}"
    elif ext in (".sh", ".bash", ".command"):
        runner = f"bash {shlex.quote(str(script_path))}"
    else:
        runner = shlex.quote(str(script_path))

    # cd into the folder first so relative paths inside the script work.
    cmd = f"cd {shlex.quote(str(folder))} && {runner}"

    # Escape for embedding inside an AppleScript double-quoted string.
    cmd_for_osa = cmd.replace("\\", "\\\\").replace('"', '\\"')
    osa = (
        'tell application "Terminal"\n'
        "    activate\n"
        f'    do script "{cmd_for_osa}"\n'
        "end tell"
    )
    subprocess.Popen(["osascript", "-e", osa])


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Mac Scripts")
        self.configure(bg=BG)
        self.geometry("620x720")
        self.minsize(520, 420)

        self.f_title = _font(20, "bold")
        self.f_sub   = _font(12)
        self.f_name  = _font(14, "bold")
        self.f_body  = _font(11)
        self.f_dim   = _font(10)
        self.f_btn   = _font(11, "bold")
        self.f_icon  = _font(20)

        self._cards = []
        self._query = tk.StringVar()
        self._query.trace_add("write", lambda *_: self._filter())

        self._build()
        self._load()

    # ---- chrome -----------------------------------------------------------
    def _build(self):
        head = tk.Frame(self, bg=HEAD_BG)
        head.pack(fill="x")
        inner = tk.Frame(head, bg=HEAD_BG, padx=22, pady=18)
        inner.pack(fill="x")

        title_row = tk.Frame(inner, bg=HEAD_BG)
        title_row.pack(fill="x")
        tk.Label(title_row, text="Mac Scripts", font=self.f_title,
                 fg=TEXT, bg=HEAD_BG).pack(side="left")
        self._btn(title_row, "Open folder", self._open_folder,
                  primary=False).pack(side="right")

        tk.Label(inner,
                 text="Personal automation scripts. Click Launch to run one in Terminal.",
                 font=self.f_sub, fg=DIMTEXT, bg=HEAD_BG).pack(anchor="w", pady=(4, 12))

        # Search box
        search = tk.Frame(inner, bg="#f1f1f4", highlightthickness=1,
                          highlightbackground=CARD_BORDER)
        search.pack(fill="x")
        tk.Label(search, text="⌕", font=self.f_name, fg=DIMTEXT,
                 bg="#f1f1f4").pack(side="left", padx=(10, 2))
        self._search_entry = tk.Entry(
            search, textvariable=self._query, font=self.f_body,
            bg="#f1f1f4", fg=TEXT, insertbackground=TEXT,
            relief="flat", bd=0)
        self._search_entry.pack(side="left", fill="x", expand=True,
                                ipady=7, padx=(0, 10))

        tk.Frame(self, bg=CARD_BORDER, height=1).pack(fill="x")

        # Scroll area
        wrap = tk.Frame(self, bg=BG)
        wrap.pack(fill="both", expand=True)
        self._canvas = tk.Canvas(wrap, bg=BG, highlightthickness=0, bd=0)
        sb = tk.Scrollbar(wrap, orient="vertical", command=self._canvas.yview)
        self._inner = tk.Frame(self._canvas, bg=BG)
        self._inner.bind(
            "<Configure>",
            lambda e: self._canvas.configure(scrollregion=self._canvas.bbox("all")))
        self._win = self._canvas.create_window((0, 0), window=self._inner, anchor="nw")
        self._canvas.bind(
            "<Configure>", lambda e: self._canvas.itemconfig(self._win, width=e.width))
        self._canvas.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self._canvas.pack(side="left", fill="both", expand=True)
        self.bind_all("<MouseWheel>",
                      lambda e: self._canvas.yview_scroll(int(-1 * (e.delta / 120)), "units"))

        # Status bar
        self._status = tk.StringVar()
        bar = tk.Frame(self, bg=HEAD_BG)
        bar.pack(fill="x", side="bottom")
        tk.Frame(bar, bg=CARD_BORDER, height=1).pack(fill="x")
        tk.Label(bar, textvariable=self._status, font=self.f_dim,
                 fg=DIMTEXT, bg=HEAD_BG, anchor="w",
                 padx=22, pady=8).pack(fill="x")

    def _btn(self, parent, text, cmd, primary=True):
        bg = ACCENT if primary else "#e8e8ec"
        fg = ACCENT_TXT if primary else SUBTEXT
        hov = ACCENT_DK if primary else "#dcdce1"
        b = tk.Label(parent, text=text, font=self.f_btn, fg=fg, bg=bg,
                     padx=16, pady=7, cursor="hand2")
        b.bind("<Enter>", lambda e: b.configure(bg=hov))
        b.bind("<Leave>", lambda e: b.configure(bg=bg))
        b.bind("<Button-1>", lambda e: cmd())
        return b

    # ---- data -------------------------------------------------------------
    def _load(self):
        for w in self._inner.winfo_children():
            w.destroy()
        self._cards = []

        shown = 0
        for name, meta in CATALOG.items():
            folder = SCRIPTS_DIR / name
            if not folder.is_dir():
                continue
            self._add_card(name, folder, meta)
            shown += 1

        if shown == 0:
            tk.Label(self._inner, text="No scripts found.",
                     font=self.f_body, fg=SUBTEXT, bg=BG, pady=40).pack()
        self._status.set(f"{shown} scripts  •  {SCRIPTS_DIR}")

    def _add_card(self, name, folder, meta):
        entry = meta["entry"]
        runnable = bool(entry) and (folder / entry).exists()

        outer = tk.Frame(self._inner, bg=BG, padx=14, pady=6)
        outer.pack(fill="x")

        card = tk.Frame(outer, bg=CARD_BG, highlightthickness=1,
                        highlightbackground=CARD_BORDER)
        card.pack(fill="x")

        # icon column
        icon = tk.Label(card, text=meta.get("icon", "•"), font=self.f_icon,
                        bg=ICON_BG, fg=TEXT, width=3, height=3)
        icon.pack(side="left", fill="y")

        body = tk.Frame(card, bg=CARD_BG, padx=14, pady=12)
        body.pack(side="left", fill="both", expand=True)

        tk.Label(body, text=meta["short"], font=self.f_name, fg=TEXT,
                 bg=CARD_BG, anchor="w").pack(anchor="w")
        tk.Label(body, text=name + (f"  ›  {entry}" if runnable else "  (no script)"),
                 font=self.f_dim, fg=DIMTEXT, bg=CARD_BG,
                 anchor="w").pack(anchor="w", pady=(1, 0))
        tk.Label(body, text=meta["long"], font=self.f_body, fg=SUBTEXT,
                 bg=CARD_BG, wraplength=350, justify="left",
                 anchor="w").pack(anchor="w", pady=(6, 0))

        right = tk.Frame(card, bg=CARD_BG, padx=14)
        right.pack(side="right", fill="y")
        if runnable:
            btn = self._btn(right, "Launch",
                            lambda f=folder, e=entry: run_in_terminal(f, e))
        else:
            btn = self._btn(right, "Open",
                            lambda f=folder: subprocess.Popen(["open", str(f)]),
                            primary=False)
        btn.pack(expand=True)

        self._cards.append((name, meta["short"], meta["long"], outer))

    # ---- behavior ---------------------------------------------------------
    def _filter(self):
        q = self._query.get().lower().strip()
        for name, short, long_desc, outer in self._cards:
            hit = not q or q in name.lower() or q in short.lower() or q in long_desc.lower()
            if hit:
                outer.pack(fill="x")
            else:
                outer.pack_forget()

    def _open_folder(self):
        subprocess.Popen(["open", str(SCRIPTS_DIR)])


if __name__ == "__main__":
    App().mainloop()
