#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# packages-update.sh — regenera las listas de paquetes desde el sistema vivo.
#
#   ./scripts/packages-update.sh            # actualizar oficiales.txt y aur.txt
#   ./scripts/packages-update.sh --diff     # solo mostrar qué cambiaría
#   ./scripts/packages-update.sh --write    # escribir sin preguntar (CI/automatización)
#
# Qué se genera:
#   packages/oficiales.txt : `pacman -Qeqn`  (explícitos de repos oficiales)
#   packages/aur.txt       : `pacman -Qeqm`  (explícitos instalados desde AUR)
#   packages/explicitos.txt: `pacman -Qeq`   (referencia: todos los explícitos)
#   packages/grupos.txt    : `pacman -Qgq`   (grupos instalados, informativo)
#
# Los comentarios y etiquetas `# hw:...` de las listas actuales se CONSERVAN:
# solo se agregan/quitan paquetes, no se pierde tu documentación.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

DIFF_ONLY="no"; WRITE="no"

# extrae "<paquete> -> comentario" del archivo actual, para conservarlos
_load_notes() { # <archivo> -> llena el array global NOTES
    local file="$1" line name note
    NOTES=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
        if [[ "$line" == *"#"* ]]; then
            note="${line#*#}"
            name="${line%%#*}"
            name="$(echo "$name" | tr -d '[:space:]')"
            note="$(printf '%s' "$note" | sed 's/[[:space:]]*$//')"
            NOTES+=("${name}=#${note}")
        else
            name="$(echo "$line" | tr -d '[:space:]')"
            [[ -n "$name" ]] && NOTES+=("${name}=")
        fi
    done < "$file"
}

_note_for() { # <paquete>
    local entry
    for entry in ${NOTES[@]+"${NOTES[@]}"}; do
        # cada entrada es "paquete=#comentario" (el comentario puede tener espacios)
        if [[ "${entry%%=*}" == "$1" ]]; then
            printf '%s' "${entry#*=}"
            return 0
        fi
    done
    printf ''
}

_render_list() { # <archivo-actual> <cabecera>   (los nombres llegan por stdin)
    local current="$1" header="${2:-}"
    _load_notes "$current"

    local -a names=()
    local n
    while IFS= read -r n; do
        n="$(echo "$n" | tr -d '[:space:]')"
        [[ -n "$n" ]] && names+=("$n")
    done

    # cabecera del archivo actual (si existe) o la proporcionada
    if [[ -f "$current" ]]; then
        sed -n '1,/^[[:space:]]*$/{ /^[[:space:]]*#/p }' "$current"
    else
        printf '%s\n' "$header"
    fi
    echo

    local note
    for n in $(printf '%s\n' "${names[@]}" | LC_ALL=C sort -u); do
        note="$(_note_for "$n")"
        if [[ -n "$note" ]]; then
            printf '%-34s%s\n' "$n" "$note"
        else
            printf '%s\n' "$n"
        fi
    done
}

_show_diff() { # <archivo> <nuevo-contenido>
    local file="$1" new="$2"
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$new" > "$tmp"
    if [[ ! -f "$file" ]]; then
        log_info "$file no existe; se crearía con $(grep -cve '^\s*#' -e '^\s*$' "$tmp") paquetes"
        diff -u /dev/null "$tmp" | sed 's/^/      /' | head -40 || true
    elif diff -q "$file" "$tmp" > /dev/null 2>&1; then
        log_ok "$file sin cambios"
    else
        log_warn "$file cambiaría:"
        diff -u "$file" "$tmp" | sed 's/^/      /' | head -60 || true
    fi
    rm -f "$tmp"
}

main() {
    if ! have pacman; then
        die "pacman no existe: este script es solo para Arch/CachyOS"
    fi

    case "${1:-}" in
        --diff|-d)  DIFF_ONLY="yes" ;;
        --write|-w) WRITE="yes" ;;
        --help|-h)  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    esac

    log_step "Leyendo el sistema de paquetes"
    local -a official=() aur=() explicit=() groups=()
    mapfile -t official < <(pacman -Qeqn 2> /dev/null | LC_ALL=C sort -u)
    mapfile -t aur      < <(pacman -Qeqm 2> /dev/null | LC_ALL=C sort -u)
    mapfile -t explicit < <(pacman -Qeq  2> /dev/null | LC_ALL=C sort -u)
    mapfile -t groups   < <(pacman -Qgq  2> /dev/null | LC_ALL=C sort -u)

    log_info "oficiales explícitos : ${#official[@]}"
    log_info "AUR explícitos       : ${#aur[@]}"
    log_info "grupos instalados    : ${#groups[@]}"

    if [[ "${#official[@]}" -eq 0 ]]; then
        die "pacman no devolvió paquetes explícitos; algo va mal"
    fi

    local hdr_official hdr_aur
    hdr_official="# Generado por scripts/packages-update.sh el $(date '+%Y-%m-%d %H:%M')
# Paquetes explícitos de los repos oficiales (pacman -Qeqn)."
    hdr_aur="# Generado por scripts/packages-update.sh el $(date '+%Y-%m-%d %H:%M')
# Paquetes explícitos instalados desde AUR (pacman -Qeqm)."

    local new_official new_aur
    new_official="$(_render_list "${PACKAGES_DIR}/oficiales.txt" < <(printf '%s\n' "${official[@]}") "$hdr_official")"
    new_aur="$(_render_list "${PACKAGES_DIR}/aur.txt" < <(printf '%s\n' "${aur[@]}") "$hdr_aur")"

    echo
    log_step "Cambios en packages/oficiales.txt"
    _show_diff "${PACKAGES_DIR}/oficiales.txt" "$new_official"
    echo
    log_step "Cambios en packages/aur.txt"
    _show_diff "${PACKAGES_DIR}/aur.txt" "$new_aur"

    if [[ "$DIFF_ONLY" == "yes" ]]; then
        log_info "--diff: no se escribe nada"
        return 0
    fi

    if [[ "$WRITE" != "yes" ]] && ! confirm "¿Guardar estas listas en el repo?" si; then
        log_info "listas sin guardar"
        return 0
    fi

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se escribirían packages/oficiales.txt y packages/aur.txt"
        return 0
    fi

    printf '%s\n' "$new_official" > "${PACKAGES_DIR}/oficiales.txt"
    printf '%s\n' "$new_aur"      > "${PACKAGES_DIR}/aur.txt"
    {
        printf '%s\n' "# Referencia: todos los paquetes explícitos (pacman -Qeq), $(date '+%Y-%m-%d %H:%M')"
        printf '%s\n' "# No se usa para instalar; sirve para comparar y auditar."
        printf '%s\n' "${explicit[@]}"
    } > "${PACKAGES_DIR}/explicitos.txt"
    {
        printf '%s\n' "# Grupos de paquetes instalados (pacman -Qgq), $(date '+%Y-%m-%d %H:%M')"
        printf '%s\n' "# Informativo: no se instala por grupos, solo por paquetes."
        printf '%s\n' "${groups[@]}"
    } > "${PACKAGES_DIR}/grupos.txt"

    log_ok "listas actualizadas"
    log_info "revisa los cambios: git diff packages/"
    log_info "y confirma: git add packages && git commit -m 'actualizar listas de paquetes'"
}

main "$@"
