#!/usr/bin/env bash
# The notch's status glyph on the lock screen, as a Material Symbols ligature name.
# Same order as the desktop: charging, then night light. Empty when nothing applies.
# Nothing either without the font: installs have no Material Symbols, and the name itself was drawn beside the
# time ("21:41 bedtime", test computer, 2026-10-29)
fc-list -q "Material Symbols Rounded" || exit 0
b=/sys/class/power_supply/book4-ec-battery/status
if [[ -r $b && $(<"$b") == Charging ]]; then echo bolt; exit; fi
t=$(hyprctl hyprsunset temperature 2>/dev/null | head -1)
[[ -n $t && $t != 6500 ]] && echo bedtime
