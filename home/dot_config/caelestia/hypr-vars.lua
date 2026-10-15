-- Personalizaciones persistentes: Caelestia carga este archivo DESPUÉS de
-- variables.lua del upstream. No editar ~/.config/hypr/variables.lua: el
-- instalador/update del proyecto oficial puede cambiarlo en cada versión.
return {
    terminal              = "foot",
    browser               = "zen-browser",
    editor                = "codium",
    fileExplorer          = "thunar",
    audioSettings         = "pavucontrol",

    blurEnabled           = true,
    blurSpecialWs         = true,
    blurPopups            = true,
    blurInputMethods      = true,
    blurSize              = 0,
    blurPasses            = 5,
    blurXray              = true,

    shadowRange           = 20,
    windowOpacity         = 0.80,
    windowRounding        = 30,
    windowBorderSize      = 0,
    cursorTheme           = "Adwaita",
    cursorSize            = 24,
    sleepGestureCmd       = "systemctl suspend",
}
