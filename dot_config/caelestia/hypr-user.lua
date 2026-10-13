-- Wallpaper random
hl.bind("SUPER + SHIFT + W", hl.dsp.exec_cmd("caelestia wallpaper -r /home/santy/Imágenes/Wallpapers && caelestia scheme set -n dynamic"))

-- Modos de energia
hl.bind("SUPER + F1", hl.dsp.exec_cmd("powerprofilesctl set power-saver"))
hl.bind("SUPER + F2", hl.dsp.exec_cmd("powerprofilesctl set balanced"))
hl.bind("SUPER + F3", hl.dsp.exec_cmd("powerprofilesctl set performance"))

-- Thunar con blur y transparencia
hl.window_rule({ match = { class = "thunar" }, opacity = "0.92 override" })
hl.window_rule({ match = { class = "Thunar" }, opacity = "0.92 override" })

-- Blur mas vivido + Dim en inactivas (un solo hl.config)
hl.config({
    decoration = {
        blur = {
            vibrancy          = 0.30,
            vibrancy_darkness = 0.2,
            contrast          = 1.15,
            brightness        = 1.05,
            noise             = 0.02,
        },
        dim_inactive = true,
        dim_strength = 0.15,
    },
})

-- Volver al workspace anterior
hl.bind("SUPER + Tab", hl.dsp.focus({ workspace = "previous" }))
