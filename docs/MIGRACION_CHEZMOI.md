# Consolidación de los dos repositorios

El usuario eligió `santy8ap/dotfile` como repositorio definitivo. Se comparó el árbol público de `santy8ap/my-arch-linux-dotfile-caelestia` (sin tocar el equipo del usuario) con este repo.

## Incorporado

- `~/.config/fastfetch/config.jsonc`: se conserva el formato de módulos. El logo SIXEL del antiguo repo señalaba `~/.config/fastfetch/pngs/*.png`, pero **no había PNG alguno versionado**. Para que el banner no dependa de un archivo ausente se usa el logo `auto` de fastfetch. Si quieres el logo exacto, respalda ese PNG por separado y actualiza la ruta.
- `~/.config/caelestia/user-config.fish` del antiguo repo estaba vacío: el archivo `create_user-config.fish` de este proyecto ya cubre ese caso, sin pisar cambios de la app.

## No copiado a ciegas

- La configuración antigua de `hypr/variables.lua` usaba LibreWolf por Flatpak, Dolphin, `sweet-cursors`, otra opacidad/animación y suspensión híbrida. La versión del repo elegido usa Zen, Thunar, Adwaita y ajustes más recientes; **copiar la antigua perdería tus personalizaciones actuales**.
- `hypr/hyprland/keybinds.lua` del repo antiguo asignaba `SUPER + Tab` a siguiente workspace; el elegido lo reasigna en `caelestia/hypr-user.lua` al workspace anterior. Se conserva la versión elegida para evitar conflicto.
- `hypr/scheme/current.lua` y `caelestia/monitors/eDP-1/shell.json` son estados generados o dependientes de monitor; hay default de colores y escala preferida. Se regeneran en la máquina destino.
- `fish/fish_variables` contiene rutas absolutas y valores universales que fish reescribe; no se versiona.
- El `install.sh` antiguo solo mueve carpetas completas a `.bak` y copia las configuraciones: es menos seguro y no instala programas. No se reutiliza.
- `screenshots/desktop.png` es una captura de exhibición, no una dependencia del entorno; se deja en el repo antiguo.

## Migración segura en el Lenovo actual

1. **No borrar** `~/dotfiles` ni `~/.local/share/chezmoi`. El instalador nuevo nunca cambia el source global de chezmoi.
2. Cuando esta rama esté disponible en GitHub, clonar `santy8ap/dotfile` **en otra carpeta**, por ejemplo `~/dotfile-nuevo`.
3. Revisar el contenido de ambos y las diferencias con `$HOME`:

   ```bash
   chezmoi --source "$HOME/dotfile-nuevo" managed
   chezmoi --source "$HOME/dotfile-nuevo" diff
   ```

4. Hacer backup externo, ejecutar `./install.sh --dry-run`, y solo después aplicar lo que decidas. Cuando chezmoi detecte un source global diferente, el instalador exige escribir `APLICAR` en una terminal incluso con `--yes`.
5. **No convertir el source global ni archivar el repo antiguo** hasta comprobar el login, atajos, colores, apps, fondos y servicios tras reiniciar. La elección de repositorio definitivo no exige cambiar el source global: este repo funciona con `chezmoi --source` explícito.

> Si Caelestia regenera `gtk.css`, `qtengine/caelestia.colors` o la paleta de Hyprland, no hay que guardar su contenido momentáneo como si fuera configuración estática.
