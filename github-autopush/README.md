# github-autopush

Auto-discovers local GitHub working copies and keeps them synced in the background.

The design goal is: put a GitHub repo somewhere under the configured roots and stop thinking about it. The runner scans each cycle, finds repos with GitHub `origin` remotes, skips anything explicitly ignored, pulls/rebases with autostash, commits local changes, and pushes.

## Files

- `github-autopush-manager.sh` - local terminal TUI for status, roots, ignored repos, settings, manual runs, and LaunchAgent control.
- `github-autopush-runner.sh` - non-interactive worker used by launchd.

## Quick start

```bash
bash github-autopush-manager.sh
```

Useful non-interactive commands:

```bash
bash github-autopush-manager.sh install   # install/restart persistent agent
bash github-autopush-manager.sh once      # run one sync cycle now
bash github-autopush-manager.sh scan      # show discovered GitHub repos
bash github-autopush-manager.sh stop      # stop the persistent agent
bash github-autopush-manager.sh loop-start # start session fallback loop
bash github-autopush-manager.sh loop-stop  # stop session fallback loop
```

## Behavior

- Discovers Git repos under `search_roots.txt` every run. The default roots are the local and iCloud `Documents/root` folders.
- Only manages repos whose `origin` is GitHub.
- New GitHub repos are managed automatically.
- `ignore.txt` is the main control: ignored paths are skipped.
- Existing `sync_enabled.txt` is still read as a legacy hint, but it is no longer required.
- Converts `https://github.com/...` origins to `git@github.com:...` when enabled.
- Pulls with `git pull --rebase --autostash` before committing and pushing.
- Commits all local changes with `auto: sync YYYY-MM-DD HH:MM:SS`.
- Pushes and sets upstream automatically when a branch has no upstream.
- Never force-pushes.
- Skips detached heads and repos with merge/rebase/cherry-pick state in progress.

## Config

Config lives in `~/.config/github-autopush/`:

- `config` - interval and behavior toggles.
- `search_roots.txt` - directories to scan.
- `ignore.txt` - exact repo paths or path fragments to skip.
- `last_scan.txt` - latest discovered GitHub repo list.
- `history.tsv` - append-only sync log.
- `last_run_summary.txt` - dashboard summary.

Main settings:

- `INTERVAL` - LaunchAgent interval in seconds, default `300`.
- `SEARCH_MAX_DEPTH` - discovery depth per search root, default `8`.
- `PULL_BEFORE_PUSH` - `1` to rebase/autostash before committing and pushing.
- `AUTO_CONVERT_HTTPS` - `1` to convert GitHub HTTPS origins to SSH.
- `AUTO_CREATE_UPSTREAM` - `1` to push `-u origin <branch>` when needed.
- `COMMIT_PREFIX` - auto commit message prefix.

## Persistent runner

The manager installs:

- Runner copy: `~/bin/github-autopush-runner.sh`
- LaunchAgent: `~/Library/LaunchAgents/com.amol.github-autopush.plist`
- Logs: `~/Library/Logs/github-autopush.out` and `~/Library/Logs/github-autopush.err`

The agent starts at login and runs at the configured interval.

On macOS systems where a LaunchAgent cannot see `~/Documents` because of privacy controls, the manager can also start a session fallback loop. That loop is launched from the current user shell, writes to `~/Library/Logs/github-autopush.session-loop.out`, and uses the same interval.

## Notes

This is intentionally aggressive for personal/local mirrors. It stages everything in managed repos. Put repos in `ignore.txt` if they should not be auto-committed and pushed.
