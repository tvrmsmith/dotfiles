local mainMod = "SUPER" -- app lifecycle: open/close/quit (mirrors Cmd on macOS)
local wmMod   = "ALT"   -- window management: focus/move/layout (mirrors AeroSpace's Alt)
local noctCall = "noctalia msg "
local launchPrefix = "uwsm app -- " -- if you are not using UWSM, make this empty (e.g. "")

---------------------------
---- WINDOW MANAGEMENT ----
---------------------------

-- Window manipulation (open/close/quit stay on SUPER, like macOS app shortcuts)
hl.bind(mainMod .. " + Escape",      hl.dsp.exec_cmd("hyprctl kill"))
hl.bind(mainMod .. " + Q",           hl.dsp.window.close())
hl.bind(wmMod .. " + SHIFT + Space", hl.dsp.window.float({ action = "toggle" })) -- AeroSpace: alt-shift-space
hl.bind(wmMod .. " + D",             hl.dsp.window.fullscreen({ mode = 1 }))
hl.bind(wmMod .. " + F",             hl.dsp.window.fullscreen())
hl.bind(wmMod .. " + Slash",         hl.dsp.layout("togglesplit")) -- AeroSpace: alt-slash toggles h/v tile split

-- AeroSpace: alt-comma toggles the "accordion" layout. Hyprland has no accordion,
-- so this flips the active workspace's whole layout engine: dwindle <-> master.
hl.bind(wmMod .. " + Comma", function()
    local current = hl.get_config("general.layout")
    hl.config({ general = { layout = (current == "master") and "dwindle" or "master" } })
end)

-- Change focus: arrows stay on SUPER (safe, no app conflicts); hjkl moves to ALT
-- to match AeroSpace exactly. Not moving arrows to ALT deliberately: Alt+Left/Right
-- is browser back/forward and Alt+Up/Down is "move line" in many editors.
hl.bind(mainMod .. " + Left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + Right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + Up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + Down",  hl.dsp.focus({ direction = "down" }))
hl.bind(wmMod .. " + H",       hl.dsp.focus({ direction = "left" }))
hl.bind(wmMod .. " + J",       hl.dsp.focus({ direction = "down" }))
hl.bind(wmMod .. " + K",       hl.dsp.focus({ direction = "up" }))
hl.bind(wmMod .. " + L",       hl.dsp.focus({ direction = "right" }))
hl.bind(wmMod .. " + Tab",     hl.dsp.window.cycle_next())
hl.bind(mainMod .. " + Tab",   hl.dsp.exec_cmd(noctCall .. "window-switcher")) -- opening a panel: stays SUPER

-- Move active window around workspaces & monitors
hl.bind(mainMod .. " + SHIFT + Right",         hl.dsp.window.move({ direction = "r" }))
hl.bind(mainMod .. " + SHIFT + Left",          hl.dsp.window.move({ direction = "l" }))
hl.bind(mainMod .. " + SHIFT + Up",            hl.dsp.window.move({ direction = "u" }))
hl.bind(mainMod .. " + SHIFT + Down",          hl.dsp.window.move({ direction = "d" }))
hl.bind(wmMod .. " + SHIFT + H",               hl.dsp.window.move({ direction = "l" }))
hl.bind(wmMod .. " + SHIFT + J",               hl.dsp.window.move({ direction = "d" }))
hl.bind(wmMod .. " + SHIFT + K",               hl.dsp.window.move({ direction = "u" }))
hl.bind(wmMod .. " + SHIFT + L",               hl.dsp.window.move({ direction = "r" }))
hl.bind(wmMod .. " + CONTROL + SHIFT + 1",     hl.dsp.window.move({ monitor = MONITOR1 }))
hl.bind(wmMod .. " + CONTROL + SHIFT + 2",     hl.dsp.window.move({ monitor = MONITOR2 }))
hl.bind(wmMod .. " + CONTROL + SHIFT + 3",     hl.dsp.window.move({ monitor = MONITOR3 }))
hl.bind(wmMod .. " + SHIFT + mouse_up",        hl.dsp.window.move({ monitor   = "+1" }))
hl.bind(wmMod .. " + SHIFT + mouse_down",      hl.dsp.window.move({ monitor   = "-1" }))
hl.bind(wmMod .. " + CONTROL + SHIFT + Right", hl.dsp.window.move({ workspace = "r+1" }))
hl.bind(wmMod .. " + CONTROL + SHIFT + Left",  hl.dsp.window.move({ workspace = "r-1" }))
-- AeroSpace: alt-shift-N moves the window to workspace N on the current monitor, and follows
for i = 1, NUM_WPM do
    local key = i % 10
    hl.bind(wmMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = "m~" .. i }))
end

-- Move & Resize with mouse
hl.bind(wmMod .. " + mouse:272", hl.dsp.window.drag())
hl.bind(wmMod .. " + mouse:273", hl.dsp.window.resize())

-------------------------------------------
---- RESIZE / SERVICE MODE (AeroSpace) ----
-------------------------------------------
-- AeroSpace: alt-shift-; enters "service mode" for resizing etc. This is a Hyprland
-- submap: a temporary keybind layer you enter and exit explicitly.
hl.define_submap("resize", function()
    hl.bind("Escape", hl.dsp.submap("reset"))
    hl.bind("Return", hl.dsp.submap("reset"))
    hl.bind("H",      hl.dsp.window.resize({ x = -20, y = 0 }),  { repeating = true })
    hl.bind("J",      hl.dsp.window.resize({ x = 0, y = 20 }),   { repeating = true })
    hl.bind("K",      hl.dsp.window.resize({ x = 0, y = -20 }),  { repeating = true })
    hl.bind("L",      hl.dsp.window.resize({ x = 20, y = 0 }),   { repeating = true })
    hl.bind("Left",   hl.dsp.window.resize({ x = -20, y = 0 }),  { repeating = true })
    hl.bind("Right",  hl.dsp.window.resize({ x = 20, y = 0 }),   { repeating = true })
    hl.bind("Up",     hl.dsp.window.resize({ x = 0, y = -20 }),  { repeating = true })
    hl.bind("Down",   hl.dsp.window.resize({ x = 0, y = 20 }),   { repeating = true })
end)
hl.bind(wmMod .. " + SHIFT + Semicolon", hl.dsp.submap("resize"))

------------------
---- LAUNCHER ----
------------------

hl.bind(mainMod .. " + Return",     hl.dsp.exec_cmd(launchPrefix .. TERMINAL))
hl.bind(mainMod .. " + E",          hl.dsp.exec_cmd(launchPrefix .. FILE_MANAGER))
hl.bind(mainMod .. " + T",          hl.dsp.exec_cmd(launchPrefix .. EDITOR))
hl.bind(mainMod .. " + C",          hl.dsp.exec_cmd(launchPrefix .. CALCULATOR))
hl.bind(mainMod .. " + W",          hl.dsp.exec_cmd(launchPrefix .. BROWSER))
hl.bind("CONTROL + SHIFT + Escape", hl.dsp.exec_cmd(launchPrefix .. TERMINAL .. " -e btop"))
hl.bind(mainMod .. " + Z",          hl.dsp.exec_cmd(noctCall .. "settings-toggle"))
hl.bind(mainMod .. " + X",          hl.dsp.exec_cmd(noctCall .. "panel-toggle control-center"))
hl.bind(mainMod .. " + Space",      hl.dsp.exec_cmd(noctCall .. "panel-toggle launcher"))
hl.bind(mainMod .. " + period",     hl.dsp.exec_cmd(noctCall .. "panel-toggle launcher /emo"))
hl.bind(mainMod .. " + ALT + L",    hl.dsp.exec_cmd(noctCall .. "session lock"))
hl.bind(mainMod .. " + ALT + C",    hl.dsp.exec_cmd(noctCall .. "panel-toggle session"))

---------------------------
---- HARDWARE CONTROLS ----
---------------------------

-- Audio
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(noctCall .. "volume-up"),   { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(noctCall .. "volume-down"), { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd(noctCall .. "volume-mute"), { locked = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd(noctCall .. "mic-mute"),    { locked = true })

-- Media
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd(noctCall .. "media toggle"),   { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd(noctCall .. "media toggle"),   { locked = true })
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd(noctCall .. "media next"),     { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd(noctCall .. "media previous"), { locked = true })

-- Brightness
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(noctCall .. "brightness-up"),   { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(noctCall .. "brightness-down"), { locked = true, repeating = true })

-------------------
---- UTILITIES ----
-------------------

-- Screen Capture
hl.bind(mainMod .. " + P",     hl.dsp.exec_cmd("hyprpicker -a"))
hl.bind("Print",               hl.dsp.exec_cmd(noctCall .. "screenshot-region"))
hl.bind(mainMod .. " + Print", hl.dsp.exec_cmd(noctCall .. "screenshot-fullscreen"))

-- Theming and Wallpaper
hl.bind(mainMod .. " + SHIFT + W", hl.dsp.exec_cmd(noctCall .. "panel-toggle wallpaper"))

-- Clipboard
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd(noctCall .. "panel-toggle clipboard"))

-- Notifications
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd(noctCall .. "panel-toggle control-center notifications"))

-------------------------------
---- WORKSPACES & MONITORS ----
-------------------------------

-- Focus on monitors
hl.bind(wmMod .. " + CONTROL + 1", hl.dsp.focus({ monitor = MONITOR1 }))
hl.bind(wmMod .. " + CONTROL + 2", hl.dsp.focus({ monitor = MONITOR2 }))
hl.bind(wmMod .. " + CONTROL + 3", hl.dsp.focus({ monitor = MONITOR3 }))

-- Focus on workspace number
-- Absolute
for i = 1, NUM_WPM do
    local key = i % 10
    hl.bind(wmMod .. " + TAB + " .. key, hl.dsp.focus({ workspace = i }))
end
-- AeroSpace: alt-N focuses workspace N on the current monitor (each monitor
-- keeps its own set of numbered workspaces via the "m~" relative selector)
for i = 1, NUM_WPM do
    local key = i % 10
    hl.bind(wmMod .. " + " .. key, hl.dsp.focus({ workspace = "m~" .. i }))
end

-- Move to adjacent workspaces and next empty on a given monitor
hl.bind(wmMod .. " + CONTROL + Right",       hl.dsp.focus({ workspace = "m+1" }))
hl.bind(wmMod .. " + CONTROL + Left",        hl.dsp.focus({ workspace = "m-1" }))
hl.bind(wmMod .. " + CONTROL + Down",        hl.dsp.focus({ workspace = "emptym" }))

-- Scroll through existing workspaces & monitors
hl.bind(wmMod .. " + mouse_down",           hl.dsp.focus({ workspace = "m+1" }))
hl.bind(wmMod .. " + mouse_up",             hl.dsp.focus({ workspace = "m-1" }))
hl.bind(wmMod .. " + CONTROL + mouse_up",   hl.dsp.focus({ workspace = "m+1" }))
hl.bind(wmMod .. " + CONTROL + mouse_down", hl.dsp.focus({ workspace = "m-1" }))

-- Special workspace (scratchpad)
hl.bind(wmMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special" }))
hl.bind(wmMod .. " + S",         hl.dsp.workspace.toggle_special())
