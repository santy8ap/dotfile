<div align="center">

# ✦ CachyOS + Caelestia, a mi manera

**Una base oficial siempre actualizable. Mis atajos, programas y estética por encima.**

[Empezar](#-instalación-paso-a-paso) · [Qué instala](#-qué-hace-este-repositorio) · [Personalizar](#-personalización-y-configuración) · [Recuperación](#-si-algo-sale-mal) · [Pendientes](docs/PENDIENTES.md)

</div>

> [!IMPORTANT]
> **Proyecto en pruebas.** El código y sus pruebas estáticas pasan, pero **todavía no se ha completado una instalación de principio a fin en un CachyOS base limpio ni se ha verificado el primer inicio de sesión**. Pruébalo primero en una VM o disco de pruebas. No borres tu único sistema funcional basándote solo en este README.

## 🧭 La idea en 30 segundos

Este repositorio reconstruye mi escritorio desde un **CachyOS base sin entorno gráfico**. En lugar de guardar una copia congelada de todos los archivos de Caelestia, instala primero los *dots* oficiales con `caelestia-cli` y **después** aplica mi capa personal con [chezmoi](https://github.com/twpayne/chezmoi): atajos, apariencia, fish, foot, aplicaciones y unidades de usuario. Instala paquetes y ajusta algunas opciones del sistema mediante etapas revisables.

```text
CachyOS base
    │
    ├─ comprobaciones + respaldo local
    ├─ pacman -Syu + herramientas + paru
    ├─ caelestia install ──────────────── base oficial de Caelestia
    ├─ paquetes propios (incluido Zen)
    ├─ chezmoi --source <este repo> ───── personalizaciones
    └─ sistema · servicios · temas · verificación
```

**No incluye** documentos personales, claves, perfiles del navegador, particiones ni los wallpapers. Estos últimos están en un respaldo externo. Tampoco instala CachyOS, configura el cargador de arranque ni garantiza que las API Lua de una versión futura sigan siendo compatibles.

## 📋 Antes de empezar

- CachyOS **ya instalado**, preferiblemente base sin desktop, usuario normal con `sudo`, conexión a Internet y una **TTY interactiva**. Ejecuta los comandos como tu usuario, **no con `sudo ./install.sh`**.
- Un **respaldo externo** de tu sistema y de `~/Imágenes/Wallpapers`. Los respaldos automáticos de estos scripts quedan **en el mismo disco**.
- `git` para clonar el repositorio (`sudo pacman -S --needed git` si todavía no existe). El instalador incorpora chezmoi y el helper AUR cuando corresponda.
- Tiempo para revisar descargas, compilaciones AUR y preguntas del instalador oficial. **No uses `--yes` para desatender la instalación upstream**: Caelestia puede añadir componentes nuevos.
- Si ya tienes un escritorio o un source global de chezmoi, haz una copia y **revisa el diff**: no asumimos que sea seguro sobrescribirlo. El source global no se modifica.

> [!NOTE]
> Mientras el [PR de instalación](https://github.com/santy8ap/dotfile/pull/1) no esté fusionado, **`main` aún no contiene este instalador**. Para probar exactamente la versión documentada aquí, clona la rama `arena/a581da79-dotfile`. Tras la fusión podrás clonar `main` normalmente.

## 🚀 Instalación paso a paso

### 1. Clonar y preparar

Desde tu CachyOS base, en una TTY:

```bash
sudo pacman -S --needed git
git clone --branch arena/a581da79-dotfile https://github.com/santy8ap/dotfile.git ~/dotfile
cd ~/dotfile
```

**Después de fusionar el PR**, el comando de clonación pasará a ser `git clone https://github.com/santy8ap/dotfile.git ~/dotfile`. No confundas este clon con tu antiguo `~/dotfiles` ni borres `~/.local/share/chezmoi`.

### 2. Inspeccionar antes de modificar

```bash
./install.sh --help
./install.sh --show-config
./install.sh --list-stages
./install.sh --dry-run
make probar                         # opcional: bash, tests estáticos y lint
```

`--dry-run` simula las etapas sin ejecutar código del upstream ni instalar paquetes. **No predice todos los cambios internos** que hará `caelestia install`. Lee los componentes y las confirmaciones que muestre el CLI real. Si el primer paso marca paquetes indisponibles, comprueba `pacman-conf --repo-list`: la disponibilidad depende de los repositorios de esa instalación.

### 3. Ajustar el equipo si hace falta

Los valores predeterminados están en [`config/defaults.env`](config/defaults.env). **No lo edites para preferencias de una máquina concreta**; crea `config/host.env` (ignorado por Git), por ejemplo:

```bash
cat > config/host.env <<'EOF'
DOTFILE_LOCALE="es_MX.UTF-8"
DOTFILE_TIMEZONE="America/Bogota"
DOTFILE_WALLPAPER_DIR="$HOME/Imágenes/Wallpapers"
EOF
./install.sh --show-config
```

También puedes usar `config/host.<nombre-de-tu-equipo>.env` o variables de entorno (`DOTFILE_TIER=core ./install.sh`). Por defecto se instalan paquetes de nivel **full**, se actualiza el sistema con `pacman -Syu`, se usa Zen en vez del Firefox opcional de Caelestia y se ejecutan ajustes configurados de sistema (locale, grupos y servicios; revísalos antes de aceptar). **No** se activan por defecto el firewall, sudoers sin contraseña, el hook de Plymouth ni la copia de `system/etc/`.

### 4. Instalar en orden

```bash
./install.sh
```

El instalador mostrará lo que va a hacer y pedirá confirmación. En orden ejecuta: `checks` → `base` → `aur` → `upstream` → `packages` → `dotfiles` → `system` → `services` → `theming` → `post` → `verify`. La etapa **upstream** instala el CLI si falta y ejecuta `caelestia install --disable-components firefox` en la terminal, antes de aplicar los archivos propios. Si esa etapa falla, **no se continúa a aplicar la capa personal** salvo que explícitamente hayas pedido `--keep-going` (no recomendado para la primera instalación).

No se ejecuta el antiguo `install.fish` de Caelestia. `--no-upstream` solo tiene sentido si **ya** instalaste la base oficial. `--no-aur` pospone upstream porque puede faltar `caelestia-cli`.

**Si prefieres avanzar por partes** (por ejemplo, para diagnosticar paquetes):

```bash
./install.sh --only checks base aur upstream
./install.sh --only packages dotfiles system services theming post verify
```

No saltes etapas sin comprobar sus dependencias. Otras opciones útiles:

| Comando | Para qué sirve |
| --- | --- |
| `./install.sh --core-only` | Solo paquetes del núcleo, además de las otras etapas. |
| `./install.sh --no-system` | No tocar ajustes/servicios de sistema de esa etapa. |
| `./install.sh --resume` | Volver a intentar etapas pendientes tras un fallo o al entrar a una sesión gráfica. |
| `./install.sh dotfiles --force` | Reaplicar **solo** la capa personal tras revisar su diff. |
| `./install.sh verify --force` | Generar de nuevo el informe de verificación. |
| `./install.sh --list-stages` | Ver etapas y marcas de completado. |

`--force` repite etapas y algunas operaciones pueden tener efectos; úsalo con una etapa concreta cuando sea posible. Una etapa que necesite sesión gráfica puede quedar **pendiente** hasta iniciar sesión. Para toda la interfaz, consulta `./install.sh --help`.

### 5. Revisar dotfiles y gestor de sesiones

Antes de volver a aplicar configuraciones manualmente:

```bash
chezmoi --source "$PWD" diff
chezmoi --source "$PWD" managed
```

En el equipo original, chezmoi global apunta a **otro** repositorio. Este instalador utiliza siempre `--source "$PWD"` y **no** ejecuta `chezmoi init --force`; si detecta otro source, pide escribir `APLICAR` para confirmar la aplicación interactiva.

**greetd no se configura automáticamente.** Primero comprueba `command -v start-hyprland` y `command -v tuigreet`; después lee [`system/etc/greetd/config.toml`](system/etc/greetd/config.toml), [`docs/MAQUINA_ORIGINAL.md`](docs/MAQUINA_ORIGINAL.md) y [`docs/RECUPERACION.md`](docs/RECUPERACION.md). Activa un gestor de login solo cuando hayas confirmado cómo volver a una TTY. La opción `DOTFILE_APPLY_ETC=yes` es **opt-in** y debe revisarse antes de usarla: aplica los archivos disponibles bajo `system/etc/`.

### 6. Recuperar wallpapers y entrar al escritorio

Copia los fondos de tu **propio** respaldo externo al directorio configurado (la ruta de origen de este ejemplo es ilustrativa):

```bash
mkdir -p "$HOME/Imágenes/Wallpapers"
rsync -av -- "/ruta/real/de/tu/respaldo/Wallpapers/" "$HOME/Imágenes/Wallpapers/"
```

No ejecutes esa copia sin sustituir la ruta de origen y comprobar primero el contenido del disco externo. Después inicia sesión en Hyprland. Revisa Caelestia, Zen, terminal, archivos, audio/red, launcher, atajos, temas, cursor y rotación de fondos. Tras entrar a una sesión gráfica:

```bash
cd ~/dotfile
./install.sh --resume
./install.sh verify --force
```

Sigue la [lista de verificación de arranque](docs/PENDIENTES.md) antes de declarar terminada la restauración.

## 🧩 Qué hace este repositorio

| Ruta | Contenido |
| --- | --- |
| `install.sh`, `scripts/00-…80-*.sh` | Orquestador y etapas ordenadas, con estado, log y modo de ensayo. |
| `scripts/15-upstream.sh` | Base oficial mediante `caelestia-cli`, antes de nuestros ajustes. |
| `home/`, `.chezmoiroot` | Estado fuente de chezmoi; **solo** `home/` se despliega sobre `$HOME`. |
| `home/.chezmoiignore` | Evita sobrescribir módulos Hyprland de upstream y estado volátil. |
| `packages/*.txt` | Núcleo, paquetes oficiales, AUR e ignorados. Nombres orientativos, **no lockfile**. |
| `config/defaults.env` | Valores iniciales; se pueden sobrescribir sin editarlo. |
| `system/etc/` | Ejemplos de ajustes de `/etc`, **no aplicados por defecto**. |
| `scripts/backup.sh`, `scripts/update-upstream.sh` | Respaldo local y actualización upstream controlada. |
| `docs/` | [Recuperación](docs/RECUPERACION.md), [actualizaciones](docs/ACTUALIZACIONES.md), [auditoría](docs/AUDITORIA.md), [secretos](docs/SECRETOS.md) y [pendientes](docs/PENDIENTES.md). |

### Personalización y configuración

Con Caelestia presente, la base es **propiedad del upstream**. Los archivos antiguos bajo `home/dot_config/hypr/` quedan como referencia, no reemplazan sus módulos Lua. Las preferencias propias viven principalmente en `home/dot_config/caelestia/hypr-vars.lua` y `hypr-user.lua.tmpl`. Algunas API Lua, opciones de `shell.json` y nombres de paquete pueden cambiar: tras cada actualización hay que revisar el diff y probar la sesión, no solo confiar en que la instalación termine.

Las rutas de usuario se generan con plantillas chezmoi; el tema Qt/GTK, fish, foot, atajos y timer de fondos se mantienen aquí. Archivos dinámicos como `fish_variables`, esquemas de color temporales y overrides por monitor **no** se capturan a ciegas. Para ampliar tu captura en **el CachyOS original**, lee [`docs/AUDITORIA.md`](docs/AUDITORIA.md) y ejecuta primero `./scripts/capture.sh --list`; revisa el diff antes de publicar cambios.

## 🛟 Si algo sale mal

**Se detuvo una etapa:** lee el error en la terminal, revisa el log indicado al final (bajo `~/.local/state/dotfile-installer/logs/`), corrige la causa y usa `./install.sh --resume`. `--list-stages` muestra el estado; evita forzar toda la instalación sin saber qué falló.

**No inicia el entorno gráfico:** entra por TTY (`Ctrl`+`Alt`+`F2`), conserva acceso al sistema y revisa primero el gestor de sesiones y el log. Para revisar/restaurar el respaldo local de archivos de usuario:

```bash
cd ~/dotfile
./scripts/backup.sh --list
./scripts/backup.sh --restore 1     # confirma qué copia es la correcta ANTES de aceptar
```

La restauración **sobrescribe** archivos presentes, pero no elimina nuevos. Los respaldos de archivos individuales de `/etc` están aparte, en `~/.local/state/dotfile-installer/backups/system/etc/`, y **no** los restaura `backup.sh --restore`; examina el archivo y restaura solo lo necesario con `sudo`. El script cancela la modificación de `/etc` si no pudo crear su respaldo. Lee el [procedimiento de recuperación](docs/RECUPERACION.md) antes de actuar.

**Privacidad:** el repositorio no debe contener claves SSH, tokens, credenciales ni perfiles privados. El backup local de `~/.config` **puede contener datos sensibles**, por eso no debes subirlo a Git ni compartirlo. Lee [SECRETOS.md](docs/SECRETOS.md).

## 🔄 Mantenerlo al día

1. Guarda un respaldo externo y comprueba que no hay cambios locales: `git status --short`.
2. Haz un respaldo local: `./scripts/backup.sh` (no sustituye al externo).
3. Consulta los paquetes: `./scripts/packages-update.sh --diff`; no sobreescribas listas automáticamente tras una instalación incompleta.
4. Actualiza CachyOS con una transacción completa (`sudo pacman -Syu`, **nunca** `pacman -Sy` seguido de instalaciones parciales).
5. Para los dots de Caelestia, primero `./scripts/update-upstream.sh --dry-run` y luego, cuando estés listo, `./scripts/update-upstream.sh`. Esta actualización puede modificar **también paquetes del sistema**; requiere TTY, backup y confirmación.
6. Examina conflictos `.new` y cambios en las API upstream. Ejecuta `chezmoi --source "$PWD" diff`, aplica `./install.sh dotfiles --force` **solo tras revisar** y prueba `./install.sh verify --force` y el login.

El script de actualización **no reaplica tus overrides automáticamente**. Los detalles, límites y comandos de diagnóstico están en [ACTUALIZACIONES.md](docs/ACTUALIZACIONES.md).

---

<div align="center">

**La meta es poder reconstruir el escritorio sin convertir una copia vieja de Caelestia en una deuda eterna.**

Primero la base oficial; después, lo nuestro. ✦

</div>
