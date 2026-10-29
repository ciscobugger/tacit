#!/usr/bin/env bash

QUICKSHELL_CONFIG_NAME="tacit"  # was "ii": pointed CONFIG_DIR at the stock config, not this one
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CONFIG_DIR="$XDG_CONFIG_HOME/quickshell/$QUICKSHELL_CONFIG_NAME"
CACHE_DIR="$XDG_CACHE_HOME/quickshell"
STATE_DIR="$XDG_STATE_HOME/quickshell"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_CONFIG_FILE="$XDG_CONFIG_HOME/illogical-impulse/config.json"
MATUGEN_DIR="$XDG_CONFIG_HOME/matugen"
# the person's own colour config if they have one, else Tacit's (the tacit-session package)
MATUGEN_CONFIG="$MATUGEN_DIR/config.toml"
[ -f "$MATUGEN_CONFIG" ] || MATUGEN_CONFIG=/usr/share/tacit/matugen/config.toml
terminalscheme="$SCRIPT_DIR/terminal/scheme-base.json"
source "$SCRIPT_DIR/../venv.sh"

handle_kde_material_you_colors() {
    if [ -f "$SHELL_CONFIG_FILE" ]; then
        enable_qt_apps=$(jq -r '.appearance.wallpaperTheming.enableQtApps' "$SHELL_CONFIG_FILE")
        if [ "$enable_qt_apps" == "false" ]; then
            return
        fi
    fi

    local kde_scheme_variant=""
    case "$type_flag" in
        scheme-content|scheme-expressive|scheme-fidelity|scheme-fruit-salad|scheme-monochrome|scheme-neutral|scheme-rainbow|scheme-tonal-spot)
            kde_scheme_variant="$type_flag"
            ;;
        *)
            kde_scheme_variant="scheme-tonal-spot"
            ;;
    esac
    "$(dirname "$MATUGEN_CONFIG")"/templates/kde/kde-material-you-colors-wrapper.sh --scheme-variant "$kde_scheme_variant"
}

gtk_theme_exists() {
    local theme="$1" dir
    for dir in "$HOME/.themes" "${XDG_DATA_HOME:-$HOME/.local/share}/themes" /usr/share/themes; do
        [[ -d "$dir/$theme" ]] && return 0
    done
    return 1
}

# Keep the GTK theme family the user picked and only move it between its dark and light
# variant. This used to force adw-gtk3 on every run, wallpaper change or palette regen alike.
set_gtk_theme_variant() {
    local mode="$1" current base target
    current="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")"
    base="${current%-dark}"
    [[ -z "$base" ]] && base="adw-gtk3"
    if [[ "$mode" == "dark" ]]; then
        target="$base-dark"
    else
        target="$base"
    fi
    [[ "$target" == "$current" ]] && return
    if gtk_theme_exists "$target"; then
        gsettings set org.gnome.desktop.interface gtk-theme "$target"
    fi
}

pre_process() {
    local mode_flag="$1"
    if [[ "$mode_flag" == "dark" ]]; then
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        set_gtk_theme_variant dark
    elif [[ "$mode_flag" == "light" ]]; then
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
        set_gtk_theme_variant light
    fi

    if [ ! -d "$CACHE_DIR"/user/generated ]; then
        mkdir -p "$CACHE_DIR"/user/generated
    fi
}

post_process() {
    local screen_width="$1"
    local screen_height="$2"
    local wallpaper_path="$3"
    local colors_lock_flag="$4"

    if [[ -n "$colors_lock_flag" ]]; then
        return
    fi

    handle_kde_material_you_colors &

    # matugen renders hyprland/colors.lua: window borders, the compositor background colour
    # and the pinned-window rule. They stay on the previous palette until Hyprland re-reads it.
    # config-only: no monitor reconfiguration, so the screen does not blink for a palette change.
    if command -v hyprctl &>/dev/null; then
        hyprctl reload config-only >/dev/null 2>&1 &
    fi
}

check_and_prompt_upscale() {
    local img="$1"
    min_width_desired="$(hyprctl monitors -j | jq '([.[].width] | max)' | xargs)"
    min_height_desired="$(hyprctl monitors -j | jq '([.[].height] | max)' | xargs)"

    if command -v identify &>/dev/null && [ -f "$img" ]; then
        local img_width img_height
        if is_video "$img"; then
            img_width=$min_width_desired
            img_height=$min_height_desired
        else
            img_width=$(identify -format "%w" "$img" 2>/dev/null)
            img_height=$(identify -format "%h" "$img" 2>/dev/null)
        fi
        if [[ "$img_width" -lt "$min_width_desired" || "$img_height" -lt "$min_height_desired" ]]; then
            # Upscayl is offered only when it is installed; nothing is installed from here.
            local small_title="The picture is smaller than the screen"
            local small_body="${img_width}×${img_height} on a ${min_width_desired}×${min_height_desired} screen, so it will look soft."
            if command -v upscayl &>/dev/null; then
                action=$(notify-send "$small_title" "$small_body" -A "open_upscayl=Open Upscayl" -a "Wallpaper")
                [[ "$action" == "open_upscayl" ]] && nohup upscayl > /dev/null 2>&1 &
            else
                notify-send "$small_title" "$small_body" -a "Wallpaper"
            fi
        fi
    fi
}

CUSTOM_DIR="$XDG_CONFIG_HOME/hypr/custom"
RESTORE_SCRIPT_DIR="$CUSTOM_DIR/scripts"
RESTORE_SCRIPT="$RESTORE_SCRIPT_DIR/__restore_video_wallpaper.sh"
THUMBNAIL_DIR="$RESTORE_SCRIPT_DIR/mpvpaper_thumbnails"
VIDEO_OPTS="no-audio loop hwdec=auto scale=bilinear interpolation=no video-sync=display-resample panscan=1.0 video-scale-x=1.0 video-scale-y=1.0 video-align-x=0.5 video-align-y=0.5 load-scripts=no"

is_video() {
    local extension="${1##*.}"
    [[ "$extension" == "mp4" || "$extension" == "webm" || "$extension" == "mkv" || "$extension" == "avi" || "$extension" == "mov" ]] && return 0 || return 1
}

kill_existing_mpvpaper() {
    pkill -f -9 mpvpaper || true
}

create_restore_script() {
    local video_path=$1
    cat > "$RESTORE_SCRIPT.tmp" << EOF
#!/bin/bash
# Generated by switchwall.sh - Don't modify it by yourself.
# Time: $(date)

pkill -f -9 mpvpaper

for monitor in \$(hyprctl monitors -j | jq -r '.[] | .name'); do
    mpvpaper -o "$VIDEO_OPTS" "\$monitor" "$video_path" &
    sleep 0.1
done
EOF
    mv "$RESTORE_SCRIPT.tmp" "$RESTORE_SCRIPT"
    chmod +x "$RESTORE_SCRIPT"
}

remove_restore() {
    cat > "$RESTORE_SCRIPT.tmp" << EOF
#!/bin/bash
# The content of this script will be generated by switchwall.sh - Don't modify it by yourself.
EOF
    mv "$RESTORE_SCRIPT.tmp" "$RESTORE_SCRIPT"
}

# Every config.json edit is a read-modify-write through one shared temp file, so two runs at
# once (a keybind during the change-interval tick) used to drop one of the two edits.
update_config() { # jq arguments, filter last
    [ -f "$SHELL_CONFIG_FILE" ] || return 0
    (
        flock 9
        jq "$@" "$SHELL_CONFIG_FILE" > "$SHELL_CONFIG_FILE.tmp" && mv "$SHELL_CONFIG_FILE.tmp" "$SHELL_CONFIG_FILE"
    ) 9>"$SHELL_CONFIG_FILE.lock"
}

set_wallpaper_path() {
    update_config --arg path "$1" '.background.wallpaperPath = $path'
}

set_thumbnail_path() {
    update_config --arg path "$1" '.background.thumbnailPath = $path'
}

switch() {
    imgpath="$1"
    mode_flag="$2"
    type_flag="$3"
    color_flag="$4"
    color="$5"
    colors_only_flag="$6"
    colors_lock_flag="$7"

    read scale screenx screeny screensizey < <(hyprctl monitors -j | jq '.[] | select(.focused) | .scale, .x, .y, .height' | xargs)
    cursorposx=$(hyprctl cursorpos -j | jq '.x' 2>/dev/null) || cursorposx=960
    cursorposx=$(bc <<< "scale=0; ($cursorposx - $screenx) * $scale / 1")
    cursorposy=$(hyprctl cursorpos -j | jq '.y' 2>/dev/null) || cursorposy=540
    cursorposy=$(bc <<< "scale=0; ($cursorposy - $screeny) * $scale / 1")
    cursorposy_inverted=$((screensizey - cursorposy))

    matugen_args=(--source-color-index 0)
    colorgen_source=""

    if [[ -z "$imgpath" && "$color_flag" != "1" ]]; then
        echo 'Aborted'
        exit 0
    fi

    # The picture is applied whenever one was given, even when the palette comes from a fixed
    # accent colour instead of the image: an accent must not stop the wallpaper from changing.
    if [[ -n "$imgpath" ]]; then
        check_and_prompt_upscale "$imgpath" &

        if [[ -z "$colors_only_flag" ]]; then
            kill_existing_mpvpaper
        fi

        if is_video "$imgpath"; then
            mkdir -p "$THUMBNAIL_DIR"

            missing_deps=()
            if ! command -v mpvpaper &> /dev/null; then
                missing_deps+=("mpvpaper")
            fi
            if ! command -v ffmpeg &> /dev/null; then
                missing_deps+=("ffmpeg")
            fi
            if [ ${#missing_deps[@]} -gt 0 ]; then
                echo "Missing deps: ${missing_deps[*]}"
                echo "Arch: sudo pacman -S ${missing_deps[*]}"
                # nothing is installed from here (kitty is not installed either)
                notify-send -a "Wallpaper" "Needs ${missing_deps[*]}" \
                    "A video wallpaper needs ${missing_deps[*]}: sudo pacman -S ${missing_deps[*]}"
                exit 0
            fi

            if [[ -z "$colors_only_flag" ]]; then
                set_wallpaper_path "$imgpath"

                local video_path="$imgpath"
                monitors=$(hyprctl monitors -j | jq -r '.[] | .name')
                for monitor in $monitors; do
                    # without the run lock (fd 8): mpvpaper never exits, and holding it made every later run wait 15 s
                    mpvpaper -o "$VIDEO_OPTS" "$monitor" "$video_path" 8>&- &
                    sleep 0.1
                done
            fi

            thumbnail="$THUMBNAIL_DIR/$(basename "$imgpath").jpg"
            ffmpeg -y -i "$imgpath" -vframes 1 "$thumbnail" 2>/dev/null

            if [[ -z "$colors_only_flag" ]]; then
                set_thumbnail_path "$thumbnail"
            fi

            if [ -f "$thumbnail" ]; then
                colorgen_source="$thumbnail"
                if [[ -z "$colors_only_flag" ]]; then
                    create_restore_script "$video_path"
                fi
            else
                echo "Cannot create image to colorgen"
                if [[ -z "$colors_only_flag" ]]; then
                    remove_restore
                fi
                exit 1
            fi
        else
            colorgen_source="$imgpath"
            if [[ -z "$colors_only_flag" ]]; then
                set_wallpaper_path "$imgpath"
                remove_restore
            fi
        fi
    fi

    if [[ "$color_flag" == "1" ]]; then
        matugen_args+=(color hex "$color")
        generate_colors_material_args=(--color "$color")
    else
        matugen_args+=(image "$colorgen_source")
        generate_colors_material_args=(--path "$colorgen_source")
    fi

    if [[ -z "$mode_flag" ]]; then
        current_mode=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")
        if [[ "$current_mode" == "prefer-dark" ]]; then
            mode_flag="dark"
        else
            mode_flag="light"
        fi
    fi

    if [[ -n "$mode_flag" ]]; then
        matugen_args+=(--mode "$mode_flag")
        if [[ $(jq -r '.appearance.wallpaperTheming.terminalGenerationProps.forceDarkMode' "$SHELL_CONFIG_FILE") == "true" ]]; then
            generate_colors_material_args+=(--mode "dark")
        else
            generate_colors_material_args+=(--mode "$mode_flag")
        fi
    fi
    [[ -n "$type_flag" ]] && matugen_args+=(--type "$type_flag") && generate_colors_material_args+=(--scheme "$type_flag")
    generate_colors_material_args+=(--termscheme "$terminalscheme" --blend_bg_fg)
    generate_colors_material_args+=(--cache "$STATE_DIR/user/generated/color.txt")

    pre_process "$mode_flag"

    if [ -f "$SHELL_CONFIG_FILE" ]; then
        enable_apps_shell=$(jq -r '.appearance.wallpaperTheming.enableAppsAndShell' "$SHELL_CONFIG_FILE")
        if [ "$enable_apps_shell" == "false" ]; then
            echo "App and shell theming disabled, skipping matugen and color generation"
            return
        fi
    fi

    if [ -f "$SHELL_CONFIG_FILE" ]; then
        harmony=$(jq -r '.appearance.wallpaperTheming.terminalGenerationProps.harmony' "$SHELL_CONFIG_FILE")
        harmonize_threshold=$(jq -r '.appearance.wallpaperTheming.terminalGenerationProps.harmonizeThreshold' "$SHELL_CONFIG_FILE")
        term_fg_boost=$(jq -r '.appearance.wallpaperTheming.terminalGenerationProps.termFgBoost' "$SHELL_CONFIG_FILE")
        [[ "$harmony" != "null" && -n "$harmony" ]] && generate_colors_material_args+=(--harmony "$harmony")
        [[ "$harmonize_threshold" != "null" && -n "$harmonize_threshold" ]] && generate_colors_material_args+=(--harmonize_threshold "$harmonize_threshold")
        [[ "$term_fg_boost" != "null" && -n "$term_fg_boost" ]] && generate_colors_material_args+=(--term_fg_boost "$term_fg_boost")
    fi

    colors_json_path="$STATE_DIR/user/generated/colors.json"
    colors_lock_json_path="$STATE_DIR/user/generated/colors-lock.json"
    if [[ -n "$colors_lock_flag" ]]; then
        # the lock picture's palette alone, into colors-lock.json: the whole set (Qt apps, the cursor, nvim, Hyprland's
        # borders, the browsers' themes) recoloured the desktop in the lock picture's colours until the next wallpaper
        local m3in lockcfg
        m3in=$(awk '/^\[templates\.m3colors\]/{f=1;next} /^\[/{f=0} f && /^input_path/{sub(/^input_path *= */,""); gsub(/["\047]/,""); print; exit}' "$MATUGEN_CONFIG")
        lockcfg=$(mktemp --suffix=.toml)
        printf "[config]\nversion_check = false\n\n[templates.m3colors]\ninput_path = '%s'\noutput_path = '%s'\n" "$m3in" "$colors_lock_json_path" > "$lockcfg"
        matugen -c "$lockcfg" "${matugen_args[@]}"
        rm -f "$lockcfg"
    else
        matugen -c "$MATUGEN_CONFIG" "${matugen_args[@]}"
    fi

    if ! activate_shell_venv; then
        notify-send "Wallpaper" "The colours did not follow the new wallpaper." -a "Tacit" &
        return 1
    fi

    if [[ -n "$colors_lock_flag" ]]; then
        output_scss="$STATE_DIR/user/generated/material_colors_lock.scss"
    else
        output_scss="$STATE_DIR/user/generated/material_colors.scss"
    fi

    python3 "$SCRIPT_DIR/generate_colors_material.py" "${generate_colors_material_args[@]}" \
        > "$output_scss"
    # how much of this wallpaper the glass lets through (generated/seethrough.json), for the shell's surfaces, the
    # terminals' alpha (applycolor.sh) and Hyprland's opacity rules at the reload in post_process. A colour picked
    # without a picture is measured on the wallpaper in use.
    if [[ -z "$colors_lock_flag" ]]; then
        local measured="$colorgen_source"
        if [[ -z "$measured" ]]; then
            measured=$(jq -r '.background.wallpaperPath // ""' "$SHELL_CONFIG_FILE" 2>/dev/null)
            is_video "$measured" && measured=$(jq -r '.background.thumbnailPath // ""' "$SHELL_CONFIG_FILE" 2>/dev/null)
        fi
        [[ -f "$measured" ]] && python3 "$SCRIPT_DIR/seethrough.py" "$measured" "$colors_json_path" > /dev/null
    fi
    deactivate

    if [[ -z "$colors_lock_flag" ]]; then
        "$SCRIPT_DIR"/applycolor.sh
    fi

    max_width_desired="$(hyprctl monitors -j | jq '([.[].width] | min)' | xargs)"
    max_height_desired="$(hyprctl monitors -j | jq '([.[].height] | min)' | xargs)"
    post_process "$max_width_desired" "$max_height_desired" "$imgpath" "$colors_lock_flag"
}

main() {
    imgpath=""
    mode_flag=""
    type_flag=""
    color_flag=""
    color=""
    noswitch_flag=""
    colors_only_flag=""
    colors_lock_flag=""
    explicit_image=""
    start_dir_flag=""

    get_type_from_config() {
        jq -r '.appearance.palette.type' "$SHELL_CONFIG_FILE" 2>/dev/null || echo "auto"
    }
    get_accent_color_from_config() {
        jq -r '.appearance.palette.accentColor' "$SHELL_CONFIG_FILE" 2>/dev/null || echo ""
    }
    set_accent_color() {
        update_config --arg color "$1" '.appearance.palette.accentColor = $color'
    }

    detect_scheme_type_from_image() {
        local img="$1"
        activate_shell_venv || return 1
        "$SCRIPT_DIR"/scheme_for_image.py "$img" 2>/dev/null | tr -d '\n'
        deactivate
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                mode_flag="$2"
                shift 2
                ;;
            --type)
                type_flag="$2"
                shift 2
                ;;
            --color)
                if [[ "$2" =~ ^#?[A-Fa-f0-9]{6}$ ]]; then
                    set_accent_color "$2"
                    shift 2
                elif [[ "$2" == "clear" ]]; then
                    set_accent_color ""
                    shift 2
                else
                    # Escape in the picker gives nothing: the accent stays as it was and nothing is recoloured (an empty
                    # one was saved and the desktop went back to the wallpaper's colours)
                    picked=$(hyprpicker --no-fancy)
                    [[ "$picked" =~ ^#?[A-Fa-f0-9]{6}$ ]] || exit 0
                    set_accent_color "$picked"
                    shift
                fi
                ;;
            --image)
                imgpath="$2"
                explicit_image="1"
                shift 2
                ;;
            --start-dir)
                start_dir_flag="$2"
                shift 2
                ;;
            --noswitch)
                noswitch_flag="1"
                if [[ -z "$imgpath" ]]; then
                    imgpath=$(jq -r '.background.wallpaperPath' "$SHELL_CONFIG_FILE" 2>/dev/null || echo "")
                fi
                shift
                ;;
            --colors_lock)
                colors_lock_flag="1"
                colors_only_flag="1"
                noswitch_flag="1"
                if [[ -z "$imgpath" ]]; then
                    imgpath=$(jq -r '.background.wallpaperPath' "$SHELL_CONFIG_FILE" 2>/dev/null || echo "")
                fi
                shift
                ;;
            --*)
                # An unknown flag used to fall through and become the wallpaper path, which
                # then got written into config.json as the wallpaper.
                echo "[switchwall.sh] Unknown option '$1'" >&2
                exit 2
                ;;
            *)
                if [[ -z "$imgpath" ]]; then
                    imgpath="$1"
                fi
                shift
                ;;
        esac
    done

    # Tacit is dark only (owner, 2026-10-07: light mode "does not fit tacit"). A light request, or
    # none, is made dark here, so the end-4 buttons still asking for light change nothing.
    mode_flag="dark"

    if [[ -n "$noswitch_flag" && -n "$explicit_image" ]]; then
        colors_only_flag="1"
    fi

    config_color="$(get_accent_color_from_config)"
    if [[ "$config_color" =~ ^#?[A-Fa-f0-9]{6}$ ]]; then
        color_flag="1"
        color="$config_color"
    fi

    if [[ -z "$type_flag" ]]; then
        type_flag="$(get_type_from_config)"
    fi

    allowed_types=(scheme-content scheme-expressive scheme-fidelity scheme-fruit-salad scheme-monochrome scheme-neutral scheme-rainbow scheme-tonal-spot auto)
    valid_type=0
    for t in "${allowed_types[@]}"; do
        if [[ "$type_flag" == "$t" ]]; then
            valid_type=1
            break
        fi
    done
    if [[ $valid_type -eq 0 ]]; then
        echo "[switchwall.sh] Warning: Invalid type '$type_flag', defaulting to 'auto'" >&2
        type_flag="auto"
    fi

    # Only prompt for wallpaper if not using --color and not using --noswitch and no imgpath set
    if [[ -z "$imgpath" && -z "$color_flag" && -z "$noswitch_flag" ]]; then
        if [[ -n "$start_dir_flag" && -d "$start_dir_flag" ]]; then
            cd "$start_dir_flag" || return 1
        else
            cd "$(xdg-user-dir PICTURES)/Wallpapers/showcase" 2>/dev/null || cd "$(xdg-user-dir PICTURES)/Wallpapers" 2>/dev/null || cd "$(xdg-user-dir PICTURES)" || return 1
        fi
        imgpath="$(kdialog --getopenfilename . --title 'Choose wallpaper')"
    fi

    if [[ "$type_flag" == "auto" ]]; then
        if [[ -n "$imgpath" && -f "$imgpath" ]]; then
            detected_type="$(detect_scheme_type_from_image "$imgpath")"
            valid_detected=0
            for t in "${allowed_types[@]}"; do
                if [[ "$detected_type" == "$t" && "$detected_type" != "auto" ]]; then
                    valid_detected=1
                    break
                fi
            done
            if [[ $valid_detected -eq 1 ]]; then
                type_flag="$detected_type"
            else
                echo "[switchwall] Warning: Could not auto-detect a valid scheme, defaulting to 'scheme-tonal-spot'" >&2
                type_flag="scheme-tonal-spot"
            fi
        else
            echo "[switchwall] Warning: No image to auto-detect scheme from, defaulting to 'scheme-tonal-spot'" >&2
            type_flag="scheme-tonal-spot"
        fi
    fi

    if [[ "$mode_flag" == "dark" || "$mode_flag" == "light" ]]; then
        local imgdir="$(dirname "$imgpath")"
        local imgbase="$(basename "$imgpath")"
        local imgname="${imgbase%.*}"
        local imgext="${imgbase##*.}"

        local stripped_name="${imgname%-dark}"
        stripped_name="${stripped_name%-light}"

        local new_imgpath="${imgdir}/${stripped_name}-${mode_flag}.${imgext}"
        local new_stripped_imgpath="${imgdir}/${stripped_name}.${imgext}"

        if [[ -f "$new_imgpath" ]]; then
            imgpath="$new_imgpath"
        elif [[ -f "$new_stripped_imgpath" ]]; then
            imgpath="$new_stripped_imgpath"
        fi
    fi

    switch "$imgpath" "$mode_flag" "$type_flag" "$color_flag" "$color" "$colors_only_flag" "$colors_lock_flag"
}

# The boot pictures (the splash's still, the lock's ground, the sky's colours) follow the wallpaper: tacit-boot's
# tacit-boot-ground once that package is installed, the hand-installed splash's mkassets.sh until then.
regen_ground() {
    # the splash and the boot lock are the desktop's: a lock picture's colour pass leaves them (they were baked from it)
    [[ -n "$colors_lock_flag" ]] && return 0
    local mkassets=/usr/lib/tacit/tacit-boot-ground
    [[ -x "$mkassets" ]] || mkassets="$HOME/book4-edge/martida-boot/mkassets.sh"
    [[ -x "$mkassets" ]] || return 0
    # tacit-boot-ground is handed the picture just switched to: read back from config.json it was "" on a new account,
    # whose shell wrote its settings over this run's (the VM test, 2026-10-16)
    local args=(--ground)
    # a video wallpaper is drawn from its still, which tacit-boot-ground can read (the video failed every time)
    local still="$imgpath"
    [[ "$imgpath" =~ \.(mp4|webm|mkv|avi|mov)$ ]] && still="$THUMBNAIL_DIR/$(basename "$imgpath").jpg"
    [[ "$mkassets" == /usr/lib/tacit/tacit-boot-ground && -n "$still" && -f "$still" ]] && args=(--wallpaper "$still")
    # A silent failure here leaves the splash and the lock ground on the previous wallpaper.
    {
        "$mkassets" "${args[@]}" >/dev/null 2>&1 || notify-send \
            -a "Wallpaper switcher" \
            -c "im.error" \
            "Boot splash not updated" \
            "The lock and splash ground still shows the previous wallpaper."
    } 8>&- &
}
# One run at a time: Light then Dark clicked quickly ran two at once, and the slower run's terminal
# colours, made in the other mode, landed last (2026-10-07). A second run waits for the first; the
# wait is capped because background jobs started here inherit the lock.
exec 8>"${XDG_RUNTIME_DIR:-/tmp}/tacit-switchwall.lock"
flock -w 15 8 || true
main "$@"
regen_ground
