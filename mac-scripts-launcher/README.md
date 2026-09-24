# 🚀 Mac Scripts Launcher

**One window to browse and launch every tool in this collection.**

A small Tk app: each tool appears as a card with an icon and a description, and a click runs it in
Terminal. The list comes from `supporting-files/catalog/launcher.json`, which is generated from each
tool's `tool.json`, so new tools show up on their own.

```bash
python3 launcher.py      # run it directly
bash build_app.sh        # or package it as "Mac Scripts Launcher.app" in /Applications
```

The repo root's `launcher.command` opens the same launcher with a double-click.
