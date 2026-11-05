# AGENTS.md

Guidance for coding agents working in this repo: Tacit's desktop and its own apps, written in QML on
[Quickshell](https://quickshell.outfoxxed.me) and [Hyprland](https://hyprland.org). Read CONTRIBUTING.md first: it says
what changes are welcome, what needs agreement first, and the design rules every change keeps.

## How changes get in

This repo is published from the one Tacit is developed in. Pull requests are read line by line and applied there with
their author kept; nothing is merged on GitHub. Keep a pull request to one fix or one agreed change, and sign off every
commit (`git commit -s`).

## Layout

| Path | What it is |
|---|---|
| `shell.qml` | the desktop: notch, palette, panels, notifications, lock |
| `tacit-settings.qml` | Settings |
| `claude.qml` | Praxis, the agent session app |
| `code.qml` | Pinax (files) and Graphis (code) |
| `viewer.qml`, `activity.qml`, `store.qml` | Viewer, Activity, Apps |
| `setup.qml`, `welcome.qml`, `bootlock.qml` | the installer, the first start, the lock at boot |
| `modules/` | the parts of each surface, by area (`modules/ii/` the desktop's, `modules/settings/`, `modules/claude/`, ...) |
| `modules/common/` | what everything shares: `Appearance.qml` (palette roles, sizes), `Tacit.qml` (inks, colour by meaning, type, corners), `Directories.qml`, `widgets/` |
| `services/` | singletons for system state (audio, network, power, updates, ...) |
| `scripts/` | Python and shell helpers: colours from the wallpaper, Setup, the Apps sandbox, thumbnails, ... |
| `assets/` | wallpapers, images, and the files Setup and Apps use |
| `session/`, `bin/`, `native/` | the Hyprland session, helper commands and compiled QML modules; installed by Tacit's packages, so a change here takes effect only once the packages are rebuilt |

## Running and checking

- Try a change on a computer or VM running Tacit: DEVELOPING.md, "Try a change on Tacit". A QML file with an error is
  not loaded; Tacit keeps running the last version that worked, and `qs log -p <your copy>` shows the error.
- Check what you touched before committing: `bash -n` for shell scripts, `python3 -m py_compile` for Python, `luac -p`
  for Lua. The same checks run on every pull request.

## Rules for code

- **Colours, sizes and corners come from `Appearance` and `Tacit`.** Never write a colour value: the palette follows
  the wallpaper. Text colour is an ink (`Tacit.inkMain`, `inkSec`, `inkMeta`, `inkFaint`), never text with opacity.
- **Paths:** use `Directories` in QML and `$TACIT_SHELL` / `$TACIT_BIN` in scripts. Installed computers have no
  `~/.local/bin` helpers and no source folders; never hard-code a home directory.
- **Wayland only.** No X11 code or fallbacks.
- **Singletons load lazily.** An app that needs the palette calls `MaterialThemeLoader.reapplyTheme()` at start, as
  `tacit-settings.qml` does.
- **Line endings are LF.** A CRLF script fails to start.
- **Match the code around you:** its naming, idiom and comment density. Comments say what the code does and why, in
  plain words. Do not reformat files you are not changing.
- **Do not edit** README.md, CONTRIBUTING.md, AGENTS.md, CLAUDE.md, LICENSE, `.github/` or `docs/`: they are written
  by the publishing step and a change to them is lost.
- **Do not add a dependency** (a package, a Python module, a font) without saying so in the pull request.

## Rules for the shell's behaviour

How the desktop's surfaces (the notch, panels, menus, pickers) open, close and sit on the screen. A change that
breaks one is sent back, however good it looks.

- **Every surface has a way out, by pointer and by key.** One that opens on a click or a key closes on a click
  elsewhere: it enrols in `GlobalFocusGrab` while open (`addDismissable` when it opens, `removeDismissable` when it
  closes, close itself in `onDismissed`), as `DropShelfPanel.qml` and `Settings.qml` do. Esc closes it too: listen to
  `IslandController.collapseExpansion` (the compositor's Esc), or handle Esc yourself while you hold the keyboard.
- **A small window can't use the grab.** Hyprland drops a grab as soon as the pointer rests on anything outside it,
  so a small, masked window like the notch's would close the moment it opens from a key; the grab also takes the
  keyboard. Such a surface puts a transparent window over the rest of the screen while it is open, with a hole where
  it is, and closes on a press there (`awayCatcher` in `modules/ii/island/Island.qml`).
- **Never count on the pointer leaving.** A surface that closes when the pointer leaves needs a click-away too: a
  touch screen and a drag never send the leave.
- **Hold the keyboard only while open.** A layer window asks for keys (`WlrLayershell.keyboardFocus`) only while it
  is open, and never when a hover opened it. While it holds them exclusively, a click on a window cannot take them
  back, so the click-away and Esc above are its only way out.
- **Keep controls on the screen.** Buttons placed beside something the person chose (a selection, a window, the
  pointer) are kept at least 16 px inside the screen's edges, moving inside the chosen area when there is no room
  around it. Screens have rounded corners and hide what sits flush against them.
- **Windows never move for the shell.** A shell surface lies over windows like a menu; its reserved space
  (`exclusiveZone`) never changes while it opens, peeks or closes.
- **A layer window keeps one size.** Hyprland animates a layer that changes size, so the content stretches and
  swings. Size the window once, move and resize what is inside it, and set `mask` to the part that takes clicks.
- **Nothing opens under a passing pointer** (CONTRIBUTING.md). The notch's sheet is the one exception.
