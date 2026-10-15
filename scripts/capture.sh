#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capture.sh — captura en el repo lo que todavía NO está versionado.
#
# Es la respuesta a "¿qué me falta guardar?". Se corre EN TU MÁQUINA ACTUAL:
# detecta las configuraciones que existen en $HOME y en /etc y las agrega al
# repo con chezmoi (o las copia a system/ para las de sistema).
#
#   ./scripts/capture.sh --list        # SOLO LISTAR qué falta (no toca nada)
#   ./scripts/capture.sh               # modo interactivo, por categorías
#   ./scripts/capture.sh --all         # capturar todo lo encontrado
#   ./scripts/capture.sh --dotfiles    # solo configuraciones de $HOME
#   ./scripts/capture.sh --system      # solo archivos de /etc
#   ./scripts/capture.sh --packages    # regenerar packages/*.txt
#   ./scripts/capture.sh --host-env    # generar config/host.<hostname>.env
#   ./scripts/capture.sh --scan        # buscar secretos en lo versionado
#
# NUNCA captura llaves privadas ni credenciales: mira docs/SECRETOS.md.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
# shellcheck source=scripts/lib/hardware.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/hardware.sh"

MODE_LIST="no"; MODE_ALL="no"; MODE_DOTFILES="no"; MODE_SYSTEM="no"
MODE_PACKAGES="no"; MODE_HOSTENV="no"; MODE_SCAN="no"
declare -a ADDED=() SKIPPED=()

# ---------------------------------------------------------------------------
# Catálogo de rutas candidatas.
# Formato: "ruta|categoria|riesgo|nota"
#   riesgo: bajo | medio | alto | pesado
# ---------------------------------------------------------------------------
CANDIDATES=(
    # --- Desarrollo ---
    ".gitconfig|desarrollo|bajo|identidad y alias de git (revisa el email)"
    ".gitignore_global|desarrollo|bajo|ignores globales de git"
    ".config/gh|desarrollo|ALTO|GitHub CLI: hosts.yml PUEDE CONTENER TOKENS"
    ".config/lazygit|desarrollo|bajo|config de lazygit"
    ".config/nvim|desarrollo|medio|tu editor principal (puede traer plugins)"
    ".config/mise|desarrollo|bajo|toolchains globales (node/python/go...)"
    ".config/direnv|desarrollo|bajo|allowlist de direnv"
    ".config/git|desarrollo|bajo|config extra de git"
    ".config/tree-sitter|desarrollo|bajo|gramáticas"

    # --- Shell y CLI ---
    ".config/starship.toml|shell|bajo|prompt de starship (config.fish lo usa)"
    ".config/btop|shell|bajo|tema y opciones de btop"
    ".config/fish/functions|shell|medio|funciones fish extra (las del repo ya están)"
    ".config/fish/completions|shell|pesado|completions generadas, normalmente NO se versionan"
    ".config/fish/conf.d|shell|medio|snippets generados por paquetes (mise, rustup...)"
    ".config/zellij|shell|bajo|si usas zellij"
    ".config/tmux|shell|bajo|si usas tmux"

    # --- Multimedia ---
    ".config/mpv|multimedia|bajo|reproductor (input.conf, mpv.conf)"
    ".config/imv|multimedia|bajo|visor de imágenes"
    ".config/zathura|multimedia|bajo|visor de PDF"
    ".config/vlc|multimedia|pesado|preferencias de VLC (suele ser ruido)"

    # --- Apariencia ---
    ".config/gtk-3.0|apariencia|bajo|settings.ini de GTK3"
    ".config/gtk-4.0|apariencia|bajo|settings.ini de GTK4"
    ".config/qtengine|apariencia|bajo|estilo Qt (darkly) — importante con hyprland"
    ".config/qt6ct|apariencia|bajo|alternativa de tema Qt"
    ".config/Kvantum|apariencia|bajo|temas Kvantum si los usas"
    ".icons/default/index.theme|apariencia|bajo|cursor por defecto para XWayland"
    ".themes|apariencia|pesado|temas GTK instalados a mano"
    ".config/fontconfig|apariencia|bajo|reglas de fuentes"
    ".config/mimeapps.list|apariencia|bajo|qué app abre cada tipo de archivo"
    ".local/share/applications|apariencia|medio|entradas .desktop personalizadas"

    # --- Escritorio / Hyprland ---
    ".config/hypr/hypridle.conf|escritorio|bajo|si tienes idle/lock propio"
    ".config/hypr/hyprlock.conf|escritorio|bajo|si tienes hyprlock (caelestia trae el suyo)"
    ".config/hypr/hyprpaper.conf|escritorio|bajo|si usas hyprpaper en lugar de caelestia"
    ".config/wlogout|escritorio|bajo|menú de apagado"
    ".config/wofi|escritorio|bajo|launcher alternativo"
    ".config/swaync|escritorio|bajo|centro de notificaciones alternativo"
    ".config/waybar|escritorio|bajo|barra alternativa"
    ".config/dunst|escritorio|bajo|notificador alternativo"

    # --- Utilidades ---
    ".config/fastfetch|utilidades|bajo|el banner de fish_greeting lo usa"
    ".config/gammastep|utilidades|bajo|luz nocturna (execs.lua arranca gammastep)"
    ".config/topgrade.toml|utilidades|bajo|config del actualizador universal"
    ".config/paru|utilidades|bajo|config del helper de AUR"
    ".config/yay|utilidades|bajo|si usas yay"
    ".config/systemd/user|utilidades|bajo|unidades de usuario (rotar-fondo ya está)"
    ".config/environment.d|utilidades|bajo|variables de entorno de systemd"
    ".config/autostart|utilidades|bajo|autostart XDG"
    ".config/neofetch|utilidades|bajo|si lo usabas antes de fastfetch"
    ".config/alacritty|utilidades|bajo|config de alacritty (está en la lista de paquetes)"
    ".config/VSCodium|utilidades|medio|settings/keybindings/snippets (ya hay settings.json)"
    ".config/Code|utilidades|medio|si también usas VSCode"

    # --- SSH (SOLO lo público, NUNCA llaves) ---
    ".ssh/config|ssh|medio|hosts y opciones — revisa que no haya secretos"
    ".ssh/known_hosts|ssh|bajo|hosts conocidos"

    # --- Pesados / sensibles: se listan pero NO se recomiendan ---
    ".config/zen-browser|peligroso|pesado|perfil completo del navegador: enorme y con cookies/historial"
    ".mozilla|peligroso|pesado|perfil de Firefox: enorme y sensible"
    ".config/Bitwarden|peligroso|ALTO|datos del gestor de contraseñas"
    ".config/discord|peligroso|ALTO|tokens de sesión"
    ".local/share/cliphist|peligroso|ALTO|historial de portapapeles"
    ".local/share/keyrings|peligroso|ALTO|llaveros de GNOME (contraseñas)"
    ".config/rclone|peligroso|ALTO|credenciales de nubes"
    ".aws|peligroso|ALTO|credenciales de AWS"
)

# Archivos de /etc que el instalador SÍ aplica (system/etc/)
SYSTEM_ETC_APPLY=(
    "/etc/greetd/config.toml|gestor de sesión (tuigreet + Hyprland)"
    "/etc/sysctl.d/99-dotfile.conf|parámetros de kernel propios"
    "/etc/modules-load.d/dotfile.conf|módulos a cargar (p. ej. uinput para ydotool)"
    "/etc/udev/rules.d/99-ydotool.rules|permisos del socket de ydotool"
)

# Archivos de /etc que solo se guardan como REFERENCIA (no se aplican solos)
SYSTEM_ETC_REFERENCE=(
    "/etc/pacman.conf|repos y opciones de pacman"
    "/etc/paru.conf|config global del helper de AUR"
    "/etc/locale.conf|LANG del sistema"
    "/etc/locale.gen|locales generados"
    "/etc/vconsole.conf|teclado de consola"
    "/etc/mkinitcpio.conf|hooks del initramfs"
    "/etc/fstab|MUY específico de la máquina: solo referencia"
    "/etc/default/grub|opciones de GRUB"
    "/etc/hosts|resoluciones locales"
    "/etc/ufw/user.rules|reglas de firewall"
    "/etc/security/limits.conf|límites (realtime, memlock)"
    "/etc/bluetooth/main.conf|ajustes de bluetooth"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_is_managed() { # <ruta-absoluta>
    have chezmoi || return 1
    chezmoi --source "$REPO_ROOT" managed 2> /dev/null | grep -Fxq "$1"
}

_split_field() { # <cadena> <n>
    printf '%s' "$1" | cut -d'|' -f"$2"
}

_scan_secrets() { # <archivo>
    local f="$1"
    grep -nIE \
        -e 'BEGIN (OPENSSH|RSA|DSA|EC|PGP) PRIVATE KEY' \
        -e 'AKIA[0-9A-Z]{16}' \
        -e 'gh[pousr]_[A-Za-z0-9]{20,}' \
        -e 'github_pat_[A-Za-z0-9_]{20,}' \
        -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
        -e '(api[_-]?key|apikey|secret|token|passwd|password)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}' \
        -e 'machine[[:space:]]+[^[:space:]]+[[:space:]]+login' \
        "$f" 2> /dev/null | head -5
}

_scan_repo() {
    log_step "Buscando posibles secretos en lo versionado"
    local found=0 f hits
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        case "$f" in
            */.git/*) continue ;;
            *.md|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.otf|*.pdf) continue ;;
        esac
        hits="$(_scan_secrets "$f" || true)"
        if [[ -n "$hits" ]]; then
            found=$(( found + 1 ))
            log_warn "posible secreto en ${f#"${REPO_ROOT}/"}:"
            printf '%s\n' "$hits" | sed 's/^/        /'
        fi
    done < <(find "$REPO_ROOT" -type f -not -path '*/.git/*' 2> /dev/null)

    # Archivos con nombre sospechoso versionados en git
    if [[ -d "${REPO_ROOT}/.git" ]] && have git; then
        local bad
        bad="$(git -C "$REPO_ROOT" ls-files 2>/dev/null | grep -iE '(^|/)(id_rsa|id_ed25519|id_ecdsa|\.netrc|\.git-credentials|.*\.pem|.*\.key|.*\.p12)$' || true)"
        if [[ -n "$bad" ]]; then
            found=$(( found + 1 ))
            log_error "archivos sensibles versionados en git:"
            printf '%s\n' "$bad" | sed 's/^/        /'
        fi
    fi

    if [[ "$found" -eq 0 ]]; then
        log_ok "no se detectaron secretos evidentes"
    else
        log_error "${found} hallazgo(s). Revisa docs/SECRETOS.md antes de hacer push."
        add_warning "Posibles secretos en el repo: revisa el listado anterior."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Captura de dotfiles ($HOME)
# ---------------------------------------------------------------------------
_capture_dotfiles() {
    have chezmoi || { log_warn "chezmoi no instalado: no se puede capturar"; return 1; }

    local entry path category risk note
    local -a by_category=()

    log_step "Configuraciones en \$HOME"

    # Agrupar para presentar por categorías
    local seen_categories=""
    for entry in "${CANDIDATES[@]}"; do
        path="$(_split_field "$entry" 1)"
        category="$(_split_field "$entry" 2)"
        case " $seen_categories " in *" $category "*) ;; *) seen_categories+=" $category" ;; esac
    done

    local cat
    for cat in $seen_categories; do
        local -a entries=()
        for entry in "${CANDIDATES[@]}"; do
            [[ "$(_split_field "$entry" 2)" == "$cat" ]] && entries+=("$entry")
        done

        # ¿Hay algo que capturar en esta categoría?
        local -a pending=()
        for entry in "${entries[@]}"; do
            path="${HOME}/$(_split_field "$entry" 1)"
            [[ -e "$path" ]] || continue
            _is_managed "$path" && continue
            pending+=("$entry")
        done
        [[ "${#pending[@]}" -eq 0 ]] && continue

        by_category+=("$cat")
        echo
        log_info "categoría: ${C_BOLD}${cat}${C_RESET} (${#pending[@]} elemento(s))"
        for entry in "${pending[@]}"; do
            printf '      - %-34s [%s] %s\n' \
                "~/$(_split_field "$entry" 1)" \
                "$(_split_field "$entry" 3)" \
                "$(_split_field "$entry" 4)"
        done

        if [[ "$MODE_LIST" == "yes" ]]; then
            continue
        fi

        local do_it="no"
        if [[ "$MODE_ALL" == "yes" && "$cat" != "peligroso" ]]; then
            do_it="yes"
        elif [[ "$cat" == "peligroso" ]]; then
            log_warn "categoría '$cat': NO se captura nunca con --all (riesgo de filtrar datos)"
            do_it="no"
        elif confirm "¿Capturar la categoría '$cat'?" no; then
            do_it="yes"
        fi

        if [[ "$do_it" == "yes" ]]; then
            for entry in "${pending[@]}"; do
                _capture_one "${HOME}/$(_split_field "$entry" 1)" "$(_split_field "$entry" 3)"
            done
        else
            for entry in "${pending[@]}"; do
                SKIPPED+=("~/$(_split_field "$entry" 1)")
            done
        fi
    done

    if [[ "${#by_category[@]}" -eq 0 ]]; then
        log_ok "todo lo conocido de \$HOME ya está capturado"
    fi
    return 0
}

_capture_one() { # <ruta-absoluta> <riesgo>
    local path="$1" risk="$2"

    if [[ "$risk" == "pesado" ]]; then
        log_warn "$path es grande/ruidoso; quizá te interese ignorarlo en vez de versionarlo"
        confirm "¿Capturarlo de todas formas?" no || { SKIPPED+=("$path"); return 0; }
    fi
    if [[ "$risk" == "ALTO" ]]; then
        log_warn "$path puede contener secretos"
        confirm "¿Capturarlo? (revísalo con git diff ANTES de hacer push)" no || { SKIPPED+=("$path"); return 0; }
    fi

    if is_true "$DRY_RUN" || [[ "$MODE_LIST" == "yes" ]]; then
        log_info "(dry-run) chezmoi --source "$REPO_ROOT" add --recursive '$path'"
        ADDED+=("$path")
        return 0
    fi

    # Antes de agregar, comprobar que no arrastra secretos
    if [[ -f "$path" ]]; then
        local hits; hits="$(_scan_secrets "$path" || true)"
        if [[ -n "$hits" ]]; then
            log_error "se detectó contenido sensible en $path — NO se captura:"
            printf '%s\n' "$hits" | sed 's/^/        /'
            SKIPPED+=("$path (contenido sensible)")
            return 0
        fi
    else
        local f hits
        while IFS= read -r f; do
            hits="$(_scan_secrets "$f" || true)"
            if [[ -n "$hits" ]]; then
                log_error "contenido sensible en $f — se omite todo $path"
                printf '%s\n' "$hits" | sed 's/^/        /'
                SKIPPED+=("$path (contenido sensible en $(basename -- "$f"))")
                return 0
            fi
        done < <(find "$path" -type f -size -2M 2> /dev/null | head -200)
    fi

    if chezmoi --source "$REPO_ROOT" add --recursive "$path" 2>> "$LOG_FILE"; then
        log_ok "capturado: $path"
        ADDED+=("$path")
    else
        log_error "chezmoi add falló con $path (mira $LOG_FILE)"
        SKIPPED+=("$path (error)")
    fi
}

# ---------------------------------------------------------------------------
# Captura de /etc
# ---------------------------------------------------------------------------
_capture_system() {
    log_step "Archivos de sistema (/etc)"

    local entry src dst note
    local -a to_apply=() to_ref=()

    for entry in "${SYSTEM_ETC_APPLY[@]}"; do
        src="$(_split_field "$entry" 1)"
        [[ -r "$src" ]] || continue
        dst="${SYSTEM_DIR}/etc/${src#/etc/}"
        if [[ -f "$dst" ]] && cmp -s -- "$src" "$dst"; then
            log_ok "ya capturado e idéntico: $src"
            continue
        fi
        to_apply+=("$src|$dst|$(_split_field "$entry" 2)")
    done

    for entry in "${SYSTEM_ETC_REFERENCE[@]}"; do
        src="$(_split_field "$entry" 1)"
        [[ -r "$src" ]] || continue
        dst="${SYSTEM_DIR}/referencia/etc/${src#/etc/}"
        if [[ -f "$dst" ]] && cmp -s -- "$src" "$dst"; then
            log_ok "ya capturado e idéntico: $src"
            continue
        fi
        to_ref+=("$src|$dst|$(_split_field "$entry" 2)")
    done

    if [[ "${#to_apply[@]}" -eq 0 && "${#to_ref[@]}" -eq 0 ]]; then
        log_ok "no hay archivos de /etc nuevos que capturar"
        return 0
    fi

    if [[ "${#to_apply[@]}" -gt 0 ]]; then
        echo
        log_info "se aplicarían con el instalador (system/etc/):"
        for entry in "${to_apply[@]}"; do printf '      - %-40s %s\n' "$(_split_field "$entry" 1)" "$(_split_field "$entry" 3)"; done
    fi
    if [[ "${#to_ref[@]}" -gt 0 ]]; then
        echo
        log_info "solo como referencia (system/referencia/, el instalador NO los toca):"
        for entry in "${to_ref[@]}"; do printf '      - %-40s %s\n' "$(_split_field "$entry" 1)" "$(_split_field "$entry" 3)"; done
    fi

    if [[ "$MODE_LIST" == "yes" ]]; then
        return 0
    fi

    local do_it="no"
    [[ "$MODE_ALL" == "yes" ]] && do_it="yes"
    [[ "$do_it" == "no" ]] && { confirm "¿Copiar estos archivos al repo?" si && do_it="yes"; }

    if [[ "$do_it" == "yes" ]]; then
        for entry in "${to_apply[@]}" "${to_ref[@]}"; do
            src="$(_split_field "$entry" 1)"; dst="$(_split_field "$entry" 2)"
            local hits; hits="$(_scan_secrets "$src" || true)"
            if [[ -n "$hits" ]]; then
                log_warn "$src contiene datos sensibles; se guarda con la línea censurada"
                printf '%s\n' "$hits" | sed 's/^/        /'
                confirm "¿Copiarlo de todas formas?" no || { SKIPPED+=("$src"); continue; }
            fi
            if is_true "$DRY_RUN"; then
                log_info "(dry-run) cp $src -> $dst"
            else
                mkdir -p "$(dirname -- "$dst")"
                if cp -a -- "$src" "$dst" 2> /dev/null; then
                    log_ok "capturado: $src -> ${dst#"${REPO_ROOT}/"}"
                    ADDED+=("${dst#"${REPO_ROOT}/"}")
                else
                    # Puede necesitar root para leerlo
                    log_warn "no se pudo leer $src; intenta: sudo cp $src $dst"
                    SKIPPED+=("$src (permisos)")
                fi
            fi
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# config/host.<hostname>.env
# ---------------------------------------------------------------------------
_capture_hostenv() {
    log_step "Configuración específica de esta máquina"
    hw_detect

    local host; host="$(hostname)"
    local dst="${CONFIG_DIR}/host.${host}.env"

    local tz km gtk icons cursor csize scheme font mono wall lang
    tz="$(timedatectl show -p Timezone --value 2> /dev/null || true)"
    km="$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf 2> /dev/null | tr -d '"' | head -1)"
    lang="$(sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | tr -d '"' | head -1)"
    wall="${DOTFILE_WALLPAPER_DIR}"
    [[ -f "${HOME}/.config/user-dirs.dirs" ]] && \
        wall="$(sed -n 's/^XDG_PICTURES_DIR=//p' "${HOME}/.config/user-dirs.dirs" | tr -d '"' | head -1)/Wallpapers"
    wall="${wall/\$HOME/$HOME}"

    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && have gsettings; then
        _g() { gsettings get "$1" "$2" 2> /dev/null | tr -d "'" || true; }
        gtk="$(_g org.gnome.desktop.interface gtk-theme)"
        icons="$(_g org.gnome.desktop.interface icon-theme)"
        cursor="$(_g org.gnome.desktop.interface cursor-theme)"
        csize="$(_g org.gnome.desktop.interface cursor-size)"
        scheme="$(_g org.gnome.desktop.interface color-scheme)"
        font="$(_g org.gnome.desktop.interface font-name)"
        mono="$(_g org.gnome.desktop.interface monospace-font-name)"
    fi

    local content
    content="$(cat <<EOF
# ---------------------------------------------------------------------------
# Generado automáticamente por scripts/capture.sh el $(date '+%Y-%m-%d %H:%M')
# Host: ${host}
#
# Este archivo NO se versiona (está en .gitignore) porque describe esta
# máquina concreta. Revísalo y ajusta lo que quieras.
# ---------------------------------------------------------------------------

# --- Hardware detectado ----------------------------------------------------
DOTFILE_TIER="${DOTFILE_TIER:-full}"
# HW_GPU_VENDOR="${HW_GPU_VENDOR}"
# HW_IS_LAPTOP="${HW_IS_LAPTOP}"
# HW_IS_FRAMEWORK="${HW_IS_FRAMEWORK}"

# --- Región y teclado ------------------------------------------------------
DOTFILE_TIMEZONE="${tz:-America/Bogota}"
DOTFILE_KEYMAP="${km:-latam}"
DOTFILE_LOCALE="${lang:-}"

# --- Rutas -----------------------------------------------------------------
DOTFILE_WALLPAPER_DIR="${wall:-${HOME}/Imágenes/Wallpapers}"

# --- Apariencia (leída de gsettings) ---------------------------------------
DOTFILE_GTK_THEME="${gtk:-adw-gtk3-dark}"
DOTFILE_ICON_THEME="${icons:-Papirus-Dark}"
DOTFILE_CURSOR_THEME="${cursor:-Adwaita}"
DOTFILE_CURSOR_SIZE="${csize:-24}"
DOTFILE_COLOR_SCHEME="${scheme:-prefer-dark}"
DOTFILE_FONT_NAME="${font:-}"
DOTFILE_FONT_MONO="${mono:-}"

# --- Servicios activos en esta máquina --------------------------------------
# (solo los que estén habilitados ahora mismo)
$(
    if have systemctl; then
        systemctl list-unit-files --state=enabled --no-legend 2> /dev/null \
            | awk '{print $1}' | grep -E '\.(service|timer)$' | sort \
            | sed 's/^/# /' | head -60
    else
        echo "# (systemd no disponible)"
    fi
)
EOF
)"

    if [[ "$MODE_LIST" == "yes" ]]; then
        log_info "se generaría: ${dst#"${REPO_ROOT}/"}"
        printf '%s\n' "$content" | sed 's/^/      /'
        return 0
    fi

    if [[ -f "$dst" ]] && is_false "$FORCE"; then
        log_warn "ya existe ${dst#"${REPO_ROOT}/"}; no se sobrescribe (usa --force)"
        SKIPPED+=("config/host.${host}.env")
        return 0
    fi

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se escribiría ${dst#"${REPO_ROOT}/"}"
        return 0
    fi

    printf '%s\n' "$content" > "$dst" && log_ok "generado: config/host.${host}.env"
    ADDED+=("config/host.${host}.env")
    log_info "el instalador lo leerá automáticamente en esta máquina"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
_usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list|-l)      MODE_LIST="yes" ;;
            --all|-a)       MODE_ALL="yes" ;;
            --dotfiles)     MODE_DOTFILES="yes" ;;
            --system)       MODE_SYSTEM="yes" ;;
            --packages)     MODE_PACKAGES="yes" ;;
            --host-env)     MODE_HOSTENV="yes" ;;
            --scan)         MODE_SCAN="yes" ;;
            -n|--dry-run)   DRY_RUN="yes" ;;
            -y|--yes)       YES="yes" ;;
            -f|--force)     FORCE="yes" ;;
            -h|--help)      _usage; return 0 ;;
            *)              log_error "opción desconocida: $1"; _usage; return 2 ;;
        esac
        shift
    done

    # Sin flags concretos -> modo completo interactivo
    if is_false "$MODE_DOTFILES" && is_false "$MODE_SYSTEM" && is_false "$MODE_PACKAGES" \
       && is_false "$MODE_HOSTENV" && is_false "$MODE_SCAN"; then
        MODE_DOTFILES="yes"; MODE_SYSTEM="yes"; MODE_PACKAGES="yes"; MODE_HOSTENV="yes"; MODE_SCAN="yes"
    fi

    log_info "repo      : ${REPO_ROOT}"
    log_info "modo      : $([[ "$MODE_LIST" == yes ]] && echo 'solo listar' || echo 'capturar')"
    echo

    is_true "$MODE_DOTFILES" && { _capture_dotfiles; echo; }
    is_true "$MODE_SYSTEM"   && { _capture_system;   echo; }
    is_true "$MODE_HOSTENV"  && { _capture_hostenv;  echo; }

    if is_true "$MODE_PACKAGES"; then
        log_step "Listas de paquetes"
        if [[ "$MODE_LIST" == "yes" ]]; then
            log_info "comparación (no se escribe): ./scripts/packages-update.sh --diff"
            run "${SCRIPTS_DIR}/packages-update.sh" --diff || true
        elif [[ "$MODE_ALL" == "yes" ]]; then
            run "${SCRIPTS_DIR}/packages-update.sh" --write || true
        else
            if confirm "¿Regenerar packages/*.txt desde el sistema actual?" si; then
                run "${SCRIPTS_DIR}/packages-update.sh" || true
            fi
        fi
        echo
    fi

    if is_true "$MODE_SCAN"; then
        _scan_repo || true
        echo
    fi

    # --- Resumen -----------------------------------------------------------
    log_step "Resumen de la captura"
    if [[ "${#ADDED[@]}" -gt 0 ]]; then
        log_ok "capturado (${#ADDED[@]}):"
        local a
        for a in "${ADDED[@]}"; do printf '      + %s\n' "$a"; done
    else
        log_info "no se agregó nada nuevo"
    fi
    if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
        log_warn "omitido (${#SKIPPED[@]}):"
        local s
        for s in "${SKIPPED[@]}"; do printf '      - %s\n' "$s"; done
    fi

    if [[ "$MODE_LIST" == "yes" ]]; then
        echo
        log_info "esto era solo un listado. Para capturar: ./scripts/capture.sh"
        return 0
    fi

    if [[ "${#ADDED[@]}" -gt 0 ]] && [[ -d "${REPO_ROOT}/.git" ]]; then
        echo
        log_step "Próximos pasos"
        log_info "1. Revisa QUÉ se agregó (imprescindible antes de publicar):"
        log_info "     git status --short"
        log_info "     git diff"
        log_info "2. Comprueba que no se versionan archivos pesados o privados:"
        log_info "     git status --short | awk '\$1==\"A\"{print \$2}'"
        log_info "3. Si algo no debería ir al repo, quítalo de chezmoi:"
        log_info "     chezmoi --source "$REPO_ROOT" forget <ruta>   (p. ej. chezmoi forget ~/.config/gh)"
        log_info "4. Confirma y sube:"
        log_info "     git add -A && git commit -m 'capturar configuraciones de $(hostname)' && git push"
        echo
        log_info "estado actual del repo:"
        git -C "$REPO_ROOT" status --short 2>/dev/null | head -30 | sed 's/^/      /' || true
    fi
    return 0
}

main "$@"
