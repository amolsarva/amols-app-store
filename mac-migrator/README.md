# mac-migrator

Bundle your Mac's background configuration — LaunchAgents, dotfiles, shell aliases, SSH keys, app settings — into a portable archive you can restore on a new Mac.

## What it does

Runs a comprehensive scan of your current Mac and packages everything into a timestamped bundle directory:

```
mac_migration_YYYYMMDD-HHMMSS/
  bundle/         ← copies of all captured config files
  staging/        ← intermediate workspace
  reports/
    README.txt    ← human-readable summary
    manifest.tsv  ← full list of what was captured
    manifest.json ← machine-readable version
  installer/
    install.sh    ← restores everything on the new Mac
  tools/          ← helper scripts
  run.log         ← full log of the capture run
```

**What gets captured:**
- LaunchAgents (user-level background tasks)
- Shell config: `.zshrc`, `.bashrc`, `.bash_profile`, `.zprofile`, aliases
- SSH keys and known hosts
- Git config
- Homebrew package list
- App-specific config for common tools (Vim, tmux, etc.)

## Usage

**On your old Mac:**

```bash
bash mac_background_migrator.sh
```

Then package the bundle:

```bash
tar -czf mac_migration_bundle.tar.gz -C ~/mac_migration_YYYYMMDD-HHMMSS .
```

**On your new Mac:**

```bash
tar -xzf mac_migration_bundle.tar.gz
cd mac_migration_YYYYMMDD-HHMMSS/installer
bash install.sh
```

## Requirements

- macOS
- bash
- No additional dependencies

## Notes

- The script captures and copies — it never deletes anything from your old Mac
- Review `reports/manifest.tsv` before running `install.sh` on the new Mac
- Some apps require separate export/import steps: Keyboard Maestro, Alfred, Raycast, BetterTouchTool, Hammerspoon
- System LaunchDaemons in `/Library` (not `~/Library`) may require `sudo` and manual review
- Login Items are captured as names only — re-enable them manually in System Settings after migration
