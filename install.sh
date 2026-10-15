#!/usr/bin/env bash
# ===========================================================================
#  install.sh — punto de entrada único del instalador.
#
#  Uso rápido:
#      ./install.sh                      # todo, preguntando lo necesario
#      ./install.sh --dry-run            # ver qué haría, sin tocar nada
#      ./install.sh packages dotfiles    # solo esas etapas
#      ./install.sh --core-only -y       # mínimo imprescindible, sin preguntas
#      ./install.sh --resume             # continuar desde donde falló
#
#  Arranque en una PC recién instalada (sin haber clonado nada):
#      curl -fsSL https://raw.githubusercontent.com/santy8ap/dotfile/main/install.sh | bash -s -- --dry-run
#
#  Documentación: docs/RECUPERACION.md (paso a paso) y docs/AUDITORIA.md.
# ===========================================================================

set -o errexit
set -o nounset
set -o pipefail

DOTFILE_INSTALLER_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# 1. Localizar el repo (o clonarlo si se ejecuta desde curl | bash)
# ---------------------------------------------------------------------------
_bootstrap_locate_repo() {
    local self="" dir=""

    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        self="$(readlink -f "${BASH_SOURCE[0]}" 2> /dev/null || printf '%s' "${BASH_SOURCE[0]}")"
        dir="$(dirname -- "$self")"
    fi

    # ¿Estamos dentro del repo?
    if [[ -n "$dir" && -d "${dir}/scripts/lib" && -f "${dir}/config/defaults.env" ]]; then
        printf '%s' "$dir"
        return 0
    fi

    # ¿Se lanzó desde un directorio que sí es el repo?
    if [[ -d "${PWD}/scripts/lib" && -f "${PWD}/config/defaults.env" ]]; then
        printf '%s' "$PWD"
        return 0
    fi

    return 1
}

_bootstrap_clone() {
    local url="$1" branch="$2" dest
    command -v git > /dev/null 2>&1 || {
        echo "  ✘ Se necesita git para descargar el repo. Instala git y reintenta:" >&2
        echo "      sudo pacman -S --needed git" >&2
        exit 1
    }
    dest="$(mktemp -d "${TMPDIR:-/tmp}/dotfile-installer.XXXXXX")"
    echo "  • Clonando $url (rama $branch) en $dest" >&2
    if ! git clone --depth 1 --branch "$branch" "$url" "$dest" >&2; then
        echo "  ✘ No se pudo clonar el repositorio. ¿Sin red? ¿URL correcta?" >&2
        exit 1
    fi
    printf '%s' "$dest"
}

# Valores que se usan antes de cargar common.sh
ARG_REPO_URL="${DOTFILE_REPO_URL:-https://github.com/santy8ap/dotfile.git}"
ARG_REPO_BRANCH="${DOTFILE_REPO_BRANCH:-main}"

# ---------------------------------------------------------------------------
# 2. Parsear argumentos (una pasada: necesita la URL antes de clonar)
# ---------------------------------------------------------------------------
declare -a STAGES=()
SHOW_HELP="no"; SHOW_CONFIG="no"; SHOW_STAGES="no"; PRINT_VERSION="no"
RESUME="no"; FROM_STAGE=""
CORE_ONLY="no"; NO_AUR="no"; NO_SYSTEM="no"; NO_DOTFILES="no"; NO_UPSTREAM="no"
WITH_IGNORED="no"; NO_BACKUP="no"; SYSUPGRADE=""; FORCE_ETC="no"
SOURCE_OVERRIDE=""

_usage() {
    cat <<'EOF'
Uso: ./install.sh [etapas...] [opciones]

Etapas (en el orden en que se ejecutan; si no indicas ninguna, corren todas):
  checks     Comprobaciones previas, hardware y respaldo de ~/.config
  base       pacman.conf, espejos, keyring, actualización del sistema
  aur        Helper de AUR (paru), compilándolo si hace falta
  upstream   Instalador oficial `caelestia install` (antes de tus dotfiles)
  packages   Instala packages/nucleo.txt + oficiales.txt + aur.txt
  dotfiles   chezmoi --source de este repo + apply de home/
  system     Grupos, servicios del sistema, ufw, locale/timezone, /etc
  services   Unidades systemd de usuario (rotar-fondo.timer, ...)
  theming    GTK/Qt/iconos/cursores/fuentes y carpetas XDG
  post       Tareas finales: mise, carpetas, permisos, chwd, informant
  verify     Informe de verificación de todo lo anterior

Opciones:
  -y, --yes             No preguntar nada (asume sí). Útil en scripts.
  -n, --dry-run         Mostrar qué se haría sin cambiar nada.
  -f, --force           Repetir etapas ya completadas (ignora el estado guardado).
      --resume          Continuar desde la primera etapa no completada.
      --from ETAPA      Empezar en ETAPA y seguir hasta el final.
      --only ETAPA...   Ejecutar únicamente las etapas indicadas.
      --core-only       Instalar solo packages/nucleo.txt (tier "core").
      --with-ignored    Instalar también lo que está en packages/ignorar.txt.
      --no-aur          Saltar todo lo que venga de AUR (upstream queda pendiente).
      --no-upstream     No ejecutar `caelestia install` (solo si ya tienes la base).
      --no-system       No tocar /etc, servicios del sistema ni grupos.
      --no-dotfiles     No aplicar chezmoi.
      --no-backup       No hacer el respaldo previo de ~/.config.
      --sysupgrade      Forzar pacman -Syu (predeterminado: sí).
      --no-sysupgrade   No actualizar el sistema antes de instalar.
      --source URL      Repo git a usar si hay que clonar (bootstrap).
      --branch REF      Rama/commit a usar al clonar.
      --show-config     Imprimir la configuración efectiva y salir.
      --list-stages     Listar etapas y su estado (hecha/pendiente) y salir.
      --keep-going      No abortar si una etapa falla.
  -v, --verbose         Salida detallada (los comandos muestran todo su output).
  -h, --help            Esta ayuda.
      --version         Versión del instalador.

Configuración: config/defaults.env y config/host.$(hostname).env
Estado y logs: ~/.local/state/dotfile-installer/

Ejemplos:
  ./install.sh --dry-run                  # ensayo general, cero riesgo
  ./install.sh checks base packages       # solo esas tres
  ./install.sh --from dotfiles            # de dotfiles en adelante
  ./install.sh packages --core-only -y    # núcleo, sin preguntas
  ./install.sh verify                     # ¿está todo bien?
EOF
}

# Primer pase: solo opciones que afectan al bootstrap y flags simples.
declare -a POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        SHOW_HELP="yes" ;;
        --show-config)    SHOW_CONFIG="yes" ;;
        --list-stages)    SHOW_STAGES="yes" ;;
        --version)        PRINT_VERSION="yes" ;;
        -y|--yes)         export DOTFILE_YES="yes" ;;
        -n|--dry-run)     export DOTFILE_DRY_RUN="yes" ;;
        -f|--force)       export DOTFILE_FORCE="yes" ;;
        -v|--verbose)     export DOTFILE_VERBOSE="yes" ;;
        --keep-going)     export DOTFILE_KEEP_GOING="yes" ;;
        --resume)         RESUME="yes" ;;
        --from)           FROM_STAGE="${2:?--from necesita una etapa}"; shift ;;
        --only)           # Las etapas siguientes se procesan como posicionales.
                          # `./install.sh checks dotfiles` ya hace exactamente esto.
                          : ;;
        --core-only)      CORE_ONLY="yes"; export DOTFILE_TIER="core" ;;
        --with-ignored)   WITH_IGNORED="yes"; export DOTFILE_WITH_IGNORED="yes" ;;
        --no-aur)         NO_AUR="yes" ;;
        --no-upstream)    NO_UPSTREAM="yes"; export DOTFILE_UPSTREAM_MODE="skip" ;;
        --no-system)      NO_SYSTEM="yes"; export DOTFILE_SYSTEM="no" ;;
        --no-dotfiles)    NO_DOTFILES="yes"; export DOTFILE_APPLY_DOTFILES="no" ;;
        --no-backup)      NO_BACKUP="yes"; export DOTFILE_BACKUP="no" ;;
        --sysupgrade)     export DOTFILE_SYSUPGRADE="yes" ;;
        --no-sysupgrade)  export DOTFILE_SYSUPGRADE="no" ;;
        --source)         ARG_REPO_URL="${2:?--source necesita una URL}"; shift ;;
        --branch)         ARG_REPO_BRANCH="${2:?--branch necesita una referencia}"; shift ;;
        --)               shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done; break ;;
        -*)               echo "  ✘ Opción desconocida: $1 (usa --help)" >&2; exit 2 ;;
        *)                POSITIONAL+=("$1") ;;
    esac
    shift
done

if [[ "$PRINT_VERSION" == "yes" ]]; then
    echo "dotfile installer ${DOTFILE_INSTALLER_VERSION}"
    exit 0
fi
if [[ "$SHOW_HELP" == "yes" ]]; then
    _usage
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Asegurar que tenemos el repo local y cargar las librerías
# ---------------------------------------------------------------------------
if ! REPO_ROOT="$(_bootstrap_locate_repo)"; then
    REPO_ROOT="$(_bootstrap_clone "$ARG_REPO_URL" "$ARG_REPO_BRANCH")"
    BOOTSTRAPPED="yes"
else
    BOOTSTRAPPED="no"
fi

# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/hardware.sh
source "${REPO_ROOT}/scripts/lib/hardware.sh"

# Las opciones del CLI mandan sobre defaults.env
export DOTFILE_REPO_URL="$ARG_REPO_URL"
export DOTFILE_REPO_BRANCH="$ARG_REPO_BRANCH"
DRY_RUN="${DOTFILE_DRY_RUN:-no}"
YES="${DOTFILE_YES:-no}"
FORCE="${DOTFILE_FORCE:-no}"
VERBOSE="${DOTFILE_VERBOSE:-no}"
KEEP_GOING="${DOTFILE_KEEP_GOING:-no}"

# ---------------------------------------------------------------------------
# 4. Definición de las etapas
# ---------------------------------------------------------------------------
# formato: "id|archivo|descripcion"
STAGE_DEFS=(
    "checks|00-checks.sh|Comprobaciones previas, hardware y respaldo"
    "base|05-base.sh|pacman.conf, espejos, keyring y actualización"
    "aur|10-aur-helper.sh|Helper de AUR (paru)"
    "upstream|15-upstream.sh|Instalar Caelestia base con su CLI oficial"
    "packages|20-packages.sh|Instalar paquetes (núcleo, oficiales y AUR)"
    "dotfiles|30-dotfiles.sh|Aplicar dotfiles con chezmoi"
    "system|40-system.sh|Grupos, servicios del sistema, ufw, locale y /etc"
    "services|50-user-services.sh|Unidades systemd de usuario"
    "theming|60-theming.sh|Apariencia: GTK, iconos, cursores, fuentes, XDG"
    "post|70-post.sh|Tareas finales y configuración de apps"
    "verify|80-verify.sh|Informe de verificación"
)

_stage_file() { # <id> -> archivo
    local def id file desc
    for def in "${STAGE_DEFS[@]}"; do
        IFS='|' read -r id file desc <<< "$def"
        if [[ "$id" == "$1" ]]; then printf '%s' "$file"; return 0; fi
    done
    return 1
}

_stage_desc() { # <id> -> descripcion
    local def id file desc
    for def in "${STAGE_DEFS[@]}"; do
        IFS='|' read -r id file desc <<< "$def"
        if [[ "$id" == "$1" ]]; then printf '%s' "$desc"; return 0; fi
    done
    return 1
}

_valid_stage() { _stage_file "$1" > /dev/null; }

_stage_done() { # <id>
    local id="$1" file hash_file current
    file="$(_stage_file "$id")" || return 1
    hash_file="${STATE_DIR}/${id}.done"
    [[ -f "$hash_file" ]] || return 1
    have sha256sum || return 1
    current="$(sha256sum "${SCRIPTS_DIR}/${file}" | cut -d' ' -f1)"
    [[ "$(cat "$hash_file" 2> /dev/null)" == "$current" ]]
}

# ---------------------------------------------------------------------------
# 5. Resolver qué etapas ejecutar
# ---------------------------------------------------------------------------
declare -a ALL_STAGE_IDS=()
for def in "${STAGE_DEFS[@]}"; do ALL_STAGE_IDS+=("${def%%|*}"); done

# Validar etapas pedidas
for s in ${POSITIONAL[@]+"${POSITIONAL[@]}"}; do
    _valid_stage "$s" || die "etapa desconocida: '$s'. Etapas válidas: ${ALL_STAGE_IDS[*]}"
done

declare -a RUN_STAGES=()

if [[ "${#POSITIONAL[@]}" -gt 0 ]]; then
    # Se respeta el orden canónico, no el orden en que se escribieron
    for s in "${ALL_STAGE_IDS[@]}"; do
        for p in "${POSITIONAL[@]}"; do
            [[ "$s" == "$p" ]] && RUN_STAGES+=("$s") && break
        done
    done
elif [[ -n "$FROM_STAGE" ]]; then
    _valid_stage "$FROM_STAGE" || die "--from: etapa desconocida '$FROM_STAGE'"
    started="no"
    for s in "${ALL_STAGE_IDS[@]}"; do
        [[ "$s" == "$FROM_STAGE" ]] && started="yes"
        [[ "$started" == "yes" ]] && RUN_STAGES+=("$s")
    done
elif [[ "$RESUME" == "yes" ]]; then
    for s in "${ALL_STAGE_IDS[@]}"; do
        [[ "$s" == "verify" || ! -f "${STATE_DIR}/${s}.done" ]] && RUN_STAGES+=("$s")
    done
    if [[ "${#RUN_STAGES[@]}" -eq 0 ]]; then
        log_ok "todas las etapas están completadas (usa --force para repetir todo)"
        exit 0
    fi
else
    RUN_STAGES=("${ALL_STAGE_IDS[@]}")
fi

# Aplicar filtros de opciones
declare -a FILTERED=()
for s in "${RUN_STAGES[@]}"; do
    case "$s" in
        aur)      [[ "$NO_AUR" == "yes" ]] && continue ;;
        system)   is_false "$DOTFILE_SYSTEM" && continue ;;
        dotfiles) is_false "$DOTFILE_APPLY_DOTFILES" && continue ;;
    esac
    FILTERED+=("$s")
done
RUN_STAGES=("${FILTERED[@]+"${FILTERED[@]}"}")

# ---------------------------------------------------------------------------
# 6. --show-config / --list-stages
# ---------------------------------------------------------------------------
if [[ "$SHOW_CONFIG" == "yes" ]]; then
    hw_detect
    print_banner
    log_step "Repo: ${REPO_ROOT}"
    log_info "versión del instalador: ${DOTFILE_INSTALLER_VERSION}"
    log_info "estado y logs: ${STATE_DIR}"
    echo
    printf '%s\n' "--- Hardware detectado ---"
    hw_summary
    echo
    printf '%s\n' "--- Configuración efectiva ---"
    while IFS= read -r v; do
        printf '%-34s %s\n' "$v" "${!v-}"
    done < <(compgen -v DOTFILE_ | sort)
    echo
    printf '%s\n' "--- Etapas a ejecutar ---"
    for s in ${RUN_STAGES[@]+"${RUN_STAGES[@]}"}; do
        printf '  %-10s %s\n' "$s" "$(_stage_desc "$s")"
    done
    exit 0
fi

if [[ "$SHOW_STAGES" == "yes" ]]; then
    printf '%-12s %-10s %s\n' "ETAPA" "ESTADO" "DESCRIPCIÓN"
    for s in "${ALL_STAGE_IDS[@]}"; do
        if _stage_done "$s"; then st="✔ hecha"; else st="· pendiente"; fi
        printf '%-12s %-10s %s\n' "$s" "$st" "$(_stage_desc "$s")"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# 7. Confirmación inicial
# ---------------------------------------------------------------------------
hw_detect
mkdir -p "$STATE_DIR" 2> /dev/null || true

if is_false "$DRY_RUN"; then
    print_banner
    log_step "Resumen de lo que se va a hacer"
    hw_summary | sed 's/^/  /'
    echo
    log_info "tier de paquetes : ${DOTFILE_TIER}"
    log_info "actualizar sistema: ${DOTFILE_SYSUPGRADE}"
    log_info "tocar /etc        : ${DOTFILE_SYSTEM}"
    log_info "aplicar dotfiles  : ${DOTFILE_APPLY_DOTFILES}"
    log_info "respaldo previo   : ${DOTFILE_BACKUP}"
    log_info "etapas            : ${RUN_STAGES[*]:-ninguna}"
    log_info "log               : ${LOG_FILE}"
    echo

    if [[ "${#RUN_STAGES[@]}" -eq 0 ]]; then
        log_warn "no hay etapas que ejecutar"
        exit 0
    fi

    if ! confirm "¿Continuar con la instalación?"; then
        log_info "cancelado. Puedes ensayar antes con: ./install.sh --dry-run"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# 8. Ejecutar
# ---------------------------------------------------------------------------
declare -a OK_STAGES=() FAIL_STAGES=() SKIP_STAGES=()
START_TS="$(date +%s)"

# Exportar lo que los pasos necesitan saber
export REPO_ROOT SCRIPTS_DIR LIB_DIR CONFIG_DIR PACKAGES_DIR SYSTEM_DIR HOME_SRC_DIR
export STATE_DIR BACKUP_DIR LOG_FILE DRY_RUN YES FORCE VERBOSE KEEP_GOING
export DOTFILE_INSTALLER_VERSION BOOTSTRAPPED
export HW_GPU_VENDOR HW_CPU_VENDOR HW_IS_LAPTOP HW_IS_FRAMEWORK HW_DISTRO HW_TAGS
[[ "$NO_AUR" == "yes" ]] && export DOTFILE_NO_AUR="yes"
[[ "$WITH_IGNORED" == "yes" ]] && export DOTFILE_WITH_IGNORED="yes"

for stage in ${RUN_STAGES[@]+"${RUN_STAGES[@]}"}; do
    file="$(_stage_file "$stage")"
    path="${SCRIPTS_DIR}/${file}"
    if [[ ! -f "$path" ]]; then
        log_error "falta el script de la etapa '$stage': $path"
        FAIL_STAGES+=("$stage")
        is_true "$KEEP_GOING" && continue || break
    fi

    echo
    if is_false "$DRY_RUN"; then
        printf '%s\n' "${C_BOLD}${C_CYAN}──────────────────────────────────────────────────────────────${C_RESET}" >&2
    fi

    rc=0
    bash "$path" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        OK_STAGES+=("$stage")
    elif [[ "$rc" -eq 75 ]]; then
        SKIP_STAGES+=("$stage")
        log_warn "etapa '$stage' pendiente hasta iniciar sesión gráfica"
    else
        FAIL_STAGES+=("$stage")
        log_error "la etapa '$stage' terminó con código $rc"
        if is_false "$KEEP_GOING"; then
            log_warn "se detiene la instalación. Para continuar donde quedaste:"
            log_warn "    ./install.sh --resume"
            break
        fi
    fi
done

END_TS="$(date +%s)"

# ---------------------------------------------------------------------------
# 9. Resumen final
# ---------------------------------------------------------------------------
echo
printf '%s\n' "${C_BOLD}${C_MAGENTA}══════════════════ RESUMEN ══════════════════${C_RESET}" >&2
log_info "duración: $(( END_TS - START_TS )) segundos"
[[ "${#OK_STAGES[@]}"   -gt 0 ]] && log_ok    "completadas : ${OK_STAGES[*]}"
[[ "${#FAIL_STAGES[@]}" -gt 0 ]] && log_error "con fallos  : ${FAIL_STAGES[*]}"
[[ "${#SKIP_STAGES[@]}" -gt 0 ]] && log_warn "pospuestas  : ${SKIP_STAGES[*]} (repite con --resume tras entrar a Hyprland)"
log_info "log completo: ${LOG_FILE}"

if [[ "${BOOTSTRAPPED}" == "yes" ]]; then
    echo
    log_warn "el repo se clonó en un directorio temporal: ${REPO_ROOT}"
    log_warn "clónalo en un sitio permanente para poder actualizarlo después:"
    log_warn "    git clone ${ARG_REPO_URL} ~/dev/dotfile && cd ~/dev/dotfile && ./install.sh --resume"
fi

if [[ "${#FAIL_STAGES[@]}" -eq 0 ]]; then
    echo
    if is_true "$DRY_RUN"; then
        log_ok "simulacro terminado; NO se instaló ni modificó el sistema"
        exit 0
    fi
    log_ok "instalación terminada"
    log_info "próximos pasos:"
    log_info "  1. Revisa el informe:  ./install.sh verify   (o make verificar)"
    log_info "  2. Captura configs que aún no estén en el repo:  make capturar"
    log_info "  3. Reinicia para cargar servicios y grupos:  sudo reboot"
    log_info "  4. Documentación: docs/RECUPERACION.md y docs/ACTUALIZACIONES.md"
    exit 0
else
    echo
    log_error "hubo fallos. Revisa el log y vuelve a intentar con: ./install.sh --resume"
    exit 1
fi
