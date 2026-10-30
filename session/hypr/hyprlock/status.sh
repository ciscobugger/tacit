#!/usr/bin/env bash
# Battery for the lock screen: the EC battery on the Book4 (the qcom-battmgr devices are dead and report 0%),
# else the first system battery (not a mouse, keyboard or controller: scope Device). Prints "42%" or "42% charging".
bat=
for d in /sys/class/power_supply/book4-ec-battery /sys/class/power_supply/*; do
  [[ -r $d/capacity && $(<"$d/type") == Battery && ( ! -r $d/scope || $(<"$d/scope") != Device ) ]] && { bat=$d; break; }
done
[[ -n $bat ]] || exit 0
cap=$(<"$bat/capacity")
if [[ $(<"$bat/status") == Charging ]]; then
  echo "${cap}% charging"
else
  echo "${cap}%"
fi
