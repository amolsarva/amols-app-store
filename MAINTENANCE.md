# How to push mac-scripts to GitHub

The repo is already initialized and committed locally. Here's how to get it on GitHub.

## Step 1: Create the repo on GitHub

Go to: https://github.com/new

- **Repository name:** `mac-scripts`
- **Visibility:** Public (so amolsarva.com can link to it)
- **Do NOT** initialize with README, .gitignore, or license (the repo already has these)

Click **Create repository**.

## Step 2: Push from your Mac

Open Terminal, then run:

```bash
cd ~/Documents/root/mac-scripts

# Add GitHub as the remote
git remote add origin https://github.com/amolsarva/amols-app-store.git

# Rename branch to main (GitHub default)
git branch -m master main

# Push
git push -u origin main
```

If prompted for credentials, use your GitHub username + a personal access token (not your password).
Generate one at: https://github.com/settings/tokens → New token → check `repo` scope.

## Step 3: Add scripts.html to your website

The catalog page is at: `~/Documents/root/mac-scripts/scripts.html`

Copy it to your amolsarva.com project as a new page (e.g. `/scripts` or `/mac-scripts`).

Also grab `homepage-section-snippet.html` — drop that into your homepage wherever you want the "Scripts to make your life easier" section.

Update the link in the snippet to point to wherever you host scripts.html:
```html
<a href="/scripts">Browse all scripts →</a>
```

## File locations summary

```
~/Documents/root/mac-scripts/
  README.md                         ← top-level GitHub README
  scripts.html                      ← the full catalog page
  homepage-section-snippet.html     ← drop into amolsarva.com homepage
  GITHUB-PUSH-INSTRUCTIONS.md       ← this file
  abbu-to-csv/
  bigfiles/
  cleanicloud/
  cpu-guard/
  drive-dedup/
  github-autopush/
  imessage-cleanup/
  mac-migrator/
  pdf-to-xls/
  personalcontacts-analyzer/
  screenshot-tidy/
```

Each subfolder contains the script(s) + a README.md.
