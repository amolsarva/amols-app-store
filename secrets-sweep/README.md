# 🔐 Secrets Sweep

**Find API keys, tokens and credential files that drifted out of your vault, and put them back.**

Keys end up in `.env` files, notes, old scripts and screenshots of terminals. Secrets Sweep audits a
folder tree and reports three things: secret-looking **files** outside the vault, live-looking **keys
pasted inside documents**, and, the dangerous case, secrets that **git is tracking**.

```bash
bash secrets-sweep.sh              # audit only, changes nothing
bash secrets-sweep.sh --fix        # move files into the vault, leave a symlink so apps keep working
bash secrets-sweep.sh --fix --yes  # same, without asking per file
```

Settings: `SWEEP_ROOT` (folder to audit, default `~/Documents/root`) and `SWEEP_VAULT`
(default `$SWEEP_ROOT/utils and keys/vault`). Keys pasted inside documents must be edited by hand;
if one ever reached a public repo, rotate it (deleting isn't enough). Pairs well with [git-privacy](../git-privacy/).
