#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 10-aur-helper.sh — dejar listo un helper de AUR (paru).
#
# En CachyOS `paru` viene del repo oficial, así que normalmente basta con un
# `pacman -S paru`. Si no existe (Arch puro, instalación mínima), se compila
# desde AUR con makepkg, que es el procedimiento documentado.
#
# También sanea la configuración de paru si existe (~/.config/paru/paru.conf).
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
# shellcheck source=scripts/lib/packages.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/packages.sh"

main() {
    if is_true "${DOTFILE_NO_AUR:-no}"; then
        log_info "AUR desactivado (--no-aur); se omite esta etapa"
        return 0
    fi

    if ! is_arch; then
        log_warn "esto no es Arch; AUR no aplica"
        return 0
    fi

    pkg_load_catalogs || return 1

    log_step "Helper de AUR"
    if ! pkg_ensure_aur_helper; then
        add_warning "Sin helper de AUR. La etapa 'packages' instalará solo lo oficial."
        return 0
    fi

    # Verificar que el helper responde
    if is_false "$DRY_RUN" && ! "$AUR_HELPER" --version > /dev/null 2>&1; then
        log_warn "$AUR_HELPER no responde correctamente"
        add_warning "$AUR_HELPER está instalado pero falla al ejecutarse."
        return 0
    fi
    log_ok "helper de AUR operativo: $AUR_HELPER"

    # --- Configuración de paru --------------------------------------------
    local paru_conf="${XDG_CONFIG_HOME:-$HOME/.config}/paru/paru.conf"
    if [[ "$AUR_HELPER" == "paru" ]]; then
        if [[ -f "$paru_conf" ]]; then
            log_info "configuración de paru encontrada: $paru_conf"
            log_info "si no está en el repo, captúrala con: make capturar"
        else
            log_info "sin configuración de paru (usa la predeterminada del sistema)"
            log_info "opcional: crea $paru_conf y captúrala con 'make capturar'"
        fi

        # Limpiar caché de compilación si ocupa demasiado (>1 GB)
        local cache_dir="${HOME}/.cache/paru/clone"
        if [[ -d "$cache_dir" ]]; then
            local size_mb
            size_mb="$(du -sm "$cache_dir" 2> /dev/null | cut -f1)"
            if [[ -n "$size_mb" && "$size_mb" -gt 1024 ]]; then
                log_info "la caché de paru ocupa ${size_mb} MB"
                if confirm "¿Vaciar la caché de compilación de paru? (no desinstala nada)" no; then
                    run_or_warn "$AUR_HELPER" -Scc --noconfirm
                fi
            fi
        fi
    fi

    # --- Sincronizar la base de datos de AUR ------------------------------
    log_step "Sincronizando bases de datos (oficiales + AUR)"
    if is_true "$DRY_RUN"; then
        run "$AUR_HELPER" -Sy
    else
        # -Sy del helper: actualiza repos oficiales y la base de AUR.
        # No se instala nada aquí, así que no hay riesgo de actualización parcial
        # (la etapa 'packages' instala a continuación).
        run_or_warn "$AUR_HELPER" -Sy
    fi
}

run_step "aur"
