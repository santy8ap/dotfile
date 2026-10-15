#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 05-base.sh — cimientos del sistema de paquetes.
#
#   1. Paquetes imprescindibles para que el resto del instalador funcione.
#   2. Ajustes idempotentes de /etc/pacman.conf (Color, ParallelDownloads,
#      ILoveCandy, VerbosePkgLists, [multilib]).
#   3. Llaveros actualizados (archlinux-keyring + cachyos-keyring).
#   4. Espejos ordenados por velocidad (cachyos-rate-mirrors / reflector).
#   5. Actualización completa del sistema (pacman -Syu) — en Arch nunca se
#      instala tras un simple `-Sy`, porque genera actualizaciones parciales.
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
# shellcheck source=scripts/lib/packages.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/packages.sh"

PACMAN_CONF="/etc/pacman.conf"

# Herramientas que el propio instalador necesita sí o sí
BASE_TOOLS=(
    base-devel git sudo curl wget rsync jq pacman-contrib pkgfile chezmoi
)

# --- Helpers de pacman.conf ------------------------------------------------
# Descomentar una opción si está comentada; si no existe, agregarla.
_pacman_conf_option() { # <opcion> <valor>
    local key="$1" value="$2"

    if is_true "$DRY_RUN"; then
        log_info "(dry-run) pacman.conf: ${key} = ${value}"
        return 0
    fi

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$PACMAN_CONF" 2> /dev/null; then
        # Ya está activa: asegurar el valor deseado
        if grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$PACMAN_CONF"; then
            log_debug "pacman.conf: ${key} ya vale ${value}"
            return 0
        fi
        backup_file "$PACMAN_CONF" || return 1
        run_root sed -i -E "s|^([[:space:]]*)${key}[[:space:]]*=.*$|\1${key} = ${value}|" "$PACMAN_CONF" \
            && log_ok "pacman.conf: ${key} = ${value}" || return 1
        return 0
    fi

    if grep -qE "^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=" "$PACMAN_CONF" 2> /dev/null; then
        backup_file "$PACMAN_CONF" || return 1
        run_root sed -i -E "s|^[[:space:]]*#[[:space:]]*(${key}[[:space:]]*=).*$|\1 ${value}|" "$PACMAN_CONF" \
            && log_ok "pacman.conf: activado ${key} = ${value}" || return 1
        return 0
    fi

    backup_file "$PACMAN_CONF" || return 1
    printf '%s = %s\n' "$key" "$value" | run_root tee -a "$PACMAN_CONF" > /dev/null \
        && log_ok "pacman.conf: agregado ${key} = ${value}"
}

# Opciones booleanas sin valor (Color, ILoveCandy, VerbosePkgLists, TotalDownload)
_pacman_conf_flag() { # <opcion>
    local key="$1"
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) pacman.conf: activar ${key}"
        return 0
    fi
    if grep -qE "^[[:space:]]*${key}[[:space:]]*$" "$PACMAN_CONF" 2> /dev/null; then
        log_debug "pacman.conf: ${key} ya está activa"
        return 0
    fi
    if grep -qE "^[[:space:]]*#[[:space:]]*${key}[[:space:]]*$" "$PACMAN_CONF" 2> /dev/null; then
        backup_file "$PACMAN_CONF" || return 1
        run_root sed -i -E "s|^[[:space:]]*#[[:space:]]*(${key}[[:space:]]*)$|\1|" "$PACMAN_CONF" \
            && log_ok "pacman.conf: activada ${key}" || return 1
        return 0
    fi
    backup_file "$PACMAN_CONF" || return 1
    printf '%s\n' "$key" | run_root tee -a "$PACMAN_CONF" > /dev/null \
        && log_ok "pacman.conf: agregada ${key}"
}

# Habilitar un repositorio comentado ([multilib] + su Include)
_pacman_conf_enable_repo() { # <repo>
    local repo="$1"
    if grep -qE "^[[:space:]]*\[${repo}\]" "$PACMAN_CONF" 2> /dev/null; then
        log_ok "repo [${repo}] ya habilitado"
        return 0
    fi
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) pacman.conf: habilitar [${repo}]"
        return 0
    fi
    if ! grep -qE "^[[:space:]]*#[[:space:]]*\[${repo}\]" "$PACMAN_CONF" 2> /dev/null; then
        log_warn "no encontré [${repo}] comentado en pacman.conf; se omite"
        return 0
    fi

    # Descomentar con awk es más predecible que sed multilinea:
    # descomenta la línea "[repo]" y el "Include" que la sigue inmediatamente.
    local tmp
    tmp="$(mktemp)"
    awk -v repo="$repo" '
        {
            line = $0
            if (line ~ ("^[ \t]*#[ \t]*\\[" repo "\\][ \t]*$")) {
                sub("^[ \t]*#[ \t]*", "", line)
                inrepo = 1
            } else if (inrepo && line ~ "^[ \t]*#[ \t]*Include") {
                sub("^[ \t]*#[ \t]*", "", line)
                inrepo = 0
            } else if (line ~ "^[ \t]*[^ \t#]") {
                inrepo = 0
            }
            print line
        }
    ' "$PACMAN_CONF" > "$tmp"

    if ! grep -qE "^[[:space:]]*\[${repo}\]" "$tmp"; then
        rm -f "$tmp"
        log_warn "no se pudo habilitar [${repo}] automáticamente; hazlo a mano en $PACMAN_CONF"
        add_warning "Repo [${repo}] no habilitado: los paquetes lib32-* fallarán si hace falta."
        return 0
    fi

    backup_file "$PACMAN_CONF" || return 1
    if run_root install -D -m 0644 "$tmp" "$PACMAN_CONF"; then
        log_ok "pacman.conf: repo [${repo}] habilitado"
    else
        log_error "no se pudo escribir $PACMAN_CONF"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

main() {
    [[ -r "$PACMAN_CONF" ]] || die "no se puede leer $PACMAN_CONF"

    # --- 2. pacman.conf ---------------------------------------------------
    log_step "Ajustes de ${PACMAN_CONF}"
    if confirm "¿Aplicar ajustes de pacman.conf (Color, ParallelDownloads=${DOTFILE_PARALLEL_DOWNLOADS}, ILoveCandy, VerbosePkgLists, [multilib])?"; then
        _pacman_conf_flag  "Color" || return 1
        _pacman_conf_flag  "ILoveCandy" || return 1
        _pacman_conf_flag  "VerbosePkgLists" || return 1
        _pacman_conf_option "ParallelDownloads" "$DOTFILE_PARALLEL_DOWNLOADS" || return 1
        if [[ "$(uname -m)" == "x86_64" ]]; then
            _pacman_conf_enable_repo "multilib" || return 1
        fi
        log_ok "pacman.conf listo"
    else
        log_info "ajustes de pacman.conf omitidos"
    fi

    # --- 3. Llaveros ------------------------------------------------------
    # Nunca hacer pacman -Sy (actualización parcial). Los keyrings se actualizan
    # como parte del -Syu completo, o con -S --needed si ya hay índices frescos.
    log_info "los llaveros se actualizarán con pacman -Syu"

    # --- 4. Espejos -------------------------------------------------------
    if is_true "$DOTFILE_RATE_MIRRORS"; then
        log_step "Ordenar espejos por velocidad"
        if have cachyos-rate-mirrors; then
            run_or_warn "${SUDO_CMD[@]}" cachyos-rate-mirrors
        elif have reflector; then
            run_or_warn "${SUDO_CMD[@]}" reflector \
                --country all --latest 20 --protocol https --sort rate \
                --save /etc/pacman.d/mirrorlist
        else
            log_info "ni cachyos-rate-mirrors ni reflector disponibles; se omite"
        fi
    else
        log_info "orden de espejos omitido (DOTFILE_RATE_MIRRORS=no)"
    fi

    # --- 5. Actualización del sistema -------------------------------------
    if is_true "$DOTFILE_SYSUPGRADE"; then
        log_step "Actualización completa del sistema (pacman -Syu)"
        if confirm "¿Actualizar todo el sistema ahora? (recomendado en Arch antes de instalar nada)" si; then
            if is_true "$DRY_RUN"; then
                run_root pacman -Syu --noconfirm
            else
                local rc=0
                if is_true "$YES"; then
                    run_root pacman -Syu --noconfirm || rc=$?
                else
                    run_root pacman -Syu || rc=$?
                fi
                if [[ "$rc" -ne 0 ]]; then
                    log_error "pacman -Syu falló"
                    add_warning "La actualización del sistema falló (código $rc). Revisa el log antes de seguir: $LOG_FILE"
                    # No instalar paquetes con el sistema a medio actualizar.
                    return 1
                else
                    log_ok "sistema actualizado"
                fi
            fi
        else
            log_warn "se omite la actualización del sistema"
            add_warning "Sistema sin actualizar: pueden aparecer conflictos de dependencias al instalar."
        fi
    else
        log_info "actualización del sistema omitida (--no-sysupgrade)"
        log_warn "en Arch, instalar paquetes sin actualizar puede fallar por bases de datos desfasadas"
    fi

    # Instalar herramientas solo DESPUÉS de la actualización completa. Hacer
    # pacman -S con bases antiguas antes de -Syu sería una actualización parcial.
    # --- 1. Herramientas base ---------------------------------------------
    log_step "Herramientas imprescindibles para el instalador"
    pkg_load_catalogs || return 1

    local to_install=() p
    for p in "${BASE_TOOLS[@]}"; do
        if ! pkg_is_installed "$p"; then
            if pkg_is_official "$p"; then
                to_install+=("$p")
            else
                log_debug "no existe en los repos: $p (se omite)"
            fi
        fi
    done

    if [[ "${#to_install[@]}" -gt 0 ]]; then
        log_info "instalando: ${to_install[*]}"
        if is_true "$DRY_RUN"; then
            run_root pacman -S --needed --asexplicit "${to_install[@]}"
        else
            local flags=(-S --needed --asexplicit --noprogressbar)
            is_true "$YES" && flags+=(--noconfirm)
            run_root pacman "${flags[@]}" "${to_install[@]}" \
                || add_warning "Alguna herramienta base no se pudo instalar: ${to_install[*]}"
        fi
        _PKG_CACHE_READY="no"
        pkg_load_catalogs || true
    else
        log_ok "todas las herramientas base ya están instaladas"
    fi

    if is_false "$DRY_RUN" && ! have chezmoi; then
        log_error "chezmoi no quedó instalado; no es seguro seguir con dotfiles"
        return 1
    fi

    # --- 6. pkgfile -------------------------------------------------------
    if have pkgfile; then
        log_step "Base de datos de pkgfile (el 'ese comando no existe' de pacman)"
        if systemctl list-unit-files --no-legend pkgfile-update.timer 2> /dev/null | grep -q 'pkgfile-update.timer'; then
            run_or_warn "${SUDO_CMD[@]}" systemctl enable --now pkgfile-update.timer
        fi
        run_or_warn "${SUDO_CMD[@]}" pkgfile -u
    fi

    _PKG_CACHE_READY="no"
    log_ok "base del sistema lista"
}

run_step "base"
