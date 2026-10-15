#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 70-post.sh — tareas finales que no encajan en las etapas anteriores.
#
# Permisos de ~/.ssh, objetivo de arranque gráfico, toolchains (rustup/mise),
# comprobaciones de autenticación (gh, git) y recordatorios de lo que hay que
# hacer a mano (capturar configs, copiar fondos, reiniciar).
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

_post_default_target() {
    have systemctl || return 0
    local current
    current="$(systemctl get-default 2> /dev/null || true)"
    if [[ "$current" == "graphical.target" ]]; then
        log_ok "objetivo de arranque: graphical.target"
        return 0
    fi
    log_warn "el objetivo de arranque es '$current' (no graphical.target)"
    if confirm "¿Fijar graphical.target como objetivo de arranque por defecto?" si; then
        run_root systemctl set-default graphical.target && log_ok "arranque gráfico habilitado"
    else
        add_warning "Arranque en modo texto: el gestor de sesión (greetd) no arrancará solo."
    fi
}

_post_greetd() {
    local conf="/etc/greetd/config.toml"
    if [[ ! -f "$conf" ]]; then
        log_warn "no existe $conf: configura el gestor de sesión antes de habilitarlo"
        add_warning "Falta $conf; el ejemplo en system/etc/greetd/ NO se aplica automáticamente."
        return 0
    fi
    log_ok "$conf presente"
    if ! have tuigreet; then
        log_warn "falta tuigreet: no se habilitará greetd"
        add_warning "Instala greetd-tuigreet antes de habilitar greetd."
        return 0
    fi
    # El setup confirmado usa el wrapper de Hyprland de CachyOS. No sustituir
    # por `uwsm start ...`: no es necesariamente la misma sesión.
    if grep -q -- '--cmd start-hyprland' "$conf"; then
        if ! have start-hyprland; then
            log_warn "$conf invoca start-hyprland pero no existe en PATH"
            add_warning "Falta start-hyprland: en la máquina original lo aporta hyprland. No habilitar greetd antes de resolverlo."
            return 0
        fi
        log_ok "start-hyprland disponible ($(command -v start-hyprland))"
    else
        log_warn "greetd no invoca start-hyprland; revisa el comando de sesión antes de habilitarlo"
        add_warning "El login de esta máquina difiere del Lenovo original: inspecciona $conf."
        return 0
    fi
    if unit_is_enabled "greetd.service"; then
        log_ok "greetd.service habilitada"
    elif is_true "$DOTFILE_SYSTEM" && confirm "¿Habilitar greetd para el próximo arranque? (NO se inicia ahora para evitar cerrar la sesión actual)" no; then
        run_root systemctl enable greetd.service \
            || add_warning "No se pudo habilitar greetd; revisa 'systemctl status greetd'."
    else
        add_warning "greetd sigue deshabilitado; el login gráfico no arrancará automáticamente."
    fi
}

_post_ssh() {
    log_step "Directorio ~/.ssh"
    local ssh_dir="${HOME}/.ssh"
    if [[ ! -d "$ssh_dir" ]]; then
        if is_true "$DRY_RUN"; then
            log_info "(dry-run) mkdir -p $ssh_dir && chmod 700"
        else
            install -d -m 700 "$ssh_dir" && log_ok "creado $ssh_dir (0700)"
        fi
    else
        chmod 700 "$ssh_dir" 2> /dev/null && log_ok "$ssh_dir con permisos 0700"
    fi

    # Soltar claves sueltas con permisos incorrectos es la causa nº1 de que ssh
    # se niegue a usarlas.
    local k fixed=0
    if [[ -d "$ssh_dir" ]]; then
        while IFS= read -r -d '' k; do
            local base; base="$(basename -- "$k")"
            # Regla de ssh: claves privadas y authorized_keys en 0600,
            # el resto (públicas, config, known_hosts) en 0644.
            local want
            case "$base" in
                *.pub|config|known_hosts) want="644" ;;
                *)                        want="600" ;;
            esac
            local now; now="$(stat -c '%a' "$k" 2> /dev/null || echo '?')"
            if [[ "$now" != "$want" ]]; then
                if is_true "$DRY_RUN"; then
                    log_info "(dry-run) chmod $want $k"
                else
                    chmod "$want" "$k" 2> /dev/null && { log_ok "permisos $want: $base"; fixed=$(( fixed + 1 )); }
                fi
            fi
        done < <(find "$ssh_dir" -maxdepth 1 -type f -print0 2> /dev/null)
        [[ "$fixed" -gt 0 ]] && log_info "se corrigieron $fixed permiso(s)"
    fi

    if [[ ! -f "${ssh_dir}/config" ]]; then
        log_info "no tienes ~/.ssh/config"
        add_warning "Sin ~/.ssh/config. Si usas hosts/llaves concretas, créalo y captúralo con 'make capturar' (NUNCA subas las llaves privadas)."
    else
        log_ok "~/.ssh/config presente"
        # Advertir si por error hay material sensible versionable
        if [[ -d "${REPO_ROOT}/.git" ]] && git -C "$REPO_ROOT" ls-files 2> /dev/null | grep -qiE '(^|/)\.?ssh/'; then
            log_warn "hay archivos de ~/.ssh en el repo: ¡revisa que no sean llaves privadas!"
            add_warning "Material de ~/.ssh dentro del repo. Ver docs/SECRETOS.md."
        fi
    fi
}

_post_rust() {
    have rustup || return 0
    log_step "Rust (rustup)"
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se comprobaría el toolchain por defecto de rustup"
        return 0
    fi
    if rustup show active-toolchain > /dev/null 2>&1; then
        log_ok "toolchain activo: $(rustup show active-toolchain 2>/dev/null | head -1)"
    else
        log_warn "rustup no tiene toolchain por defecto"
        if confirm "¿Instalar el toolchain 'stable' de Rust? (ocupa ~500 MB)" si; then
            run rustup default stable || add_warning "rustup default stable falló."
        else
            add_warning "Sin toolchain de Rust: cargo/rustc no funcionarán hasta 'rustup default stable'."
        fi
    fi
}

_post_mise() {
    have mise || return 0
    log_step "mise (gestor de toolchains)"
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se listarían las herramientas de mise"
        return 0
    fi
    local tools
    tools="$(mise ls 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -u | paste -sd', ' - || true)"
    if [[ -n "$tools" ]]; then
        log_ok "herramientas globales de mise: $tools"
    else
        log_info "mise no tiene herramientas globales configuradas"
        add_warning "mise sin herramientas globales. Si usabas node/python/etc. globales, defínelos con 'mise use -g node@lts' y captura ~/.config/mise con 'make capturar'."
    fi
    if [[ ! -d "${HOME}/.config/mise" ]]; then
        log_warn "no existe ~/.config/mise (tu configuración de mise no está en el repo)"
        add_warning "Falta ~/.config/mise en el repo: captúrala con 'make capturar'."
    fi
    # mise necesita que su shell esté activado; config.fish ya lo hace.
    log_debug "activación en fish: 'mise activate fish | source' (ver home/dot_config/fish/config.fish)"
}

_post_git() {
    log_step "git / gh"
    have git || { log_warn "git no instalado"; return 0; }

    local name email
    name="$(git config --global user.name 2>/dev/null || true)"
    email="$(git config --global user.email 2>/dev/null || true)"
    if [[ -n "$name" && -n "$email" ]]; then
        log_ok "git global: $name <$email>"
    else
        log_warn "git no tiene user.name/user.email globales"
        add_warning "Configura git: git config --global user.name 'Tu Nombre' && git config --global user.email 'tu@correo'. Luego captura ~/.gitconfig con 'make capturar'."
    fi

    if ! git config --global --get init.defaultBranch > /dev/null 2>&1; then
        log_info "sin init.defaultBranch global (git avisará en cada 'git init')"
        if confirm "¿Fijar init.defaultBranch=main globalmente?" si; then
            run git config --global init.defaultBranch main || true
        fi
    fi

    if have gh; then
        if is_true "$DRY_RUN"; then
            log_info "(dry-run) se comprobaría la autenticación de gh"
        elif gh auth status > /dev/null 2>&1; then
            log_ok "gh autenticado"
        else
            log_warn "gh no está autenticado"
            add_warning "Autentica GitHub CLI con: gh auth login"
        fi
    fi
}

_post_docker() {
    have docker || return 0
    log_step "Docker"
    if group_exists docker; then
        if user_in_group "$(id -un)" docker; then
            log_ok "perteneces al grupo docker (docker sin sudo)"
        else
            log_warn "no perteneces al grupo docker"
            add_warning "Agrega tu usuario a docker: sudo usermod -aG docker $(id -un) (y reinicia sesión)."
        fi
    fi
    if unit_is_active "docker.service"; then
        log_ok "docker.service activa"
    else
        log_info "docker.service no está activa ahora (se habilitó en la etapa 'system')"
    fi
}

_post_caelestia() {
    have caelestia || { log_info "caelestia no instalado; se omite su comprobación"; return 0; }
    log_step "Caelestia"

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se verificarían esquema y fondos de caelestia"
        return 0
    fi

    local scheme_file="${HOME}/.config/hypr/scheme/current.lua"
    if [[ -f "$scheme_file" ]]; then
        log_ok "esquema de colores presente: $scheme_file"
    else
        log_warn "no existe $scheme_file (hyprland.lua lo crea desde scheme/default.lua)"
        add_warning "Sin scheme/current.lua: al primer arranque se generará desde default.lua."
    fi

    local n=0
    if [[ -d "$DOTFILE_WALLPAPER_DIR" ]]; then
        n="$(find "$DOTFILE_WALLPAPER_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2> /dev/null | wc -l)"
    fi
    if [[ "$n" -eq 0 ]]; then
        log_warn "no hay fondos en ${DOTFILE_WALLPAPER_DIR}"
        add_warning "Copia tus wallpapers a ${DOTFILE_WALLPAPER_DIR} y luego: caelestia wallpaper -r '${DOTFILE_WALLPAPER_DIR}' && caelestia scheme set -n dynamic"
    else
        log_ok "${n} fondo(s) disponibles"
    fi

    if [[ ! -f "${HOME}/.config/caelestia/user-config.fish" ]]; then
        log_info "no existe ~/.config/caelestia/user-config.fish (chezmoi lo crea vacío con create_)"
    fi
}

_post_shell() {
    log_step "Shell (fish)"
    if ! have fish; then
        log_warn "fish no instalado"
        add_warning "fish no está instalado: la terminal foot no arrancará bien."
        return 0
    fi

    local current_shell
    current_shell="$(getent passwd "$(id -un)" 2> /dev/null | cut -d: -f7)"
    if [[ "$current_shell" == *"fish" ]]; then
        log_ok "shell de login: $current_shell"
    else
        log_warn "tu shell de login es '$current_shell', no fish"
        if confirm "¿Cambiar el shell de login a fish? (chsh -s $(command -v fish))" si; then
            run_root chsh -s "$(command -v fish)" "$(id -un)" \
                && log_ok "shell cambiado a fish (efectivo en el próximo login)" \
                || add_warning "No se pudo cambiar el shell a fish: hazlo con 'chsh -s $(command -v fish)'."
        else
            add_warning "Shell de login sin cambiar a fish."
        fi
    fi

    # Validar la sintaxis de la configuración aplicada
    local cfg="${HOME}/.config/fish/config.fish"
    if [[ -f "$cfg" ]]; then
        if is_false "$DRY_RUN" && fish -n "$cfg" > /dev/null 2>&1; then
            log_ok "config.fish: sintaxis válida"
        elif is_false "$DRY_RUN"; then
            log_error "config.fish tiene errores de sintaxis"
            add_warning "config.fish inválido: revísalo con 'fish -n ~/.config/fish/config.fish'."
        fi
    else
        log_warn "no existe $cfg (aplica los dotfiles: ./install.sh dotfiles --force)"
    fi
}

_post_checklist() {
    cat >&2 <<EOF

  ── Tareas manuales pendientes ─────────────────────────────────────────────
   1. Copia tus fondos de pantalla a:  ${DOTFILE_WALLPAPER_DIR}
   2. Captura las configuraciones que aún no están en el repo:
          make capturar
   3. Revisa qué se agregó y confirma que no haya secretos:
          git status && git diff --cached
          git commit -m "capturar configuraciones de $(hostname)" && git push
   4. Restaura tus llaves SSH desde tu respaldo (ver docs/SECRETOS.md)
   5. Reinicia para aplicar grupos y servicios:  sudo reboot
  ───────────────────────────────────────────────────────────────────────────

EOF
}

main() {
    log_step "Objetivo de arranque y gestor de sesión"
    _post_default_target
    _post_greetd

    echo
    _post_ssh

    echo
    _post_shell

    echo
    _post_rust
    _post_mise

    echo
    _post_git
    _post_docker

    echo
    _post_caelestia

    echo
    _post_checklist
    log_ok "tareas finales terminadas"
}

run_step "post"
