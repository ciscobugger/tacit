#!/usr/bin/env bash

QUICKSHELL_CONFIG_NAME="tacit"  # was "ii": pointed CONFIG_DIR at the stock config, not this one
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE_DIR="$XDG_CACHE_HOME/quickshell"
STATE_DIR="$XDG_STATE_HOME/quickshell"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# the shell's own folder, the one this script is in: ~/.config/quickshell/tacit on the owner's laptop, /usr/share/tacit/shell
# on an install, where the ~/.config one does not exist and the cd below quit before the terminal's colours were made
# (a new account's prompt was the terminal's built-in green, 2026-10-17)
CONFIG_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# The terminals' alpha: Tacit's one window see-through (Tacit.windowSeeThrough: Solid none, Frosted 0.15, Clear its
# own) times this wallpaper's scale (seethrough.py), so foot follows the apps' glass. It was foot.ini's 0.85 always.
term_seethrough=$(jq -r 'if (.appearance.transparency.enable | not) then 0 elif .appearance.transparency.automatic then 0.15
    else .appearance.transparency.backgroundTransparency end' "$XDG_CONFIG_HOME/illogical-impulse/config.json" 2>/dev/null)
term_scale=$(jq -r '.scale // 1' "$STATE_DIR/user/generated/seethrough.json" 2>/dev/null)
term_alpha=$(awk -v s="${term_seethrough:-0.15}" -v k="${term_scale:-1}" 'BEGIN { printf "%d", 100 - 100 * s * k + 0.5 }')
# sleep 0 # idk i wanted some delay or colors dont get applied properly
if [ ! -d "$STATE_DIR"/user/generated ]; then
  mkdir -p "$STATE_DIR"/user/generated
fi
cd "$CONFIG_DIR" || exit

colornames=''
colorstrings=''
colorlist=()
colorvalues=()

colornames=$(cat $STATE_DIR/user/generated/material_colors.scss | cut -d: -f1)
colorstrings=$(cat $STATE_DIR/user/generated/material_colors.scss | cut -d: -f2 | cut -d ' ' -f2 | cut -d ";" -f1)
IFS=$'\n'
colorlist=($colornames)     # Array of color names
colorvalues=($colorstrings) # Array of color values

apply_anyterm() {
  # Check if terminal escape sequence template exists
  if [ ! -f "$SCRIPT_DIR/terminal/sequences.txt" ]; then
    echo "Template file not found for Terminal. Skipping that."
    return
  fi
  # Copy template
  mkdir -p "$STATE_DIR"/user/generated/terminal
  cp "$SCRIPT_DIR/terminal/sequences.txt" "$STATE_DIR"/user/generated/terminal/sequences.txt
  # Apply colors
  sedscript=""
  for i in "${!colorlist[@]}"; do
    sedscript+="s/${colorlist[$i]} #/${colorvalues[$i]#\#}/g"$'\n'
  done
  sedscript+="s/\$alpha/$term_alpha/g"
  sed -i "$sedscript" "$STATE_DIR"/user/generated/terminal/sequences.txt

  for file in /dev/pts/*; do
    if [[ $file =~ ^/dev/pts/[0-9]+$ ]]; then
      {
      cat "$STATE_DIR"/user/generated/terminal/sequences.txt >"$file"
      } & disown || true
    fi
  done
}

apply_term() {
  apply_anyterm
}

# Check if terminal theming is enabled in config
CONFIG_FILE="$XDG_CONFIG_HOME/illogical-impulse/config.json"
if [ -f "$CONFIG_FILE" ]; then
  enable_terminal=$(jq -r '.appearance.wallpaperTheming.enableTerminal' "$CONFIG_FILE")
  if [ "$enable_terminal" = "true" ]; then
    apply_term &
  fi
else
  echo "Config file not found at $CONFIG_FILE. Applying terminal theming by default."
  apply_term &
fi

# Qt theming is handled by kde-material-you-colors

# Folder icons follow the palette (see scripts/colors/icons.py)
python3 "$SCRIPT_DIR/icons.py" &
