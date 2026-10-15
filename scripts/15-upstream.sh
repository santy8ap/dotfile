#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 15-upstream.sh — instalar los dotfiles BASE de Caelestia, ANTES de los tuyos.
#
# Fuentes verificadas en octubre de 2026:
#   https://github.com/caelestia-dots/caelestia (manifest.toml)
#   https://github.com/caelestia-dots/cli (comando `caelestia install`)
#   https://github.com/caelestia-dots/shell (solo el shell, NO todo el desktop)
#
# NO clona ni ejecuta install.fish (legado/retirado). El CLI de Caelestia clona
# su repo oficial en ~/.local/state/caelestia/dots y registra dots-state.json.
# Este script no toca ese clon directamente, ni llama a `caelestia update`:
# las actualizaciones del upstream se hacen por separado y con revisión.
#
# Orden seguro: checks (backup) -> base (-Syu) -> aur -> upstream -> packages
# -> dotfiles propios. Si upstream falla, NO se aplica la capa personal.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

_upstream_state() {
    printf '%s/caelestia/dots-state.json' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

main() {
    local mode="${DOTFILE_UPSTREAM_MODE:-install}"
    case "$mode" in
        skip)
            log_warn "instalación base de Caelestia omitida por configuración"
            add_warning "Sin `caelestia install`, este repo no puede garantizar que exista la base compatible de Hyprland/Quickshell."
            return 0
            ;;
        install) : ;;
        *) log_error "DOTFILE_UPSTREAM_MODE debe ser install o skip (recibido: $mode)"; return 1 ;;
    esac

    if is_true "${DOTFILE_NO_AUR:-no}"; then
        log_warn "--no-aur impide instalar caelestia-cli; upstream se pospone"
        return 75
    fi

    local state; state="$(_upstream_state)"
    if [[ -f "$state" ]]; then
        log_ok "Caelestia ya tiene estado de instalación: $state"
        log_info "NO se reejecuta `caelestia install`; para actualizar usa el flujo de docs/ACTUALIZACIONES.md"
        return 0
    fi

    log_step "Instalador oficial de los DOTFILES de Caelestia"
    log_info "CLI: caelestia-cli (AUR/CachyOS); dots: caelestia-dots/caelestia"
    log_info "Shell: caelestia-dots/shell, instalado como paquete estable caelestia-shell"
    log_warn "upstream puede reemplazar archivos bajo ~/.config; la etapa checks hizo respaldo."
    log_warn "después de upstream, este repo aplicará tus personalizaciones."

    local -a args=(install)
    local disabled="${DOTFILE_UPSTREAM_DISABLE_COMPONENTS:-firefox}"
    # El usuario usa Zen, no Firefox. --disable-components acepta lista CSV.
    if [[ -n "$disabled" ]]; then
        args+=(--disable-components "$disabled")
        log_info "componentes upstream desactivados: $disabled"
    fi

    if is_true "$DRY_RUN"; then
        log_cmd "(dry-run) instalar caelestia-cli con helper de AUR si falta"
        log_cmd "(dry-run) caelestia ${args[*]}"
        log_info "no se consulta ni ejecuta código de upstream en --dry-run"
        return 0
    fi
    if ! is_arch; then
        log_error "la instalación upstream está diseñada para Arch/CachyOS"
        return 1
    fi

    if ! have caelestia; then
        local helper=""
        for helper in paru yay; do
            have "$helper" && break
        done
        if ! have "$helper"; then
            log_error "falta paru/yay. Ejecuta primero ./install.sh aur"
            return 1
        fi
        log_step "Instalando el CLI oficial de Caelestia"
        local -a flags=(-S --needed caelestia-cli)
        is_true "$YES" && flags+=(--noconfirm)
        # Paquetes AUR pueden preguntar por PKGBUILD; no ocultar stdout/stderr.
        log_cmd "$helper ${flags[*]}"
        "$helper" "${flags[@]}" || return 1
    fi

    if ! caelestia install --help > /dev/null 2>&1; then
        log_error "el CLI instalado no soporta `caelestia install`; revisa la versión del paquete caelestia-cli"
        return 1
    fi
    if ! caelestia install --help 2>&1 | grep -q -- '--disable-components'; then
        log_error "el CLI cambió su interfaz (--disable-components); se detiene antes de ejecutar upstream"
        return 1
    fi

    # Upstream instala paquetes, despliega configuraciones y ejecuta hooks.
    # No pasar --noconfirm aunque el usuario haya usado --yes: upstream puede
    # añadir paquetes/componentes nuevos entre versiones; que los revise.
    if [[ ! -t 0 ]]; then
        log_error "`caelestia install` necesita una terminal para revisar componentes y paquetes"
        return 1
    fi
    if ! confirm "¿Ejecutar ahora el instalador OFICIAL de Caelestia antes de aplicar tus configuraciones?" no; then
        log_warn "instalación upstream cancelada"
        return 1
    fi
    # Dejar stdin/stdout/stderr conectados a la TTY: el CLI muestra selección
    # de componentes y preguntas que `run` ocultaría en un archivo temporal.
    log_cmd "caelestia ${args[*]}"
    if ! caelestia "${args[@]}"; then
        log_error "falló `caelestia install`; NO se aplicarán los dotfiles propios todavía"
        return 1
    fi
    if [[ ! -f "$state" ]]; then
        log_error "upstream terminó sin crear $state; no se puede verificar que se haya instalado"
        return 1
    fi

    local dots="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/dots"
    if [[ -d "$dots/.git" ]]; then
        local rev url
        rev="$(git -C "$dots" rev-parse --short HEAD 2>/dev/null || echo '?')"
        url="$(git -C "$dots" remote get-url origin 2>/dev/null || echo '?')"
        log_ok "upstream instalado: $url @ $rev"
        printf '%s\n' "$rev" > "${STATE_DIR}/upstream-revision" 2>/dev/null || true
    else
        log_warn "no encuentro el clon de dots upstream en $dots"
    fi
    log_ok "base upstream lista; ahora se puede aplicar la capa personal"
}

run_step "upstream"
