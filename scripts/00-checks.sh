#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-checks.sh — comprobaciones previas y respaldo de seguridad.
#
# No instala nada: solo verifica que el entorno es el esperado, muestra el
# hardware detectado y hace una copia de ~/.config antes de tocar nada.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
# shellcheck source=scripts/lib/hardware.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/hardware.sh"

# Espacio mínimo libre en / (en MB) para instalar todo el tier "full"
MIN_DISK_MB="${DOTFILE_MIN_DISK_MB:-15360}"

main() {
    # --- Sistema operativo -------------------------------------------------
    if [[ "$(uname -s)" != "Linux" ]]; then
        die "este instalador es solo para Linux (detectado: $(uname -s))"
    fi

    hw_detect
    log_info "hardware detectado:"
    hw_summary | sed 's/^/      /'

    case "$HW_DISTRO" in
        cachyos) log_ok "distribución: CachyOS" ;;
        arch)
            log_warn "distribución: Arch Linux (no CachyOS)"
            add_warning "Varios paquetes cachyos-* de la lista no existirán en Arch puro. El instalador los reportará como no disponibles y seguirá."
            ;;
        *)
            log_warn "esto no parece Arch ni CachyOS (ID=$HW_DISTRO)"
            if ! confirm "¿Continuar de todas formas?" no; then
                die "instalación cancelada"
            fi
            ;;
    esac

    # --- Usuario -----------------------------------------------------------
    if is_root; then
        die "no ejecutes el instalador como root. Correlo como tu usuario normal (usará sudo cuando haga falta)."
    fi

    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        die "no se pudo determinar \$HOME"
    fi
    log_info "usuario: $(id -un)  (uid=$(id -u), home=$HOME)"

    if ! id -nG | tr ' ' '\n' | grep -qx wheel && ! id -nG | tr ' ' '\n' | grep -qx sudo; then
        log_warn "tu usuario no está en el grupo wheel/sudo: las etapas que necesitan root fallarán"
        add_warning "El usuario no pertenece a wheel; agrega con: sudo usermod -aG wheel $(id -un)"
    fi

    # --- Herramientas imprescindibles --------------------------------------
    # Solo comprobar. Instalar paquetes aquí antes de `pacman -Syu` podría
    # introducir una actualización parcial en Arch/CachyOS.
    local missing=() tool
    for tool in pacman git sudo awk sed grep mktemp tar; do
        have "$tool" || missing+=("$tool")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        die "faltan herramientas previas: ${missing[*]}. Instala lo mínimo con una actualización COMPLETA: sudo pacman -Syu --needed git sudo"
    fi
    log_ok "herramientas previas presentes"

    # --- Red ---------------------------------------------------------------
    if have curl; then
        if curl -fsS --max-time 8 -o /dev/null "https://archlinux.org" 2> /dev/null; then
            log_ok "conexión a internet correcta"
        else
            log_warn "no se pudo verificar la conexión a internet"
            add_warning "Sin red confirmada: pacman/paru/git y la clonación de AUR pueden fallar."
            confirm "¿Continuar sin red confirmada?" no || die "instalación cancelada"
        fi
    fi

    # --- Espacio en disco --------------------------------------------------
    local avail_kb avail_mb root_mount="/"
    avail_kb="$(df -Pk "$root_mount" 2> /dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$avail_kb" ]]; then
        avail_mb=$(( avail_kb / 1024 ))
        log_info "espacio libre en ${root_mount}: ${avail_mb} MB"
        if [[ "$avail_mb" -lt "$MIN_DISK_MB" ]]; then
            log_warn "menos de ${MIN_DISK_MB} MB libres: una instalación 'full' podría quedarse a medias"
            add_warning "Poco espacio libre en / (${avail_mb} MB). Considera --core-only."
            confirm "¿Continuar con poco espacio libre?" no || die "instalación cancelada"
        fi
    fi

    # --- Sesión gráfica ----------------------------------------------------
    if in_graphical_session; then
        log_ok "sesión gráfica activa (las etapas de apariencia podrán usar gsettings)"
    else
        log_warn "no hay sesión gráfica activa"
        add_warning "Sin sesión gráfica: la etapa 'theming' no podrá aplicar gsettings (se omite y se puede repetir luego con: ./install.sh theming --force)."
    fi

    # --- Estado del repo ---------------------------------------------------
    if [[ -d "${REPO_ROOT}/.git" ]] && have git; then
        if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2> /dev/null)" ]]; then
            log_warn "el repo tiene cambios sin confirmar (working tree sucio)"
            log_info "revisa con:  git -C '$REPO_ROOT' status"
        else
            log_ok "repo limpio en $(git -C "$REPO_ROOT" rev-parse --short HEAD 2> /dev/null || echo '?')"
        fi
    else
        log_info "el repo no es un clon de git (ejecución desde archivo suelto)"
    fi

    # --- Archivos de configuración del instalador --------------------------
    [[ -f "${CONFIG_DIR}/defaults.env" ]] || die "falta ${CONFIG_DIR}/defaults.env"
    if [[ -f "${CONFIG_DIR}/host.$(hostname).env" ]]; then
        log_ok "configuración por máquina: config/host.$(hostname).env"
    else
        log_info "sin config/host.$(hostname).env (se usan los valores predeterminados)"
        log_info "puedes crearla con:  make host-env   o   scripts/capture.sh"
    fi

    # --- Listas de paquetes ------------------------------------------------
    local list
    for list in nucleo oficiales aur ignorar; do
        if [[ -f "${PACKAGES_DIR}/${list}.txt" ]]; then
            log_ok "lista presente: packages/${list}.txt ($(grep -cve '^\s*#' -e '^\s*$' "${PACKAGES_DIR}/${list}.txt" 2> /dev/null || echo 0) paquetes)"
        else
            [[ "$list" == "ignorar" ]] && continue
            log_warn "falta la lista packages/${list}.txt"
        fi
    done

    # --- Respaldo ----------------------------------------------------------
    if is_true "$DOTFILE_BACKUP"; then
        log_step "Haciendo respaldo de seguridad"
        if run "${SCRIPTS_DIR}/backup.sh"; then
            log_ok "respaldo listo en ${BACKUP_DIR}"
        else
            log_warn "el respaldo falló (mira el log)"
            add_warning "No se pudo crear el respaldo de ~/.config. Continúa bajo tu responsabilidad."
            confirm "¿Continuar sin respaldo?" no || die "instalación cancelada"
        fi
    else
        log_info "respaldo omitido (--no-backup)"
    fi

    echo
    log_ok "comprobaciones previas terminadas"
}

run_step "checks"
