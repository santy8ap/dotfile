#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lint.sh — comprobaciones estáticas del repo (no toca el sistema).
#
#   ./scripts/lint.sh          # todo
#   ./scripts/lint.sh --quick  # solo sintaxis (sin shellcheck)
#
# Comprueba:
#    1. Sintaxis bash de todos los scripts
#    2. shellcheck (si está instalado)
#    3. JSON válidos (jq)
#    4. Sintaxis fish (fish -n)
#    5. Sintaxis Lua (luac -p)
#    6. Que no queden rutas /home/<usuario> hardcodeadas en home/
#    7. Higiene: sin .bak versionados, sin secretos evidentes, sin archivos enormes
#    8. Listas de paquetes bien formadas y coherentes
#    9. Estructura del instalador (run_step, ejecutables, etapas declaradas)
#   10. Estado fuente de chezmoi (.chezmoiroot, .chezmoiignore, plantillas)
#
# Sale con código 1 si hay errores. Los avisos no fallan.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

QUICK="no"
N_ERR=0
N_WARN=0

_fail() { N_ERR=$(( N_ERR + 1 ));  log_error "$*"; }
_warn() { N_WARN=$(( N_WARN + 1 )); log_warn "$*"; }
_ok()   { log_ok "$*"; }

# Archivos ejecutables con shebang bash/sh dentro del repo
_scripts_con_shebang() {
    find "$REPO_ROOT" -type f -not -path '*/.git/*' 2> /dev/null | sort | while IFS= read -r f; do
        case "$f" in *.md|*.txt|*.json|*.png|*.jpg|*.ico) continue ;; esac
        # ERE no admite (?:...); usamos grupos de alternancia normales.
        head -1 "$f" 2> /dev/null \
            | grep -qE '^#![[:space:]]*/(usr/)?bin/(env[[:space:]]+)?(bash|sh|dash)([[:space:]]|$)' \
            && printf '%s\n' "$f"
    done
}

_lint_bash_syntax() {
    log_step "1. Sintaxis bash"
    local f rc=0 n=0
    while IFS= read -r f; do
        n=$(( n + 1 ))
        if ! bash -n "$f" 2>> "$LOG_FILE"; then
            _fail "sintaxis inválida: ${f#"${REPO_ROOT}/"}"
            bash -n "$f" 2>&1 | head -5 | sed 's/^/        /' || true
            rc=1
        fi
    done < <(_scripts_con_shebang)
    [[ "$rc" -eq 0 ]] && _ok "${n} script(s) con sintaxis válida"
    return 0
}

_lint_shellcheck() {
    log_step "2. shellcheck"
    if [[ "$QUICK" == "yes" ]]; then
        log_info "--quick: se omite shellcheck"
        return 0
    fi
    if ! have shellcheck; then
        _warn "shellcheck no instalado (Arch: sudo pacman -S shellcheck); se omite"
        return 0
    fi

    local -a files=()
    mapfile -t files < <(_scripts_con_shebang)
    if [[ "${#files[@]}" -eq 0 ]]; then
        _warn "no se encontraron scripts para analizar"
        return 0
    fi

    local tmp out rc=0
    tmp="$(mktemp)"
    (
        cd "$REPO_ROOT" || exit 1
        shellcheck --severity=warning --shell=bash --format=tty "${files[@]#"${REPO_ROOT}/"}"
    ) > "$tmp" 2>&1 || rc=$?

    if [[ -s "$tmp" ]]; then
        out="$(head -80 "$tmp")"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
    fi
    rm -f "$tmp"

    if [[ "$rc" -eq 0 ]]; then
        _ok "shellcheck: sin avisos de severidad 'warning' o superior"
    else
        # Distinguir errores graves de avisos menores
        local tmp2 rc2=0
        tmp2="$(mktemp)"
        (
            cd "$REPO_ROOT" || exit 1
            shellcheck --severity=error --shell=bash "${files[@]#"${REPO_ROOT}/"}"
        ) > "$tmp2" 2>&1 || rc2=$?
        rm -f "$tmp2"
        if [[ "$rc2" -eq 0 ]]; then
            _warn "shellcheck: hay avisos menores (ver arriba) pero ningún error grave"
        else
            _fail "shellcheck reporta errores graves (ver arriba)"
        fi
    fi
    return 0
}

_lint_json() {
    log_step "3. JSON"
    if ! have jq; then
        _warn "jq no instalado; no se validan los JSON"
        return 0
    fi
    local f rc=0 n=0
    while IFS= read -r f; do
        if grep -q '{{' "$f" 2> /dev/null; then
            log_debug "plantilla, se omite: ${f#"${REPO_ROOT}/"}"
            continue
        fi
        n=$(( n + 1 ))
        if ! jq empty "$f" > /dev/null 2>&1; then
            _fail "JSON inválido: ${f#"${REPO_ROOT}/"}"
            jq empty "$f" 2>&1 | head -3 | sed 's/^/        /' || true
            rc=1
        fi
    done < <(find "$REPO_ROOT" -type f -name '*.json' -not -path '*/.git/*' -not -name '*.tmpl' 2> /dev/null | sort)
    [[ "$rc" -eq 0 ]] && _ok "${n} JSON válido(s)"
    return 0
}

_lint_fish() {
    log_step "4. fish"
    if ! have fish; then
        _warn "fish no instalado; no se valida la sintaxis de los .fish"
        return 0
    fi
    local f rc=0 n=0
    while IFS= read -r f; do
        if grep -q '{{' "$f" 2> /dev/null; then
            log_debug "plantilla, se omite: ${f#"${REPO_ROOT}/"}"
            continue
        fi
        n=$(( n + 1 ))
        if ! fish -n "$f" > /dev/null 2>&1; then
            _fail "sintaxis fish inválida: ${f#"${REPO_ROOT}/"}"
            fish -n "$f" 2>&1 | head -3 | sed 's/^/        /' || true
            rc=1
        fi
    done < <(find "$REPO_ROOT/home" -type f -name '*.fish' -not -name '*.tmpl' 2> /dev/null | sort)
    [[ "$rc" -eq 0 ]] && _ok "${n} archivo(s) fish válido(s)"
    return 0
}

_lint_lua() {
    log_step "5. Lua"
    local luac=""
    if have luac; then luac="luac"
    elif have luac5.4; then luac="luac5.4"
    elif have luac5.3; then luac="luac5.3"
    elif have luajit; then luac="luajit -bl"
    else
        _warn "no hay luac instalado; no se valida Lua (Arch: sudo pacman -S lua)"
        return 0
    fi

    local f rc=0 n=0
    while IFS= read -r f; do
        if grep -q '{{' "$f" 2> /dev/null; then
            log_debug "plantilla, se omite: ${f#"${REPO_ROOT}/"}"
            continue
        fi
        n=$(( n + 1 ))
        if [[ "$luac" == "luajit -bl" ]]; then
            luajit -bl "$f" /dev/null > /dev/null 2>&1 || { _fail "sintaxis Lua inválida: ${f#"${REPO_ROOT}/"}"; rc=1; }
        else
            "$luac" -p "$f" > /dev/null 2>&1 || {
                _fail "sintaxis Lua inválida: ${f#"${REPO_ROOT}/"}"
                "$luac" -p "$f" 2>&1 | head -3 | sed 's/^/        /' || true
                rc=1
            }
        fi
    done < <(find "$REPO_ROOT/home" -type f -name '*.lua' -not -name '*.tmpl' 2> /dev/null | sort)
    [[ "$rc" -eq 0 ]] && _ok "${n} archivo(s) Lua válido(s) con $luac"
    return 0
}

_lint_hardcoded_paths() {
    log_step "6. Rutas hardcodeadas en home/"
    local hits
    hits="$(grep -rIn --exclude='*.tmpl' -E '/home/[A-Za-z0-9_.-]+' "$REPO_ROOT/home" 2> /dev/null || true)"
    if [[ -n "$hits" ]]; then
        local n; n="$(printf '%s\n' "$hits" | wc -l)"
        _fail "${n} ruta(s) /home/<usuario> hardcodeada(s). Deben ir en un .tmpl con {{ .chezmoi.homeDir }}:"
        printf '%s\n' "$hits" | sed "s|${REPO_ROOT}/||" | sed 's/^/        /' | head -15
    else
        _ok "sin rutas de usuario hardcodeadas en home/"
    fi
    return 0
}

_lint_repo_hygiene() {
    log_step "7. Higiene del repo"
    have git || { _warn "git no instalado; se omite"; return 0; }

    local baks
    baks="$(git -C "$REPO_ROOT" ls-files 2> /dev/null | grep -c '\.bak$' || true)"
    if [[ "${baks:-0}" -gt 0 ]]; then
        _fail "${baks} archivo(s) .bak versionados (caelestia los regenera; van en .gitignore)"
        git -C "$REPO_ROOT" ls-files 2> /dev/null | grep '\.bak$' | sed 's/^/        /'
    else
        _ok "sin .bak versionados"
    fi

    local sensitive
    sensitive="$(git -C "$REPO_ROOT" ls-files 2> /dev/null \
        | grep -iE '(^|/)(id_rsa|id_ed25519|id_ecdsa|\.netrc|\.git-credentials|.*\.pem|.*\.key|.*\.p12|.*\.secret)$' || true)"
    if [[ -n "$sensitive" ]]; then
        _fail "archivos sensibles versionados:"
        printf '%s\n' "$sensitive" | sed 's/^/        /'
    else
        _ok "sin archivos con nombre sensible versionados"
    fi

    local big="" f sz
    while IFS= read -r f; do
        [[ -f "${REPO_ROOT}/${f}" ]] || continue
        sz="$(stat -c '%s' "${REPO_ROOT}/${f}" 2> /dev/null || echo 0)"
        if [[ "$sz" -gt 1048576 ]]; then
            big+="${f} ($(( sz / 1048576 )) MB)"$'\n'
        fi
    done < <(git -C "$REPO_ROOT" ls-files 2> /dev/null)
    if [[ -n "$big" ]]; then
        _warn "archivos de más de 1 MB versionados:"
        printf '%s' "$big" | sed 's/^/        /'
    else
        _ok "sin archivos enormes versionados"
    fi
    return 0
}

# Devuelve un nombre de paquete por línea. OJO: `tr -d '[:space:]'` también
# borraría los saltos de línea, así que solo quitamos espacios y tabuladores.
_pkg_names() { # <archivo>
    grep -ve '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" 2> /dev/null \
        | sed 's/[[:space:]]*#.*$//' | tr -d ' \t'
}

_lint_package_lists() {
    log_step "8. Listas de paquetes"
    local f path names dupes bad count
    for f in nucleo oficiales aur ignorar; do
        path="${PACKAGES_DIR}/${f}.txt"
        [[ -f "$path" ]] || { _warn "falta packages/${f}.txt"; continue; }

        names="$(_pkg_names "$path")"
        dupes="$(printf '%s\n' "$names" | sort | uniq -d || true)"
        bad="$(printf '%s\n' "$names" | grep -nE '[^A-Za-z0-9._@+-]' || true)"
        count="$(printf '%s\n' "$names" | grep -c . || true)"

        if [[ -n "$dupes" ]]; then
            _fail "packages/${f}.txt tiene duplicados: $(printf '%s ' $dupes)"
        elif [[ -n "$bad" ]]; then
            _fail "packages/${f}.txt tiene nombres inválidos:"
            printf '%s\n' "$bad" | sed 's/^/        /'
        else
            _ok "packages/${f}.txt: ${count} paquete(s), sin duplicados"
        fi
    done

    if [[ -f "${PACKAGES_DIR}/nucleo.txt" && -f "${PACKAGES_DIR}/ignorar.txt" ]]; then
        local clash
        clash="$(comm -12 \
            <(_pkg_names "${PACKAGES_DIR}/nucleo.txt" | LC_ALL=C sort) \
            <(_pkg_names "${PACKAGES_DIR}/ignorar.txt" | LC_ALL=C sort) || true)"
        if [[ -n "$clash" ]]; then
            _fail "paquetes en nucleo.txt y en ignorar.txt a la vez: $(printf '%s ' $clash)"
        else
            _ok "núcleo e ignorados son coherentes"
        fi
    fi

    # Etiquetas hw: válidas
    local tags_ok="amd intel nvidia laptop desktop framework cachyos multilib"
    local t used
    # Solo en líneas de paquete (no en las cabeceras explicativas)
    used="$(grep -hve '^[[:space:]]*#' "${PACKAGES_DIR}"/*.txt 2> /dev/null \
        | grep -hoE 'hw:[A-Za-z0-9,_-]+' | sed 's/^hw://' | tr ',' '\n' \
        | LC_ALL=C sort -u || true)"
    for t in $used; do
        case " ${tags_ok} " in
            *" ${t} "*) : ;;
            *) _fail "etiqueta hw desconocida: 'hw:${t}' (válidas: ${tags_ok})" ;;
        esac
    done
    [[ -n "$used" ]] && _ok "etiquetas hw: válidas ($(printf '%s ' $used))"
    return 0
}

_lint_steps() {
    log_step "9. Estructura del instalador"
    local f base rc=0
    while IFS= read -r f; do
        base="$(basename -- "$f")"
        grep -q '^run_step ' "$f" || { _fail "${base} no termina en run_step (no marcará su estado)"; rc=1; }
        [[ -x "$f" ]]              || { _warn "${base} no tiene bit de ejecución (chmod +x)"; rc=1; }
        grep -q 'lib/common.sh' "$f" || { _fail "${base} no carga scripts/lib/common.sh"; rc=1; }
        grep -q "$base" "${REPO_ROOT}/install.sh" || { _fail "install.sh no referencia ${base}"; rc=1; }
    done < <(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' | sort)

    for f in install.sh scripts/backup.sh scripts/capture.sh scripts/lint.sh scripts/packages-update.sh; do
        [[ -e "${REPO_ROOT}/${f}" ]] || { _fail "falta ${f}"; rc=1; continue; }
        [[ -x "${REPO_ROOT}/${f}" ]] || { _warn "${f} no es ejecutable"; rc=1; }
    done

    for f in README.md Makefile .gitignore .chezmoiroot .editorconfig config/defaults.env; do
        [[ -e "${REPO_ROOT}/${f}" ]] || { _warn "falta ${f}"; }
    done

    [[ "$rc" -eq 0 ]] && _ok "estructura del instalador correcta"
    return 0
}

_lint_chezmoi() {
    log_step "10. Estado fuente de chezmoi"
    if [[ ! -f "${REPO_ROOT}/.chezmoiroot" ]]; then
        _fail "falta .chezmoiroot: scripts/, docs/ y packages/ se copiarían a \$HOME"
        return 0
    fi
    local root; root="$(tr -d '[:space:]' < "${REPO_ROOT}/.chezmoiroot")"
    if [[ ! -d "${REPO_ROOT}/${root}" ]]; then
        _fail ".chezmoiroot apunta a '${root}/', que no existe"
        return 0
    fi
    _ok ".chezmoiroot -> ${root}/"

    if [[ -f "${REPO_ROOT}/${root}/.chezmoiignore" ]]; then
        _ok "${root}/.chezmoiignore presente"
    else
        _warn "no hay ${root}/.chezmoiignore (los .bak podrían colarse en \$HOME)"
    fi

    # Solo deben usarse variables estándar de chezmoi (o definidas en [data])
    local tmpl vars rc=0
    while IFS= read -r tmpl; do
        vars="$(grep -oE '\{\{[^}]*\}\}' "$tmpl" 2> /dev/null \
            | grep -oE '\.[A-Za-z][A-Za-z0-9_.]*' \
            | grep -vE '^\.(chezmoi\.|homeDir$|username$|hostname$|os$|arch$|kernel$|fqdnHostname$|osRelease\.)' \
            | LC_ALL=C sort -u || true)"
        if [[ -n "$vars" ]]; then
            _warn "${tmpl#"${REPO_ROOT}/"} usa variables no estándar: $(printf '%s ' $vars)"
            _warn "    defínelas en [data] de ~/.config/chezmoi/chezmoi.toml o usa {{ .chezmoi.* }}"
            rc=1
        fi
    done < <(find "${REPO_ROOT}/${root}" -type f -name '*.tmpl' 2> /dev/null | sort)
    [[ "$rc" -eq 0 ]] && _ok "las plantillas solo usan variables estándar de chezmoi"

    # Nombres de destino con guion bajo pueden confundirse con prefijos de chezmoi
    local f base first
    while IFS= read -r f; do
        base="$(basename -- "$f")"
        first="${base%%_*}"
        case "$first" in
            run|once|onchange|before|after|create|empty|modify|remove|exact|encrypt|delete|script|symlink|readonly)
                log_debug "prefijo de chezmoi reconocido: ${base}"
                ;;
        esac
    done < <(find "${REPO_ROOT}/${root}" -type f -name '*_*' 2> /dev/null | sort)
    return 0
}

main() {
    case "${1:-}" in
        --quick|-q) QUICK="yes" ;;
        --help|-h)  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    esac

    mkdir -p "$(dirname -- "$LOG_FILE")" 2> /dev/null || true
    log_step "Lint del repo: ${REPO_ROOT}"
    echo

    _lint_bash_syntax
    _lint_shellcheck
    _lint_json
    _lint_fish
    _lint_lua
    _lint_hardcoded_paths
    _lint_repo_hygiene
    _lint_package_lists
    _lint_steps
    _lint_chezmoi

    echo
    log_step "Resultado"
    log_info "errores : ${N_ERR}"
    log_info "avisos  : ${N_WARN}"
    log_info "log     : ${LOG_FILE}"

    if [[ "$N_ERR" -gt 0 ]]; then
        log_error "lint falló con ${N_ERR} error(es)"
        return 1
    fi
    log_ok "lint correcto"
    return 0
}

main "$@"
