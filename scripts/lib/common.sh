#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# common.sh — utilidades compartidas por el instalador.
#
# NUNCA se ejecuta directo: los demás scripts hacen `source` de este archivo.
# Es auto-suficiente: resuelve las rutas del repo, carga config/defaults.env y
# config/host.<hostname>.env, y define los helpers de logging/ejecución.
#
# Contrato de variables globales que deja listas:
#   REPO_ROOT, SCRIPTS_DIR, LIB_DIR, CONFIG_DIR, PACKAGES_DIR, SYSTEM_DIR, HOME_SRC_DIR
#   DRY_RUN, YES, FORCE, VERBOSE, KEEP_GOING, LOG_FILE, SUDO_CMD[]
# ---------------------------------------------------------------------------

# Protección contra doble `source`
[[ -n "${_DOTFILE_COMMON_SH:-}" ]] && return 0
_DOTFILE_COMMON_SH=1

set -o errexit
set -o nounset
set -o pipefail
# Logs y respaldos pueden incluir rutas, tokens o contenido de ~/.config.
# No permitir lectura por otros usuarios del sistema.
umask 077

# --- Rutas del repo --------------------------------------------------------
LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname -- "$LIB_DIR")"
REPO_ROOT="$(dirname -- "$SCRIPTS_DIR")"
CONFIG_DIR="${REPO_ROOT}/config"
PACKAGES_DIR="${REPO_ROOT}/packages"
SYSTEM_DIR="${REPO_ROOT}/system"
HOME_SRC_DIR="${REPO_ROOT}/home"

# --- Carga de configuración ------------------------------------------------
# defaults.env usa la forma VAR="${VAR:-valor}", así que cualquier variable ya
# exportada (por install.sh o por el entorno del usuario) tiene prioridad.
_load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    # shellcheck disable=SC1090
    set -a
    source "$file"
    set +a
}

_load_env_file "${CONFIG_DIR}/defaults.env"
_load_env_file "${CONFIG_DIR}/host.$(hostname 2> /dev/null || echo desconocido).env"
_load_env_file "${CONFIG_DIR}/host.env"

# --- Flags (los fija install.sh; aquí solo se normalizan) -------------------
DRY_RUN="${DOTFILE_DRY_RUN:-no}"
YES="${DOTFILE_YES:-no}"
FORCE="${DOTFILE_FORCE:-no}"
VERBOSE="${DOTFILE_VERBOSE:-no}"
KEEP_GOING="${DOTFILE_KEEP_GOING:-no}"

# --- sudo ------------------------------------------------------------------
SUDO_CMD=()
if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo > /dev/null 2>&1; then
        SUDO_CMD=(sudo)
    fi
fi

# --- Estado y logs ---------------------------------------------------------
XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
STATE_DIR="${DOTFILE_STATE_DIR:-${XDG_STATE_HOME}/dotfile-installer}"
[[ -n "$STATE_DIR" ]] || STATE_DIR="${XDG_STATE_HOME}/dotfile-installer"
BACKUP_DIR="${STATE_DIR}/backups"
LOG_FILE="${DOTFILE_LOG_FILE:-}"
if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="${STATE_DIR}/logs/instalar-$(date +%Y%m%d-%H%M%S).log"
fi

# --- Colores ---------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""
    C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# TODOS los logs van a stderr. Motivo: varias funciones de las librerías
# devuelven datos por stdout (pkg_select, pkg_detect_aur_helper...) y un log
# mezclado ahí corrompería el resultado. stdout queda reservado para datos.
_log_raw() { # <color> <etiqueta> <mensaje...>
    local color="$1" tag="$2"; shift 2
    local msg="$*"
    printf '%s%s%s %s\n' "$color" "$tag" "$C_RESET" "$msg" >&2
    _log_to_file "$tag $msg"
}

_log_to_file() {
    [[ -n "$LOG_FILE" ]] || return 0
    local dir; dir="$(dirname -- "$LOG_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2> /dev/null || return 0
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2> /dev/null || true
}

log_step()  { _log_raw "$C_BOLD$C_MAGENTA" "==>" "$*"; }
log_info()  { _log_raw "$C_BLUE"           "  •" "$*"; }
log_ok()    { _log_raw "$C_GREEN"          "  ✔" "$*"; }
log_warn()  { _log_raw "$C_YELLOW"         "  !" "$*"; }
log_error() { _log_raw "$C_RED"            "  ✘" "$*"; }
log_debug() { is_true "$VERBOSE" && _log_raw "$C_DIM" "  ·" "$*"; return 0; }
log_cmd()   { _log_raw "$C_DIM"            "  \$" "$*"; }

die() { log_error "$*"; exit 1; }

# --- Predicados ------------------------------------------------------------
is_true()  { case "${1:-}" in [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1|on|ON) return 0;; *) return 1;; esac; }
is_false() { ! is_true "${1:-}"; }

have() { command -v "$1" > /dev/null 2>&1; }

need_cmd() { # <comando> [paquete]
    local cmd="$1" pkg="${2:-$1}"
    if ! have "$cmd"; then
        log_error "falta '$cmd' (paquete: $pkg)"
        return 1
    fi
    return 0
}

is_arch() { [[ -r /etc/arch-release ]]; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

in_graphical_session() { [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; }

# --- Confirmación ----------------------------------------------------------
# Devuelve 0 si se debe continuar. Con --yes nunca pregunta; en dry-run
# responde "sí" para poder mostrar todo lo que se haría.
confirm() { # <mensaje> [predeterminado: si|no]
    local msg="$1" default="${2:-si}" reply
    is_true "$YES" && return 0
    is_true "$DRY_RUN" && return 0
    if [[ ! -t 0 ]]; then
        log_warn "$msg — sin terminal interactivo, se omite (predeterminado: $default)"
        [[ "$default" == "si" ]] && return 0 || return 1
    fi
    local hint="[S/n]"; [[ "$default" == "no" ]] && hint="[s/N]"
    printf '%s  %s %s ' "$C_BOLD$C_YELLOW" "?" "$C_RESET$msg $hint" >&2
    read -r reply
    case "$reply" in
        "") [[ "$default" == "si" ]] ;;
        [Ss]|[Ss][Ii]|[Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Ejecución -------------------------------------------------------------
# run <comando...>   -> ejecuta mostrando el comando; en dry-run solo lo imprime.
# Devuelve el código del comando (o 0 en dry-run).
run() {
    log_cmd "$*"
    if is_true "$DRY_RUN"; then
        return 0
    fi
    _log_to_file "EJECUTAR: $*"
    local rc=0
    # En una terminal real NUNCA ocultar stdout/stderr: pacman, paru y
    # chezmoi pueden pedir confirmaciones o mostrar conflictos importantes.
    if is_true "$VERBOSE" || [[ -t 0 ]]; then
        "$@" || rc=$?
    else
        local tmp; tmp="$(mktemp)"
        if "$@" > "$tmp" 2>&1; then
            rm -f "$tmp"
        else
            rc=$?
            _log_to_file "----- salida de: $* -----"
            cat "$tmp" >> "$LOG_FILE" 2> /dev/null || true
            sed 's/^/      | /' "$tmp" >&2
            rm -f "$tmp"
        fi
    fi
    return "$rc"
}

# run_root <comando...> -> igual que run pero con sudo cuando hace falta.
run_root() {
    if is_root; then
        run "$@"
    else
        run "${SUDO_CMD[@]}" "$@"
    fi
}

# run_or_warn <comando...> -> no aborta si falla (para pasos opcionales).
run_or_warn() {
    local rc=0
    run "$@" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log_warn "falló (código $rc), se continúa: $*"
    fi
    return 0
}

# --- Archivos --------------------------------------------------------------
ensure_dir() { # <dir> [modo]
    local dir="$1" mode="${2:-0755}"
    [[ -d "$dir" ]] || run mkdir -p "$dir"
    run chmod "$mode" "$dir" 2> /dev/null || true
}

# backup_file <archivo> -> respaldo FUERA de /etc en el estado del usuario.
# Si no se puede respaldar, falla y NO se permite modificar el original.
backup_file() { # <archivo>
    local f="$1" dest stamp relative
    [[ -e "$f" ]] || return 0
    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    if [[ "$f" == /* ]]; then
        relative="${f#/}"
    else
        relative="relative/${f#./}"
    fi
    dest="${BACKUP_DIR}/system/${relative}.${stamp}"
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) respaldo de $f -> $dest"
        return 0
    fi
    # El directorio de respaldos no debe ser legible por otros usuarios.
    mkdir -p -- "$(dirname -- "$dest")" || return 1
    chmod 0700 "$BACKUP_DIR" || return 1
    if cp -a -- "$f" "$dest" 2>/dev/null; then
        :
    elif [[ "${#SUDO_CMD[@]}" -gt 0 ]] && "${SUDO_CMD[@]}" cp -a -- "$f" "$dest"; then
        :
    else
        log_error "no se pudo respaldar $f: se cancela su modificación"
        return 1
    fi
    [[ -s "$dest" ]] || { log_error "respaldo vacío: $dest"; return 1; }
    log_info "respaldo: $dest"
}

# install_file <origen> <destino> [modo] [propietario]
# Copia con respaldo previo y solo si el contenido difiere (idempotente).
install_file() { # <src> <dst> [modo=0644] [owner=root]
    local src="$1" dst="$2" mode="${3:-0644}" owner="${4:-root}"
    [[ -f "$src" ]] || { log_error "install_file: no existe $src"; return 1; }

    if [[ -f "$dst" ]] && cmp -s -- "$src" "$dst"; then
        log_ok "sin cambios: $dst"
        return 0
    fi

    if [[ -e "$dst" ]]; then
        backup_file "$dst" || return 1
    fi

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se instalaría $src -> $dst (modo $mode, dueño $owner)"
        return 0
    fi

    local dstdir; dstdir="$(dirname -- "$dst")"
    [[ -d "$dstdir" ]] || run_root mkdir -p "$dstdir"

    if is_root || [[ -w "$dstdir" && "$owner" == "$(id -un)" ]]; then
        install -D -m "$mode" -- "$src" "$dst" || return 1
    else
        run_root install -D -m "$mode" -o "$owner" -g "$owner" -- "$src" "$dst" || return 1
    fi
    log_ok "instalado: $dst"
    return 0
}

# --- Edición idempotente de archivos de configuración -----------------------
# file_contains_line <archivo> <línea exacta>
file_contains_line() { grep -Fxq -- "$2" "$1" 2> /dev/null; }

# file_append_line <archivo> <línea> [comentario]
file_append_line() { # <archivo> <línea>
    local f="$1" line="$2"
    if file_contains_line "$f" "$line"; then
        return 0
    fi
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se agregaría a $f: $line"
        return 0
    fi
    printf '%s\n' "$line" >> "$f" || return 1
    log_ok "agregado a $(basename -- "$f"): $line"
}

# --- Resumen final del paso -------------------------------------------------
declare -a STEP_WARNINGS=()
add_warning() { STEP_WARNINGS+=("$1"); }

print_warnings() {
    local w
    if [[ "${#STEP_WARNINGS[@]}" -gt 0 ]]; then
        log_warn "quedaron ${#STEP_WARNINGS[@]} advertencia(s) en este paso:"
        for w in "${STEP_WARNINGS[@]}"; do
            printf '      - %s\n' "$w" >&2
        done
    fi
    return 0
}

# --- Helpers de listas y unidades ------------------------------------------
# words_to_array <nombre-array> <texto>
# Convierte una variable multilínea (como las de defaults.env) en un array,
# separando por espacios, tabuladores o saltos de línea.
words_to_array() {
    local -n _arr="$1"
    local texto="${2:-}" w
    _arr=()
    while read -r w; do
        w="${w//[[:space:]]/}"
        [[ -n "$w" ]] && _arr+=("$w")
    done < <(printf '%s\n' "$texto" | tr -s '[:space:]' '\n')
    return 0
}

# _scope_args <array-dest> [segundo-argumento]
# Construye el prefijo de systemctl (vacío o --user) como array, para poder
# expandirlo con comillas y sin avisos de shellcheck.
_scope_args() {
    local -n _scope="$1"
    _scope=()
    [[ "${2:-}" == "--user" ]] && _scope+=(--user)
    return 0
}

# unit_exists <unidad> [--user]
unit_exists() {
    local unit="$1"
    local -a scope=()
    _scope_args scope "${2:-}"
    have systemctl || return 1
    if systemctl "${scope[@]}" list-unit-files --no-legend "$unit" 2> /dev/null | grep -q "^${unit}"; then
        return 0
    fi
    if systemctl "${scope[@]}" list-units --no-legend --all "$unit" 2> /dev/null | grep -q "${unit}"; then
        return 0
    fi
    return 1
}

unit_is_active() { # <unidad> [--user]
    local unit="$1"
    local -a scope=()
    _scope_args scope "${2:-}"
    have systemctl || return 1
    [[ "$(systemctl "${scope[@]}" is-active "$unit" 2> /dev/null)" == "active" ]]
}

unit_is_enabled() { # <unidad> [--user]
    local unit="$1"
    local -a scope=()
    _scope_args scope "${2:-}"
    have systemctl || return 1
    [[ "$(systemctl "${scope[@]}" is-enabled "$unit" 2> /dev/null)" == "enabled" ]]
}

group_exists() { getent group "$1" > /dev/null 2>&1; }

user_in_group() { # <usuario> <grupo>
    id -nG "$1" 2> /dev/null | tr ' ' '\n' | grep -qx "$2"
}

# --- run_step: envoltorio común de todos los pasos --------------------------
# Cada script de paso define `main` y termina con:  run_step "20-packages" "$@"
run_step() { # <id-del-paso>
    local step_id="$1"
    local script_path="${BASH_SOURCE[1]}"
    mkdir -p "$STATE_DIR" 2> /dev/null || true

    log_step "Paso ${step_id}"
    _log_to_file "=== INICIO PASO ${step_id} (${script_path}) ==="

    # Los pasos consultan el estado real del sistema y deben poder repetirse.
    # No se omiten por hash: un mismo script puede ejecutarse tras un cambio
    # de paquetes, config o hardware sin que su propio contenido cambie.
    local hash_file="${STATE_DIR}/${step_id}.done"
    local current_hash=""
    if [[ -f "$script_path" ]] && have sha256sum; then
        current_hash="$(sha256sum "$script_path" | cut -d' ' -f1)"
    fi

    local rc=0
    STEP_WARNINGS=()
    main || rc=$?
    print_warnings || true

    if [[ "$rc" -eq 75 ]]; then
        # 75 = etapa pospuesta: p. ej. faltaba sesión gráfica/DBus en una TTY.
        # No escribir .done; --resume podrá completarla tras iniciar Hyprland.
        rm -f "$hash_file" 2> /dev/null || true
        log_warn "paso ${step_id} pospuesto; vuelve a ejecutarlo tras iniciar sesión gráfica"
        return 75
    fi

    if [[ "$rc" -eq 0 ]]; then
        if is_false "$DRY_RUN" && [[ -n "$current_hash" ]]; then
            printf '%s\n' "$current_hash" > "$hash_file" 2> /dev/null || true
        fi
        _log_to_file "=== FIN PASO ${step_id}: OK ==="
        log_ok "paso ${step_id} completado"
    else
        rm -f "$hash_file" 2> /dev/null || true
        _log_to_file "=== FIN PASO ${step_id}: FALLO (código $rc) ==="
        log_error "paso ${step_id} falló (código $rc)"
    fi
    return "$rc"
}

# --- Banner -----------------------------------------------------------------
print_banner() {
    cat <<'EOF'

   ╔═══════════════════════════════════════════════════════════════╗
   ║  dotfile — CachyOS + Hyprland + Caelestia Shell               ║
   ║  Instalador reproducible de sistema y configuraciones         ║
   ╚═══════════════════════════════════════════════════════════════╝

EOF
}