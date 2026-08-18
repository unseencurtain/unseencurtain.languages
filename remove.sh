#!/usr/bin/env bash

set -euo pipefail

PLUGIN_ID="unseencurtain.languages"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
FCITX_PROFILE="$HOME/.config/fcitx5/profile"
FCITX_CONFIG="$HOME/.config/fcitx5/config"
FCITX_CONF_DIR="$HOME/.config/fcitx5/conf"
INPUT_LUA="$HOME/.config/hypr/input.lua"
BINDINGS_LUA="$HOME/.config/hypr/bindings.lua"
LOOKNFEEL_LUA="$HOME/.config/hypr/looknfeel.lua"
FCITX_THEME_DIR="$HOME/.local/share/fcitx5/themes/active"
LEGACY_FCITX_THEME_DIR="$HOME/.local/share/fcitx5/themes/tokyonight"
CLASSICUI_CONF="$HOME/.config/fcitx5/conf/classicui.conf"
FCITX_THEME_HOOK="$HOME/.config/omarchy/hooks/theme-set.d/fcitx-theme-gen.sh"
STATE_DIR="$HOME/.local/state/unseencurtain.languages"
MOZC_SO="/usr/lib/fcitx5/fcitx5-mozc.so"
MOZC_BACKUP="$STATE_DIR/fcitx5-mozc.so.orig"
PACKAGES=(fcitx5-mozc fcitx5-chinese-addons fcitx5-hangul)

log() {
  printf '[remove-sine-languages] %s\n' "$*"
}

restart_fcitx5() {
  systemctl --user start omarchy-fcitx5.service 2>/dev/null || true
}

trap restart_fcitx5 EXIT

run_privileged() {
  if sudo -n true 2>/dev/null; then
    sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  else
    sudo "$@"
  fi
}

run_privileged_pacman() {
  run_privileged pacman "$@"
}

# Undo the install.sh binary patch of mozc's "Full Katakana" label. Only
# restores when the installed engine is actually patched AND a pristine backup
# exists — never overwrites a newer packaged binary with an older backup.
restore_mozc_label() {
  [[ -f "$MOZC_SO" ]] || return 0
  if [[ -f "$MOZC_BACKUP" ]] && ! grep -aq 'Full Katakana' "$MOZC_SO"; then
    run_privileged install -m 755 "$MOZC_BACKUP" "$MOZC_SO"
    log "Restored original mozc engine (unpatched the 'Katakana' label)"
  elif grep -aq 'Full Katakana' "$MOZC_SO"; then
    log "mozc engine label already original"
  else
    log "NOTE: mozc engine is patched but no backup exists; removing the fcitx5-mozc package below installs a pristine file"
  fi
}

remove_packages() {
  local installed=()
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 && installed+=("$pkg")
  done

  if (( ${#installed[@]} == 0 )); then
    log "CJK fcitx5 packages already absent"
    return 0
  fi

  log "Removing CJK fcitx5 packages and unused dependencies: ${installed[*]}"
  run_privileged_pacman -Rns --noconfirm "${installed[@]}"
}

remove_kana_bind() {
  [[ -f "$BINDINGS_LUA" ]] || return 0
  python3 - "$BINDINGS_LUA" <<'PY'
import sys

path = sys.argv[1]
markers = [
    "# [unseencurtain.languages] Alt+U toggles Japanese hiragana/katakana mode",
    "o.bind(\"ALT + U\", \"Toggle hiragana/katakana\", \"omarchy-shell unseencurtain.languages toggleKana\")",
    "# [unseencurtain.languages] Alt+I toggles the previous input method",
    "o.bind(\"ALT + I\", \"Toggle previous input method\", \"omarchy-shell unseencurtain.languages toggleLast\")",
]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

filtered = [
    line for line in lines
    if line.strip() not in markers
]
if filtered != lines:
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(filtered)
PY
}

remove_glassy_popup() {
  [[ -f "$LOOKNFEEL_LUA" ]] || return 0
  python3 - "$LOOKNFEEL_LUA" <<'PY'
import sys

path = sys.argv[1]
start = "-- [unseencurtain.languages] glassy fcitx5/mozc candidate popup (START)"
end = "-- [unseencurtain.languages] glassy fcitx5/mozc candidate popup (END)"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

filtered = []
skipping = False
removed = False
for line in lines:
    if line.strip() == start:
        skipping = True
        removed = True
        continue
    if skipping:
        if line.strip() == end:
            skipping = False
        continue
    filtered.append(line)
if removed and filtered != lines:
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(filtered)
PY
}

remove_bar_entry_fallback() {
  [[ -f "$SHELL_JSON" ]] || return 0
  python3 - "$SHELL_JSON" "$PLUGIN_ID" <<'PY'
import json
import sys

path, plugin_id = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

layout = data.get("bar", {}).get("layout", {})
changed = False
for section in ("left", "center", "right"):
    entries = layout.get(section)
    if not isinstance(entries, list):
        continue
    filtered = [entry for entry in entries if not (isinstance(entry, dict) and entry.get("id") == plugin_id)]
    if filtered != entries:
        layout[section] = filtered
        changed = True

if changed:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PY
}

log "Disabling Omarchy plugin entry if present"
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
remove_bar_entry_fallback

log "Removing plugin directory"
rm -rf "$PLUGIN_DIR"

log "Restoring Hyprland input config to US layout with Caps as Escape"
mkdir -p "$(dirname "$INPUT_LUA")"
cat > "$INPUT_LUA" <<'EOF'
-- Keep only your personal input overrides here. Uncommented settings below
-- replace Omarchy's defaults.

-- Keyboard layout and options.
hl.config({
  input = {
    kb_layout = "us",
    kb_options = "caps:escape",
  },
})
EOF

log "Removing Alt+U hiragana/katakana and Alt+I previous-IM hotkeys from Hyprland bindings"
remove_kana_bind

log "Removing glassy candidate-popup blur from Hyprland looknfeel"
remove_glassy_popup

log "Reloading Hyprland"
hyprctl reload >/dev/null 2>&1 || true

log "Resetting fcitx5 profile to English-only"
systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
mkdir -p "$(dirname "$FCITX_PROFILE")"
cat > "$FCITX_PROFILE" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=keyboard-us

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[GroupOrder]
0=Default
EOF

log "Unpatching mozc 'Full Katakana' label if this install patched it"
restore_mozc_label

remove_packages

log "Removing fcitx5 config files created for this plugin"
rm -f "$FCITX_CONFIG"
rm -f "$CLASSICUI_CONF"
rm -f "$FCITX_CONF_DIR/hangul.conf"
rm -f "$FCITX_CONF_DIR/pinyin.conf"
rm -f "$FCITX_CONF_DIR/chttrans.conf"
rm -f "$FCITX_PROFILE".bak.*

log "Removing the theme-set hook that kept the candidate popup themed"
rm -f "$FCITX_THEME_HOOK"

log "Removing fcitx5 theme created for this plugin (and legacy tokyonight dir)"
rm -rf "$FCITX_THEME_DIR" "$LEGACY_FCITX_THEME_DIR"

log "Removing plugin state directory (kana mode, last IM, mozc backup)"
rm -rf "$STATE_DIR"

restart_fcitx5
trap - EXIT

log "Restarting Omarchy shell"
omarchy restart shell >/dev/null 2>&1 || true

log "Removal complete. The plugin source in the omarchy-plugins repo was left in place."
