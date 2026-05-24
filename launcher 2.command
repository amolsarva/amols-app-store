#!/usr/bin/env python3
"""Mac Scripts Launcher — clean, compact UI"""

import tkinter as tk
from tkinter import scrolledtext
import subprocess
import threading
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent

# Real descriptions for each script folder
DESCRIPTIONS = {
    "abbu-to-csv": (
        "Export Apple Contacts",
        "Takes the .abbu backup file that Apple Contacts creates and converts it into a plain CSV "
        "spreadsheet. Useful when you want to open your contacts in Excel, import them somewhere else, "
        "or just have a readable backup that isn't locked inside Apple's format."
    ),
    "bigfiles": (
        "Find disk hogs",
        "Scans your Mac and lists the largest folders and files, sorted by size. Helps you figure out "
        "where your disk space actually went — usually it's old Xcode simulators, unused VMs, or "
        "forgotten video files buried three folders deep."
    ),
    "cleanicloud": (
        "Clean up iCloud Drive",
        "Finds duplicate files and large items in your iCloud Drive and walks you through deleting them "
        "interactively. Useful when iCloud is full and the 'Manage Storage' screen in System Settings "
        "isn't telling you the full story."
    ),
    "cpu-guard": (
        "Stop runaway background processes",
        "Watches your CPU in the background and alerts you when a process starts hogging it — things "
        "like mds_stores, bird, or Spotlight going haywire. You can set a threshold and it'll notify "
        "you (or kill the offender) instead of letting your fans spin up for hours unnoticed."
    ),
    "drive-dedup": (
        "Deduplicate an external drive",
        "Scans an external hard drive for duplicate files, then consolidates everything into a clean "
        "folder structure. Runs in two phases: first it maps what's there, then it moves things around. "
        "Good for cleaning up drives that have been backed up to multiple times without a plan."
    ),
    "github-autopush": (
        "Auto-push git repos to GitHub",
        "Installs a background LaunchAgent that automatically commits and pushes your git repos to "
        "GitHub on a schedule. Set it up once and your local projects stay synced to GitHub without "
        "you having to remember to push."
    ),
    "imessage-cleanup": (
        "Export & archive iMessage attachments",
        "The big one. Extracts photos, videos, and files from your iMessage history, organized by "
        "sender. Can export full per-contact archives (SQLite DB + transcript + media), refresh "
        "previous exports to pick up new messages, and optionally delete the local copies from your "
        "Mac to free up iCloud storage. Currently running 1.6 GB of attachments."
    ),
    "mac-migrator": (
        "Pack up your Mac for migration",
        "Bundles your Mac's configuration — shell settings, LaunchAgents, background tasks, dotfiles "
        "— into a portable archive you can restore on a new machine. Saves the hours of re-configuring "
        "everything from scratch when you get a new Mac."
    ),
    "personalcontacts-analyzer": (
        "Analyze your contacts & relationships",
        "Reads your Contacts database and produces stats and insights about your network — who you "
        "actually have info on, gaps in your address book, duplicate entries, and so on. Useful for "
        "a contacts cleanup or figuring out who's missing an email or phone number."
    ),
    "screenshot-tidy": (
        "Auto-organize screenshots",
        "Watches your Desktop for new screenshots and automatically moves them into dated folders so "
        "they don't pile up. Installs as a background watcher so it runs silently — you take a "
        "screenshot, it disappears from your Desktop into a tidy folder within seconds."
    ),
}

# Entry points per folder (tried in order)
ENTRY_POINTS = ["run.sh", "main.py", "run.py"]

# Colors — light, clean, Mac-like
BG          = "#f5f5f5"
CARD_BG     = "#ffffff"
CARD_BORDER = "#e0e0e0"
ACCENT      = "#2d6a4f"
ACCENT_TXT  = "#ffffff"
TEXT        = "#1a1a1a"
SUBTEXT     = "#555555"
DIMTEXT     = "#999999"
BTN_BG      = "#e8e8e8"
BTN_HOV     = "#d8d8d8"
OUT_BG      = "#1e1e1e"
OUT_FG      = "#d4d4d4"

F_TITLE  = ("Helvetica Neue", 15, "bold")
F_NAME   = ("Helvetica Neue", 12, "bold")
F_SUB    = ("Helvetica Neue", 11, "bold")
F_BODY   = ("Helvetica Neue", 11)
F_DIM    = ("Helvetica Neue", 10)
F_MONO   = ("Menlo", 11)


def find_entry(folder: Path):
    for ep in ENTRY_POINTS:
        p = folder / ep
        if p.exists():
            return p
    return folder   # fallback: open in Finder


def discover():
    if not SCRIPTS_DIR.exists():
        return []
    results = []
    for p in sorted(SCRIPTS_DIR.iterdir()):
        if p.name.startswith(".") or not p.is_dir():
            continue
        entry = find_entry(p)
        results.append((p.name, entry))
    return results


def run_script(path: Path, text_widget):
    def _log(msg, tag="normal"):
        text_widget.configure(state="normal")
        text_widget.insert(tk.END, msg, tag)
        text_widget.see(tk.END)
        text_widget.configure(state="disabled")

    def _go():
        _log(f"▶  {path}\n\n", "accent")
        try:
            if path.is_dir():
                subprocess.Popen(["open", str(path)])
                _log("Opened in Finder.\n", "ok")
                return
            ext = path.suffix.lower()
            if ext == ".py":
                cmd = ["python3", str(path)]
            elif ext in (".sh", ".bash"):
                cmd = ["bash", str(path)]
            else:
                cmd = [str(path)]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True,
                                    cwd=str(path.parent))
            for line in proc.stdout:
                _log(line)
            proc.wait()
            tag = "ok" if proc.returncode == 0 else "err"
            _log(f"\n{'✓' if proc.returncode == 0 else '✗'}  Exit {proc.returncode}\n", tag)
        except Exception as e:
            _log(f"\n✗  {e}\n", "err")

    threading.Thread(target=_go, daemon=True).start()


class OutputWin(tk.Toplevel):
    def __init__(self, parent, name):
        super().__init__(parent)
        self.title(name)
        self.configure(bg=OUT_BG)
        self.geometry("660x360")
        self.minsize(400, 200)

        bar = tk.Frame(self, bg=OUT_BG, padx=12, pady=8)
        bar.pack(fill="x")
        tk.Label(bar, text=name, font=F_SUB, fg=OUT_FG, bg=OUT_BG).pack(side="left")
        tk.Button(bar, text="Close", command=self.destroy,
                  font=F_DIM, fg=DIMTEXT, bg="#333", activebackground="#444",
                  relief="flat", bd=0, padx=8, pady=3, cursor="hand2").pack(side="right")

        self.txt = scrolledtext.ScrolledText(
            self, font=F_MONO, bg=OUT_BG, fg=OUT_FG,
            insertbackground=OUT_FG, relief="flat",
            state="disabled", wrap="word", padx=12, pady=8)
        self.txt.pack(fill="both", expand=True, padx=6, pady=(0, 6))
        self.txt.tag_config("accent", foreground="#7ec8a4")
        self.txt.tag_config("ok",     foreground="#6fcf97")
        self.txt.tag_config("err",    foreground="#eb5757")


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Mac Scripts")
        self.configure(bg=BG)
        self.geometry("560x640")
        self.minsize(480, 300)
        self.resizable(True, True)
        self._build()
        self._load()

    def _build(self):
        # Header
        hdr = tk.Frame(self, bg=BG, padx=18, pady=14)
        hdr.pack(fill="x")
        tk.Label(hdr, text="Mac Scripts", font=F_TITLE,
                 fg=TEXT, bg=BG).pack(side="left")
        tk.Button(hdr, text="⟳", command=self._load,
                  font=F_BODY, fg=SUBTEXT, bg=BTN_BG,
                  activebackground=BTN_HOV, relief="flat",
                  bd=0, padx=10, pady=4, cursor="hand2").pack(side="right")
        tk.Button(hdr, text="Open folder", command=self._open_folder,
                  font=F_DIM, fg=SUBTEXT, bg=BTN_BG,
                  activebackground=BTN_HOV, relief="flat",
                  bd=0, padx=10, pady=4, cursor="hand2").pack(side="right", padx=(0, 6))

        # Search
        sf = tk.Frame(self, bg=BG, padx=18, pady=0)
        sf.pack(fill="x")
        self._sq = tk.StringVar()
        self._sq.trace_add("write", lambda *_: self._filter())
        se = tk.Entry(sf, textvariable=self._sq, font=F_BODY,
                      bg=CARD_BG, fg=TEXT, insertbackground=TEXT,
                      relief="solid", bd=1)
        se.pack(fill="x", ipady=6)
        se.insert(0, "Search…")
        se.bind("<FocusIn>",  lambda e: se.delete(0, "end") if se.get() == "Search…" else None)
        se.bind("<FocusOut>", lambda e: se.insert(0, "Search…") if not se.get() else None)

        tk.Frame(self, bg=CARD_BORDER, height=1).pack(fill="x", pady=(10, 0))

        # Scroll canvas
        wrap = tk.Frame(self, bg=BG)
        wrap.pack(fill="both", expand=True)
        self._canvas = tk.Canvas(wrap, bg=BG, highlightthickness=0, bd=0)
        sb = tk.Scrollbar(wrap, orient="vertical", command=self._canvas.yview)
        self._inner = tk.Frame(self._canvas, bg=BG)
        self._inner.bind("<Configure>",
            lambda e: self._canvas.configure(scrollregion=self._canvas.bbox("all")))
        self._canvas.create_window((0, 0), window=self._inner, anchor="nw")
        self._canvas.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self._canvas.pack(side="left", fill="both", expand=True)
        self.bind_all("<MouseWheel>",
            lambda e: self._canvas.yview_scroll(-1*(e.delta//120), "units"))

        # Status
        self._status = tk.StringVar()
        tk.Label(self, textvariable=self._status,
                 font=F_DIM, fg=DIMTEXT, bg=BG,
                 anchor="w", padx=18, pady=6).pack(fill="x", side="bottom")

        self._cards = []

    def _load(self):
        for w in self._inner.winfo_children():
            w.destroy()
        self._cards = []
        scripts = discover()
        if not scripts:
            tk.Label(self._inner, text=f"No scripts found in\n{SCRIPTS_DIR}",
                     font=F_BODY, fg=SUBTEXT, bg=BG, justify="center", pady=40).pack()
            self._status.set("No scripts found")
            return
        for name, path in scripts:
            self._add_card(name, path)
        self._status.set(f"{len(scripts)} scripts  •  {SCRIPTS_DIR}")

    def _add_card(self, name, path):
        short, long_desc = DESCRIPTIONS.get(name, ("Script", "No description available."))

        outer = tk.Frame(self._inner, bg=BG, padx=12, pady=4)
        outer.pack(fill="x")

        card = tk.Frame(outer, bg=CARD_BG, relief="flat", bd=0,
                        highlightthickness=1, highlightbackground=CARD_BORDER)
        card.pack(fill="x")

        body = tk.Frame(card, bg=CARD_BG, padx=14, pady=10)
        body.pack(fill="x", side="left", expand=True)

        # Script name + short label
        top = tk.Frame(body, bg=CARD_BG)
        top.pack(fill="x")
        tk.Label(top, text=name, font=F_NAME, fg=TEXT, bg=CARD_BG,
                 anchor="w").pack(side="left")
        tk.Label(top, text=f"  {short}", font=F_DIM, fg=DIMTEXT, bg=CARD_BG,
                 anchor="w").pack(side="left")

        # Long description
        tk.Label(body, text=long_desc, font=F_BODY, fg=SUBTEXT, bg=CARD_BG,
                 wraplength=360, justify="left", anchor="w").pack(anchor="w", pady=(4, 0))

        # Launch button on the right
        btn_frame = tk.Frame(card, bg=CARD_BG, padx=12)
        btn_frame.pack(side="right", fill="y")
        btn = tk.Button(btn_frame, text="Launch",
                        command=lambda p=path, n=name: self._launch(p, n),
                        font=F_DIM, fg=ACCENT_TXT, bg=ACCENT,
                        activeforeground=ACCENT_TXT, activebackground="#245a41",
                        relief="flat", bd=0, padx=12, pady=6, cursor="hand2")
        btn.pack(expand=True)

        self._cards.append((name, short, long_desc, outer))

    def _filter(self):
        if not self._cards:
            return
        q = self._sq.get().lower().strip()
        if q == "search…":
            q = ""
        for (name, short, desc, outer) in self._cards:
            show = not q or q in name.lower() or q in short.lower() or q in desc.lower()
            if show:
                outer.pack(fill="x")
            else:
                outer.pack_forget()

    def _launch(self, path, name):
        win = OutputWin(self, name)
        run_script(path, win.txt)

    def _open_folder(self):
        subprocess.Popen(["open", str(SCRIPTS_DIR)])


if __name__ == "__main__":
    App().mainloop()
