#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# backup.sh — respaldo de seguridad de tus configuraciones actuales.
#
# Se llama solo desde install.sh (etapa 'checks'), pero puedes usarlo directo:
#     ./scripts/backup.sh              # respaldo normal
#     ./scripts/backup.sh --list       # ver respaldos existentes
#     ./scripts/backup.sh --restore N  # restaurar el respaldo N
#
# Guarda un .tar.zst (o .tar.gz si no hay zstd) en:
#     ~/.local/state/dotfile-installer/backups/
# y conserva solo los últimos DOTFILE_BACKUP_KEEP (5 por defecto).
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

# Qué se respalda (rutas relativas a $HOME). Se ignora lo que no exista.
BACKUP_TARGETS=(
    .config
    .local/bin
    .local/share/applications
    .local/state/caelestia
    .gitconfig
    .gitignore_global
    .ssh/config
    .ssh/known_hosts
    .gtkrc-2.0
    .xinitrc
    .profile
    .bashrc
    .bash_profile
)

# Qué se EXCLUYE del respaldo (cachés y cosas enormes sin valor)
BACKUP_EXCLUDES=(
    --exclude=.cache
    --exclude=*/Cache
    --exclude=*/CacheStorage
    --exclude=*/GPUCache
    '--exclude=*/Code Cache'
    --exclude=*/node_modules
    --exclude=*/__pycache__
    --exclude=*/thumbnails
    --exclude=.config/Google
    --exclude=.config/zen-browser/*/storage
    --exclude=.config/fish/fish_history
    --exclude=.config/fish/fish_read_history
)

_backup_dir() { printf '%s' "$BACKUP_DIR"; }

backup_list() {
    local dir; dir="$(_backup_dir)"
    if [[ ! -d "$dir" ]] || [[ -z "$(ls -A "$dir" 2> /dev/null)" ]]; then
        echo "No hay respaldos en $dir"
        return 0
    fi
    echo "Respaldos en $dir:"
    local i=1 f size
    while IFS= read -r f; do
        size="$(du -h "$f" 2> /dev/null | cut -f1)"
        printf '  [%d] %-50s %8s  %s\n' "$i" "$(basename -- "$f")" "$size" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2> /dev/null)"
        i=$(( i + 1 ))
    done < <(ls -1t "$dir"/backup-*.tar.* 2> /dev/null)
}

backup_restore() { # <índice>
    local idx="${1:-}"
    [[ -n "$idx" ]] || { echo "Uso: $0 --restore <n>  (mira la lista con --list)"; return 1; }
    local dir; dir="$(_backup_dir)"
    local -a files=()
    mapfile -t files < <(ls -1t "$dir"/backup-*.tar.* 2> /dev/null)
    local f="${files[$(( idx - 1 ))]:-}"
    [[ -n "$f" && -f "$f" ]] || { echo "No existe el respaldo número $idx"; return 1; }

    echo "Se va a restaurar $(basename -- "$f") sobre $HOME"
    echo "Los archivos actuales se sobrescriben (NO se borran los que no estén en el respaldo)."
    if ! confirm "¿Confirmar la restauración?" no; then
        echo "Cancelado."
        return 0
    fi

    local tar_opts=(-x)
    case "$f" in
        *.tar.zst) command -v zstd > /dev/null 2>&1 || { echo "falta zstd para descomprimir"; return 1; }
                   tar_opts+=(--use-compress-program=unzstd) ;;
        *.tar.gz)  tar_opts+=(-z) ;;
        *.tar)     : ;;
        *)         echo "formato no reconocido: $f"; return 1 ;;
    esac

    tar "${tar_opts[@]}" -f "$f" -C "$HOME" && echo "✔ Restaurado desde $(basename -- "$f")"
}

backup_prune() {
    local dir; dir="$(_backup_dir)"
    local keep="${DOTFILE_BACKUP_KEEP:-5}"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
    local -a files=()
    mapfile -t files < <(ls -1t "$dir"/backup-*.tar.* 2> /dev/null)
    local n="${#files[@]}"
    [[ "$n" -gt "$keep" ]] || return 0
    local f
    for f in "${files[@]:$keep}"; do
        rm -f -- "$f" && log_info "respaldo antiguo eliminado: $(basename -- "$f")"
    done
}

main() {
    case "${1:-}" in
        --list|-l)    backup_list; return 0 ;;
        --restore|-r) shift; backup_restore "${1:-}"; return $? ;;
        --help|-h)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            return 0 ;;
    esac

    # ~/.config puede contener tokens: directorio 0700 y archivo tar 0600.
    umask 077
    mkdir -p "$(_backup_dir)" 2> /dev/null || { log_error "no se pudo crear $(_backup_dir)"; return 1; }
    chmod 0700 "$(_backup_dir)" || return 1

    local -a existing=()
    local t
    for t in "${BACKUP_TARGETS[@]}"; do
        [[ -e "${HOME}/${t}" ]] && existing+=("$t")
    done

    if [[ "${#existing[@]}" -eq 0 ]]; then
        log_warn "no hay nada que respaldar en \$HOME (¿sistema recién instalado?)"
        return 0
    fi

    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local outfile compress
    if command -v zstd > /dev/null 2>&1; then
        compress="--use-compress-program=zstd"
        outfile="$(_backup_dir)/backup-${stamp}.tar.zst"
    else
        compress="-z"
        outfile="$(_backup_dir)/backup-${stamp}.tar.gz"
    fi

    log_step "Creando respaldo de ${#existing[@]} elemento(s)"
    log_info "destino: $outfile"
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) tar -C \$HOME ${compress} -cf ... ${existing[*]}"
        return 0
    fi

    local rc=0
    # shellcheck disable=SC2086
    tar -C "$HOME" $compress -cf "$outfile" "${BACKUP_EXCLUDES[@]}" "${existing[@]}" 2>> "$LOG_FILE" || rc=$?

    if [[ "$rc" -ne 0 || ! -s "$outfile" ]]; then
        rm -f "$outfile" 2> /dev/null || true
        log_error "el respaldo falló (código $rc); mira $LOG_FILE"
        return 1
    fi

    local size; size="$(du -h "$outfile" 2> /dev/null | cut -f1)"
    chmod 0600 "$outfile" || return 1
    log_ok "respaldo creado: $(basename -- "$outfile") (${size})"
    backup_prune
    return 0
}

# backup.sh es una utilidad: se ejecuta siempre que se invoca (sin el control de
# idempotencia de run_step). La etapa 'checks' del instalador lo llama una vez.
main "$@"
