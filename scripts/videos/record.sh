#!/usr/bin/env bash
# Screen recording: a second call while one runs stops it.
#   record.sh [--region "X,Y WxH" | --fullscreen [--output NAME]] [--sound | --mic]
#   record.sh --stop       stops one if it runs, and clears a state left saying it does
# --region takes slurp's form (logical, global); without it or --fullscreen, slurp asks. --sound records what the
# computer plays, --mic the microphone. The notch reads the state (states.json .record: enable, file, started, thumb)
# and says it all, so this script only speaks when something fails.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"
CUSTOM_PATH=$(jq -r '.screenRecord.savePath // empty' "$CONFIG_FILE" 2>/dev/null)
RECORDING_DIR="${CUSTOM_PATH:-$HOME/Videos}"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/states.json"
THUMB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/recordings"

say() {
    notify-send "Screen recording" "$1" -a 'Recorder' & disown
}

# set_state <jq filter> [jq args...]
set_state() {
    local filter=$1 tmp
    shift
    tmp=$(mktemp)
    # Without the file the jq pipeline writes nothing, the `&& mv` never runs, and the shell's
    # recording indicator keeps whatever it had - so it says "recording" when nothing is.
    if [[ ! -f "$STATE_FILE" ]] || ! jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
        rm -f "$tmp"
        say "Could not update $STATE_FILE, so the notch may be wrong about the recording."
        return 1
    fi
    mv "$tmp" "$STATE_FILE"
}

getactivemonitor() {
    hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name'
}

# The second call: wf-recorder finishes the file on SIGINT, and the call that started it writes the state once it has.
if [[ "$1" == --stop ]] && ! pgrep -x wf-recorder > /dev/null; then
    [[ "$(jq -r '.record.enable' "$STATE_FILE" 2>/dev/null)" == "true" ]] && set_state '.record.enable = false'
    exit 0
fi
if pgrep -x wf-recorder > /dev/null; then
    pkill -INT -x wf-recorder
    for _ in $(seq 50); do
        pgrep -x wf-recorder > /dev/null || break
        sleep 0.1
    done
    pkill -KILL -x wf-recorder 2>/dev/null
    # the starting call was killed with it (a shell restart, a logout): nobody else will say it stopped
    for _ in $(seq 30); do
        [[ "$(jq -r '.record.enable' "$STATE_FILE" 2>/dev/null)" == "true" ]] || exit 0
        sleep 0.1
    done
    set_state '.record.enable = false'
    exit 0
fi

REGION=""
FULLSCREEN=0
OUTPUT=""
AUDIO=""
while (( $# > 0 )); do
    case "$1" in
        --region) REGION="$2"; shift ;;
        --fullscreen) FULLSCREEN=1 ;;
        --output) OUTPUT="$2"; shift ;;
        --sound) AUDIO=system ;;
        --mic) AUDIO=mic ;;
    esac
    shift
done

mkdir -p "$RECORDING_DIR" || { say "Could not make $RECORDING_DIR."; exit 1; }

WHERE=()
if (( FULLSCREEN )); then
    WHERE=(-o "${OUTPUT:-$(getactivemonitor)}")
else
    if [[ -z "$REGION" ]] && ! REGION="$(slurp 2>/dev/null)"; then
        exit 1
    fi
    WHERE=(--geometry "$REGION")
fi

# pactl, not wpctl: wf-recorder takes a PulseAudio source name, and only pactl gives them (pipewire-pulse)
SOUND=()
if [[ -n "$AUDIO" ]]; then
    if ! command -v pactl > /dev/null 2>&1; then
        say "pactl is not installed, so this recording has no sound."
    elif [[ "$AUDIO" == system ]]; then
        SOUND=(--audio="$(pactl get-default-sink).monitor")
    else
        SOUND=(--audio="$(pactl get-default-source)")
    fi
fi

# "Screen recording 21 Oct at 07.15.mp4", as the notch names it; a second one in the same minute gets "(2)"
base="Screen recording $(LC_ALL=C date '+%-d %b at %H.%M')"
FILE="$RECORDING_DIR/$base.mp4"
n=2
while [[ -e "$FILE" ]]; do
    FILE="$RECORDING_DIR/$base ($n).mp4"
    n=$((n + 1))
done

set_state '.record.enable = true | .record.file = $f | .record.started = ($t | tonumber) | .record.stopped = 0 | .record.thumb = ""' \
    --arg f "$FILE" --arg t "$(date +%s%3N)" || exit 1
wf-recorder "${WHERE[@]}" "${SOUND[@]}" --pixel-format yuv420p -f "$FILE" > /dev/null 2>&1
code=$?
STOPPED=$(date +%s%3N)

if [[ ! -s "$FILE" ]]; then
    rm -f "$FILE"
    set_state '.record.enable = false | .record.file = ""'
    say "The recording could not start (wf-recorder exited with $code)."
    exit 1
fi
# the notch's card shows a still from the start; the old stills go
THUMB=""
if mkdir -p "$THUMB_DIR"; then
    find "$THUMB_DIR" -name '*.jpg' -delete
    THUMB="$THUMB_DIR/$(date +%s%3N).jpg"
    ffmpeg -loglevel error -y -i "$FILE" -frames:v 1 -vf 'scale=-2:240' "$THUMB" < /dev/null || THUMB=""
fi
set_state '.record.enable = false | .record.thumb = $th | .record.stopped = ($s | tonumber)' --arg th "$THUMB" --arg s "$STOPPED"
