-- Material 3 Expressive material model.
--
-- M3 puts background blur on SYSTEM SURFACES -- notification shade, quick
-- settings, lock screen, app drawer, recents -- so the colour of what is behind
-- shimmers through, instead of the flat opaque panels it moved away from. It
-- never makes an application window translucent; focus is elevation and
-- outline, not opacity.
--
-- This config had that backwards: windows were translucent (inactive_opacity
-- 0.9) while every shell surface was a flat opaque matugen tone with no blur
-- rule at all. These rules put the frost where M3 actually specifies it.
--
-- ignore_alpha is the threshold below which a pixel is left unblurred, so the
-- fully transparent margin around each surface stays clear and only the panel
-- body frosts.

-- ignore_alpha = the panel's own alpha minus a hair (caelestia services/Colours.qml:94:
-- `ignore_alpha = transparency.base - 0.03`). Hyprland masks the blur by surface alpha,
-- so every anti-aliased edge pixel below the threshold is composited over the RAW
-- backdrop and blends smoothly into it; only the body (full frost alpha) sits on the
-- blur. With the old 0.1 the edge pixels sat on blurred backdrop while the pixel next
-- to them showed the raw one, and every curve was a staircase with a bright or dark
-- fringe (bleed from windows under the idle notch, wallpaper-vs-window when open).
-- colPanelFrost is surfaceContainer at alpha 0.67, so the threshold is 0.64.
hl.layer_rule({ match = { namespace = "quickshell:island" },            blur = true, ignore_alpha = 0.64 })
-- no_anim: these three draw their own edge reveal (caelestia's model, see
-- shell-fusion-motion-plan.md). Left on layersIn they would get Hyprland's popin on
-- top of the shell's slide. The island keeps riding layersIn.
hl.layer_rule({ match = { namespace = "quickshell:overview" },          blur = true, ignore_alpha = 0.89, no_anim = true })
hl.layer_rule({ match = { namespace = "quickshell:sidebarRight" },      blur = true, ignore_alpha = 0.64, no_anim = true })
hl.layer_rule({ match = { namespace = "quickshell:notificationPopup" }, blur = true, ignore_alpha = 0.64 })
hl.layer_rule({ match = { namespace = "quickshell:session" },           blur = true, ignore_alpha = 0.1 })
-- The password request is drawn as the notch opening (modules/ii/polkit/PolkitContent.qml): the
-- notch's frost and threshold; it draws its own opening, so no layer animation.
hl.layer_rule({ match = { namespace = "quickshell:polkit" },            blur = true, ignore_alpha = 0.64, no_anim = true })
-- The reload popup is drawn in the notch's shape and frost and grows out of it (ReloadPopup.qml).
hl.layer_rule({ match = { namespace = "quickshell:reloadPopup" },       blur = true, ignore_alpha = 0.64, no_anim = true })
hl.layer_rule({ match = { namespace = "quickshell:saveAs" },          blur = true, ignore_alpha = 0.64, no_anim = true })

-- ---------------------------------------------------------------------------
-- Windows: frosted, not passthrough.
--
-- hyprland/rules.lua:7 sets no_blur on class ".*", so blur was off for EVERY
-- window. Combined with inactive_opacity 0.9 that gave transparency with
-- nothing behind it -- raw content showing through, which is the "passthrough"
-- look, not frosted glass. custom.rules is required at hyprland.lua:43, after
-- hyprland.rules at :32, so this override wins.
--
-- decoration:blur:xray stays true (general.lua:72): blur samples the wallpaper
-- rather than the windows behind, which is both cheaper on this SoC and gives
-- the clean single-layer frost rather than a busy stack of blurred windows.

-- ---------------------------------------------------------------------------
-- Frosted in BOTH states, less so when unfocused -- matching what foot does.
--
-- foot draws its own background with alpha (colors-dark.alpha=0.85), so its
-- surface is translucent whether focused or not: 0.85 focused, 0.85*0.82 ~ 0.70
-- unfocused. Blur renders in both states; only the amount changes.
--
-- Firefox/Chromium render opaque, so the compositor has to create the
-- translucent region for them. These give the same pair of values.
-- opacity takes {active, inactive}. This build's window_rule does not accept
-- active_opacity/inactive_opacity as separate fields, despite the stub listing
-- them -- the installed lua wrapper is older than /usr/share/hypr/stubs.
-- Each pair is the design on dusk; tacit_glass (hyprland.lua) scales its see-through for a bright wallpaper.
local glass = tacit_glass or function(o) return o end
local function pair(active, inactive) return string.format("%.3f %.3f", glass(active), glass(inactive)) end
hl.window_rule({ match = { class = "firefox" },   opacity = pair(0.85, 0.77) })
hl.window_rule({ match = { class = "thorium.*" }, opacity = pair(0.85, 0.77) })
hl.window_rule({ match = { class = "[cC]hromium" }, opacity = pair(0.85, 0.77) })
hl.window_rule({ match = { class = "zen" },       opacity = pair(0.85, 0.77) })
hl.window_rule({ match = { class = "[hH]elium" }, opacity = pair(0.85, 0.77) })
hl.window_rule({ match = { class = "browser" },   opacity = pair(0.85, 0.77) })  -- ~/dev/browser
-- Helium's compact tab strip starts 4px in; the global 22px corner cuts the first tab.
hl.window_rule({ match = { class = "[hH]elium" }, rounding = 16 })

-- foot already draws its surface at alpha 0.85 (colors-dark.alpha), so the
-- compositor must NOT fade it further on focus, and only to 0.906 when
-- unfocused: 0.85 * 0.906 = 0.77, the same effective pair as the browsers.
hl.window_rule({ match = { class = "foot" }, opacity = pair(1.0, 0.906) })
-- Nautilus wears the shell's frost: libadwaita is opaque, so the translucency comes from
-- Hyprland (the blur behind it is the same one the panels get). 0.84 keeps the list readable.
hl.window_rule({ match = { class = "org.gnome.Nautilus" }, opacity = pair(0.84, 0.78) })

-- Praxis keeps its own opacity: the global inactive 0.82 turned its text grey-on-grey
hl.window_rule({ match = { class = "^(praxis)$" }, opacity = "1.0 override 1.0 override" })

-- Activity floats in the middle, opening at 840 x 680; it then fits its height to the open page itself
-- (activity.qml fitTimer). Tiled beside two windows its list had no room.
hl.window_rule({ match = { class = "^(activity)$" }, float = true })
hl.window_rule({ match = { class = "^(activity)$" }, size = { "840", "680" } })
hl.window_rule({ match = { class = "^(activity)$" }, center = true })
-- Apps (store.qml): floating, at the size its pages are laid out for (1528 x 928 fits a 1920 x 1080 screen with room)
hl.window_rule({ match = { class = "^(store)$" }, float = true })
hl.window_rule({ match = { class = "^(store)$" }, size = { "1528", "928" } })
hl.window_rule({ match = { class = "^(store)$" }, center = true })
-- The viewer floats in the middle at its own 1280 x 820 (viewer.qml): Files floats, and a floating window stays above
-- every tiled one, so a picture opened from Files came up tiled behind it (Discord 2026-10-21). Focused, it is on top.
hl.window_rule({ match = { class = "^(viewer)$" }, float = true })
-- not faded when another window has focus: a picture or a video is watched while typing elsewhere, and its window draws
-- its own glass (viewer.qml: solid under a file shown on its own)
hl.window_rule({ match = { class = "^(viewer)$" }, opacity = "1.0 override 1.0 override" })
hl.window_rule({ match = { class = "^(viewer)$" }, center = true })

-- Tacit setup's practice run (setup.qml with TACIT_SETUP_WINDOWED=1): a 16:9 window in the middle, the shape it is
-- drawn for. On the stick it is full screen and this never applies.
hl.window_rule({ match = { class = "^(tacit-setup)$" }, float = true })
hl.window_rule({ match = { class = "^(tacit-setup)$" }, size = { "1440", "810" } })
hl.window_rule({ match = { class = "^(tacit-setup)$" }, center = true })
