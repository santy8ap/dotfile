# Recuperación después de una instalación fallida

> Este procedimiento aún no se ha validado en una instalación limpia de CachyOS. Si cambias el gestor de inicio de sesión o el arranque, ten a mano un medio de rescate y un respaldo externo.

## 1. Recuperar una terminal

Si la sesión gráfica no abre, prueba `Ctrl`+`Alt`+`F2` (o F3/F4) para entrar por TTY con tu usuario. **No borres tu configuración anterior** hasta saber qué falló. Si no hay TTY o el sistema no arranca, inicia con el medio de instalación/rescate de CachyOS; no intentes cambios de arranque a ciegas.

Consulta el resultado del instalador y las etapas:

```bash
cd ~/dotfile
./install.sh --list-stages
ls -lt ~/.local/state/dotfile-installer/logs/
./install.sh verify --force
```

La verificación puede marcar fallos esperables desde TTY sin sesión gráfica; lee cada línea antes de actuar. Si la instalación se detuvo en una etapa, corrige primero la causa y usa `./install.sh --resume`; **no fuerces todas las etapas** indiscriminadamente.

## 2. Examinar y restaurar la configuración de usuario

El respaldo local se crea bajo `~/.local/state/dotfile-installer/backups/`, en el **mismo disco**, y conserva por defecto hasta cinco archivos comprimidos. Se excluyen cachés y ciertos datos grandes; no sustituye el respaldo externo.

```bash
./scripts/backup.sh --list
./scripts/backup.sh --restore 1
```

Antes de confirmar la restauración, verifica que el número corresponde al respaldo correcto. El script restaura sobre `$HOME`: **sobrescribe** los archivos que estén en el archivo tar, **no elimina** archivos nuevos. Si necesitas solo uno, inspecciona primero el tar correspondiente y extrae el archivo de forma selectiva en lugar de restaurar todo.

## 3. Archivos del sistema y login

Los respaldos de archivos de `/etc` modificados por los scripts se guardan aparte en `~/.local/state/dotfile-installer/backups/system/etc/`, y **no** están en el tar anterior. El instalador cancela una modificación crítica si falla el respaldo, pero el CLI oficial y los comandos del sistema tienen sus propios efectos. Compara el archivo actual con su copia antes de restaurarlo; usa `sudo` solo para el archivo concreto que de verdad quieras recuperar. **Nunca restaures `/etc` entero de otra máquina**.

Si activaste `greetd` manualmente y dejó de funcionar, vuelve a una TTY y comprueba las unidades y el journal:

```bash
systemctl status greetd
journalctl -b -u greetd --no-pager
command -v start-hyprland
command -v tuigreet
```

No habilites `greetd` hasta comprobar ambos ejecutables y revisar `system/etc/greetd/config.toml`. Si no inicia la sesión, deshabilita temporalmente la unidad desde una TTY (`sudo systemctl disable --now greetd`) para volver al arranque sin gestor gráfico mientras investigas. Si tocaste Plymouth/mkinitcpio manualmente, usa el respaldo específico, el medio de rescate y la documentación de CachyOS antes de regenerar initramfs.

## 4. Caelestia y chezmoi

Este repositorio **no cambia** el source global de chezmoi. Para inspeccionar *su* capa sin aplicar cambios:

```bash
cd ~/dotfile
chezmoi --source "$PWD" diff
chezmoi --source "$PWD" managed
```

Los dots oficiales se administran con `caelestia-cli` y mantienen estado en `~/.local/state/caelestia/`. No ejecutes `caelestia install` repetidamente sobre un escritorio con cambios propios para intentar arreglarlo. Revisa conflictos `.new` y sigue [ACTUALIZACIONES.md](ACTUALIZACIONES.md). Si restauras un backup de usuario antiguo, compara sus archivos con la versión actual antes de volver a aplicar la capa personal.

## 5. Lo que este repositorio no puede recuperar

Wallpapers (respaldados externamente), perfiles del navegador, documentos, claves, particiones, cifrado, cargador de arranque y firmware no forman parte de este proyecto. Ver [SECRETOS.md](SECRETOS.md) y [PENDIENTES.md](PENDIENTES.md).
