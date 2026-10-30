#!/usr/bin/env bash
#
# Live 10-band equalizer backend for illogical-impulse / end-4's pC fork,
# ported from ilyaMiro's Serpantinum shell.
#
# It writes a 32-band EasyEffects "Equalizer" preset (only 10 of the bands
# are user-editable, matching Serpantinum's slider layout) and loads it live
# through EasyEffects.
#
# Needs python3 and jq.
#
# Usage:
#   equalizer.sh <state_dir> get
#   equalizer.sh <state_dir> set_band <1-10> <gainDb>
#   equalizer.sh <state_dir> apply
#   equalizer.sh <state_dir> preset <Flat|Bass|Treble|Vocal|Pop|Rock|Jazz|Classic>
#
# <state_dir> is expected to be Directories.eqStateDir from the QML side
# (e.g. ~/.local/state/quickshell/user/eq), passed in so this script never
# has to guess XDG paths itself.

set -u

STATE_DIR="$1"; shift
cmd="${1:-}"; arg1="${2:-}"; arg2="${3:-}"

mkdir -p "$STATE_DIR"
# Slider drags start one process per step; each reads, edits and rewrites the state file.
exec 9>"$STATE_DIR/.lock"
flock 9
STATE_FILE="$STATE_DIR/eq_state.json"
PRESET_NAME="live_eq"
DEFAULT_STATE='{"b1": 0, "b2": 0, "b3": 0, "b4": 0, "b5": 0, "b6": 0, "b7": 0, "b8": 0, "b9": 0, "b10": 0, "preset": "Flat", "pending": false}'

# EasyEffects is either the native package or the flatpak. The flatpak cannot read
# ~/.config/easyeffects and its binary is not on PATH, so on a flatpak install the preset
# was written where nothing would ever look for it.
if command -v easyeffects >/dev/null 2>&1; then
    PRESET_DIR="$HOME/.config/easyeffects/output"
    EE_LOAD="easyeffects"
elif flatpak info com.github.wwmm.easyeffects >/dev/null 2>&1; then
    PRESET_DIR="$HOME/.var/app/com.github.wwmm.easyeffects/config/easyeffects/output"
    EE_LOAD="flatpak run com.github.wwmm.easyeffects"
else
    PRESET_DIR="$HOME/.config/easyeffects/output"
    EE_LOAD=""
fi
PRESET_FILE="$PRESET_DIR/${PRESET_NAME}.json"

mkdir -p "$PRESET_DIR"

require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    echo "equalizer.sh: jq is required for '$cmd'" >&2
    exit 1
}

# An empty or truncated state file passed the old "does the file exist" guard forever, so a
# single failed write left the equalizer dead until the file was deleted by hand.
seed_state_if_broken() {
    local first=""
    if [ -s "$STATE_FILE" ]; then
        read -r -n1 first < "$STATE_FILE" || true
    fi
    [ "$first" = "{" ] || printf '%s\n' "$DEFAULT_STATE" > "$STATE_FILE"
}
seed_state_if_broken

# Write beside the file and move it into place, so a failed producer cannot blank the state.
write_state() {
    if [ -z "$1" ]; then
        echo "equalizer.sh: refusing to write an empty state file" >&2
        exit 1
    fi
    printf '%s\n' "$1" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

apply_eq() {
    local vals preset
    vals=$(cat "$STATE_FILE")
    preset=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    # 10 user-facing sliders -> spread across a 32-band IIR equalizer,
    # same mapping Serpantinum uses so presets/behaviour stay identical.
    slider_map = { 0:0, 1:3, 2:6, 3:9, 4:12, 5:15, 6:18, 7:21, 8:24, 9:27 }
    freqs = [32, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000, 22000, 24000, 24000]
    gains = [float(data['b1']), float(data['b2']), float(data['b3']), float(data['b4']), float(data['b5']), float(data['b6']), float(data['b7']), float(data['b8']), float(data['b9']), float(data['b10'])]
    bands = {}
    for i in range(32):
        freq = freqs[i] if i < len(freqs) else 20000.0
        gain = 0.0
        for s_idx, b_idx in slider_map.items():
            if i == b_idx:
                gain = gains[s_idx]
                break
        bands[f'band{i}'] = { 'frequency': freq, 'gain': gain, 'mode': 'Bell', 'mute': False, 'q': 1.0, 'solo': False, 'width': 1.0, 'slope': 'x1' }
    preset = { 'output': { 'blocklist': [], 'plugins_order': [ 'equalizer' ], 'equalizer': { 'bypass': False, 'input-gain': 0.0, 'output-gain': 0.0, 'left': bands, 'right': bands, 'mode': 'IIR', 'num-bands': 32, 'split-channels': False } } }
    print(json.dumps(preset, indent=4))
except Exception:
    sys.exit(1)
" "$vals") || {
        echo "equalizer.sh: could not build the EasyEffects preset from the saved state" >&2
        exit 1
    }
    printf '%s\n' "$preset" > "$PRESET_FILE.tmp" && mv "$PRESET_FILE.tmp" "$PRESET_FILE"

    if [ -z "$EE_LOAD" ]; then
        echo "equalizer.sh: EasyEffects is not installed; the preset was saved but not loaded" >&2
        exit 1
    fi
    # Without a running service, -l starts one; keep it out of sight like EasyEffects.enable() does.
    $EE_LOAD --hide-window --service-mode -l "$PRESET_NAME" >/dev/null 2>&1 9>&- &
}

save_preset() {
    require_jq
    local json
    json=$(jq -n -c --arg b1 "$1" --arg b2 "$2" --arg b3 "$3" --arg b4 "$4" --arg b5 "$5" \
          --arg b6 "$6" --arg b7 "$7" --arg b8 "$8" --arg b9 "$9" --arg b10 "${10}" --arg p "${11}" \
       '{"b1": $b1, "b2": $b2, "b3": $b3, "b4": $b4, "b5": $b5, "b6": $b6, "b7": $b7, "b8": $b8, "b9": $b9, "b10": $b10, "preset": $p, "pending": false}') || exit 1
    write_state "$json"
}

case "$cmd" in
    "get") cat "$STATE_FILE" ;;
    "set_band")
        require_jq
        # An empty index built the filter ".b", which jq rejects - and the empty output then
        # went straight into the state file.
        if ! [[ "$arg1" =~ ^([1-9]|10)$ ]] || ! [[ "$arg2" =~ ^-?[0-9]+$ ]]; then
            echo "equalizer.sh: set_band takes a band 1-10 and a whole-number gain" >&2
            exit 1
        fi
        updated=$(jq -c --arg val "$arg2" ".b$arg1 = \$val | .preset = \"Custom\" | .pending = true" "$STATE_FILE") || exit 1
        write_state "$updated"
        ;;
    "apply")
        require_jq
        updated=$(jq -c ".pending = false" "$STATE_FILE") || exit 1
        write_state "$updated"
        apply_eq
        ;;
    "preset")
        case "$arg1" in
            "Flat")    save_preset 0 0 0 0 0 0 0 0 0 0 "Flat" ;;
            "Bass")    save_preset 5 7 5 2 1 0 0 0 1 2 "Bass" ;;
            "Treble")  save_preset -2 -1 0 1 2 3 4 5 6 6 "Treble" ;;
            "Vocal")   save_preset -2 -1 1 3 5 5 4 2 1 0 "Vocal" ;;
            "Pop")     save_preset 2 4 2 0 1 2 4 2 1 2 "Pop" ;;
            "Rock")    save_preset 5 4 2 -1 -2 -1 2 4 5 6 "Rock" ;;
            "Jazz")    save_preset 3 3 1 1 1 1 2 1 2 3 "Jazz" ;;
            "Classic") save_preset 0 1 2 2 2 2 1 2 3 4 "Classic" ;;
            *)
                echo "equalizer.sh: unknown preset '$arg1'" >&2
                exit 1
                ;;
        esac
        apply_eq
        ;;
    *)
        echo "Usage: equalizer.sh <state_dir> <get|set_band|apply|preset> [args...]" >&2
        exit 1
        ;;
esac
