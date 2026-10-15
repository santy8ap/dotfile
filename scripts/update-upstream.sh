#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Actualización CONTROLADA de Caelestia upstream (nunca se ejecuta al arrancar).
# El CLI `caelestia update` hace -Syu, instala/actualiza paquetes y despliega
# archivos nuevos (si hay cambios locales, escribe .new). No reemplazamos
# nuestras personalizaciones automáticamente tras actualizar: primero se
# comparan los archivos tocados y se prueba la sesión.
# ---------------------------------------------------------------------------
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

main() {
    local dry="no"
    [[ "${1:-}" == "--dry-run" ]] && dry="yes"
    if ! have caelestia; then die "falta caelestia-cli; instala la base con ./install.sh upstream"; fi
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia"
    local dots="${state}/dots"
    [[ -f "$state/dots-state.json" ]] || die "el CLI no registra una instalación; ejecuta ./install.sh upstream"
    [[ -d "$dots/.git" ]] || die "no existe el clon upstream en $dots"

    local old url
    old="$(git -C "$dots" rev-parse HEAD)" || return 1
    url="$(git -C "$dots" remote get-url origin)" || return 1
    log_step "Caelestia upstream: $url @ ${old:0:12}"
    if [[ "$url" != "https://github.com/caelestia-dots/caelestia.git" ]]; then
        log_warn "la fuente upstream difiere de la oficial conocida; revisa ~/.config/caelestia/cli.json antes de actualizar"
        return 1
    fi
    if [[ -n "$(git -C "$dots" status --porcelain)" ]]; then
        log_error "el clon upstream tiene cambios locales; el CLI podría hacer reset --hard. No se actualiza."
        return 1
    fi
    if [[ "$dry" == "yes" ]] || is_true "$DRY_RUN"; then
        log_info "ensayo: NO se invoca `caelestia update` (no ofrece dry-run)"
        log_info "consulta changelog y estado remoto antes de actualizar: $url"
        return 0
    fi
    [[ -t 0 ]] || die "la actualización requiere TTY interactiva; no se ejecuta desatendida"
    log_warn "`caelestia update` actualizará TAMBIÉN paquetes del sistema y puede cambiar la API Lua."
    log_warn "No actualizará automáticamente tus personalizaciones de este repo."
    if ! confirm "¿Hacer backup de ~/.config antes de actualizar?" si; then
        die "por seguridad, se cancela la actualización sin backup"
    fi
    "${SCRIPTS_DIR}/backup.sh" || die "falló el respaldo; no se actualiza"
    if ! confirm "¿Ejecutar `caelestia update` ahora?" no; then
        log_info "actualización cancelada"
        return 0
    fi
    # Directo a la TTY: CLI necesita poder hacer preguntas.
    caelestia update || die "el CLI upstream falló; revisa su salida y el backup"

    local new
    new="$(git -C "$dots" rev-parse HEAD)" || return 1
    log_step "Revisión después de upstream: ${old:0:12} -> ${new:0:12}"
    if [[ "$old" != "$new" ]]; then
        log_info "archivos de upstream modificados:"
        git -C "$dots" diff --name-only "$old" "$new" -- | sed 's/^/      /'
    else
        log_info "sin cambios en el repo de dots; pueden haberse actualizado los paquetes"
    fi
    log_warn "antes de aplicar la capa personal, compara API/configs nuevos con tu repo:"
    log_info "    chezmoi --source '$REPO_ROOT' diff"
    log_info "    ./install.sh dotfiles --force"
    log_info "    ./install.sh verify --force"
    log_warn "revisa posibles archivos .new en ~/.config; prueba login, atajos y wallpapers antes de volver a actualizar"
    return 0
}

main "$@"
