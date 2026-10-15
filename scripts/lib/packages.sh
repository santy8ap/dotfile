#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# packages.sh — lectura de las listas, filtrado por hardware e instalación.
#
# Estrategia:
#   1. Se cargan de una sola vez los paquetes disponibles en los repos
#      oficiales (`pacman -Slq`) y los ya instalados (`pacman -Qq`).
#   2. Cada entrada de packages/*.txt se filtra por: lista de ignorados,
#      etiquetas `hw:` y si ya está instalada.
#   3. Lo que no existe en repos oficiales se resuelve contra AUR con paru.
#   4. Se instala en una sola transacción; si falla, se reintenta uno a uno
#      para identificar al culpable y no perder el resto.
# ---------------------------------------------------------------------------

[[ -n "${_DOTFILE_PACKAGES_SH:-}" ]] && return 0
_DOTFILE_PACKAGES_SH=1

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/hardware.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/hardware.sh"

declare -A PKG_OFFICIAL=()
declare -A PKG_INSTALLED=()
declare -A PKG_IGNORED=()
declare -A PKG_MISSING=()
declare -A PKG_SKIPPED_HW=()
AUR_HELPER=""
_PKG_CACHE_READY="no"

# --- Carga de catálogos ----------------------------------------------------
pkg_load_catalogs() {
    [[ "$_PKG_CACHE_READY" == "yes" ]] && return 0

    if ! have pacman; then
        log_error "pacman no existe: esto no parece Arch/CachyOS"
        return 1
    fi

    log_debug "cargando catálogo de repos oficiales (pacman -Slq)"
    local name
    while read -r name; do
        [[ -n "$name" ]] && PKG_OFFICIAL["$name"]=1
    done < <(pacman -Slq 2> /dev/null || true)

    log_debug "cargando paquetes instalados (pacman -Qq)"
    while read -r name; do
        [[ -n "$name" ]] && PKG_INSTALLED["$name"]=1
    done < <(pacman -Qq 2> /dev/null || true)

    log_debug "cargando lista de ignorados"
    local ignored_file="${PACKAGES_DIR}/ignorar.txt"
    if [[ -f "$ignored_file" ]]; then
        local line
        while read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | tr -d '[:space:]')"
            [[ -n "$line" ]] && PKG_IGNORED["$line"]=1
        done < "$ignored_file"
    fi

    _PKG_CACHE_READY="yes"
    log_debug "catálogos listos: ${#PKG_OFFICIAL[@]} disponibles, ${#PKG_INSTALLED[@]} instalados"
    return 0
}

pkg_is_official()  { [[ -n "${PKG_OFFICIAL[$1]:-}" ]]; }
pkg_is_installed() { [[ -n "${PKG_INSTALLED[$1]:-}" ]]; }
pkg_is_ignored()   { [[ -n "${PKG_IGNORED[$1]:-}" ]]; }

# --- Helper de AUR ---------------------------------------------------------
pkg_detect_aur_helper() {
    [[ -n "$AUR_HELPER" ]] && { printf '%s' "$AUR_HELPER"; return 0; }
    local h
    for h in paru yay pacaur; do
        if have "$h"; then AUR_HELPER="$h"; printf '%s' "$AUR_HELPER"; return 0; fi
    done
    AUR_HELPER=""
    return 1
}

# pkg_ensure_aur_helper — instala paru si no hay helper de AUR.
pkg_ensure_aur_helper() {
    if pkg_detect_aur_helper > /dev/null; then
        log_ok "helper de AUR disponible: $AUR_HELPER"
        return 0
    fi

    if pkg_is_official "paru"; then
        log_info "instalando paru desde los repos oficiales"
        run_root pacman -S --needed --noconfirm paru && { AUR_HELPER="paru"; return 0; }
    fi

    log_info "compilando paru desde AUR (necesita base-devel y git)"
    run_root pacman -S --needed --noconfirm base-devel git sudo || return 1

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se clonararía y compilaría paru desde https://aur.archlinux.org/paru.git"
        AUR_HELPER="paru"
        return 0
    fi

    local build_dir
    build_dir="$(mktemp -d)"
    # Compilar como usuario normal: makepkg se niega a correr como root.
    local build_user="${SUDO_USER:-$(id -un)}"
    local rc=0
    (
        cd "$build_dir" \
        && git clone --depth 1 https://aur.archlinux.org/paru.git \
        && cd paru \
        && if [[ "$(id -un)" == "root" ]]; then
               sudo -u "$build_user" makepkg -si --noconfirm --needed
           else
               makepkg -si --noconfirm --needed
           fi
    ) >> "$LOG_FILE" 2>&1 || rc=$?
    rm -rf "$build_dir"

    if [[ "$rc" -eq 0 ]] && have paru; then
        AUR_HELPER="paru"
        log_ok "paru compilado e instalado"
        return 0
    fi

    log_error "no se pudo instalar un helper de AUR; los paquetes de AUR se omitirán"
    add_warning "Sin helper de AUR (paru). Instala AUR a mano o revisa el log: $LOG_FILE"
    return 1
}

# --- Lectura de listas -----------------------------------------------------
# pkg_parse_list <archivo>
# Imprime una línea por paquete: "<nombre>\t<etiquetas hw>"
pkg_parse_list() {
    local file="$1" line name comment tags
    [[ -f "$file" ]] || { log_warn "no existe la lista: $file"; return 1; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Quitar \r de archivos editados en Windows y espacios sobrantes
        line="${line%$'\r'}"
        [[ -z "${line// }" ]] && continue
        # Línea de comentario completa
        [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue

        comment=""
        if [[ "$line" == *"#"* ]]; then
            comment="${line#*#}"
            name="${line%%#*}"
        else
            name="$line"
        fi
        name="$(echo "$name" | tr -d '[:space:]')"
        [[ -z "$name" ]] && continue

        # Etiqueta hw: se toma como la primera palabra tras "hw:" (puede llevar
        # comas: "hw:amd,intel"). hw_matches() entiende ese formato.
        tags=""
        if [[ "$comment" == *"hw:"* ]]; then
            tags="${comment#*hw:}"
            tags="${tags%%[[:space:]]*}"
        fi

        printf '%s\t%s\n' "$name" "$tags"
    done < "$file"
}

# pkg_select <archivo> [--with-ignored] [--all]
# Imprime los nombres que SÍ se deben instalar (filtrados por hw e ignorados).
# `--all` incluye también los ya instalados (útil para --needed/reparar).
pkg_select() {
    local file="$1"; shift || true
    local with_ignored="no" include_installed="no"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-ignored) with_ignored="yes" ;;
            --all)          include_installed="yes" ;;
        esac
        shift
    done

    pkg_load_catalogs || return 1
    [[ -n "$HW_TAGS" ]] || hw_detect

    local name tags
    while IFS=$'\t' read -r name tags; do
        [[ -n "$name" ]] || continue

        if is_false "$with_ignored" && pkg_is_ignored "$name"; then
            log_debug "omitido (está en ignorar.txt): $name"
            continue
        fi

        if ! hw_matches "$tags"; then
            PKG_SKIPPED_HW["$name"]="$tags"
            log_debug "omitido (hw:$tags no coincide con [$HW_TAGS]): $name"
            continue
        fi

        if [[ "$include_installed" == "no" ]] && pkg_is_installed "$name"; then
            log_debug "ya instalado: $name"
            continue
        fi

        printf '%s\n' "$name"
    done < <(pkg_parse_list "$file")
}

# --- Instalación -----------------------------------------------------------
# pkg_split_by_source < <lista>  -> rellena PKG_FROM_OFFICIAL[] y PKG_FROM_AUR[]
declare -a PKG_FROM_OFFICIAL=()
declare -a PKG_FROM_AUR=()
declare -a PKG_UNAVAILABLE=()

pkg_classify() { # recibe nombres por stdin
    PKG_FROM_OFFICIAL=()
    PKG_FROM_AUR=()
    PKG_UNAVAILABLE=()
    local name
    while read -r name; do
        [[ -n "$name" ]] || continue
        if pkg_is_official "$name"; then
            PKG_FROM_OFFICIAL+=("$name")
        elif [[ -n "$AUR_HELPER" ]]; then
            PKG_FROM_AUR+=("$name")
        else
            PKG_UNAVAILABLE+=("$name")
        fi
    done
}

# pkg_exists_aur <nombre> — consulta puntual (solo para los pocos de AUR)
pkg_exists_aur() {
    [[ -n "$AUR_HELPER" ]] || return 1
    "$AUR_HELPER" -Si "$1" > /dev/null 2>&1
}

# pkg_verify_aur — descarta de PKG_FROM_AUR los que no existen en AUR
pkg_verify_aur() {
    [[ "${#PKG_FROM_AUR[@]}" -gt 0 ]] || return 0
    local kept=() name
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se comprobarían ${#PKG_FROM_AUR[@]} nombres en AUR; no se consulta la red"
        return 0
    fi
    log_info "verificando ${#PKG_FROM_AUR[@]} paquete(s) contra AUR..."
    for name in "${PKG_FROM_AUR[@]}"; do
        if pkg_exists_aur "$name"; then
            kept+=("$name")
        else
            PKG_MISSING["$name"]="no está en los repos oficiales ni en AUR"
            log_warn "no existe en AUR: $name (se omite)"
        fi
    done
    PKG_FROM_AUR=("${kept[@]}")
}

_pacman_flags() {
    local -n _out=$1
    _out=(-S --needed --asexplicit)
    is_true "$YES" && _out+=(--noconfirm)
    is_true "$VERBOSE" || _out+=(--noprogressbar)
}

# pkg_install_selected — instala lo clasificado (oficiales primero, luego AUR)
pkg_install_selected() {
    local total=$(( ${#PKG_FROM_OFFICIAL[@]} + ${#PKG_FROM_AUR[@]} ))
    if [[ "$total" -eq 0 ]]; then
        log_ok "no hay nada nuevo que instalar"
        return 0
    fi

    log_info "a instalar: ${#PKG_FROM_OFFICIAL[@]} oficial(es), ${#PKG_FROM_AUR[@]} de AUR"
    if is_true "$DRY_RUN"; then
        local p
        for p in "${PKG_FROM_OFFICIAL[@]+"${PKG_FROM_OFFICIAL[@]}"}"; do log_cmd "(dry-run) pacman -S $p"; done
        for p in "${PKG_FROM_AUR[@]+"${PKG_FROM_AUR[@]}"}";       do log_cmd "(dry-run) $AUR_HELPER -S $p"; done
        return 0
    fi

    local flags=()
    _pacman_flags flags

    local rc=0
    if [[ "${#PKG_FROM_OFFICIAL[@]}" -gt 0 ]]; then
        log_step "Instalando paquetes oficiales"
        if ! run_root pacman "${flags[@]}" "${PKG_FROM_OFFICIAL[@]}"; then
            log_warn "la transacción completa falló; se reintenta uno a uno"
            rc=1
            local p
            for p in "${PKG_FROM_OFFICIAL[@]}"; do
                if ! run_root pacman "${flags[@]}" "$p"; then
                    PKG_MISSING["$p"]="falló la instalación con pacman"
                    log_error "no se pudo instalar: $p"
                fi
            done
        fi
    fi

    if [[ "${#PKG_FROM_AUR[@]}" -gt 0 ]]; then
        log_step "Instalando paquetes de AUR con $AUR_HELPER"
        local aur_flags=(-S --needed --asexplicit)
        is_true "$YES" && aur_flags+=(--noconfirm)
        if ! run "$AUR_HELPER" "${aur_flags[@]}" "${PKG_FROM_AUR[@]}"; then
            log_warn "la transacción de AUR falló; se reintenta uno a uno"
            rc=1
            local p
            for p in "${PKG_FROM_AUR[@]}"; do
                if ! run "$AUR_HELPER" "${aur_flags[@]}" "$p"; then
                    PKG_MISSING["$p"]="falló la instalación desde AUR"
                    log_error "no se pudo instalar: $p"
                fi
            done
        fi
    fi

    # Refrescar el catálogo de instalados para los pasos siguientes
    _PKG_CACHE_READY="no"
    pkg_load_catalogs > /dev/null 2>&1 || true

    return "$rc"
}

# pkg_report — resumen legible de lo que pasó
pkg_report() {
    local k
    if [[ "${#PKG_SKIPPED_HW[@]}" -gt 0 ]]; then
        log_info "omitidos por hardware (${#PKG_SKIPPED_HW[@]}):"
        for k in "${!PKG_SKIPPED_HW[@]}"; do printf '      - %s (hw:%s)\n' "$k" "${PKG_SKIPPED_HW[$k]}"; done
    fi
    if [[ "${#PKG_MISSING[@]}" -gt 0 ]]; then
        log_warn "paquetes con problemas (${#PKG_MISSING[@]}):"
        for k in "${!PKG_MISSING[@]}"; do printf '      - %s: %s\n' "$k" "${PKG_MISSING[$k]}"; done
        add_warning "${#PKG_MISSING[@]} paquete(s) no se pudieron instalar; revisa el resumen arriba"
    fi
    return 0
}

# pkg_install_from_file <archivo> [opciones de pkg_select]
pkg_install_from_file() {
    local file="$1"; shift || true
    [[ -f "$file" ]] || { log_warn "no existe $file"; return 0; }

    log_step "Lista: $(basename -- "$file")"
    # pkg_select se ejecuta en una sustitución de proceso (subshell): cargar
    # el catálogo primero evita que pkg_classify vea arrays vacíos en el padre.
    pkg_load_catalogs || return 1
    pkg_classify < <(pkg_select "$file" "$@")
    pkg_verify_aur
    pkg_install_selected
    return 0
}
