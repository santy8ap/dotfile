#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-packages.sh — instalar los paquetes del repo.
#
# Tiers:
#   core : solo packages/nucleo.txt (lo mínimo para el escritorio)
#   full : nucleo.txt + oficiales.txt + aur.txt  (predeterminado)
#
# Cada paquete se filtra antes de instalar:
#   - packages/ignorar.txt (salvo --with-ignored)
#   - etiquetas `# hw:...` contra el hardware detectado
#   - ya instalados (pacman usa --needed de todas formas)
# Y se resuelve solo de qué repo viene, así que el orden de las listas da igual.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
# shellcheck source=scripts/lib/packages.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/packages.sh"

main() {
    if ! is_arch; then
        log_warn "esto no es Arch/CachyOS; la instalación de paquetes se omite"
        add_warning "Sistema no-Arch: no se instaló ningún paquete."
        return 0
    fi

    hw_detect
    pkg_load_catalogs || return 1

    local tier="${DOTFILE_TIER:-full}"
    log_info "tier de instalación: ${tier}"
    log_info "hardware: ${HW_TAGS}"

    # --- Helper de AUR (si no se corrió la etapa 'aur') --------------------
    local want_aur="yes"
    is_true "${DOTFILE_NO_AUR:-no}" && want_aur="no"

    if [[ "$want_aur" == "yes" ]]; then
        pkg_detect_aur_helper > /dev/null || pkg_ensure_aur_helper \
            || log_warn "sin helper de AUR: solo se instalarán paquetes oficiales"
    else
        log_info "AUR desactivado (--no-aur)"
    fi

    # --- Selección de listas ----------------------------------------------
    local -a lists=()
    case "$tier" in
        core) lists+=("nucleo") ;;
        full) lists+=("nucleo" "oficiales" "aur") ;;
        all)  lists+=("nucleo" "oficiales" "aur") ;;
        *)    log_warn "tier desconocido '$tier'; se usa 'full'"; lists+=("nucleo" "oficiales" "aur") ;;
    esac

    # Listas extra definidas por el usuario (config/host.*.env)
    if [[ -n "${DOTFILE_EXTRA_LISTS:-}" ]]; then
        local extra
        for extra in $DOTFILE_EXTRA_LISTS; do
            lists+=("$extra")
        done
    fi

    [[ "$want_aur" == "no" ]] && {
        local filtered=() l
        for l in "${lists[@]}"; do [[ "$l" == "aur" ]] || filtered+=("$l"); done
        lists=("${filtered[@]}")
    }

    # --- Previsualización --------------------------------------------------
    local select_opts=()
    is_true "${DOTFILE_WITH_IGNORED:-no}" && select_opts+=("--with-ignored")

    local total=0 name
    declare -A ALL_SELECTED=()
    for l in "${lists[@]}"; do
        local f="${PACKAGES_DIR}/${l}.txt"
        [[ -f "$f" ]] || { log_warn "no existe $f"; continue; }
        while read -r name; do
            [[ -n "$name" ]] || continue
            ALL_SELECTED["$name"]=1
        done < <(pkg_select "$f" ${select_opts[@]+"${select_opts[@]}"})
    done
    total="${#ALL_SELECTED[@]}"

    if [[ "$total" -eq 0 ]]; then
        log_ok "todos los paquetes de las listas (${lists[*]}) ya están instalados"
        pkg_report
        return 0
    fi

    log_step "Se instalarán ${total} paquete(s)"
    if is_true "$VERBOSE"; then
        while read -r name; do
            printf '      - %s\n' "$name"
        done < <(printf '%s\n' "${!ALL_SELECTED[@]}" | sort)
    else
        local preview
        preview="$(printf '%s\n' "${!ALL_SELECTED[@]}" | sort | head -30 | paste -sd' ' -)"
        printf '      %s\n' "$preview"
        [[ "$total" -gt 30 ]] && printf '      ... y %s más\n' "$(( total - 30 ))"
        log_info "lista completa con: ./install.sh packages --dry-run -v"
    fi

    if ! confirm "¿Instalar estos ${total} paquetes?"; then
        log_info "instalación de paquetes omitida por el usuario"
        return 0
    fi

    # --- Instalación -------------------------------------------------------
    # Se hace en una sola pasada con la unión de todas las listas: menos
    # transacciones, mejor resolución de dependencias.
    pkg_classify < <(printf '%s\n' "${!ALL_SELECTED[@]}" | sort)
    pkg_verify_aur

    local rc=0
    pkg_install_selected || rc=$?

    pkg_report

    if [[ "$rc" -ne 0 ]]; then
        add_warning "Algunos paquetes fallaron; el instalador reintentó uno a uno. Revisa el resumen."
        return 1   # no marcar como completada una instalación parcial
    fi

    # --- Paquetes que quedaron sin instalar por falta de AUR ---------------
    if [[ "${#PKG_UNAVAILABLE[@]}" -gt 0 ]]; then
        log_warn "sin resolver (no están en repos oficiales y no hay helper de AUR): ${PKG_UNAVAILABLE[*]}"
        add_warning "Paquetes no resueltos: ${PKG_UNAVAILABLE[*]}"
        return 1
    fi
    if [[ "${#PKG_MISSING[@]}" -gt 0 ]]; then
        return 1
    fi

    log_ok "etapa de paquetes terminada"
}

run_step "packages"
