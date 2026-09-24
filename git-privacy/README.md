# 🔏 git-privacy

**Some things belong on GitHub. Some belong only on your Macs. This keeps them apart.**

If your projects live in iCloud Drive (or Dropbox), your private notes, contact lists and AI
instructions sit right next to public code, one `git add -A` away from the internet.
git-privacy turns one rule into something every Mac enforces:

> **Anything git ignores is private.** It stays in the folder (so iCloud syncs it to your other
> Macs) and is never pushed.

| Command | Does |
|---|---|
| `run.sh install` | Once per Mac: adds the shared private patterns (`private-patterns`: `AI-README.md`, `_private/`, `_notes/`, `*.private.*`) to your global gitignore and installs a pre-commit + pre-push guard. |
| `run.sh audit` | Every repo under `~/Documents/root`: private files still tracked, unpushed commits containing private files, and repository corruption (`git fsck`). |
| `run.sh scrub <repo>` | Dry run of removing private files from the index and from **unpushed** commits. Add `--apply` to do it. Files stay on disk; pushed history is never rewritten. |

Make something private: add it to the repo's `.gitignore` (or to `private-patterns` for every repo),
then `scrub`. Files already on GitHub are left alone, since hiding them now would only delete them.
To publish a file that matches a pattern, un-ignore it with `!path`.

**Why the corruption check:** a `.git` folder synced by iCloud between two Macs can lose objects
(evicted files, half-synced packs). `audit` finds it early. For public repos, the usual repair is
`git fetch --refetch <https-url>`, which re-downloads every object from GitHub.
