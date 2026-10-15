#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 50-user-services.sh — unidades systemd DEL USUARIO (no necesita sudo).
#
# Este repo aporta:  ~/.config/systemd/user/rotar-fondo.{service,timer}
# Aquí se recarga systemd y se habilitan las unidades configuradas en
# DOTFILE_USER_SERVICES (ver config/defaults.env).
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

main() {
    if ! have systemctl; then
        log_warn "systemctl no existe; se omite esta etapa"
        add_warning "Sin systemd no se pudieron habilitar los servicios de usuario."
        return 0
    fi

    # ¿Hay instancia de usuario? (no la hay en un chroot, en tty sin login, ...)
    if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -S "${XDG_RUNTIME_DIR}/systemd/private" ]]; then
        log_warn "no hay una instancia de usuario de systemd activa"
        log_warn "(normal si estás en una TTY sin sesión o dentro de un chroot)"
        add_warning "Servicios de usuario NO habilitados: no había sesión de usuario activa. Al iniciar sesión gráfica corre: ./install.sh services --force"
        if is_true "$DOTFILE_ENABLE_LINGER" && [[ "${#SUDO_CMD[@]}" -gt 0 ]]; then
            log_info "activando 'linger' para que la instancia de usuario exista sin sesión"
            run_or_warn "${SUDO_CMD[@]}" loginctl enable-linger "$(id -un)"
        fi
        return 75
    fi

    log_step "Recargando unidades de usuario"
    run systemctl --user daemon-reload || log_warn "daemon-reload de usuario falló"

    # --- Linger (opcional) -------------------------------------------------
    if is_true "$DOTFILE_ENABLE_LINGER"; then
        if [[ "${#SUDO_CMD[@]}" -gt 0 ]]; then
            run_or_warn "${SUDO_CMD[@]}" loginctl enable-linger "$(id -un)"
            log_ok "linger activado: los servicios de usuario viven aunque no haya sesión"
        else
            log_warn "no hay sudo: no se pudo activar linger"
        fi
    fi

    # --- Unidades de usuario ----------------------------------------------
    local -a units=()
    words_to_array units "${DOTFILE_USER_SERVICES:-}"

    local u ok=0 skipped=0 failed=0
    for u in "${units[@]+"${units[@]}"}"; do
        local unit="$u"
        [[ "$unit" == *.timer || "$unit" == *.service || "$unit" == *.socket ]] || unit="${unit}.service"

        local unit_file="${HOME}/.config/systemd/user/${unit}"
        if [[ ! -f "$unit_file" ]]; then
            # Puede venir de un paquete en lugar del repo
            if ! unit_exists "$unit" --user; then
                log_debug "unidad de usuario inexistente: $unit"
                skipped=$(( skipped + 1 ))
                continue
            fi
        fi

        if unit_is_enabled "$unit" --user && unit_is_active "$unit" --user; then
            log_ok "ya activa: $unit"
            ok=$(( ok + 1 ))
            continue
        fi

        if run systemctl --user enable --now "$unit"; then
            log_ok "habilitada: $unit"
            ok=$(( ok + 1 ))
        else
            if run systemctl --user enable "$unit" 2> /dev/null; then
                log_warn "$unit habilitada, pero no arrancó ahora"
                ok=$(( ok + 1 ))
            else
                log_error "no se pudo habilitar: $unit"
                failed=$(( failed + 1 ))
            fi
        fi
    done

    log_info "unidades de usuario: ${ok} listas, ${skipped} inexistentes, ${failed} con error"
    [[ "$failed" -gt 0 ]] && add_warning "${failed} unidad(es) de usuario no se pudieron habilitar."

    # --- rotar-fondo: comprobación específica ------------------------------
    if [[ -f "${HOME}/.config/systemd/user/rotar-fondo.timer" ]]; then
        log_step "rotar-fondo (cambio automático de fondo)"
        local script="${HOME}/.local/bin/rotar-fondo"
        if [[ ! -x "$script" ]]; then
            log_warn "$script no existe o no es ejecutable"
            add_warning "Falta ~/.local/bin/rotar-fondo ejecutable: aplica los dotfiles (./install.sh dotfiles --force)."
        else
            log_ok "script presente: $script"
        fi
        if ! have caelestia; then
            log_warn "'caelestia' no está instalado: el timer fallará al ejecutarse"
            add_warning "rotar-fondo necesita caelestia-cli. Instálalo con: ./install.sh packages --core-only"
        fi
        if [[ ! -d "${DOTFILE_WALLPAPER_DIR}" ]]; then
            log_warn "no existe la carpeta de fondos: ${DOTFILE_WALLPAPER_DIR}"
            add_warning "Carpeta de wallpapers vacía/inexistente: ${DOTFILE_WALLPAPER_DIR}"
        else
            local n=0
            n="$(find "$DOTFILE_WALLPAPER_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2> /dev/null | wc -l)"
            if [[ "$n" -eq 0 ]]; then
                log_warn "no hay imágenes en ${DOTFILE_WALLPAPER_DIR}"
                add_warning "Sin wallpapers en ${DOTFILE_WALLPAPER_DIR}: copia ahí tus fondos (ver docs/AUDITORIA.md)."
            else
                log_ok "${n} fondo(s) en ${DOTFILE_WALLPAPER_DIR}"
            fi
        fi
        if unit_is_active "rotar-fondo.timer" --user; then
            log_info "próxima ejecución: $(systemctl --user show -p NextElapseUSecRealtime --value rotar-fondo.timer 2> /dev/null || echo 'desconocida')"
        fi
    fi

    log_ok "servicios de usuario terminados"
}

run_step "services"
