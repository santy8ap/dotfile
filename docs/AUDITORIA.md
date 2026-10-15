# Auditoría del repositorio (octubre de 2026)

## Hallazgos iniciales

El repo original tenía 41 archivos: dotfiles de Caelestia, Hyprland, fish, foot, VSCodium, un timer para cambiar fondos y dos listados de paquetes. **No había README, instalador, pruebas, backup ni reglas de privacidad.** Se encontraron copias `.bak`, `fish_variables` con rutas `/home/santy`, rutas absolutas en Caelestia y ningún mecanismo de aplicar configuraciones de sistema.

Se organizaron los archivos bajo `home/` para chezmoi, se reemplazaron las rutas de usuario en dos plantillas, se retiraron copias `.bak` y variables volátiles y se agregó un instalador por etapas. El archivo original `hyprland.conf` coexiste con `hyprland.lua`. En el flujo nuevo ambos quedan como referencia: cuando está instalado el CLI de Caelestia, `.chezmoiignore` evita sobrescribir los módulos Hyprland del upstream; tus valores se aplican vía `hypr-vars.lua` y `hypr-user.lua`. Hay que comprobar el resultado visual en una sesión real.

## Faltantes por capturar en tu PC original

Ejecuta `./scripts/capture.sh --list` **en el CachyOS original**; este entorno no tiene acceso a tus archivos. Candidatos: `~/.gitconfig`, `~/.config/nvim`, `starship.toml`, `mise`, `btop`, `lazygit`, `mpv`, `zathura`, `fastfetch`, `gammastep`, `qtengine`, GTK, iconos, entradas `.desktop`, MIME, reglas de usuario y ajustes de energía. Después de capturar, revisa todo antes del push. La configuración de fish universal y overrides por monitor son volátiles y se excluyeron intencionalmente.

## Datos que requieren respaldo independiente

- `~/Imágenes/Wallpapers`: **no hay imágenes** en Git. El timer y el binding dependen de ellas; usa un disco externo, nube o repo de medios separado.
- Perfil de Zen/Firefox, marcadores e historial: sincroniza con la app o respáldalos cifrados fuera de este repo.
- Claves SSH, tokens, credenciales GitHub/Bitwarden, llaveros GNOME, historial de portapapeles: nunca subirlos en texto plano. Ver [SECRETOS.md](SECRETOS.md).
- Documentos, fotos, juegos, contenedores Docker, bases de datos y perfiles de aplicaciones: **no incluidos**.
- Particiones, fstab, LUKS, bootloader, kernel, firmware y drivers de otras GPUs: se configuran en el instalador de CachyOS, no mediante estos scripts.

## Límites y decisiones pendientes

1. Confirmar modelo GPU/CPU de la máquina destino. Los paquetes originales incluyen Radeon/AMD y kernels CachyOS; el filtrado por hardware es aproximado, especialmente en equipos con GPU híbrida.
2. Confirmado: greetd/tuigreet ejecuta `start-hyprland` en la máquina original; el ejecutable proviene del paquete `hyprland`. Probarlo en una instalación limpia; `system/etc/greetd/config.toml` refleja la salida del usuario, pero **no se aplica automáticamente**. Ver [MAQUINA_ORIGINAL.md](MAQUINA_ORIGINAL.md).
3. Confirmar si realmente usas `tuned-ppd` o `cpupower`: dos gestores de energía pueden competir; el sudoers para cpupower está desactivado por defecto.
4. Wallpapers confirmados en `~/Imágenes/Wallpapers` (69 archivos, ~159 MiB); el usuario tiene respaldo externo. Documentar cómo se copian tras instalar. Perfiles del navegador fuera del alcance acordado.
5. Decidir el futuro de secretos: actualmente se manejan **fuera** del repositorio, según lo acordado para esta primera versión.
6. Listas de paquetes son una **captura puntual**, no un lockfile: AUR puede cambiar nombres, desaparecer o tener builds incompatibles. Nada instala la distro ni garantiza que el escritorio sea idéntico.
7. `hyprland.conf` y configuración Lua dependen de la versión actual de Hyprland/Caelestia. Comprobarlos en la máquina original antes de confiar en el setup.

## Seguridad operacional

`--dry-run` y `./scripts/lint.sh --quick` permiten inspeccionar sin instalar paquetes. Antes de tocar `/etc` o habilitar servicios se debe verificar el hardware, leer los scripts y tener un medio de rescate. `DOTFILE_APPLY_ETC=no`, `DOTFILE_PLYMOUTH_MKINITCPIO=no`, `DOTFILE_SUDOERS_CPUPOWER=no` y `DOTFILE_CHWD=no` por defecto. El respaldo de `~/.config` está en `~/.local/state/dotfile-installer/backups`; los archivos de `/etc` tocados se copian bajo `backups/system/etc` y **se aborta su modificación si la copia falla**. Ambos quedan **en el mismo disco**: no sustituyen un backup externo.

## Base upstream (decisión nueva)

La instalación futura usa `caelestia-cli` → `caelestia install` para obtener los dots oficiales desde `caelestia-dots/caelestia` antes de aplicar nuestras configuraciones. Upstream conserva estado en `~/.local/state/caelestia/dots-state.json` y provee `caelestia update` para nuevas versiones. El shell en `caelestia-dots/shell` es solo un componente; su README remite al CLI para el escritorio completo. **El CLI instala dotfiles y paquetes, pero no configura hardware ni gestor de login.** Este diseño se verificó leyendo la documentación/código upstream, no ejecutándolo aún en CachyOS real.
