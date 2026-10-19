#!/bin/bash
# release.sh — after ANY change in mac-scripts, this brings everything that depends on it up to date.
#
#   release.sh              dry run: what is stale, what would be rebuilt / reinstalled / published
#   release.sh --local-only fix THIS Mac only: Python, catalog, installed copies, artifacts (no pushes)
#   release.sh --go         everything below, including GitHub + amolsarva.com, then verify live
#
# The chain (in order; each step stops the release if it fails):
#   1. Python      python-guard: Homebrew python3 + Tk for its current version + tool venvs current
#   2. Catalog     build_catalog.py → README tables, amolsarva.com/scripts app list, launcher.json,
#                  .gitignore block for non-public tools, announcement drafts
#   3. Lint        Backstage scripts.json / setup.json paths, launcher entries, installs/artifacts commands
#   4. Validate    publish.sh dry run: syntax of every script, store page JS, private-data gate
#   5. Installs    deps.py sync → re-install every installed copy on this Mac whose source changed
#                  (LaunchAgents' copies, Backstage.app, Sunlight.app, Mac Scripts Launcher.app, …)
#   6. Artifacts   deps.py artifacts → rebuild published binaries/zips (Backstage dmg + latest.json,
#                  Chrome extension zips) and copy them into the amolsarva.com repo
#   7. Publish     publish.sh --go → commit + push amols-app-store, push amolsarva.com, wait for live
#   8. Nested      own-repo tools (screenshot-mover, imessage-cleanup): commit tracked changes + push
#   9. Verify      deps.py status + build_catalog.py --check + live latest.json
#
# Needs macOS for steps 5–9 (swift, launchctl, Keychain git credentials). From a Linux AI sandbox,
# run the dry run, fix what it reports, and ask Amol to press Backstage ▸ "Release mac-scripts".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SITE="${SITE_REPO:-$REPO/../amolsarva.com}"
export SITE_REPO="$SITE"
MODE="dry"; for a in "$@"; do case "$a" in --go) MODE=go;; --local-only) MODE=local;; --dry-run) MODE=dry;; esac; done
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" HOMEBREW_NO_AUTO_UPDATE=1
LOG="$HOME/Library/Logs/mac-scripts-release.log"
MAC=0; [[ "$(uname)" == Darwin ]] && MAC=1
cd "$REPO" || exit 1

# Log to ~/Library/Logs AND to a private (gitignored, iCloud-synced) copy here, so an AI in a sandbox
# that can't see ~/Library can still read how the last release went.
if [[ $MAC -eq 1 ]]; then mkdir -p "$(dirname "$LOG")"; : > "$HERE/.last-release.log"; exec > >(tee -a "$LOG" "$HERE/.last-release.log") 2>&1; fi
LOCK="${TMPDIR:-/tmp}/mac-scripts-release.lock"
mkdir "$LOCK" 2>/dev/null || { echo "Another release is running ($LOCK). If not, remove that folder."; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

PY="$(/bin/bash "$REPO/python-guard/pyenv.sh" find --quiet 2>/dev/null || command -v python3)"
step() { echo; echo "━━ $*"; }
ARGS="$*"
die()  { echo "✗ $*"; echo "Release stopped. Fix the above, then run again: $0 $ARGS"; exit 1; }
WARN=0; warn() { echo "⚠️  $*"; WARN=$((WARN+1)); }

echo "mac-scripts release · $(date '+%F %T') · mode=$MODE · $(hostname -s 2>/dev/null)"

step "1. Python (python-guard)"
if [[ $MODE == dry ]]; then /bin/bash "$REPO/python-guard/pyenv.sh" doctor || warn "Python needs repair (the release will run: python-guard/run.sh ensure)"
else /bin/bash "$REPO/python-guard/pyenv.sh" ensure || warn "python-guard could not fully heal Python (see ~/Library/Logs/python-guard.log)"; fi

step "2. Catalog (README, store page, launcher, .gitignore)"
"$PY" "$HERE/build_catalog.py" || die "catalog build failed"

step "3. Lint (Backstage registrations, launcher entries, installs/artifacts)"
"$PY" "$HERE/deps.py" lint || warn "lint found problems (listed above)"

step "4. Validate + privacy gate (publish.sh dry run)"
/bin/bash "$HERE/publish.sh" || die "validation failed"

step "5. Installed copies on this Mac"
if [[ $MAC -eq 0 ]]; then echo "  (not macOS: skipped)"; "$PY" "$HERE/deps.py" status | sed -n '/^Installed/,/^Published/p'
elif [[ $MODE == dry ]]; then "$PY" "$HERE/deps.py" sync --dry-run || true
else "$PY" "$HERE/deps.py" sync || warn "some installed copies still need you (see ⚠️ above)"; fi

step "6. Published artifacts (Backstage dmg, extension zips → amolsarva.com repo)"
if [[ $MODE == dry ]]; then "$PY" "$HERE/deps.py" status | sed -n '/^Published/,/^Repos/p'
else "$PY" "$HERE/deps.py" artifacts || warn "an artifact could not be built"; fi

if [[ $MODE != go ]]; then
  step "Summary"
  "$PY" "$HERE/deps.py" status
  echo; echo "Not published (mode=$MODE). Publish everything with: $0 --go"
  exit 0
fi

step "7. Publish: GitHub (amols-app-store) + amolsarva.com"
# Hygiene: anything .gitignore now excludes (own-repo tools, build output, private files) must not stay tracked.
ign="$(git ls-files -ci --exclude-standard)"
if [[ -n "$ign" ]]; then
  echo "  untracking $(echo "$ign" | wc -l | tr -d ' ') file(s) that .gitignore excludes:"; echo "$ign" | sed 's/^/    /' | head -20
  git ls-files -ci --exclude-standard -z | xargs -0 git rm -q --cached -- || die "could not untrack ignored files"
fi
RELEASE_MSG="${RELEASE_MSG:-Release $(date +%F): catalog, tools and downloads}" /bin/bash "$HERE/publish.sh" --go || die "publish failed"

step "8. Tools that live in their own repos"
for n in screenshot-mover imessage-cleanup; do
  d="$REPO/$n"; [[ -d "$d/.git" ]] || continue
  if ! git -C "$d" diff --quiet || ! git -C "$d" diff --cached --quiet; then
    git -C "$d" add -u && git -C "$d" commit -q -m "Sync from mac-scripts release $(date +%F)" && echo "  committed $n"
  fi
  if [[ "$(git -C "$d" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" != 0 ]]; then
    b="$(git -C "$d" branch --show-current)"
    url="$(git -C "$d" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#')"
    git -C "$d" push -q origin HEAD 2>/dev/null || git -C "$d" push -q "$url" "HEAD:$b" || { warn "$n: push failed"; continue; }
    git -C "$d" fetch -q "$url" "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
    echo "  ✓ pushed $n"
  else echo "  ✓ $n up to date"; fi
done

step "9. Verify"
"$PY" "$HERE/deps.py" status || warn "something is still not current (above)"
"$PY" "$HERE/build_catalog.py" --check | grep -E "❌|✅|stale" || true
if [[ -f "$REPO/backstage/dist/latest.json" ]]; then
  want="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["build"])' "$REPO/backstage/dist/latest.json")"
  for i in $(seq 1 20); do
    live="$(curl -fsS "https://amolsarva.com/downloads/backstage/latest.json?v=$(date +%s)" 2>/dev/null | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["build"])' 2>/dev/null)"
    [[ "$live" == "$want" ]] && { echo "  ✅ Backstage update feed live (build $live): other Macs will auto-update"; break; }
    [[ $i -eq 20 ]] && warn "Backstage latest.json not live yet (want $want, got ${live:-nothing})"; sleep 15
  done
fi
echo; [[ $WARN -eq 0 ]] && echo "✅ Release complete: everything downstream is current." || echo "Release finished with $WARN warning(s) above."
echo "Other Macs: iCloud carries the source; Backstage there offers 'Update now' and New Mac setup flags stale installs."
