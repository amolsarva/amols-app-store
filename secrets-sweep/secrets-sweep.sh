#!/bin/bash
# secrets-sweep — find keys and secrets that have drifted out of the vault.
#
# Policy: every secret lives in ~/Documents/root/utils and keys/vault/<project>/,
# with a symlink left at the original path so apps keep working.
#
#   ./secrets-sweep.sh              audit and report (default, changes nothing)
#   ./secrets-sweep.sh --fix        move what it finds into the vault and symlink it back
#   ./secrets-sweep.sh --fix --yes  same, without asking per file
#
# It reports three things:
#   1. secret-looking FILES outside the vault
#   2. live-looking KEYS pasted inside ordinary documents (these must be edited by hand)
#   3. anything secret that git is actually TRACKING (the dangerous case)

set -uo pipefail

ROOT="$HOME/Documents/root"
VAULT="$ROOT/utils and keys/vault"
FIX=false; YES=false
for a in "$@"; do
  case "$a" in
    --fix) FIX=true ;;
    --yes|-y) YES=true ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  esac
done

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
red()  { printf "\033[31m%s\033[0m\n" "$1"; }

mkdir -p "$VAULT"

bold "1. Secret-looking files outside the vault"
found_files=()
while IFS= read -r f; do
  [ -L "$f" ] && continue                      # already vaulted (symlink)
  case "$f" in *"/utils and keys/"*) continue ;; esac
  case "$(basename "$f")" in *.example|*.sample) continue ;; esac
  found_files+=("$f")
  echo "   $f"
done < <(find "$ROOT" \
            \( -name node_modules -o -name .git -o -name .venv -o -name .next -o -name venv \) -prune -o \
            -type f \( -name '.env' -o -name '.env.*' -o -name 'env.keys' -o -name '*.pem' \
                       -o -name '*.p12' -o -name 'id_rsa*' -o -name 'credentials.json' \
                       -o -iname '*recovery_codes*' -o -iname '*recovery-codes*' \
                       -o -iname '*keys and logins*' -o -iname '*private key*' \) -print 2>/dev/null | sort)
[ ${#found_files[@]} -eq 0 ] && echo "   none — clean."

echo
bold "2. Live-looking keys pasted inside ordinary documents"
grep -rlE '(sk-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16}|SG\.[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|sb_secret_[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
  --include='*.md' --include='*.txt' --include='*.json' --include='*.yml' --include='*.yaml' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.venv --exclude-dir='utils and keys' \
  "$ROOT" 2>/dev/null | sed 's|^|   |' || echo "   none found"
echo "   (these need editing by hand: move the value into the vault, leave a pointer, then ROTATE the key)"

echo
bold "3. Secrets currently tracked by git"
any_tracked=false
while IFS= read -r gitdir; do
  repo="$(dirname "$gitdir")"
  tracked=$(cd "$repo" && git ls-files 2>/dev/null | grep -iE '(^|/)(\.env($|\.)|env\.keys|.*\.pem$|id_rsa|credentials\.json)' | grep -viE '\.example$|\.sample$|cacert\.pem')
  if [ -n "$tracked" ]; then
    any_tracked=true
    red "   $repo"
    echo "$tracked" | sed 's|^|      |'
  fi
done < <(find "$ROOT" -maxdepth 3 -name .git -type d 2>/dev/null)
$any_tracked || echo "   none — clean."
$any_tracked && echo "   Fix: git rm --cached <file>, add it to .gitignore, move it to the vault, and ROTATE the key."

if $FIX && [ ${#found_files[@]} -gt 0 ]; then
  echo
  bold "Moving files into the vault"
  for f in "${found_files[@]}"; do
    rel="${f#$ROOT/}"; proj="${rel%%/*}"
    [ "$proj" = "$rel" ] && proj="loose"
    dest="$VAULT/$proj/$(basename "$f")"
    if [ -e "$dest" ]; then echo "   already in vault, skipped: $dest"; continue; fi
    if ! $YES; then
      read -r -p "   Move $rel to vault/$proj/ ? [y/N] " ans </dev/tty
      [[ "$ans" =~ ^[Yy]$ ]] || { echo "      skipped"; continue; }
    fi
    mkdir -p "$(dirname "$dest")"
    mv "$f" "$dest" && ln -s "$dest" "$f" && echo "   vaulted $rel (symlink left behind)"
  done
fi

echo
echo "Vault: $VAULT   (policy: VAULT-README.md there)"
$FIX || echo "Run with --fix to move the files in section 1 into the vault."
