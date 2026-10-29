<div align="center">

# Tacit

**A Wayland desktop on [Quickshell](https://quickshell.outfoxxed.me) and [Hyprland](https://hyprland.org)**


</div>

---

Tacit has no bar. A notch at the top of the screen carries the clock, the notifications and the
short-lived state the desktop needs to tell you about; everything else is reached from the
command palette (tap `Super`), the Settings app, or a keybind. It ships its own file window,
code window, lock screen, on-screen keyboard and agent session app.

It began as a fork of [illogical-impulse](https://github.com/end-4/dots-hyprland) by
[@end-4](https://github.com/end-4) and still shares a great deal of its structure.

---

## Try a change on Tacit

All you need is a computer, or a virtual machine, running Tacit. It already has everything else this repo uses.

**1. Get your copy.** Fork this repo on GitHub, then:

```bash
git clone https://github.com/YOUR-NAME/tacit ~/src/tacit
```

**2. Point Tacit at it.** Add this line to `~/.config/hypr/custom/env.lua`:

```lua
hl.env("TACIT_SHELL", os.getenv("HOME") .. "/src/tacit")
```

**3. Restart your computer.** The notch, the palette, Settings and Tacit's own apps now run from `~/src/tacit`.

**4. Change something and save.** The desktop reloads straight away; Settings and the other apps show the change the
next time you open them. If nothing changes, press **Ctrl+Super+R** to restart the desktop. If it still doesn't change,
the file has a mistake and Tacit keeps running the last version that worked. This shows the mistake:

```bash
qs log -p ~/src/tacit
```

**5. Send it.** Commit with `git commit -s` (see CONTRIBUTING.md), push to your fork and open a pull request.

**To go back** to the installed Tacit, delete the line from step 2 and restart your computer.

Your copy covers everything in `modules/`, `services/`, `scripts/` and `assets/`, and the app files at the top
(`tacit-settings.qml`, `viewer.qml` and the rest). The Hyprland setup (`session/`), the small commands in `bin/` and the
compiled parts in `native/` come from Tacit's installed packages instead, so a change there only takes effect once the
packages are rebuilt with it ([tacit-build](https://github.com/ciscobugger/tacit-build)). Say so in your pull request.

---

## Requirements

### Compositor configuration

**Tacit is not a standalone shell.** It dispatches Hyprland's `hl.dsp.*` Lua helpers from eleven
QML files, and reads or writes these files, none of which it ships:

| File | What Tacit does with it |
|---|---|
| `~/.config/hypr/hyprland.lua` | must define the `hl.*` Lua API; without it every dispatch is a no-op |
| `~/.config/hypr/hyprland/scripts/fuzzel-emoji.sh` | the palette's whole emoji list is read out of it |
| `~/.config/hypr/hyprland/keybinds.lua`, `custom/keybinds.lua` | parsed for the `Super+/` keybind sheet |
| `~/.config/hypr/hyprland/shellOverrides/main.lua`, `animations.lua` | written by the settings app |
| `~/.config/hypr/monitors.lua` | written by Settings (Display & power) when absent or written by it before; one another tool wrote is left alone |
| `~/.config/hypr/hypridle.conf` | Settings (Lock & sleep) rewrites the `timeout` lines only, then restarts hypridle |
| `~/.config/hypr/custom/variables.lua` | Settings keeps two marked blocks in it: the default browser, files and terminal the keys open, and the cursor size |
| `~/.config/hypr/custom/keybinds.lua` | Settings (Keyboard & touchpad) changes the key bound to dictation |
| `~/.config/flow/words.txt`, `~/.face` | Settings edits the dictation words and sets your picture (the previous one is kept as `~/.face.previous`) |
| `~/.config/hypr/hyprlock.conf` | edited in place by the general settings |

Nothing checks for any of these, and nothing reports their absence. The Lua configuration in
`end-4`'s dots is what provides them.

### Configuration directory

Tacit reads and writes `~/.config/illogical-impulse/config.json` — **the same file upstream
illogical-impulse uses**, with keys upstream does not know (`island.*`, `commandPalette.*` and
others). Two shells writing that one file will each drop what the other added. Do not run both.

### Python environment

Eight helpers — including the one that generates the entire colour palette — need a virtualenv:

```bash
python3 -m venv ~/.local/state/quickshell/.venv
~/.local/state/quickshell/.venv/bin/pip install \
    materialyoucolor pillow numpy opencv-python pygobject loguru click tqdm
```

`$ILLOGICAL_IMPULSE_VIRTUAL_ENV` overrides that path if it is set. Without the environment the
palette is never generated and every colour falls back to the literals in
`modules/common/Appearance.qml`, which reads as a broken design rather than a missing file.

### Binaries

The shell execs these; none of them is checked for, and a missing one is silent unless noted.

| Area | Needs |
|---|---|
| always | `bash`, `jq`, `notify-send`, `hyprctl`, `python3`, `xdg-open`, `xdg-user-dir` |
| palette and theming | `matugen`, `gsettings`, `magick`/`identify` (ImageMagick) |
| palette (calculator) | `qalc` (libqalculate) |
| clipboard | `cliphist`, `wl-copy`, `wl-paste` |
| files and search | `fd`, `rg`, `gio` (glib2), `udisksctl` |
| screen capture | `grim`, `slurp`, `hyprpicker`, `wf-recorder`, `pactl` (pipewire-pulse), `tesseract` |
| audio and media | `wpctl` (wireplumber), `playerctl`, `cava`, `ffmpeg` |
| brightness | `brightnessctl`, `ddcutil` (external monitors) |
| night light | `hyprsunset` |
| network | `nmcli` (NetworkManager) |
| keyring | `gnome-keyring-daemon` (unlocked at the lock by `pam_gnome_keyring` in `/etc/pam.d/login`), `secret-tool`, `fprintd-list` (fingerprint unlock) |
| agent sessions | `claude`, `git`, `gh` |
| dictation | `ydotool` |
| updates | `checkupdates` (pacman-contrib), and `paru` or `yay` for AUR counts — Arch only |
| Settings | `timedatectl`, `xdg-mime`, `gtk-launch` (gtk3, for the default browser and files keys), `gsettings`; files and folders are chosen in Tacit's own Files |

`checkupdates` is the only update backend, so on any other distribution the update count reads
"Unsupported" rather than a number.

### Fonts

| Font | Used for |
|---|---|
| Material Symbols Rounded | every icon in the shell (hardcoded, not configurable) |
| Readex Pro | body, titles, reading |
| Rubik | numbers |
| JetBrainsMono Nerd Font | monospace and Nerd Font glyphs |
| Space Grotesk | the expressive/display face |

All five are configurable under `appearance.fonts` except Material Symbols Rounded. A missing
font is not reported; Qt silently substitutes.

### Components outside this repo

Some features call helpers that live in `~/.local/bin` and are installed separately: `flowd`
(dictation), `code-file` (open a file in the code window), `app-scope`, `quiet-btagent`,
`claude-context`, `claude-hand`, `claude-review`, `notch-dirty`, `notch-prs`, `notch-session`,
`notch-sessions-restore`. Each feature degrades on its own if its helper is absent.

---

## Running it without Tacit

On your own Arch and Hyprland setup, with the requirements above:

```bash
cd ~/.config/quickshell/
git clone <this repo> tacit
killall qs 2>/dev/null; qs -c tacit > /dev/null 2>&1 & disown
```

To load it at login instead of another Quickshell config, set the folder name in
`~/.config/hypr/hyprland/variables.lua`:

```lua
hl.env("qsConfig", "tacit")
```

then `hyprctl reload`.

---

## Keys worth knowing

| Key | Does |
|---|---|
| `Super` (tap) | command palette |
| `Super + Space` | open the notch |
| `Super + Shift + Space` | ask Claude in the notch |
| `Super + I` or `Super + Escape` | settings |
| `Super + N` | control panel |
| `Super + /` | every keybind |
| `Super + E` | files |
| `Ctrl + Super + R` | restart the shell |

---

## FAQ

**How do I see my keybinds?** Open the palette (`Super`) and type `<`, or press `Super + /`.

**How do I find a setting?** Type in the search field at the top of Settings, or open the palette
(`Super`) and type what you are looking for (`wallpaper`, `blur`, `notch`): both go to the page it is on.

---

## Credits

- **[@end-4](https://github.com/end-4)** — [dots-hyprland](https://github.com/end-4/dots-hyprland)
  / illogical-impulse, which this desktop grew out of
- **[@pctrade](https://github.com/pctrade)** — [end4-pC](https://github.com/pctrade/end4-pC), the fork of it Tacit
  started from on 2026-09-07 (its history is kept in this repository)
- **[@gh0stzk](https://github.com/gh0stzk)** — the weather API integration behind the weather widget
- **[@simeulinuxkaliaiwr](https://github.com/simeulinuxkaliaiwr)** — some shader transitions

## Licence

GPL-3.0, as illogical-impulse and end4-pC are ([LICENSE](LICENSE)). Tacit has been its own project since 2026-10-14:
it no longer follows either upstream, and most of it has been rewritten, but files that still carry their code keep
their licence and authorship.
