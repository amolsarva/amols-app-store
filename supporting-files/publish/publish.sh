#!/bin/bash
# Publish Amol's App Store: GitHub (amols-app-store) + amolsarva.com/scripts, from the tool.json files.
#
#   publish.sh          dry run: rebuild lists, validate, show exactly what would go out
#   publish.sh --go     commit + push this repo, copy the store page into the website repo,
#                       push that, then wait until amolsarva.com/scripts shows the new list
#
# Hard stops (it refuses rather than publishing something wrong):
#   - private-looking files in anything about to be pushed (contact CSVs, campaign archives,
#     config.json, .env, logs …), see build_catalog.py PRIVATE_PATTERNS
#   - shell/python syntax errors in tracked scripts, or a store page whose JavaScript won't parse
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SITE="${SITE_REPO:-$REPO/../amolsarva.com}"
PY="$(command -v python3)"
GO=0; [[ "${1:-}" == "--go" ]] && GO=1
cd "$REPO"

step() { echo; echo "── $*"; }
# Push over SSH; if this Mac has no GitHub SSH key, retry over HTTPS (uses the Keychain login).
push() {
  local dir="$1" branch https
  branch="$(git -C "$dir" branch --show-current)"
  git -C "$dir" push -q origin HEAD 2>/dev/null && return 0
  https="$(git -C "$dir" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#')"
  echo "  (SSH push failed; retrying over HTTPS: $https)"
  git -C "$dir" push -q "$https" "HEAD:$branch" || return 1
  git -C "$dir" fetch -q "$https" "+refs/heads/$branch:refs/remotes/origin/$branch" || true  # keep "ahead/behind" accurate
}
die() { echo "✗ $*"; exit 1; }

step "1. Rebuild README, store page, launcher catalog, announcement drafts"
"$PY" "$HERE/build_catalog.py" || die "catalog build failed"

step "2. Validate"
bad=0
while IFS= read -r f; do bash -n "$f" 2>/dev/null || { echo "  syntax error: $f"; bad=1; }; done \
  < <(git ls-files '*.sh' '*.command'; git ls-files --others --exclude-standard '*.sh' '*.command')
while IFS= read -r f; do "$PY" -m py_compile "$f" 2>/dev/null || { echo "  syntax error: $f"; bad=1; }; done \
  < <(git ls-files '*.py'; git ls-files --others --exclude-standard '*.py')
node -e "const fs=require('fs');const h=fs.readFileSync('supporting-files/scripts.html','utf8');for(const m of h.matchAll(/<script>([\s\S]*?)<\/script>/g)) new Function(m[1]);" \
  || { echo "  store page JavaScript does not parse"; bad=1; }
[[ $bad -eq 0 ]] && echo "  ✓ scripts and store page parse" || die "fix the errors above first"

step "3. Private-data gate"
"$PY" "$REPO/git-privacy/git_privacy.py" scrub "$REPO" | grep -qE "would (untrack|remove)" \
  && die "git-privacy: private (git-ignored) files are tracked or in unpushed commits. Run: git-privacy/run.sh scrub \"$REPO\" --apply"
"$PY" "$HERE/build_catalog.py" --leaks || die "private files would be published. Untrack them (git rm --cached …) or add them to .gitignore. If they are already in an unpushed commit, rewrite that commit before publishing."
echo "  ✓ nothing private in what would be pushed"

step "4. What would go out"
git status --short | sed 's/^/  /' | head -40
echo "  unpushed commits: $(git rev-list --count @{u}..HEAD 2>/dev/null || echo ?)"
if [[ -d "$SITE/.git" ]]; then
  if cmp -s supporting-files/scripts.html "$SITE/scripts.html"; then echo "  website: scripts.html already current"
  else echo "  website: scripts.html would be updated in $SITE"; fi
else
  echo "  website repo not found at $SITE (set SITE_REPO)"
fi
"$PY" "$HERE/build_catalog.py" --check | sed 's/^/  /' | grep -E "⚠️|❌|✅" | head -20

if [[ $GO -eq 0 ]]; then
  echo; echo "Dry run only. Publish with:  $0 --go"
  exit 0
fi

step "5. Commit + push amols-app-store"
git add -A
"$PY" "$HERE/build_catalog.py" --leaks >/dev/null || die "private files got staged; aborting"
if ! git diff --cached --quiet; then
  git commit -q -m "Publish App Store catalog ($(date +%F))" || die "commit failed (the global pre-commit secret hook may have blocked it; read its message)"
fi
push "$REPO" || die "push failed"
echo "  ✓ pushed $(git rev-parse --short HEAD)"

step "6. Update amolsarva.com"
[[ -d "$SITE/.git" ]] || die "website repo not found at $SITE"
git -C "$SITE" pull -q --rebase --autostash "$(git -C "$SITE" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#')" "$(git -C "$SITE" branch --show-current)" \
  || die "could not bring the website repo up to date (resolve in $SITE, then re-run)"
cp supporting-files/scripts.html "$SITE/scripts.html"
cat > "$SITE/amols-scripts.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Amol's App Store</title>
<meta http-equiv="refresh" content="0; url=/scripts"><link rel="canonical" href="https://amolsarva.com/scripts">
<p><a href="/scripts">Amol's App Store has moved to /scripts</a></p>
HTML
(
  cd "$SITE" || exit 1
  git add scripts.html amols-scripts.html
  git diff --cached --quiet || git commit -q -m "Update App Store page from amols-app-store ($(date +%F))" || exit 1
  true
) || die "website push failed (check: git -C \"$SITE\" fsck)"
push "$SITE" || die "website push failed"
echo "  ✓ website pushed"

step "7. Wait for the live page"
for i in $(seq 1 30); do
  if "$PY" "$HERE/build_catalog.py" --live; then echo "  ✓ https://amolsarva.com/scripts is live and matches"; exit 0; fi
  sleep 20
done
die "live page still stale after 10 minutes; GitHub Pages may be slow. Re-check with: build_catalog.py --check"
