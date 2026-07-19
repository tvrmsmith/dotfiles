-- Input configuration

hl.config({
    input = {
        -- sensitivity = -0.25,
        accel_profile = "flat",
        -- NOTE: altwin:swap_alt_win disabled. It collided with kanata's home-row
        -- mods (d=lalt, f=lmet): the XKB swap re-flipped them, so holding `d`
        -- landed on SUPER and `f` on ALT — inverting window-nav (wmMod=ALT).
        -- Without the swap, kanata's `d` hold is a real Alt and navigates.
        -- kb_options = "altwin:swap_alt_win",
    },
    -- Uncomment the section below to enable software cursors; this can help with cursor display or behavior issues
    -- cursor = {
    --     no_hardware_cursors = 1,
    -- },
})

hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 3, direction = "down",       action = "close" })
hl.gesture({ fingers = 3, direction = "up",         action = "fullscreen" })
hl.gesture({ fingers = 3, direction = "left",       action = "float" })
