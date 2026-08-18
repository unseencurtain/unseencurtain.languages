#!/usr/bin/env bash
# Generates the fcitx5/mozc candidate popup theme from the active Omarchy theme.
# Colors are read from the active theme snapshot (~/.local/state/omarchy/current/theme/colors.toml)
# so the popup follows theme switches automatically. This script is installed
# as a theme-set hook (theme-set.d/fcitx-theme-gen.sh) and re-runs on every
# `omarchy theme set`.
#
# It writes ~/.local/share/fcitx5/themes/active/theme.conf (the theme referenced
# by classicui.conf: Theme=active), then asks fcitx5 to reload its config so the
# new colors appear immediately.

set -euo pipefail

FCITX_THEME_DIR="${FCITX_THEME_DIR:-$HOME/.local/share/fcitx5/themes/active}"
THEME_COLORS="${THEME_COLORS:-$HOME/.local/state/omarchy/current/theme/colors.toml}"

# Fallbacks (Tokyo Night) apply when no active theme colors are found, so a
# sane popup still renders outside Omarchy / before any theme is set.
DEFAULT_BACKGROUND="#1a1b26"
DEFAULT_FOREGROUND="#a9b1d6"
DEFAULT_BRIGHT_FOREGROUND="#c0caf5"
DEFAULT_ACCENT="#7aa2f7"
DEFAULT_SELECTION="#292e42"
DEFAULT_MUTED="#3b4261"

get_color() {
  local key="$1" default="$2" val
  val="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$THEME_COLORS" | head -n 1)"
  printf '%s' "${val:-$default}"
}

# fcitx5 theme colors are #RRGGBB; the popup background needs an alpha channel
# (#RRGGBBAA, alpha LAST) for the glassy blur to show the desktop through.
with_alpha() {
  local color="$1" alpha="${2:-cc}"
  if [[ "$color" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
    printf '%s%s' "$color" "$alpha"
  else
    printf '%s' "$color"
  fi
}

background="$(get_color background "$DEFAULT_BACKGROUND")"
foreground="$(get_color foreground "$DEFAULT_FOREGROUND")"
highlight_text="$(get_color bright_foreground "$DEFAULT_BRIGHT_FOREGROUND")"
accent="$(get_color accent "$DEFAULT_ACCENT")"
selection="$(get_color selection "$DEFAULT_SELECTION")"
muted="$(get_color muted "$DEFAULT_MUTED")"
background_alpha="$(with_alpha "$background")"

mkdir -p "$FCITX_THEME_DIR"

cat > "$FCITX_THEME_DIR/theme.conf" <<EOF
[Metadata]
Name=Active Omarchy Theme
Version=1
Author=unseencurtain.languages
Description=Generated from the active Omarchy theme for unseencurtain.languages
ScaleWithDPI=True

[InputPanel]
NormalColor=$foreground
HighlightColor=$highlight_text
PageButtonAlignment=Last Candidate

[InputPanel/TextMargin]
Left=10
Right=10
Top=6
Bottom=6

[InputPanel/ContentMargin]
Left=6
Right=6
Top=4
Bottom=4

[InputPanel/Background]
Color=$background_alpha
BorderColor=$accent
BorderWidth=1

[InputPanel/Background/Margin]
Left=2
Right=2
Top=2
Bottom=2

[InputPanel/Highlight]
Color=$selection
BorderColor=$accent
BorderWidth=1

[InputPanel/Highlight/Margin]
Left=5
Right=5
Top=5
Bottom=5

[Menu/Background]
Color=$background_alpha
BorderColor=$accent
BorderWidth=1

[Menu/Background/Margin]
Left=2
Right=2
Top=2
Bottom=2

[Menu/ContentMargin]
Left=2
Right=2
Top=2
Bottom=2

[Menu/TextMargin]
Left=8
Right=8
Top=5
Bottom=5

[Menu/Highlight]
Color=$selection

[Menu/Highlight/Margin]
Left=5
Right=5
Top=5
Bottom=5

[Menu/Separator]
Color=$muted
EOF

# fcitx5 re-reads the classicui theme only at startup: `fcitx5-remote -r`
# (ReloadConfig) does NOT re-apply theme.conf, so restart the process. Use the
# D-Bus Restart() method, not `systemctl --user restart`: it restarts the
# actual running instance even when fcitx5 was started outside the service,
# and it avoids systemd start-limit throttling when themes are switched
# quickly. Only restart when fcitx5 is actually running — install.sh calls
# this before the service starts, and the theme file is read when it does.
if fcitx5-remote --check >/dev/null 2>&1; then
  gdbus call --address "unix:path=/run/user/$(id -u)/bus" \
    --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.Restart >/dev/null 2>&1 || true
fi