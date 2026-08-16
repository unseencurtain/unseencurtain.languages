#!/usr/bin/env bash

set -euo pipefail

PLUGIN_ID="unseencurtain.languages"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$SCRIPT_DIR"
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
FCITX_PROFILE="$HOME/.config/fcitx5/profile"
FCITX_CONFIG="$HOME/.config/fcitx5/config"
INPUT_LUA="$HOME/.config/hypr/input.lua"
BINDINGS_LUA="$HOME/.config/hypr/bindings.lua"
LOOKNFEEL_LUA="$HOME/.config/hypr/looknfeel.lua"
FCITX_THEME_DIR="$HOME/.local/share/fcitx5/themes/tokyonight"
CLASSICUI_CONF="$HOME/.config/fcitx5/conf/classicui.conf"
PACKAGES=(fcitx5-mozc fcitx5-chinese-addons fcitx5-hangul wtype)
KANA_BIND_MARKER="# [unseencurtain.languages] Alt+U toggles Japanese hiragana/katakana mode"
KANA_BIND='o.bind("ALT + U", "Toggle hiragana/katakana", "omarchy-shell unseencurtain.languages toggleKana")'
LAST_BIND_MARKER="# [unseencurtain.languages] Alt+I toggles the previous input method"
LAST_BIND='o.bind("ALT + I", "Toggle previous input method", "omarchy-shell unseencurtain.languages toggleLast")'
GLASSY_MARKER_START="-- [unseencurtain.languages] glassy fcitx5/mozc candidate popup (START)"
GLASSY_MARKER_END="-- [unseencurtain.languages] glassy fcitx5/mozc candidate popup (END)"

log() {
  printf '[install-sine-languages] %s\n' "$*"
}

run_privileged_pacman() {
  if sudo -n true 2>/dev/null; then
    sudo pacman "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec pacman "$@"
  else
    sudo pacman "$@"
  fi
}

install_packages() {
  local missing=()
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if (( ${#missing[@]} == 0 )); then
    log "IME packages already installed"
    return 0
  fi

  log "Installing missing IME packages: ${missing[*]}"
  run_privileged_pacman -S --needed --noconfirm "${missing[@]}"
}

[[ -f "$PLUGIN_SRC/manifest.json" ]] || { log "Missing plugin source: $PLUGIN_SRC"; exit 1; }

install_packages

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
hyprctl reload >/dev/null 2>&1 || true

log "Adding Alt+U hiragana/katakana and Alt+I previous-IM hotkeys to Hyprland bindings"
mkdir -p "$(dirname "$BINDINGS_LUA")"
touch "$BINDINGS_LUA"
if ! grep -qF "$KANA_BIND" "$BINDINGS_LUA" 2>/dev/null; then
  {
    echo
    echo "$KANA_BIND_MARKER"
    echo "$KANA_BIND"
  } >> "$BINDINGS_LUA"
fi
if ! grep -qF "$LAST_BIND" "$BINDINGS_LUA" 2>/dev/null; then
  {
    echo
    echo "$LAST_BIND_MARKER"
    echo "$LAST_BIND"
  } >> "$BINDINGS_LUA"
fi
hyprctl reload >/dev/null 2>&1 || true

log "Installing Tokyo Night theme for the fcitx5/mozc candidate popup"
mkdir -p "$FCITX_THEME_DIR" "$(dirname "$CLASSICUI_CONF")"
cp "$PLUGIN_SRC/themes/tokyonight/theme.conf" "$FCITX_THEME_DIR/theme.conf"
cp "$PLUGIN_SRC/classicui.conf" "$CLASSICUI_CONF"

log "Enabling glassy blur for the candidate popup in Hyprland looknfeel"
mkdir -p "$(dirname "$LOOKNFEEL_LUA")"
touch "$LOOKNFEEL_LUA"
if ! grep -qF -e "$GLASSY_MARKER_START" "$LOOKNFEEL_LUA" 2>/dev/null; then
  {
    echo
    echo "$GLASSY_MARKER_START"
    echo "hl.config({"
    echo "  decoration = {"
    echo "    blur = {"
    echo "      input_methods = true,"
    echo "      input_methods_ignorealpha = 0.2,"
    echo "    },"
    echo "  },"
    echo "})"
    echo "$GLASSY_MARKER_END"
  } >> "$LOOKNFEEL_LUA"
fi
hyprctl reload >/dev/null 2>&1 || true

log "Configuring fcitx5 input methods"
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

[Groups/0/Items/1]
# Name
Name=mozc
# Layout
Layout=

[Groups/0/Items/2]
# Name
Name=pinyin
# Layout
Layout=

[Groups/0/Items/3]
# Name
Name=hangul
# Layout
Layout=

[GroupOrder]
0=Default
EOF

log "Configuring fcitx5 shared input state (English safe default)"
cat > "$FCITX_CONFIG" <<'EOF'
[Behavior]
ShareInputState=All
ActiveByDefault=False
EOF
systemctl --user start omarchy-fcitx5.service 2>/dev/null || true
sleep 2

log "Installing plugin into Omarchy config"
rm -rf "$PLUGIN_DST"
mkdir -p "$PLUGIN_DST"
cp "$PLUGIN_SRC/manifest.json" "$PLUGIN_SRC/Panel.qml" "$PLUGIN_DST/"

log "Validating and enabling plugin"
omarchy plugin validate "$PLUGIN_DST"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1
omarchy plugin enable "$PLUGIN_ID" right

log "Restarting Omarchy shell"
omarchy restart shell >/dev/null 2>&1 || true

log "Verifying fcitx5 switching"
for im in mozc pinyin hangul; do
  sh -c "fcitx5-remote -s $im && fcitx5-remote -o" >/dev/null
  sleep 0.2
  [[ "$(fcitx5-remote -n)" == "$im" ]] || { log "Failed to switch to $im"; exit 1; }
done
sh -c "fcitx5-remote -s keyboard-us && fcitx5-remote -c" >/dev/null

log "Install complete"
