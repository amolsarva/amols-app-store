#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Background Migrator"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE_DIR="${HOME}/mac_migration_${STAMP}"
BUNDLE_DIR="${BASE_DIR}/bundle"
STAGING_DIR="${BASE_DIR}/staging"
REPORT_DIR="${BASE_DIR}/reports"
TOOLS_DIR="${BASE_DIR}/tools"
INSTALLER_DIR="${BASE_DIR}/installer"
LOG_FILE="${BASE_DIR}/run.log"

mkdir -p "$BUNDLE_DIR" "$STAGING_DIR" "$REPORT_DIR" "$TOOLS_DIR" "$INSTALLER_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

json_escape() {
  /usr/bin/python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1]))
PY
}

copy_if_exists() {
  local src="$1"
  local dest="$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    /usr/bin/ditto "$src" "$dest"
    return 0
  fi
  return 1
}

safe_relpath() {
  local p="$1"
  if [[ "$p" == "$HOME"* ]]; then
    printf '%s\n' "\$HOME${p#$HOME}"
  else
    printf '%s\n' "$p"
  fi
}

plist_label() {
  local f="$1"
  /usr/libexec/PlistBuddy -c 'Print :Label' "$f" 2>/dev/null || true
}

plist_program_summary() {
  local f="$1"
  local prog args
  prog=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$f" 2>/dev/null || true)
  if [ -z "$prog" ]; then
    prog=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$f" 2>/dev/null || true)
  fi
  args=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$f" 2>/dev/null || true)
  printf '%s\n' "${prog:-${args:-unknown}}"
}

plist_runatload() {
  local f="$1"
  /usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$f" 2>/dev/null || echo "false"
}

plist_keepalive() {
  local f="$1"
  /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$f" 2>/dev/null || echo "false"
}

plist_health() {
  local f="$1"
  local label prog runatload keepalive lint loaded pid status
  label="$(plist_label "$f")"
  prog="$(plist_program_summary "$f")"
  runatload="$(plist_runatload "$f")"
  keepalive="$(plist_keepalive "$f")"
  lint="bad"
  if plutil -lint "$f" >/dev/null 2>&1; then
    lint="ok"
  fi

  loaded="unknown"
  pid=""
  status=""

  if [ -n "$label" ]; then
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      loaded="loaded"
      pid="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'= ' '/pid =/{print $2; exit}' | tr -d ';')"
      status="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'= ' '/last exit code =/{print $2; exit}' | tr -d ';')"
    elif sudo -n launchctl print "system/$label" >/dev/null 2>&1; then
      loaded="loaded-system"
      pid="$(sudo -n launchctl print "system/$label" 2>/dev/null | awk -F'= ' '/pid =/{print $2; exit}' | tr -d ';')"
      status="$(sudo -n launchctl print "system/$label" 2>/dev/null | awk -F'= ' '/last exit code =/{print $2; exit}' | tr -d ';')"
    else
      loaded="not-loaded"
    fi
  fi

  printf '%s|%s|%s|%s|%s|%s|%s\n' "$label" "$prog" "$lint" "$loaded" "${pid:-}" "${status:-}" "RunAtLoad=$runatload KeepAlive=$keepalive"
}

append_manifest_line() {
  printf '%s\n' "$*" >> "${REPORT_DIR}/manifest.tsv"
}

append_json_item() {
  local type="$1"
  local name="$2"
  local source="$3"
  local bundled="$4"
  local health="$5"
  local details="$6"

  printf '  {\n' >> "${REPORT_DIR}/manifest.json"
  printf '    "type": %s,\n' "$(json_escape "$type")" >> "${REPORT_DIR}/manifest.json"
  printf '    "name": %s,\n' "$(json_escape "$name")" >> "${REPORT_DIR}/manifest.json"
  printf '    "source": %s,\n' "$(json_escape "$source")" >> "${REPORT_DIR}/manifest.json"
  printf '    "bundled": %s,\n' "$(json_escape "$bundled")" >> "${REPORT_DIR}/manifest.json"
  printf '    "health": %s,\n' "$(json_escape "$health")" >> "${REPORT_DIR}/manifest.json"
  printf '    "details": %s\n' "$(json_escape "$details")" >> "${REPORT_DIR}/manifest.json"
  printf '  },\n' >> "${REPORT_DIR}/manifest.json"
}

init_reports() {
  : > "${REPORT_DIR}/manifest.tsv"
  printf '[\n' > "${REPORT_DIR}/manifest.json"
  printf '# %s\n\n' "$APP_NAME" > "${REPORT_DIR}/README.txt"
  printf 'Created: %s\n' "$(date)" >> "${REPORT_DIR}/README.txt"
  printf 'Host: %s\n' "$(scutil --get ComputerName 2>/dev/null || hostname)" >> "${REPORT_DIR}/README.txt"
  printf 'User: %s\n' "$USER" >> "${REPORT_DIR}/README.txt"
  printf 'macOS: %s\n' "$(sw_vers -productVersion 2>/dev/null || true)" >> "${REPORT_DIR}/README.txt"
  printf '\n' >> "${REPORT_DIR}/README.txt"
}

finish_reports() {
  perl -0pi -e 's/,\n\z/\n/s' "${REPORT_DIR}/manifest.json" 2>/dev/null || true
  printf ']\n' >> "${REPORT_DIR}/manifest.json"
}

capture_launchd_user() {
  log "Scanning user LaunchAgents"
  local src_dir="${HOME}/Library/LaunchAgents"
  local dest_dir="${BUNDLE_DIR}/Library/LaunchAgents"
  mkdir -p "$dest_dir"
  if [ -d "$src_dir" ]; then
    find "$src_dir" -maxdepth 1 -type f \( -name '*.plist' -o -name '*.PLIST' \) | while IFS= read -r f; do
      local bn rel health label
      bn="$(basename "$f")"
      rel="$(safe_relpath "$f")"
      copy_if_exists "$f" "${dest_dir}/${bn}" || true
      health="$(plist_health "$f")"
      label="$(plist_label "$f")"
      append_manifest_line "launchagent_user\t${label:-$bn}\t${rel}\t\$HOME/Library/LaunchAgents/${bn}\t${health}"
      append_json_item "launchagent_user" "${label:-$bn}" "$rel" "\$HOME/Library/LaunchAgents/${bn}" "$health" "$bn"
    done
  fi
}

capture_launchd_system() {
  log "Scanning system LaunchDaemons and LaunchAgents"
  local targets=("/Library/LaunchDaemons" "/Library/LaunchAgents")
  local t
  for t in "${targets[@]}"; do
    if [ -d "$t" ]; then
      find "$t" -maxdepth 1 -type f -name '*.plist' | while IFS= read -r f; do
        local bn rel outdir health label typ
        bn="$(basename "$f")"
        rel="$f"
        outdir="${BUNDLE_DIR}${t}"
        mkdir -p "$outdir"
        copy_if_exists "$f" "${outdir}/${bn}" || true
        health="$(plist_health "$f")"
        label="$(plist_label "$f")"
        typ="$(basename "$t" | tr '[:upper:]' '[:lower:]')"
        append_manifest_line "${typ}\t${label:-$bn}\t${rel}\t${t}/${bn}\t${health}"
        append_json_item "$typ" "${label:-$bn}" "$rel" "${t}/${bn}" "$health" "$bn"
      done
    fi
  done
}

capture_cron() {
  log "Scanning cron"
  mkdir -p "${BUNDLE_DIR}/cron"
  local crontxt="${BUNDLE_DIR}/cron/user.crontab"
  if crontab -l >"$crontxt" 2>/dev/null; then
    local count
    count="$(grep -vc '^\s*#' "$crontxt" || true)"
    append_manifest_line "cron\tuser-crontab\tcrontab -l\tbundle/cron/user.crontab\tentries=${count}"
    append_json_item "cron" "user-crontab" "crontab -l" "bundle/cron/user.crontab" "entries=${count}" "user cron"
  else
    rm -f "$crontxt"
  fi

  if [ -d /usr/lib/cron/tabs ]; then
    mkdir -p "${BUNDLE_DIR}/cron/system_tabs"
    copy_if_exists "/usr/lib/cron/tabs" "${BUNDLE_DIR}/cron/system_tabs" || true
  fi
}

capture_shell_startup() {
  log "Scanning shell startup files"
  mkdir -p "${BUNDLE_DIR}/shell"
  local files=(
    "$HOME/.zshrc"
    "$HOME/.zprofile"
    "$HOME/.zlogin"
    "$HOME/.zlogout"
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.profile"
    "$HOME/.config/fish/config.fish"
  )
  local f
  for f in "${files[@]}"; do
    if [ -e "$f" ]; then
      local rel dest
      rel="$(safe_relpath "$f")"
      dest="${BUNDLE_DIR}/shell${rel//\$HOME/}"
      mkdir -p "$(dirname "$dest")"
      copy_if_exists "$f" "$dest" || true
      append_manifest_line "shell\t$(basename "$f")\t${rel}\t${dest#$BASE_DIR/}\tpresent"
      append_json_item "shell" "$(basename "$f")" "$rel" "${dest#$BASE_DIR/}" "present" "shell startup"
    fi
  done
}

capture_login_items() {
  log "Capturing login items"
  mkdir -p "${BUNDLE_DIR}/login_items"
  local out="${BUNDLE_DIR}/login_items/login_items.txt"
  osascript <<'OSA' > "$out" 2>/dev/null || true
tell application "System Events"
  get the name of every login item
end tell
OSA
  if [ -s "$out" ]; then
    append_manifest_line "login_items\tmacos-login-items\tSystem Events\tbundle/login_items/login_items.txt\tcaptured"
    append_json_item "login_items" "macos-login-items" "System Events" "bundle/login_items/login_items.txt" "captured" "names only"
  fi
}

capture_common_automation_dirs() {
  log "Capturing common automation directories"
  local paths=(
    "$HOME/.hammerspoon"
    "$HOME/Library/Application Support/Keyboard Maestro"
    "$HOME/Library/Application Support/BetterTouchTool"
    "$HOME/Library/Application Support/Alfred"
    "$HOME/Library/Application Support/com.raycast.macos"
    "$HOME/Library/Scripts"
    "$HOME/Library/Services"
    "$HOME/Applications"
    "$HOME/bin"
    "$HOME/.local/bin"
    "$HOME/.config"
    "$HOME/.shortcuts"
    "$HOME/Documents/Automator"
  )
  local p
  for p in "${paths[@]}"; do
    if [ -e "$p" ]; then
      local rel dest
      rel="$(safe_relpath "$p")"
      dest="${BUNDLE_DIR}/extras${rel//\$HOME/}"
      mkdir -p "$(dirname "$dest")"
      copy_if_exists "$p" "$dest" || true
      append_manifest_line "extra\t$(basename "$p")\t${rel}\t${dest#$BASE_DIR/}\tpresent"
      append_json_item "extra" "$(basename "$p")" "$rel" "${dest#$BASE_DIR/}" "present" "common automation folder"
    fi
  done
}

capture_brew_services() {
  if ! have brew; then
    return 0
  fi
  log "Capturing Homebrew services"
  mkdir -p "${BUNDLE_DIR}/brew"
  brew services list > "${BUNDLE_DIR}/brew/services.txt" 2>/dev/null || true
  brew list --formula > "${BUNDLE_DIR}/brew/formulae.txt" 2>/dev/null || true
  brew list --cask > "${BUNDLE_DIR}/brew/casks.txt" 2>/dev/null || true

  append_manifest_line "brew\tservices\tbrew services list\tbundle/brew/services.txt\tcaptured"
  append_json_item "brew" "services" "brew services list" "bundle/brew/services.txt" "captured" "brew services"
}

capture_recent_logs() {
  log "Capturing helpful diagnostics"
  mkdir -p "${BUNDLE_DIR}/diagnostics"
  launchctl list > "${BUNDLE_DIR}/diagnostics/launchctl_list.txt" 2>/dev/null || true
  ps aux > "${BUNDLE_DIR}/diagnostics/ps_aux.txt" 2>/dev/null || true
  if have brew; then
    brew services list > "${BUNDLE_DIR}/diagnostics/brew_services.txt" 2>/dev/null || true
  fi
}

write_installer() {
  log "Writing installer TUI"
  cat > "${INSTALLER_DIR}/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SELF_DIR}/.." && pwd)"
BUNDLE_DIR="${ROOT_DIR}/bundle"
REPORT_DIR="${ROOT_DIR}/reports"
LOG_FILE="${ROOT_DIR}/installer/install.log"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

pause() {
  read -r -p "Press Enter to continue..."
}

have() {
  command -v "$1" >/dev/null 2>&1
}

copy_merge() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  /usr/bin/ditto "$src" "$dest"
}

install_launchagents() {
  local src="${BUNDLE_DIR}/Library/LaunchAgents"
  local dest="${HOME}/Library/LaunchAgents"
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    find "$src" -maxdepth 1 -type f -name '*.plist' | while IFS= read -r f; do
      local bn
      bn="$(basename "$f")"
      log "Installing LaunchAgent $bn"
      cp "$f" "$dest/$bn"
      launchctl bootout "gui/$(id -u)" "$dest/$bn" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/$(id -u)" "$dest/$bn" >/dev/null 2>&1 || true
      launchctl enable "gui/$(id -u)/$(/usr/libexec/PlistBuddy -c 'Print :Label' "$dest/$bn" 2>/dev/null || true)" >/dev/null 2>&1 || true
      launchctl kickstart -k "gui/$(id -u)/$(/usr/libexec/PlistBuddy -c 'Print :Label' "$dest/$bn" 2>/dev/null || true)" >/dev/null 2>&1 || true
    done
  fi
}

install_shell_files() {
  local src="${BUNDLE_DIR}/shell"
  if [ -d "$src" ]; then
    log "Installing shell files"
    find "$src" -mindepth 1 | while IFS= read -r f; do
      local rel dest
      rel="${f#$src/}"
      dest="${HOME}/${rel}"
      mkdir -p "$(dirname "$dest")"
      if [ -d "$f" ]; then
        mkdir -p "$dest"
      else
        cp "$f" "$dest"
      fi
    done
  fi
}

install_extras() {
  local src="${BUNDLE_DIR}/extras"
  if [ -d "$src" ]; then
    log "Installing extras"
    find "$src" -mindepth 1 -maxdepth 1 | while IFS= read -r f; do
      local bn
      bn="$(basename "$f")"
      copy_merge "$f" "${HOME}/${bn}"
    done
  fi
}

install_cron() {
  local src="${BUNDLE_DIR}/cron/user.crontab"
  if [ -f "$src" ]; then
    log "Installing user crontab"
    crontab "$src"
  fi
}

show_health() {
  echo
  echo "=== Bundle contents ==="
  if [ -f "${REPORT_DIR}/manifest.tsv" ]; then
    column -t -s $'\t' "${REPORT_DIR}/manifest.tsv" 2>/dev/null || cat "${REPORT_DIR}/manifest.tsv"
  else
    echo "No manifest found."
  fi
  echo
}

customize_plists() {
  local dir="${HOME}/Library/LaunchAgents"
  [ -d "$dir" ] || { echo "No user LaunchAgents installed yet."; return; }
  echo
  echo "Installed LaunchAgents:"
  find "$dir" -maxdepth 1 -type f -name '*.plist' -print | nl -w2 -s'. '
  echo
  echo "You can now edit them manually, for example:"
  echo "  nano ~/Library/LaunchAgents/com.example.task.plist"
  echo
  pause
}

brew_reinstall_suggestions() {
  local formulas="${BUNDLE_DIR}/brew/formulae.txt"
  local casks="${BUNDLE_DIR}/brew/casks.txt"
  echo
  echo "=== Suggested Homebrew reinstall commands ==="
  if [ -f "$formulas" ]; then
    echo "# Formulae"
    awk '{print "brew install " $0}' "$formulas"
  fi
  if [ -f "$casks" ]; then
    echo
    echo "# Casks"
    awk '{print "brew install --cask " $0}' "$casks"
  fi
  echo
  pause
}

guided_install() {
  echo
  echo "Guided install:"
  echo "1) Install user LaunchAgents"
  echo "2) Install shell startup files"
  echo "3) Install extras/common automation folders"
  echo "4) Install cron"
  echo "5) Show brew reinstall suggestions"
  echo "6) Back"
  read -r -p "Choose: " c
  case "$c" in
    1) install_launchagents; pause ;;
    2) install_shell_files; pause ;;
    3) install_extras; pause ;;
    4) install_cron; pause ;;
    5) brew_reinstall_suggestions ;;
    *) ;;
  esac
}

full_install() {
  install_shell_files
  install_extras
  install_cron
  install_launchagents
  echo
  echo "Done. Some app-specific tools may still need a first launch or permissions."
  echo
  pause
}

main_menu() {
  while true; do
    clear
    echo "=========================================="
    echo " Mac Background Migrator Installer"
    echo "=========================================="
    echo "1) Show bundle contents / health report"
    echo "2) Guided install"
    echo "3) Full install"
    echo "4) Customize / inspect LaunchAgents"
    echo "5) Show brew reinstall suggestions"
    echo "6) Quit"
    echo
    read -r -p "Choose: " choice
    case "$choice" in
      1) show_health; pause ;;
      2) guided_install ;;
      3) full_install ;;
      4) customize_plists ;;
      5) brew_reinstall_suggestions ;;
      6) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu
INSTALL
  chmod +x "${INSTALLER_DIR}/install.sh"
}

write_quickstart() {
  cat > "${BASE_DIR}/HOW_TO_USE.txt" <<EOF
${APP_NAME}

OLD MAC:
1. This bundle was created at:
   ${BASE_DIR}
2. Review:
   - ${REPORT_DIR}/README.txt
   - ${REPORT_DIR}/manifest.tsv
   - ${REPORT_DIR}/manifest.json
3. Package to a single archive:
   tar -czf "${HOME}/mac_migration_bundle_${STAMP}.tar.gz" -C "${BASE_DIR}" .

NEW MAC:
1. Copy the .tar.gz over
2. Extract it:
   tar -xzf mac_migration_bundle_${STAMP}.tar.gz
3. Run:
   cd mac_migration_${STAMP}/installer
   ./install.sh

Notes:
- Some apps require separate export/import or app-specific authorization:
  Keyboard Maestro, Alfred, Raycast, BetterTouchTool, Hammerspoon, Automator, Shortcuts.
- System LaunchDaemons in /Library may require sudo and manual review.
- Login Items are captured as names only; re-enable them manually if needed.
EOF
}

main() {
  if ! have /usr/bin/python3; then
    echo "python3 is required on this Mac."
    exit 1
  fi

  init_reports
  capture_launchd_user
  capture_launchd_system
  capture_cron
  capture_shell_startup
  capture_login_items
  capture_common_automation_dirs
  capture_brew_services
  capture_recent_logs
  write_installer
  write_quickstart
  finish_reports

  local archive="${HOME}/mac_migration_bundle_${STAMP}.tar.gz"
  log "Creating archive at ${archive}"
  tar -czf "$archive" -C "${BASE_DIR}" .

  echo
  echo "=================================================="
  echo "Done."
  echo "Bundle dir:  ${BASE_DIR}"
  echo "Archive:     ${archive}"
  echo "Installer:   ${INSTALLER_DIR}/install.sh"
  echo "Manifest:    ${REPORT_DIR}/manifest.tsv"
  echo "=================================================="
  echo
}

main "$@"
