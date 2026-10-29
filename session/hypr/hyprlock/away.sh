#!/usr/bin/env bash
# Unread notifications from the shell, phrased for the lock screen; empty when none.
# Only a plain number from a call that worked: with no shell running (when this lock stands in for the shell's), qs
# printed its dead instances' names, and their digits read as "9681 notifications" (test computer, 2026-10-29)
n=$(timeout 1 qs -p "${TACIT_SHELL:-$HOME/.config/quickshell/tacit}" ipc call notifications count 2>/dev/null) || exit 0
[[ $n =~ ^[0-9]+$ && $n != 0 ]] || exit 0
[[ $n == 1 ]] && echo "1 notification while you were away" || echo "$n notifications while you were away"
