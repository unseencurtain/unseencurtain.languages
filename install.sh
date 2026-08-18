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
FCITX_THEME_DIR="$HOME/.local/share/fcitx5/themes/active"
CLASSICUI_CONF="$HOME/.config/fcitx5/conf/classicui.conf"
STATE_DIR="$HOME/.local/state/unseencurtain.languages"
MOZC_SO="/usr/lib/fcitx5/fcitx5-mozc.so"
MOZC_BACKUP="$STATE_DIR/fcitx5-mozc.so.orig"
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

# mozc's engine hardcodes the composition-mode label "Full Katakana"; patch it
# in place to just "Katakana" (same byte length, NUL-padded, so no offsets
# shift). Offset-independent: searches the string, works across package
# upgrades. Idempotent: skips when the label is already patched. A pristine
# backup is kept so remove.sh can restore the packaged binary.
patch_mozc_label() {
  [[ -f "$MOZC_SO" ]] || { log "fcitx5-mozc engine not found; skipping label patch"; return 0; }
  local tmp
  tmp="$(mktemp /tmp/fcitx5-mozc.so.XXXXXX)"
  cp "$MOZC_SO" "$tmp"
  if ! grep -aq 'Full Katakana' "$tmp"; then
    log "mozc label already patched (or upstream string changed); nothing to do"
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$STATE_DIR"
  cp "$tmp" "$MOZC_BACKUP"
  python3 - "$tmp" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

old = b"Full Katakana\x00"
new = b"Katakana\x00" + b"\x00" * 5
assert len(old) == len(new)
patched = data.replace(old, new)
assert len(patched) == len(data)
assert old not in patched
with open(path, "wb") as f:
    f.write(patched)
PY
  run_privileged install -m 755 "$tmp" "$MOZC_SO"
  rm -f "$tmp"
  if grep -aq 'Full Katakana' "$MOZC_SO"; then
    log "ERROR: mozc label patch failed verification"
    exit 1
  fi
  log "Patched mozc mode label 'Full Katakana' -> 'Katakana' (backup: $MOZC_BACKUP)"
  log "Note: a fcitx5-mozc package upgrade reverts this; re-run install.sh to re-apply"
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

log "Generating the fcitx5/mozc candidate popup theme from the active Omarchy theme"
mkdir -p "$(dirname "$CLASSICUI_CONF")"
cp "$PLUGIN_SRC/classicui.conf" "$CLASSICUI_CONF"
"$PLUGIN_SRC/fcitx-theme-gen.sh"

log "Installing theme-set hook so the popup follows future theme switches"
omarchy hook install theme-set "$PLUGIN_SRC/fcitx-theme-gen.sh"

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

log "Patching mozc 'Full Katakana' mode label to 'Katakana'"
patch_mozc_label

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
