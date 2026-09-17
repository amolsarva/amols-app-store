#!/usr/bin/env python3
"""
Mac Scripts Launcher
A native-feeling macOS app to browse and launch your scripts from ~/Documents/root/mac-scripts
"""

import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
import subprocess
import os
import json
import threading
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPTS_DIR = Path.home() / "Documents" / "root" / "mac-scripts"
DESCRIPTIONS_FILE = SCRIPTS_DIR / "descriptions.json"

# Default descriptions – add your own in descriptions.json inside the folder
DEFAULT_DESCRIPTIONS = {
    "_default": "A Mac utility script."
}

# Which extensions we treat as launchable scripts
SCRIPT_EXTENSIONS = {".py", ".sh", ".bash", ".rb", ".applescript", ".scpt", ""}

# ── Colors / theme ───────────────────────────────────────────────────────────
BG_DARK      = "#1e1e2e"
BG_CARD      = "#2a2a3e"
BG_CARD_HOV  = "#32324a"
ACCENT       = "#7c6af7"
ACCENT_HOV   = "#9d8fff"
TEXT_PRIMARY = "#cdd6f4"
TEXT_MUTED   = "#a6adc8"
TEXT_DIM     = "#6c7086"
SUCCESS      = "#a6e3a1"
ERROR        = "#f38ba8"
BORDER       = "#45475a"

FONT_TITLE   = ("SF Pro Display", 22, "bold")
FONT_HEADING = ("SF Pro Text",    14, "bold")
FONT_BODY    = ("SF Pro Text",    12)
FONT_MONO    = ("SF Mono",        11)
FONT_SMALL   = ("SF Pro Text",    10)

# Fall back to system fonts if SF Pro isn't available
import tkinter.font as tkfont


def available_font(*candidates):
    families = set(tkfont.families())
    for f in candidates:
        if f in families:
            return f
    return "Helvetica"


def resolve_fonts():
    global FONT_TITLE, FONT_HEADING, FONT_BODY, FONT_MONO, FONT_SMALL
    body = available_font("SF Pro Text", "Helvetica Neue", "Helvetica")
    mono = available_font("SF Mono", "Menlo", "Monaco", "Courier")
    FONT_TITLE   = (body, 22, "bold")
    FONT_HEADING = (body, 14, "bold")
    FONT_BODY    = (body, 12)
    FONT_MONO    = (mono, 11)
    FONT_SMALL   = (body, 10)


# ── Helpers ───────────────────────────────────────────────────────────────────
def load_descriptions():
    if DESCRIPTIONS_FILE.exists():
        try:
            with open(DESCRIPTIONS_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_descriptions(data):
    with open(DESCRIPTIONS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def discover_scripts():
    """Return list of (name, path) for each launchable item in SCRIPTS_DIR."""
    if not SCRIPTS_DIR.exists():
        return []
    items = []
    for p in sorted(SCRIPTS_DIR.iterdir()):
        if p.name.startswith("."):
            continue
        if p.is_dir():
            # Include directories that contain a main entry point
            for entry in ("main.py", "run.py", "start.py", "main.sh", "run.sh"):
                ep = p / entry
                if ep.exists():
                    items.append((p.name, ep))
                    break
            else:
                # No entry point found – still list the dir as openable
                items.append((p.name, p))
        elif p.suffix.lower() in SCRIPT_EXTENSIONS or not p.suffix:
            items.append((p.name, p))
    return items


def launch_script(path: Path, output_widget=None):
    """Run a script and stream output to a text widget."""
    def _log(msg, tag="normal"):
        if output_widget:
            output_widget.configure(state="normal")
            output_widget.insert(tk.END, msg, tag)
            output_widget.see(tk.END)
            output_widget.configure(state="disabled")

    def _run():
        _log(f"▶ Launching: {path}\n\n", "accent")
        try:
            if path.is_dir():
                subprocess.Popen(["open", str(path)])
                _log("📂 Opened folder in Finder.\n", "success")
                return

            ext = path.suffix.lower()
            if ext == ".py":
                cmd = ["python3", str(path)]
            elif ext in (".sh", ".bash"):
                cmd = ["bash", str(path)]
            elif ext == ".rb":
                cmd = ["ruby", str(path)]
            elif ext in (".applescript", ".scpt"):
                cmd = ["osascript", str(path)]
            else:
                # Try running directly (assumes shebang or executable)
                cmd = [str(path)]

            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                cwd=str(path.parent),
            )
            for line in proc.stdout:
                _log(line)
            proc.wait()
            if proc.returncode == 0:
                _log(f"\n✓ Finished (exit 0)\n", "success")
            else:
                _log(f"\n✗ Exited with code {proc.returncode}\n", "error")
        except Exception as e:
            _log(f"\n✗ Error: {e}\n", "error")

    threading.Thread(target=_run, daemon=True).start()


# ── UI Components ─────────────────────────────────────────────────────────────
class ScriptCard(tk.Frame):
    def __init__(self, parent, name, path, description, on_launch, on_edit_desc, **kwargs):
        super().__init__(parent, bg=BG_CARD, **kwargs)
        self.name = name
        self.path = path
        self.on_launch = on_launch

        self.configure(pady=2)

        # ── Inner content frame ──
        inner = tk.Frame(self, bg=BG_CARD, padx=18, pady=14)
        inner.pack(fill="x", expand=True)

        # Left side: icon + text
        left = tk.Frame(inner, bg=BG_CARD)
        left.pack(side="left", fill="both", expand=True)

        icon = "📁" if path.is_dir() else self._icon_for(path)
        tk.Label(left, text=f"{icon}  {name}",
                 font=FONT_HEADING, fg=TEXT_PRIMARY, bg=BG_CARD,
                 anchor="w").pack(anchor="w")

        self.desc_var = tk.StringVar(value=description)
        desc_lbl = tk.Label(left, textvariable=self.desc_var,
                            font=FONT_SMALL, fg=TEXT_MUTED, bg=BG_CARD,
                            wraplength=520, justify="left", anchor="w")
        desc_lbl.pack(anchor="w", pady=(3, 0))

        path_lbl = tk.Label(left, text=str(path),
                            font=FONT_SMALL, fg=TEXT_DIM, bg=BG_CARD,
                            anchor="w")
        path_lbl.pack(anchor="w", pady=(2, 0))

        # Right side: buttons
        right = tk.Frame(inner, bg=BG_CARD)
        right.pack(side="right", padx=(12, 0))

        self._launch_btn = self._make_btn(right, "▶  Launch", ACCENT, ACCENT_HOV,
                                          lambda: on_launch(self.path))
        self._launch_btn.pack(pady=(0, 6))

        self._edit_btn = self._make_btn(right, "✏  Edit desc", BG_CARD_HOV, BORDER,
                                        lambda: on_edit_desc(self), small=True)
        self._edit_btn.pack()

        # Separator line
        sep = tk.Frame(self, bg=BORDER, height=1)
        sep.pack(fill="x", padx=18)

    def _icon_for(self, path):
        icons = {".py": "🐍", ".sh": "⚡", ".bash": "⚡",
                 ".rb": "💎", ".applescript": "🍎", ".scpt": "🍎"}
        return icons.get(path.suffix.lower(), "📄")

    def _make_btn(self, parent, text, bg, active_bg, command, small=False):
        font = FONT_SMALL if small else FONT_BODY
        btn = tk.Button(parent, text=text, command=command,
                        font=font, fg=TEXT_PRIMARY, bg=bg,
                        activeforeground=TEXT_PRIMARY, activebackground=active_bg,
                        relief="flat", bd=0, padx=14, pady=6, cursor="hand2")
        return btn


class OutputWindow(tk.Toplevel):
    def __init__(self, parent, script_name):
        super().__init__(parent)
        self.title(f"Output — {script_name}")
        self.configure(bg=BG_DARK)
        self.geometry("700x420")
        self.minsize(500, 300)

        toolbar = tk.Frame(self, bg=BG_DARK, pady=8, padx=12)
        toolbar.pack(fill="x")
        tk.Label(toolbar, text=f"▶ {script_name}",
                 font=FONT_HEADING, fg=TEXT_PRIMARY, bg=BG_DARK).pack(side="left")
        tk.Button(toolbar, text="✕ Close", command=self.destroy,
                  font=FONT_SMALL, fg=TEXT_MUTED, bg=BG_DARK,
                  activeforeground=TEXT_PRIMARY, activebackground=BG_CARD,
                  relief="flat", bd=0, padx=10, pady=4, cursor="hand2").pack(side="right")

        self.text = scrolledtext.ScrolledText(
            self, font=FONT_MONO, bg="#11111b", fg=TEXT_PRIMARY,
            insertbackground=TEXT_PRIMARY, relief="flat",
            state="disabled", wrap="word", padx=12, pady=10,
        )
        self.text.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.text.tag_config("accent",  foreground=ACCENT)
        self.text.tag_config("success", foreground=SUCCESS)
        self.text.tag_config("error",   foreground=ERROR)


class EditDescDialog(tk.Toplevel):
    def __init__(self, parent, card, descriptions, on_save):
        super().__init__(parent)
        self.title("Edit description")
        self.configure(bg=BG_DARK)
        self.geometry("480x200")
        self.resizable(False, False)
        self.grab_set()

        tk.Label(self, text=f"Description for "{card.name}"",
                 font=FONT_HEADING, fg=TEXT_PRIMARY, bg=BG_DARK,
                 pady=16).pack()

        self.entry = tk.Text(self, font=FONT_BODY, bg=BG_CARD, fg=TEXT_PRIMARY,
                             insertbackground=TEXT_PRIMARY, relief="flat",
                             height=3, padx=10, pady=8, wrap="word")
        self.entry.insert("1.0", card.desc_var.get())
        self.entry.pack(fill="x", padx=20)
        self.entry.focus_set()

        btn_row = tk.Frame(self, bg=BG_DARK, pady=14)
        btn_row.pack()
        tk.Button(btn_row, text="Save", command=lambda: self._save(card, descriptions, on_save),
                  font=FONT_BODY, fg=TEXT_PRIMARY, bg=ACCENT, activeforeground=TEXT_PRIMARY,
                  activebackground=ACCENT_HOV, relief="flat", bd=0,
                  padx=18, pady=6, cursor="hand2").pack(side="left", padx=6)
        tk.Button(btn_row, text="Cancel", command=self.destroy,
                  font=FONT_BODY, fg=TEXT_MUTED, bg=BG_CARD, activeforeground=TEXT_PRIMARY,
                  activebackground=BG_CARD_HOV, relief="flat", bd=0,
                  padx=18, pady=6, cursor="hand2").pack(side="left", padx=6)

    def _save(self, card, descriptions, on_save):
        new_desc = self.entry.get("1.0", "end-1c").strip()
        card.desc_var.set(new_desc)
        descriptions[card.name] = new_desc
        on_save(descriptions)
        self.destroy()


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        resolve_fonts()
        self.title("Mac Scripts Launcher")
        self.configure(bg=BG_DARK)
        self.geometry("780x680")
        self.minsize(600, 400)

        self.descriptions = load_descriptions()
        self._build_ui()
        self._load_scripts()

    def _build_ui(self):
        # ── Header ──
        header = tk.Frame(self, bg=BG_DARK, padx=24, pady=20)
        header.pack(fill="x")

        tk.Label(header, text="🚀  Mac Scripts", font=FONT_TITLE,
                 fg=TEXT_PRIMARY, bg=BG_DARK).pack(side="left")

        refresh_btn = tk.Button(header, text="⟳  Refresh", command=self._load_scripts,
                                font=FONT_SMALL, fg=TEXT_MUTED, bg=BG_CARD,
                                activeforeground=TEXT_PRIMARY, activebackground=BG_CARD_HOV,
                                relief="flat", bd=0, padx=12, pady=6, cursor="hand2")
        refresh_btn.pack(side="right")

        open_btn = tk.Button(header, text="📂  Open folder",
                             command=lambda: subprocess.Popen(["open", str(SCRIPTS_DIR)]),
                             font=FONT_SMALL, fg=TEXT_MUTED, bg=BG_CARD,
                             activeforeground=TEXT_PRIMARY, activebackground=BG_CARD_HOV,
                             relief="flat", bd=0, padx=12, pady=6, cursor="hand2")
        open_btn.pack(side="right", padx=(0, 8))

        # ── Search ──
        search_frame = tk.Frame(self, bg=BG_DARK, padx=24, pady=0)
        search_frame.pack(fill="x")
        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", lambda *_: self._filter_cards())
        search_entry = tk.Entry(search_frame, textvariable=self.search_var,
                                font=FONT_BODY, bg=BG_CARD, fg=TEXT_PRIMARY,
                                insertbackground=TEXT_PRIMARY, relief="flat",
                                bd=0)
        search_entry.pack(fill="x", ipady=8, padx=2)
        search_entry.insert(0, "🔍  Search scripts…")
        search_entry.bind("<FocusIn>",  lambda e: search_entry.delete(0, "end")
                          if search_entry.get().startswith("🔍") else None)
        search_entry.bind("<FocusOut>", lambda e: search_entry.insert(0, "🔍  Search scripts…")
                          if not search_entry.get() else None)

        spacer = tk.Frame(self, bg=BG_DARK, height=12)
        spacer.pack(fill="x")

        # ── Scrollable script list ──
        container = tk.Frame(self, bg=BG_DARK)
        container.pack(fill="both", expand=True, padx=24, pady=(0, 16))

        canvas = tk.Canvas(container, bg=BG_DARK, highlightthickness=0, bd=0)
        scrollbar = ttk.Scrollbar(container, orient="vertical", command=canvas.yview)
        self.cards_frame = tk.Frame(canvas, bg=BG_DARK)

        self.cards_frame.bind("<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=self.cards_frame, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)

        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        # Mouse-wheel scrolling
        self.bind_all("<MouseWheel>",
            lambda e: canvas.yview_scroll(-1 * (e.delta // 120), "units"))
        self.bind_all("<Button-4>",
            lambda e: canvas.yview_scroll(-1, "units"))
        self.bind_all("<Button-5>",
            lambda e: canvas.yview_scroll(1, "units"))

        # ── Status bar ──
        self.status_var = tk.StringVar(value="Loading…")
        tk.Label(self, textvariable=self.status_var,
                 font=FONT_SMALL, fg=TEXT_DIM, bg=BG_DARK,
                 anchor="w", padx=26, pady=6).pack(fill="x", side="bottom")

        self._cards = []

    def _load_scripts(self):
        for w in self.cards_frame.winfo_children():
            w.destroy()
        self._cards = []

        scripts = discover_scripts()
        if not scripts:
            tk.Label(self.cards_frame,
                     text=f"No scripts found in\n{SCRIPTS_DIR}",
                     font=FONT_BODY, fg=TEXT_MUTED, bg=BG_DARK,
                     justify="center", pady=40).pack()
            self.status_var.set(f"Folder: {SCRIPTS_DIR}  •  No scripts found")
            return

        for name, path in scripts:
            desc = self.descriptions.get(name, DEFAULT_DESCRIPTIONS.get("_default", ""))
            card = ScriptCard(
                self.cards_frame, name, path, desc,
                on_launch=self._launch,
                on_edit_desc=self._edit_desc,
            )
            card.pack(fill="x", pady=(0, 8))
            self._cards.append(card)

        self.status_var.set(
            f"Folder: {SCRIPTS_DIR}  •  {len(scripts)} script{'s' if len(scripts) != 1 else ''} found"
        )

    def _filter_cards(self):
        q = self.search_var.get().lower().strip()
        if q.startswith("🔍"):
            q = ""
        for card in self._cards:
            match = q in card.name.lower() or q in card.desc_var.get().lower()
            if match:
                card.pack(fill="x", pady=(0, 8))
            else:
                card.pack_forget()

    def _launch(self, path):
        win = OutputWindow(self, path.name)
        launch_script(path, win.text)

    def _edit_desc(self, card):
        EditDescDialog(self, card, self.descriptions,
                       on_save=save_descriptions)


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    app = App()
    app.mainloop()
