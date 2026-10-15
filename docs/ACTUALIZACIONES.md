# Mantener el respaldo útil con el tiempo

## Arquitectura upstream → capa personal

En un CachyOS base, `scripts/15-upstream.sh` instala primero `caelestia-cli` y ejecuta **`caelestia install --disable-components firefox`**. Ese CLI clona por su cuenta `caelestia-dots/caelestia` bajo `~/.local/state/caelestia/dots`, despliega sus configuraciones y registra `dots-state.json`; luego el instalador de este repo aplica tus personalizaciones con chezmoi. El upstream no incluye gestor de login: greetd se gestiona aparte. El proyecto `caelestia-dots/shell` es solo el shell, no el instalador del desktop completo.

La capa personal NO sobrescribe los módulos compartidos en `~/.config/hypr/` cuando existe `caelestia` en PATH: esa carpeta pertenece a upstream. Las apps, opacidad, blur y cursor viven en `hypr-vars.lua`; atajos especiales, reglas y animaciones viven en `hypr-user.lua`. Si upstream cambia esas API, hay que adaptar la capa personal antes de aplicarla.

No ejecutamos `install.fish` del repo upstream (fue retirado), ni copiamos sus carpetas manualmente. Si el CLI cambia sus opciones, la etapa se detiene antes de ejecutarlo. `--no-upstream` solo se usa si ya instalaste la base. **En la máquina original NO vuelvas a ejecutar `caelestia install` sin respaldo y sin revisar diferencias:** para actualizaciones usa `./scripts/update-upstream.sh`, que exige copia de seguridad, muestra el cambio y no reaplica tu capa automáticamente.

Este repo no congela CachyOS: **pacman y AUR son rolling release**. Guardar nombres de paquetes y dotfiles no garantiza que Hyprland 0.56, Caelestia 2.5 o sus API sigan iguales en otra fecha. La estrategia es separar personalizaciones, diagnosticar antes de aplicar y probar cada actualización importante.

## Antes de actualizar

```bash
cd ~/dotfile-nuevo                  # clon de santy8ap/dotfile, NO el otro ~/dotfiles
git status --short                 # no perder cambios locales
./scripts/backup.sh               # copia de ~/.config, ¡en el mismo disco!
./scripts/packages-update.sh --diff
./scripts/lint.sh --quick
./install.sh verify --force
```

Lee los avisos de CachyOS/Arch antes de una actualización grande. Para actualizar paquetes: usa `sudo pacman -Syu` y el helper AUR en una transacción normal, o `./scripts/update-upstream.sh` para actualizar los dots mediante el CLI upstream; **no uses `pacman -Sy` seguido de instalaciones parciales**. Haz una copia externa antes de modificar Hyprland, Caelestia o el gestor de sesiones.

## Mantener listas de paquetes

`./scripts/packages-update.sh --diff` muestra qué nombres se añadieron/quitaron; `--write` guarda las listas tras revisión. La clasificación en "oficiales" y "AUR" depende de los repositorios habilitados en **esa máquina**, así que no es un lockfile. El instalador resuelve de nuevo si cada paquete está disponible en sus repositorios y deja los problemas en el log. **No reemplaces automáticamente las listas con el resultado de una instalación incompleta.** No se reinstala el kernel ni se clonan particiones.

## Actualizar Caelestia / Hyprland sin perder el fork

El upstream puede cambiar estructura, nombres de opciones de `shell.json` y la API Lua `hl.*`; una actualización del paquete no fusiona automáticamente las personalizaciones de este repo. Procedimiento recomendado:

1. Anota las versiones actuales: `pacman -Q hyprland caelestia-shell caelestia-cli quickshell-git`.
2. Revisa el changelog del proyecto fuente y los cambios de configuración por versión. **Pendiente: confirmar la URL y el commit del repositorio original que copiaste.** No inventaremos un remote upstream.
3. Compara los archivos *de ejemplo* del paquete nuevo con `home/dot_config/hypr/`, `home/dot_config/caelestia/` y `home/dot_config/foot/`. Conserva tus personalizaciones separadas (`hypr-user.lua`, `hypr-vars.lua`, shell JSON, variables). No copies todo el upstream encima.
4. En una rama de prueba/VM, ejecuta `./scripts/lint.sh --quick`, `chezmoi --source "$PWD" diff`, aplica solo tras revisar el diff, inicia sesión y ejecuta `./install.sh verify --force`. Si el login falla, entra por TTY y restaura el backup.
5. Comprueba `SUPER` launcher, `SUPER+Tab`, bloqueador, capturas, Thunar, cursor, tema Qt/GTK, cambio de wallpaper y timer. Solo entonces incorpora el cambio al repo definitivo.

El CI comprueba sintaxis y parsing de listas sin tocar un sistema real; **no puede demostrar** que la versión nueva del shell se verá igual ni que el login funcione. Para esa garantía hace falta probar en CachyOS real o VM.

## Datos que cambian en caliente

`scheme/current.lua`, `qtengine/caelestia.colors`, `gtk.css`, estado por monitor y variables universales de fish pueden ser reescritos por Caelestia/fish. No uses `chezmoi add` indiscriminadamente sobre ellos. `gtk.css` se crea solo como paleta inicial; Caelestia puede sustituirla. La configuración persistente de Qt (`config.json`) y los ajustes de Thunar (`thunar.css`) sí están en Git.
