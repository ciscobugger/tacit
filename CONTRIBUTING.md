# Contributing to Tacit

Bug reports, fixes, translations and hardware support are welcome. This page says how a report or a change gets into
Tacit, and which design rules a change has to keep.

Questions and talk: [Discord](https://discord.gg/Geg72FUhY).

## Reporting a bug

Open an issue with the bug form. The things that make a bug fixable:

- what you did and what happened, step by step
- your Tacit version (Settings › About) and your computer's model
- a screenshot or a short recording when it is about something you see

Security problems go to **Report a vulnerability** on this repo's Security tab, not to a public issue.

## Before you write code

- **Go ahead:** fixes for a bug you can reproduce, translations, support for a computer or device.
- **Ask first:** anything that adds a feature or changes how Tacit looks or behaves. Open an idea issue or ask on
  Discord, with a screenshot or a mock. Tacit's design is deliberate, and a change nobody agreed to is declined
  however good its code is.
- These repos take pull requests: [tacit](https://github.com/ciscobugger/tacit) (the desktop and its apps),
  [thyris](https://github.com/ciscobugger/thyris) (the browser),
  [tacit-build](https://github.com/ciscobugger/tacit-build) (packages, installer, ISO),
  [tacit-kit](https://github.com/ciscobugger/tacit-kit) (the design kit; its guide is
  [design.tacitos.co](https://design.tacitos.co)) and
  [tacit-music-example](https://github.com/ciscobugger/tacit-music-example) (an example app to build on). The other
  parts of Tacit are not public yet.
- Building and running a part: DEVELOPING.md in its repo. Working with an AI agent? Point it at AGENTS.md, which
  tells it the layout, the checks and the rules.

## How a pull request gets in

These repos are published from the ones Tacit is developed in, so a pull request is not merged here. Instead:

1. Checks run on it at once: every commit signed off, and the scripts, Python, Lua, JSON and YAML it changes read
   without errors. Fix what they report.
2. Every line is read. Tacit's packages run with full access to everyone's computer, so nothing goes in unread or
   automatically.
3. Your commits are applied to Tacit's working repo as they are, with you as their author.
4. They reach this repo with the next publish, under your name, and your pull request is closed with a link to them.
   GitHub shows it as closed rather than merged; the commits are yours.
5. They ship in the next Tacit release.

## Sign off your commits

Every commit needs a `Signed-off-by:` line with your name and email, which `git commit -s` adds. By signing off you
certify the [Developer Certificate of Origin 1.1](https://developercertificate.org): you wrote the change or have the
right to submit it, and it is released under this repo's licence (GPL-3.0-or-later). A check on each pull request
looks for the line.

## Design rules

These hold everywhere in Tacit today. A change that breaks one is sent back.

- **Dark only.** There is no light mode.
- **Colours come from the wallpaper.** Every colour is a role of the palette made from the wallpaper. Never type a
  colour value: someone else's wallpaper gives other colours.
- **Text is ranked by brightness, never by transparency.** Use the ink levels in `modules/common/Tacit.qml`:
  `inkMain`, `inkSec`, `inkMeta`, `inkFaint`.
- **Colour by meaning.** The accent (`Tacit.accent`) marks the default, safe action. An action that risks something
  uses `Tacit.risk` and a warning symbol, since on some palettes the two are close. Everything else stays plain.
- **Two materials.** An app window stands on the terminal's ground at `Tacit.windowSeeThrough`. A shell surface that
  floats over apps (the notch, notifications, panels) uses the frost, `Appearance.colors.colPanelFrost`.
- **Docked, not floating.** A surface that comes to you grows out of an edge with coves
  (`modules/common/widgets/DockedRect.qml`) instead of floating as a card. Only the notch docks to the top edge.
- **Each app has its own interface.** Share the language (colour, material, type, motion), not another app's layout.
- **Nothing opens under a passing pointer.** The notch's sheet is the one exception.
- **No generic patterns:** accent stripes, cards with hairline borders made for one screen, small uppercase labels,
  rows of outlined pills, captions that repeat what a button says, colours picked by hand.

## Code

Match the code around your change: its naming, its idiom and how much it comments. Comments say what the code does
and why, in plain words.
