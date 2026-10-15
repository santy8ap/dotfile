#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 60-theming.sh — apariencia del escritorio (GTK, iconos, cursores, fuentes).
#
# Casi todo va por gsettings/dconf. Hace falta una sesión con DBus; si no la
# hay, se aplica lo que se puede por archivo y el resto se deja para cuando
# inicies sesión (./install.sh theming --force).
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

HAVE_DBUS="no"

# _gset <schema> <clave> <valor...>
# Solo toca la clave si el schema y la clave existen de verdad (así no revienta
# en instalaciones sin los esquemas de GNOME).
_gset() {
    local schema="$1" key="$2"; shift 2
    local value="$*"

    if [[ "$HAVE_DBUS" != "yes" ]]; then
        log_debug "sin DBus: se omite gsettings $schema $key"
        return 1
    fi
    if ! gsettings list-keys "$schema" > /dev/null 2>&1; then
        log_debug "schema no disponible: $schema"
        return 1
    fi
    if ! gsettings list-keys "$schema" 2> /dev/null | grep -qx "$key"; then
        log_debug "clave no existe en $schema: $key"
        return 1
    fi

    local current
    current="$(gsettings get "$schema" "$key" 2> /dev/null || true)"
    # gsettings get devuelve el valor con formato GVariant (comillas simples)
    if [[ "$current" == "'${value}'" || "$current" == "$value" ]]; then
        log_ok "ya configurado: $schema $key = $value"
        return 0
    fi

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) gsettings set $schema $key '$value'"
        return 0
    fi
    if run gsettings set "$schema" "$key" "$value"; then
        log_ok "$schema $key = $value"
    else
        log_warn "no se pudo aplicar $schema $key"
        return 1
    fi
}

_theme_gtk() {
    log_step "Tema GTK / iconos / cursor"
    _gset org.gnome.desktop.interface gtk-theme      "$DOTFILE_GTK_THEME"   || true
    _gset org.gnome.desktop.interface color-scheme   "$DOTFILE_COLOR_SCHEME" || true
    _gset org.gnome.desktop.interface icon-theme     "$DOTFILE_ICON_THEME"  || true
    _gset org.gnome.desktop.interface cursor-theme   "$DOTFILE_CURSOR_THEME" || true
    _gset org.gnome.desktop.interface cursor-size    "$DOTFILE_CURSOR_SIZE" || true
    _gset org.gnome.desktop.wm.preferences theme     "$DOTFILE_GTK_THEME"   || true

    if [[ -n "$DOTFILE_FONT_NAME" ]]; then
        _gset org.gnome.desktop.interface font-name "$DOTFILE_FONT_NAME" || true
    fi
    if [[ -n "$DOTFILE_FONT_MONO" ]]; then
        _gset org.gnome.desktop.interface monospace-font-name "$DOTFILE_FONT_MONO" || true
    fi

    # GTK2 (algunas apps viejas siguen leyéndolo)
    local gtkrc="${HOME}/.gtkrc-2.0"
    if [[ ! -e "$gtkrc" ]] && have gtk-theme-switch2 2> /dev/null; then
        log_debug "gtk-theme-switch2 presente pero sin ~/.gtkrc-2.0"
    fi
    log_info "GTK2: si alguna app se ve mal, crea ~/.gtkrc-2.0 y captúrala con 'make capturar'"
}

_theme_papirus_folders() {
    have papirus-folders || { log_debug "papirus-folders no instalado"; return 0; }

    local color="${DOTFILE_PAPIRUS_COLOR:-}"
    local theme="$DOTFILE_ICON_THEME"

    if [[ -z "$color" ]]; then
        log_info "DOTFILE_PAPIRUS_COLOR vacío: no se recolorean las carpetas de Papirus"
        log_info "colores disponibles:  papirus-folders --list"
        log_info "ejemplo: DOTFILE_PAPIRUS_COLOR=catppuccin-mocha-green ./install.sh theming --force"
        return 0
    fi

    # Verificar que el color existe en esta versión de papirus-folders
    if ! papirus-folders --list 2> /dev/null | grep -qx "$color"; then
        log_warn "el color '$color' no está disponible en papirus-folders"
        log_info "colores disponibles: $(papirus-folders --list 2>/dev/null | paste -sd', ' - || echo 'no se pudieron listar')"
        add_warning "papirus-folders: color '$color' inexistente."
        return 0
    fi

    if is_true "$DRY_RUN"; then
        run papirus-folders -C "$color" --theme "$theme"
        return 0
    fi
    if run papirus-folders -C "$color" --theme "$theme"; then
        log_ok "carpetas Papirus en color '$color' con tema '$theme'"
    else
        log_warn "papirus-folders falló"
    fi
}

_theme_cursor() {
    log_step "Cursor a nivel de sistema"
    # hypr/hyprland/env.lua ya fija XCURSOR_THEME/XCURSOR_SIZE y
    # hyprland/execs.lua ejecuta `hyprctl setcursor`. Aquí dejamos el índice de
    # cursores listo para apps X11/XWayland.
    local idx="${HOME}/.icons/default/index.theme"
    if [[ -d "${HOME}/.icons/${DOTFILE_CURSOR_THEME}" || -d "/usr/share/icons/${DOTFILE_CURSOR_THEME}" ]]; then
        if [[ -f "$idx" ]] && grep -q "^Inherits=${DOTFILE_CURSOR_THEME}$" "$idx" 2> /dev/null; then
            log_ok "cursor predeterminado ya es ${DOTFILE_CURSOR_THEME}"
            return 0
        fi
        if confirm "¿Fijar el cursor '${DOTFILE_CURSOR_THEME}' para apps XWayland (~/.icons/default/index.theme)?" si; then
            local tmp; tmp="$(mktemp)"
            printf '[Icon Theme]\nInherits=%s\n' "$DOTFILE_CURSOR_THEME" > "$tmp"
            if is_true "$DRY_RUN"; then
                log_info "(dry-run) se escribiría $idx"
            else
                mkdir -p "$(dirname -- "$idx")"
                install -D -m 0644 "$tmp" "$idx" && log_ok "cursor predeterminado: ${DOTFILE_CURSOR_THEME}"
            fi
            rm -f "$tmp"
        fi
    else
        log_warn "el tema de cursor '${DOTFILE_CURSOR_THEME}' no está instalado"
        add_warning "Tema de cursor '${DOTFILE_CURSOR_THEME}' no encontrado en ~/.icons ni /usr/share/icons."
    fi

    # Refrescar el cursor de la sesión Hyprland en curso, si existe
    if have hyprctl && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        run_or_warn hyprctl setcursor "$DOTFILE_CURSOR_THEME" "$DOTFILE_CURSOR_SIZE"
    fi
}

_theme_xdg_dirs() {
    log_step "Carpetas XDG (Escritorio, Descargas, Imágenes...)"
    local dirs_file="${HOME}/.config/user-dirs.dirs"

    if [[ ! -f "$dirs_file" ]]; then
        log_info "no existe $dirs_file (lo aplica la etapa 'dotfiles')"
        return 0
    fi

    # Crear las carpetas declaradas. Importante: caelestia busca los fondos en
    # $XDG_PICTURES_DIR/Wallpapers (por defecto ~/Imágenes/Wallpapers).
    local line path
    local -a created=()
    while IFS= read -r line; do
        [[ "$line" == XDG_* ]] || continue
        path="${line#*=}"
        path="${path%\"}"; path="${path#\"}"
        path="${path/\$HOME/$HOME}"
        [[ -n "$path" ]] || continue
        if [[ ! -d "$path" ]]; then
            if is_true "$DRY_RUN"; then
                log_info "(dry-run) mkdir -p $path"
            else
                mkdir -p "$path" 2> /dev/null && created+=("$path")
            fi
        fi
    done < "$dirs_file"

    if [[ "${#created[@]}" -gt 0 ]]; then
        log_ok "carpetas creadas: ${created[*]}"
    else
        log_ok "todas las carpetas XDG existen"
    fi

    # Carpeta de fondos de pantalla
    if [[ ! -d "$DOTFILE_WALLPAPER_DIR" ]]; then
        if is_true "$DRY_RUN"; then
            log_info "(dry-run) mkdir -p $DOTFILE_WALLPAPER_DIR"
        else
            mkdir -p "$DOTFILE_WALLPAPER_DIR" && log_ok "creada: $DOTFILE_WALLPAPER_DIR"
        fi
        add_warning "La carpeta de wallpapers está vacía: copia tus fondos a $DOTFILE_WALLPAPER_DIR"
    fi
}

_theme_fonts() {
    log_step "Fuentes"
    if have fc-cache; then
        run_or_warn fc-cache -f
    fi
    if have fc-list; then
        local fam
        for fam in "JetBrainsMono Nerd Font" "Noto Sans" "DejaVu Sans"; do
            if fc-list 2> /dev/null | grep -qi "$fam"; then
                log_ok "fuente presente: $fam"
            else
                log_warn "fuente ausente: $fam"
                add_warning "No está instalada la fuente '$fam' (revisa ttf-jetbrains-mono-nerd / noto-fonts / ttf-dejavu)."
            fi
        done
    fi
}

_theme_qt() {
    log_step "Qt"
    # env.lua fija QT_QPA_PLATFORMTHEME=qtengine; el estilo (darkly) y los
    # detalles viven en ~/.config/qtengine/. Ese archivo no está en el repo:
    # captúralo con 'make capturar' si quieres conservarlo.
    if have qtengine 2> /dev/null || [[ -d "${HOME}/.config/qtengine" ]]; then
        if [[ -d "${HOME}/.config/qtengine" ]]; then
            log_ok "existe ~/.config/qtengine"
            log_info "si no está en el repo, captúralo: make capturar"
        else
            log_warn "no existe ~/.config/qtengine: las apps Qt usarán el estilo por defecto"
            add_warning "Falta ~/.config/qtengine (estilo Qt). Configúralo con qtengine y captura con 'make capturar'."
        fi
    else
        log_info "qtengine no instalado; se omite (paquetes: qtengine, darkly-bin)"
    fi
}

main() {
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        HAVE_DBUS="yes"
        log_ok "DBus de sesión disponible: se pueden aplicar gsettings"
    else
        HAVE_DBUS="no"
        log_warn "sin DBUS_SESSION_BUS_ADDRESS: gsettings no funcionará"
        add_warning "Sin sesión DBus no se aplicó el tema GTK. Al iniciar sesión: ./install.sh theming --force"
    fi

    _theme_gtk
    echo
    _theme_papirus_folders
    echo
    _theme_cursor
    echo
    _theme_qt
    echo
    _theme_fonts
    echo
    _theme_xdg_dirs

    if [[ "$HAVE_DBUS" != "yes" ]]; then
        log_warn "GTK/gsettings pendientes; repite esta etapa dentro de Hyprland"
        return 75
    fi
    log_ok "apariencia terminada"
}

run_step "theming"
