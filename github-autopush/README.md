# github-autopush

Automatically keep your git repos synced to GitHub in the background — a LaunchAgent-powered auto-push system with an interactive manager UI.

## What it does

Two scripts work together:

**`github-autopush-manager.sh`** — interactive terminal UI that:
- Discovers all git repos under your configured search folders
- Lets you toggle auto-sync on/off per repo
- Installs/uninstalls the background LaunchAgent
- Shows sync history and last-run status
- Adjustable sync interval (default: every 5 minutes)

**`github-autopush-runner.sh`** — the background worker that:
- Runs on a schedule via macOS LaunchAgent
- For each enabled repo: `git add -A`, `git commit`, `git push`
- Skips repos with no changes
- Logs everything to `~/.config/github-autopush/history.tsv`

## Usage

```bash
# Launch the manager (interactive)
bash github-autopush-manager.sh
```

From the manager menu you can:
- See all discovered repos and their sync status
- Enable/disable auto-push per repo
- Start/stop the background agent
- View recent sync history
- Configure the sync interval and search roots

## Setup

1. Make sure your repos already have a GitHub remote set (`git remote -v` to check)
2. Make sure you can push without a password prompt (SSH key or credential helper)
3. Run the manager and enable sync for the repos you want

The LaunchAgent (`com.amol.github-autopush`) will install to `~/Library/LaunchAgents/` and auto-start at login.

## Configuration

Config lives at `~/.config/github-autopush/`:
- `search_roots.txt` — directories to search for git repos (one per line)
- `sync_enabled.txt` — repos that have auto-push enabled
- `history.tsv` — full sync log

## Requirements

- macOS
- `git` with GitHub access (SSH key recommended)
- bash 3.2+

## Notes

- Only pushes — never force-pushes, never rebases, never pulls
- If a push fails (e.g. remote has new commits), the repo is skipped and logged
- Designed for personal repos where you're the sole committer
