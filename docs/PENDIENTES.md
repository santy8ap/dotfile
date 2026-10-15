# Qué falta antes de llamar a esto «restauración completa»

## Bloqueadores (probar en CachyOS limpio)

- [ ] Instalar CachyOS **base sin desktop** en VM/partición de pruebas. Registrar ISO, kernel y repos presentes (`pacman-conf --repo-list`).
- [ ] Ejecutar `./install.sh --dry-run`, luego una instalación interactiva. Confirmar que `caelestia install` del CLI ofrece `--disable-components firefox`, instala el shell estable y guarda `dots-state.json`.
- [ ] Verificar que la capa personal **no reemplaza** los módulos Lua de upstream, pero sí aplica `hypr-vars.lua` y `hypr-user.lua`. Revisar `chezmoi --source "$PWD" managed` y `diff` antes de aplicar.
- [ ] Configurar `greetd` **después** de validar que `start-hyprland` y `tuigreet` existen. El archivo `/etc/greetd/config.toml` no se instala automáticamente por defecto.
- [ ] Reiniciar: login por greetd, arranque de Hyprland/Caelestia, Super abre launcher, Super+Tab vuelve al workspace anterior, Super+T/W/E/C abren apps, tema Qt/GTK, Thunar, audio, red, brillo, suspensión, capturas y bloqueo.
- [ ] Copiar desde el respaldo externo los 69 wallpapers (~159 MiB) a `~/Imágenes/Wallpapers`. El formato y montaje del respaldo aún no se conocen; la copia no se automatiza sin esa información.
- [ ] Una vez iniciada sesión gráfica, `./install.sh --resume` y `./install.sh verify --force`. Inspeccionar reportes y servicios.
- [ ] Simular una actualización del CLI/dots; `./scripts/update-upstream.sh --dry-run` y luego actualización interactiva, comprobar conflictos `.new` y persistencia de los overrides.

## Mejoras futuras (no bloquean la primera restauración)

- [ ] Separar los 261 paquetes de la captura en imprescindibles/opcionales del usuario/sistema base. Con `core` y `extra` únicamente, algunos `cachyos-*` pueden no existir en repos ni AUR; una lista completa no equivale a un lockfile portable.
- [ ] Revisar complementos de fish: `fisher list` salió vacío, pero no se confirmó el contenido de `~/.config/fish/conf.d/` (en el comando compartido apareció `&gt;` en lugar de `>`).
- [ ] Elegir, si se desea, un mecanismo opcional de importación de wallpapers desde disco externo; nunca incluir credenciales ni perfiles del navegador en Git.
- [ ] Identificar el commit original desde el que se personalizaron los dots para comparar mejoras upstream de forma más exacta. No es imprescindible para instalar: el CLI ya conoce el repo oficial.
- [ ] Probar las unidades/ajustes de sistema en la misma versión de CachyOS. `ufw`, sudoers, Plymouth y cambios de `/etc` sensibles siguen desactivados u opt-in.

## Seguridad

Nunca comprobar esto borrando primero el único sistema funcional. Mantener `~/dotfiles` y `~/.local/share/chezmoi` hasta terminar la prueba; trabajar en la rama de este repo y publicar el cambio solo tras revisión. Los respaldos locales de los scripts viven en el mismo disco y **no sustituyen un respaldo externo**.
