#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 80-verify.sh — informe de verificación del sistema reconstruido.
#
# Comprueba comandos, servicios, grupos, dotfiles y coherencia entre lo que
# declaran las configuraciones y lo que hay instalado. Genera un informe en
# Markdown que puedes guardar o pegar en un issue.
#
# Sale con código 1 solo si falla algo CRÍTICO (sin eso el escritorio no anda).
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
# shellcheck source=scripts/lib/hardware.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/hardware.sh"

REPORT_FILE=""
N_FAIL=0
N_WARN=0
N_OK=0

# Todo se escribe al informe Y a la consola
_rep() { printf '%s\n' "$*" >> "$REPORT_FILE"; }
_r_ok()   { N_OK=$(( N_OK + 1 ));   log_ok "$*";   _rep "- ✅ $*"; }
_r_warn() { N_WARN=$(( N_WARN + 1 )); log_warn "$*"; _rep "- ⚠️  $*"; }
_r_fail() { N_FAIL=$(( N_FAIL + 1 )); log_error "$*"; _rep "- ❌ $*"; }
_r_sec()  { log_step "$*"; _rep ""; _rep "## $*"; }

# Comandos imprescindibles: si falta uno, el escritorio no funciona
CRITICAL_CMDS=(Hyprland start-hyprland qs caelestia foot fish wl-paste hyprpicker cliphist)
# Comandos importantes: se avisa pero no se falla
IMPORTANT_CMDS=(
    starship zoxide direnv eza bat btop lazygit git jq curl wget rsync
    neovim nvim mise npm pnpm rustup gammastep imv mpv thunar qbittorrent
    pavucontrol fastfetch ripgrep zathura trash-empty gh paru chezmoi
    ydotool mpris-proxy pwvucontrol glances duf micro
)

_v_cmds() {
    _r_sec "Comandos"
    local c path
    for c in "${CRITICAL_CMDS[@]}"; do
        if path="$(command -v "$c" 2> /dev/null)"; then
            _r_ok "crítico presente: $c ($path)"
        else
            _r_fail "FALTA comando crítico: $c"
        fi
    done
    for c in "${IMPORTANT_CMDS[@]}"; do
        if have "$c"; then
            log_debug "presente: $c"
        else
            _r_warn "falta comando: $c"
        fi
    done
    _rep "- ✅ comandos críticos: $(printf '%s ' "${CRITICAL_CMDS[@]}")"
}

_v_dotfiles() {
    _r_sec "Dotfiles (chezmoi)"
    if ! have chezmoi; then
        _r_fail "chezmoi no está instalado"
        return 0
    fi

    # Este instalador usa --source explícito y NO cambia el source global.
    # Que `chezmoi source-path` apunte a ~/.local/share/chezmoi es normal en
    # el Lenovo original, y en una PC nueva no hace falta `chezmoi init`.
    local src managed_count
    src="$(chezmoi source-path 2> /dev/null || true)"
    [[ -n "$src" ]] && _rep "- ℹ️  Source global conservado: $src"
    managed_count="$(chezmoi --source "$REPO_ROOT" managed 2>/dev/null | wc -l || echo 0)"
    if [[ "$managed_count" -eq 0 ]]; then
        _r_fail "este repo no genera archivos gestionados: comprueba .chezmoiroot"
        return 0
    fi
    _r_ok "estado fuente explícito: $REPO_ROOT ($managed_count objetivos)"

    # Archivos clave aplicados
    local f
    local -a key_files=(
        ".config/fish/config.fish"
        ".config/foot/foot.ini"
        ".config/hypr/hyprland.lua"
        ".config/hypr/variables.lua"
        ".config/hypr/scheme/current.lua"
        ".config/caelestia/shell.json"
        ".config/caelestia/hypr-user.lua"
        ".config/caelestia/user-config.fish"
        ".config/systemd/user/rotar-fondo.timer"
        ".config/user-dirs.dirs"
        ".local/bin/rotar-fondo"
        ".config/VSCodium/User/settings.json"
    )
    for f in "${key_files[@]}"; do
        if [[ -e "${HOME}/${f}" ]]; then
            _r_ok "existe ~/${f}"
        else
            _r_warn "falta ~/${f}"
        fi
    done

    # ¿Quedan diferencias pendientes?
    if is_false "$DRY_RUN"; then
        local diff_out
        diff_out="$(chezmoi --source "$REPO_ROOT" diff 2>/dev/null || true)"
        if [[ -z "$diff_out" ]]; then
            _r_ok "chezmoi diff: sin diferencias pendientes"
        else
            local n
            n="$(printf '%s\n' "$diff_out" | grep -c '^diff ' || true)"
            _r_warn "chezmoi diff: ${n} archivo(s) con cambios sin aplicar (make apply)"
        fi
    fi

    # Sintaxis
    if have fish && [[ -f "${HOME}/.config/fish/config.fish" ]]; then
        if fish -n "${HOME}/.config/fish/config.fish" > /dev/null 2>&1; then
            _r_ok "config.fish: sintaxis válida"
        else
            _r_fail "config.fish tiene errores de sintaxis"
        fi
    fi

    local j
    for j in ".config/caelestia/shell.json" ".config/VSCodium/User/settings.json"; do
        [[ -f "${HOME}/${j}" ]] || continue
        if have jq && jq empty "${HOME}/${j}" > /dev/null 2>&1; then
            _r_ok "JSON válido: ~/${j}"
        elif have jq; then
            _r_fail "JSON inválido: ~/${j}"
        fi
    done

    # Rutas absolutas con nombre de usuario antiguo
    local hardcoded
    hardcoded="$(grep -rIn --exclude-dir=.git -E '/home/[a-z_][a-z0-9_-]*' "${HOME}/.config/caelestia" "${HOME}/.config/hypr" 2>/dev/null \
                 | grep -v "$(printf '%s' "$HOME" | sed 's/[\/&]/\\&/g')" | head -5 || true)"
    if [[ -n "$hardcoded" ]]; then
        _r_warn "rutas absolutas ajenas a este \$HOME en configs aplicadas:"
        _rep '```'
        _rep "$hardcoded"
        _rep '```'
    else
        _r_ok "sin rutas absolutas de otro usuario en las configs aplicadas"
    fi
}

_v_services() {
    _r_sec "Servicios"
    have systemctl || { _r_warn "systemd no disponible"; return 0; }

    local -a sys_units=() usr_units=()
    words_to_array sys_units "${DOTFILE_SYSTEM_SERVICES:-}"
    words_to_array usr_units "${DOTFILE_USER_SERVICES:-}"

    local u unit
    for u in "${sys_units[@]+"${sys_units[@]}"}"; do
        unit="$u"; [[ "$unit" == *.* ]] || unit="${unit}.service"
        unit_exists "$unit" || { log_debug "no existe: $unit"; continue; }
        if unit_is_enabled "$unit"; then
            _r_ok "habilitado: $unit"
        else
            _r_warn "NO habilitado: $unit"
        fi
    done

    local -a timers=()
    words_to_array timers "${DOTFILE_SYSTEM_TIMERS:-}"
    for u in "${timers[@]+"${timers[@]}"}"; do
        unit_exists "$u" || continue
        if unit_is_enabled "$u"; then _r_ok "habilitado: $u"; else _r_warn "NO habilitado: $u"; fi
    done

    if [[ -n "${XDG_RUNTIME_DIR:-}" && -S "${XDG_RUNTIME_DIR}/systemd/private" ]]; then
        for u in "${usr_units[@]+"${usr_units[@]}"}"; do
            unit="$u"; [[ "$unit" == *.* ]] || unit="${unit}.service"
            if [[ ! -f "${HOME}/.config/systemd/user/${unit}" ]] && ! unit_exists "$unit" --user; then
                _r_warn "unidad de usuario inexistente: $unit"
                continue
            fi
            if unit_is_enabled "$unit" --user; then
                _r_ok "habilitado (usuario): $unit"
            else
                _r_warn "NO habilitado (usuario): $unit"
            fi
        done
    else
        _r_warn "sin sesión de usuario activa: no se pudieron comprobar las unidades --user"
    fi

    if unit_is_enabled "greetd.service"; then
        _r_ok "gestor de sesión: greetd habilitado"
    else
        _r_warn "greetd no habilitado: no habrá login gráfico"
    fi
}

_v_groups() {
    _r_sec "Grupos del usuario"
    local -a groups=()
    words_to_array groups "${DOTFILE_USER_GROUPS:-}"
    local g
    for g in "${groups[@]+"${groups[@]}"}"; do
        group_exists "$g" || { log_debug "grupo inexistente en el sistema: $g"; continue; }
        if user_in_group "$(id -un)" "$g"; then
            log_debug "grupo OK: $g"
        else
            _r_warn "falta pertenecer al grupo: $g"
        fi
    done
    _r_ok "grupos actuales: $(id -nG | tr '\n' ' ')"
}

_v_firewall() {
    _r_sec "Firewall"
    if ! have ufw; then
        _r_warn "ufw no instalado"
        return 0
    fi
    local status
    status="$("${SUDO_CMD[@]}" ufw status 2>/dev/null | head -1 || true)"
    if [[ "$status" == *"active"* ]]; then
        _r_ok "ufw: $status"
        if is_true "$DOTFILE_UFW_ALLOW_LOCALSEND"; then
            if "${SUDO_CMD[@]}" ufw status 2>/dev/null | grep -q '53317'; then
                _r_ok "ufw: puerto 53317 (LocalSend) abierto"
            else
                _r_warn "ufw activo pero sin regla para LocalSend (53317)"
            fi
        fi
    else
        _r_warn "ufw no está activo (${status:-sin estado})"
    fi
}

_v_appearance() {
    _r_sec "Apariencia"
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && have gsettings; then
        local k v
        for k in gtk-theme icon-theme cursor-theme cursor-size color-scheme; do
            v="$(gsettings get org.gnome.desktop.interface "$k" 2>/dev/null || echo 'n/d')"
            _rep "- ℹ️  ${k}: ${v}"
            log_info "${k}: ${v}"
        done
        local gtk
        gtk="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'" || true)"
        if [[ -n "$gtk" && -d "/usr/share/themes/${gtk}" ]]; then
            _r_ok "el tema GTK '$gtk' está instalado"
        elif [[ -n "$gtk" ]]; then
            _r_warn "el tema GTK '$gtk' no existe en /usr/share/themes"
        fi
        local icons
        icons="$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'" || true)"
        if [[ -n "$icons" && -d "/usr/share/icons/${icons}" ]]; then
            _r_ok "el tema de iconos '$icons' está instalado"
        elif [[ -n "$icons" ]]; then
            _r_warn "el tema de iconos '$icons' no existe en /usr/share/icons"
        fi
    else
        _r_warn "sin DBus de sesión: no se pudo comprobar la apariencia GTK"
    fi

    # Coherencia con lo que declaran las configuraciones del repo
    local vars_file="${HOME}/.config/hypr/variables.lua"
    if [[ -f "$vars_file" ]]; then
        local ct cs
        ct="$(sed -n 's/.*cursorTheme[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$vars_file" | head -1)"
        cs="$(sed -n 's/.*cursorSize[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$vars_file" | head -1)"
        if [[ -n "$ct" && "$ct" != "$DOTFILE_CURSOR_THEME" ]]; then
            _r_warn "variables.lua usa cursor '$ct' pero DOTFILE_CURSOR_THEME='$DOTFILE_CURSOR_THEME'"
        elif [[ -n "$ct" ]]; then
            _r_ok "cursor coherente: $ct ($cs)"
        fi
    fi
}

_v_versions() {
    _r_sec "Compatibilidad de versiones (informativa)"
    if ! have pacman; then
        _r_warn "sin pacman: no se pueden comprobar las versiones instaladas"
        return 0
    fi
    local pkg version
    for pkg in hyprland caelestia-shell caelestia-cli quickshell-git fish foot; do
        version="$(pacman -Q "$pkg" 2>/dev/null || true)"
        if [[ -n "$version" ]]; then
            _rep "- ℹ️  $version"
            log_info "$version"
        elif [[ "$pkg" == hyprland || "$pkg" == caelestia-shell || "$pkg" == caelestia-cli ]]; then
            _r_fail "falta componente del escritorio: $pkg"
        else
            _r_warn "no instalado: $pkg"
        fi
    done
    _rep "- ℹ️  Referencia original (no fijada): Hyprland 0.56.2, Caelestia Shell 2.5.0 y CLI 1.1.3."
    _rep "- ⚠️  Una versión más nueva puede cambiar la API Lua o el formato JSON; ver docs/ACTUALIZACIONES.md."
    return 0
}

_v_wallpapers() {
    _r_sec "Fondos de pantalla"
    if [[ ! -d "$DOTFILE_WALLPAPER_DIR" ]]; then
        _r_warn "no existe ${DOTFILE_WALLPAPER_DIR}"
        return 0
    fi
    local n
    n="$(find "$DOTFILE_WALLPAPER_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2> /dev/null | wc -l)"
    if [[ "$n" -gt 0 ]]; then
        _r_ok "${n} fondo(s) en ${DOTFILE_WALLPAPER_DIR}"
    else
        _r_warn "la carpeta existe pero no tiene imágenes"
    fi
}

_v_repo() {
    _r_sec "Repositorio"
    if [[ -d "${REPO_ROOT}/.git" ]] && have git; then
        local branch dirty remote
        branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo 'sin remote')"
        _rep "- ℹ️  rama: ${branch}"
        _rep "- ℹ️  remote: ${remote}"
        _rep "- ℹ️  commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
        dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l)"
        if [[ "$dirty" -eq 0 ]]; then
            _r_ok "working tree limpio"
        else
            _r_warn "${dirty} cambio(s) sin confirmar en el repo"
        fi
        # ¿Hay algo sensible versionado?
        if git -C "$REPO_ROOT" ls-files 2>/dev/null | grep -qiE '(^|/)(\.ssh/|id_rsa|id_ed25519|.*\.pem$|.*\.key$|\.netrc$)'; then
            _r_fail "hay archivos potencialmente secretos versionados (ver docs/SECRETOS.md)"
        else
            _r_ok "no se detectaron secretos evidentes en los archivos versionados"
        fi
        # ¿Quedan .bak o rutas de otro usuario?
        local baks hardcodes
        baks="$(git -C "$REPO_ROOT" ls-files 2>/dev/null | grep -c '\.bak$' || true)"
        [[ "$baks" -eq 0 ]] && _r_ok "sin archivos .bak versionados" || _r_warn "${baks} archivo(s) .bak versionados"

        hardcodes="$(grep -rIn --exclude-dir=.git -E '/home/[a-z_][a-z0-9_-]*/' "$REPO_ROOT/home" 2>/dev/null | wc -l)"
        [[ "$hardcodes" -eq 0 ]] \
            && _r_ok "sin rutas /home/<usuario> hardcodeadas en home/" \
            || _r_warn "${hardcodes} ruta(s) /home/<usuario> hardcodeadas en home/ (usa {{ .chezmoi.homeDir }})"
    else
        _r_warn "el repo no es un clon de git"
    fi
}

_v_pending_captures() {
    _r_sec "Configuraciones que aún no están en el repo"
    # Rutas típicas de las apps instaladas que NO se versionan todavía.
    local -a candidates=(
        ".gitconfig"
        ".config/starship.toml"
        ".config/nvim"
        ".config/mise"
        ".config/btop"
        ".config/lazygit"
        ".config/zathura"
        ".config/mpv"
        ".config/fastfetch"
        ".config/gammastep"
        ".config/gtk-3.0"
        ".config/gtk-4.0"
        ".config/qtengine"
        ".config/qt6ct"
        ".config/topgrade.toml"
        ".config/paru"
        ".config/gh"
        ".config/imv"
        ".config/hypr/hypridle.conf"
        ".config/zen-browser"
        ".local/share/applications"
        ".config/mimeapps.list"
    )
    local c missing=0 present_untracked=0
    for c in "${candidates[@]}"; do
        if [[ -e "${HOME}/${c}" ]]; then
            # ¿está versionado? (comparar contra la lista de archivos de chezmoi)
            if have chezmoi && chezmoi --source "$REPO_ROOT" managed 2> /dev/null | grep -qx "${HOME}/${c}"; then
                log_debug "ya versionado: $c"
            else
                present_untracked=$(( present_untracked + 1 ))
                _rep "- 📥 sin capturar: ~/${c}"
            fi
        else
            missing=$(( missing + 1 ))
        fi
    done
    if [[ "$present_untracked" -gt 0 ]]; then
        _r_warn "${present_untracked} configuración(es) existen en \$HOME pero no están en el repo → ejecutá 'make capturar'"
    else
        _r_ok "todo lo relevante de \$HOME parece estar capturado"
    fi
    _r_ok "${missing} ruta(s) candidata(s) no existen en esta máquina (nada que capturar)"
}

main() {
    hw_detect
    mkdir -p "$STATE_DIR" 2> /dev/null || true
    REPORT_FILE="${STATE_DIR}/verificacion-$(date +%Y%m%d-%H%M%S).md"

    {
        printf '# Verificación del sistema — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '- Host: `%s`\n' "$(hostname)"
        printf '- Usuario: `%s`\n' "$(id -un)"
        printf '- Distro: `%s`\n' "$HW_DISTRO"
        printf '- Kernel: `%s`\n' "$(uname -r)"
        printf '- Hardware: `%s`\n' "$HW_TAGS"
        printf '- Repo: `%s`\n' "$REPO_ROOT"
    } > "$REPORT_FILE"

    log_step "Generando informe: ${REPORT_FILE}"

    _v_cmds
    _v_dotfiles
    _v_services
    _v_groups
    _v_firewall
    _v_appearance
    _v_versions
    _v_wallpapers
    _v_repo
    _v_pending_captures

    {
        printf '\n---\n\n'
        printf '## Resumen\n\n'
        printf '- ✅ correctos: %s\n' "$N_OK"
        printf '- ⚠️  avisos: %s\n' "$N_WARN"
        printf '- ❌ fallos críticos: %s\n' "$N_FAIL"
    } >> "$REPORT_FILE"

    echo
    log_step "Resumen de la verificación"
    log_ok    "correctos        : ${N_OK}"
    log_warn  "avisos           : ${N_WARN}"
    if [[ "$N_FAIL" -gt 0 ]]; then
        log_error "fallos críticos  : ${N_FAIL}"
    else
        log_ok    "fallos críticos  : 0"
    fi
    log_info "informe completo: ${REPORT_FILE}"

    if [[ "$N_FAIL" -gt 0 ]]; then
        add_warning "Hay ${N_FAIL} fallo(s) crítico(s): revisa el informe ${REPORT_FILE}"
        return 1
    fi
    return 0
}

run_step "verify"
