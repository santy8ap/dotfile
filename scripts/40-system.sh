#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 40-system.sh — configuración a nivel de SISTEMA (necesita sudo).
#
# Toca, en este orden:
#   1. Zona horaria, teclado de consola y locale
#   2. Grupos del usuario (video, audio, input, docker, realtime, ...)
#   3. Servicios y temporizadores del sistema
#   4. Firewall ufw
#   5. Archivos de system/etc/ -> /etc (siempre con respaldo previo)
#   6. /etc/sudoers.d para `server_mode`/`normal_mode` de fish
#   7. informant (avisos de Arch antes de actualizar)
#   8. plymouth en mkinitcpio (OPT-IN: por defecto apagado)
#   9. chwd (detección de hardware de CachyOS)
#
# Todo es idempotente: correrlo dos veces no duplica nada.
# Transparencia completa de qué se modifica: docs/SISTEMA.md
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

TARGET_USER="$(id -un)"

# --- 1. Zona horaria / teclado / idioma -----------------------------------
_system_timezone() {
    local tz="${DOTFILE_TIMEZONE:-}"
    [[ -n "$tz" ]] || { log_info "timezone: sin configurar, se omite"; return 0; }
    have timedatectl || { log_warn "timedatectl no existe; no se pudo fijar la zona horaria"; return 0; }

    if [[ "$(timedatectl show -p Timezone --value 2> /dev/null)" == "$tz" ]]; then
        log_ok "zona horaria ya es $tz"
        return 0
    fi
    if ! timedatectl list-timezones 2> /dev/null | grep -qx "$tz"; then
        log_warn "la zona horaria '$tz' no existe en el sistema"
        add_warning "Zona horaria '$tz' no válida; se dejó la actual."
        return 0
    fi
    run_root timedatectl set-timezone "$tz" && log_ok "zona horaria: $tz"
}

_system_keymap() {
    local km="${DOTFILE_KEYMAP:-}"
    [[ -n "$km" ]] || { log_info "keymap: sin configurar, se omite"; return 0; }

    local current=""
    [[ -r /etc/vconsole.conf ]] && current="$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf | tr -d '"' | head -1)"
    if [[ "$current" == "$km" ]]; then
        log_ok "teclado de consola ya es $km"
        return 0
    fi

    if have localectl && run_root localectl set-keymap "$km" 2> /dev/null; then
        log_ok "teclado de consola: $km (vía localectl)"
        return 0
    fi

    log_info "localectl no pudo validarlo; se escribe /etc/vconsole.conf directamente"
    backup_file /etc/vconsole.conf || return 1
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) /etc/vconsole.conf: KEYMAP=$km"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    if [[ -r /etc/vconsole.conf ]]; then
        grep -v '^KEYMAP=' /etc/vconsole.conf > "$tmp" || true
    fi
    printf 'KEYMAP=%s\n' "$km" >> "$tmp"
    run_root install -D -m 0644 "$tmp" /etc/vconsole.conf && log_ok "teclado de consola: $km"
    rm -f "$tmp"
}

_system_locale() {
    local loc="${DOTFILE_LOCALE:-}"
    [[ -n "$loc" ]] || { log_info "locale: sin configurar (DOTFILE_LOCALE vacío), se omite"; return 0; }

    local enc="${loc#*.}"; enc="${enc:-UTF-8}"
    local gen_line="${loc} ${enc}"

    if [[ -r /etc/locale.gen ]]; then
        if grep -qE "^${loc}[[:space:]]" /etc/locale.gen 2> /dev/null; then
            log_debug "locale.gen ya tiene $loc"
        else
            backup_file /etc/locale.gen || return 1
            if is_false "$DRY_RUN"; then
                # Descomentar si está comentado, si no, agregarlo
                if grep -qE "^#[[:space:]]*${loc}[[:space:]]" /etc/locale.gen; then
                    run_root sed -i -E "s|^#[[:space:]]*(${loc}[[:space:]].*)$|\1|" /etc/locale.gen || return 1
                else
                    printf '%s\n' "$gen_line" | run_root tee -a /etc/locale.gen > /dev/null || return 1
                fi
                log_ok "locale.gen: habilitado $loc"
            else
                log_info "(dry-run) locale.gen: habilitar $loc"
            fi
        fi
        run_or_warn "${SUDO_CMD[@]}" locale-gen
    fi

    local current=""
    [[ -r /etc/locale.conf ]] && current="$(sed -n 's/^LANG=//p' /etc/locale.conf | tr -d '"' | head -1)"
    if [[ "$current" == "$loc" ]]; then
        log_ok "LANG ya es $loc"
        return 0
    fi
    backup_file /etc/locale.conf || return 1
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) /etc/locale.conf: LANG=$loc"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    printf 'LANG=%s\n' "$loc" > "$tmp"
    run_root install -D -m 0644 "$tmp" /etc/locale.conf && log_ok "locale: LANG=$loc"
    rm -f "$tmp"
    log_info "hace falta cerrar sesión (o reiniciar) para que LANG surta efecto"
}

# --- 2. Grupos -------------------------------------------------------------
_system_groups() {
    local -a groups=()
    words_to_array groups "${DOTFILE_USER_GROUPS:-}"
    [[ "${#groups[@]}" -gt 0 ]] || { log_info "sin grupos configurados"; return 0; }

    local g added=0 skipped=0 already=0
    local -a to_add=() missing_groups=()

    for g in "${groups[@]}"; do
        if ! group_exists "$g"; then
            missing_groups+=("$g")
            skipped=$(( skipped + 1 ))
            continue
        fi
        if user_in_group "$TARGET_USER" "$g"; then
            already=$(( already + 1 ))
            continue
        fi
        to_add+=("$g")
    done

    if [[ "${#missing_groups[@]}" -gt 0 ]]; then
        log_info "grupos inexistentes en este sistema (se omiten): ${missing_groups[*]}"
    fi
    log_info "grupos: ${already} ya asignados, ${skipped} inexistentes, ${#to_add[@]} por agregar"

    if [[ "${#to_add[@]}" -eq 0 ]]; then
        log_ok "el usuario ya pertenece a todos los grupos disponibles"
        return 0
    fi

    if ! confirm "¿Agregar a '$TARGET_USER' a los grupos: ${to_add[*]}?" si; then
        log_info "grupos omitidos por el usuario"
        return 0
    fi

    for g in "${to_add[@]}"; do
        if run_root usermod -aG "$g" "$TARGET_USER"; then
            added=$(( added + 1 ))
            log_ok "grupo agregado: $g"
        else
            log_warn "no se pudo agregar el grupo: $g"
        fi
    done

    if [[ "$added" -gt 0 ]]; then
        add_warning "Se agregaron $added grupo(s). Hay que cerrar sesión y volver a entrar (o reiniciar) para que surtan efecto."
    fi
}

# --- 3. Servicios del sistema ---------------------------------------------
_system_services() {
    local -a units=()
    words_to_array units "${DOTFILE_SYSTEM_SERVICES:-}"

    local u ok=0 skipped=0 failed=0
    for u in "${units[@]+"${units[@]}"}"; do
        local unit="$u"
        [[ "$unit" == *.service || "$unit" == *.timer || "$unit" == *.socket ]] || unit="${unit}.service"

        if ! unit_exists "$unit"; then
            log_debug "unidad inexistente, se omite: $unit"
            skipped=$(( skipped + 1 ))
            continue
        fi
        if unit_is_enabled "$unit" && unit_is_active "$unit"; then
            log_debug "ya activa y habilitada: $unit"
            ok=$(( ok + 1 ))
            continue
        fi
        if run_root systemctl enable --now "$unit"; then
            log_ok "servicio habilitado: $unit"
            ok=$(( ok + 1 ))
        else
            # Algunas unidades no pueden arrancar ahora (p. ej. greetd sin sesión)
            if run_root systemctl enable "$unit" 2> /dev/null; then
                log_warn "$unit habilitada pero no arrancó ahora (es normal en algunas)"
                ok=$(( ok + 1 ))
            else
                log_error "no se pudo habilitar: $unit"
                failed=$(( failed + 1 ))
            fi
        fi
    done
    log_info "servicios: ${ok} listos, ${skipped} inexistentes, ${failed} con error"
    [[ "$failed" -gt 0 ]] && add_warning "${failed} servicio(s) del sistema no se pudieron habilitar."

    # Temporizadores
    local -a timers=()
    words_to_array timers "${DOTFILE_SYSTEM_TIMERS:-}"
    local t
    for t in "${timers[@]+"${timers[@]}"}"; do
        unit_exists "$t" || { log_debug "temporizador inexistente: $t"; continue; }
        if run_root systemctl enable --now "$t"; then
            log_ok "temporizador habilitado: $t"
        else
            log_warn "no se pudo habilitar el temporizador: $t"
        fi
    done
    return 0
}

# --- 4. Firewall -----------------------------------------------------------
_system_ufw() {
    is_true "$DOTFILE_UFW" || { log_info "ufw desactivado por configuración"; return 0; }
    have ufw || { log_info "ufw no instalado; se omite (paquetes: ufw, ufw-extras)"; return 0; }

    # SEGURIDAD: si estamos conectados por SSH ahora mismo, permitir SSH sí o sí.
    local force_ssh="no"
    if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
        force_ssh="yes"
        log_warn "estás conectado por SSH: se permitirá el puerto 22 para no dejarte fuera"
    fi

    if ! confirm "¿Configurar y activar el firewall ufw (deny incoming / allow outgoing)?" si; then
        log_info "ufw omitido por el usuario"
        return 0
    fi

    run_or_warn "${SUDO_CMD[@]}" ufw default deny incoming
    run_or_warn "${SUDO_CMD[@]}" ufw default allow outgoing

    if is_true "$DOTFILE_UFW_ALLOW_LOCALSEND"; then
        # LocalSend usa 53317 (tcp y udp) para descubrirse y transferir en la LAN
        run_or_warn "${SUDO_CMD[@]}" ufw allow 53317/tcp comment 'localsend'
        run_or_warn "${SUDO_CMD[@]}" ufw allow 53317/udp comment 'localsend'
        log_ok "ufw: puerto 53317 abierto para LocalSend"
    fi

    if is_true "$DOTFILE_UFW_ALLOW_SSH" || [[ "$force_ssh" == "yes" ]]; then
        run_or_warn "${SUDO_CMD[@]}" ufw allow OpenSSH
        log_ok "ufw: SSH permitido"
    elif unit_is_enabled "sshd.service"; then
        log_warn "sshd está habilitado pero ufw bloqueará el puerto 22"
        add_warning "sshd habilitado sin regla en ufw: no podrás entrar por SSH. Solución: sudo ufw allow OpenSSH"
    fi

    run_or_warn "${SUDO_CMD[@]}" ufw --force enable
    run_or_warn "${SUDO_CMD[@]}" systemctl enable --now ufw
    log_ok "ufw activo"
    return 0
}

# --- 5. Archivos de system/etc -> /etc ------------------------------------
_apply_etc_tree() {
    is_true "$DOTFILE_APPLY_ETC" || { log_info "DOTFILE_APPLY_ETC=no: no se toca /etc"; return 0; }
    local etc_src="${SYSTEM_DIR}/etc"
    [[ -d "$etc_src" ]] || { log_info "no hay archivos de sistema en ${etc_src}"; return 0; }

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$etc_src" -type f -print0 2> /dev/null | sort -z)

    if [[ "${#files[@]}" -eq 0 ]]; then
        log_info "system/etc está vacío"
        return 0
    fi

    log_info "archivos de sistema disponibles:"
    local f rel
    for f in "${files[@]}"; do
        rel="${f#"${etc_src}/"}"
        printf '      /etc/%s\n' "$rel"
    done

    if ! confirm "¿Aplicar estos archivos sobre /etc? (se respalda cada uno antes)" si; then
        log_info "archivos de /etc omitidos por el usuario"
        return 0
    fi

    for f in "${files[@]}"; do
        rel="${f#"${etc_src}/"}"
        local dst="/etc/${rel}"

        # sudoers.d exige validación y permisos especiales
        if [[ "$rel" == sudoers.d/* ]]; then
            _install_sudoers "$f" "$dst"
            continue
        fi

        local mode="0644"
        case "$rel" in
            greetd/*)       mode="0644" ;;
            sysctl.d/*)     mode="0644" ;;
            modules-load.d/*) mode="0644" ;;
            udev/rules.d/*) mode="0644" ;;
            *.sh|profile.d/*) mode="0755" ;;
        esac

        # No pisar una configuración existente del sistema salvo que se pida
        if [[ -e "$dst" ]] && is_false "$FORCE"; then
            if cmp -s -- "$f" "$dst"; then
                log_ok "sin cambios: $dst"
            else
                log_warn "$dst ya existe y difiere del repo"
                add_warning "$dst no se modificó (ya existía). Usa --force para sobrescribirlo con respaldo."
            fi
            continue
        fi

        install_file "$f" "$dst" "$mode" "root" || add_warning "No se pudo instalar $dst"
    done

    # Recargar lo que haga falta
    if [[ -d /etc/sysctl.d ]] && have sysctl; then
        run_or_warn "${SUDO_CMD[@]}" sysctl --system
    fi
    run_or_warn "${SUDO_CMD[@]}" systemctl daemon-reload
    return 0
}

# Instala un archivo de sudoers validándolo con visudo antes
_install_sudoers() { # <origen> <destino>
    local src="$1" dst="$2"
    if ! have visudo; then
        log_warn "visudo no disponible: no se instala $dst por seguridad"
        add_warning "Falta visudo; el drop-in de sudoers no se instaló."
        return 0
    fi
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) se validaría e instalaría $src -> $dst (modo 0440)"
        return 0
    fi
    if ! "${SUDO_CMD[@]}" visudo -cf "$src" > /dev/null 2>&1; then
        log_error "$src tiene errores de sintaxis: NO se instala (podría romper sudo)"
        add_warning "Drop-in de sudoers inválido: $src"
        return 1
    fi
    if [[ -f "$dst" ]] && cmp -s -- "$src" "$dst"; then
        log_ok "sin cambios: $dst"
        return 0
    fi
    backup_file "$dst" || return 1
    run_root install -D -m 0440 -o root -g root "$src" "$dst" && log_ok "instalado: $dst (0440)"
}

# --- 6. sudoers para cpupower ---------------------------------------------
_system_sudoers_cpupower() {
    is_true "$DOTFILE_SUDOERS_CPUPOWER" || { log_info "sudoers de cpupower desactivado"; return 0; }
    have cpupower || { log_info "cpupower no instalado; se omite su regla de sudoers"; return 0; }

    local cpupower_bin
    cpupower_bin="$(command -v cpupower)"
    local dst="/etc/sudoers.d/50-dotfile-cpupower"

    if [[ -f "$dst" ]] && is_false "$FORCE"; then
        log_ok "ya existe $dst"
        return 0
    fi

    # Las funciones server_mode/normal_mode de fish llaman a
    # `sudo cpupower frequency-set -g <gobernador>`; sin esta regla piden clave.
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# Generado por dotfile/scripts/40-system.sh — no editar a mano.
# Permite cambiar el gobernador de CPU sin contraseña para que las funciones
# server_mode / normal_mode de fish funcionen sin interrumpir la sesión.
Cmnd_Alias CPUPOWER_GOV = ${cpupower_bin} frequency-set -g powersave, \\
                          ${cpupower_bin} frequency-set -g schedutil, \\
                          ${cpupower_bin} frequency-set -g performance, \\
                          ${cpupower_bin} frequency-set -g ondemand, \\
                          ${cpupower_bin} frequency-set -g conservative

${TARGET_USER} ALL=(root) NOPASSWD: CPUPOWER_GOV
EOF

    if confirm "¿Permitir '$TARGET_USER' cambiar el gobernador de CPU sin contraseña? (necesario para server_mode/normal_mode)" si; then
        _install_sudoers "$tmp" "$dst" || true
    else
        log_info "regla de sudoers omitida: server_mode/normal_mode pedirán contraseña"
    fi
    rm -f "$tmp"
}

# --- 7. informant ---------------------------------------------------------
_system_informant() {
    have informant || { log_debug "informant no instalado"; return 0; }
    if run_root informant list > /dev/null 2>&1; then
        log_debug "informant responde"
    fi
    # `informant enable` instala el hook de pacman que obliga a leer las noticias
    run_or_warn "${SUDO_CMD[@]}" informant enable
    log_ok "informant habilitado (leer noticias de Arch antes de actualizar)"
}

# --- 8. plymouth en mkinitcpio (opt-in) ------------------------------------
_system_plymouth() {
    if is_false "$DOTFILE_PLYMOUTH_MKINITCPIO"; then
        log_debug "plymouth/mkinitcpio desactivado (DOTFILE_PLYMOUTH_MKINITCPIO=no)"
        return 0
    fi
    have plymouth || { log_warn "plymouth no instalado; se omite"; return 0; }
    local conf="/etc/mkinitcpio.conf"
    [[ -r "$conf" ]] || { log_warn "no existe $conf"; return 0; }

    local hooks
    hooks="$(sed -n 's/^HOOKS=(\(.*\))/\1/p' "$conf" | tail -1)"
    if [[ -z "$hooks" ]]; then
        log_warn "no encontré la línea HOOKS=(...) en $conf; se omite"
        add_warning "No se pudo modificar mkinitcpio.conf automáticamente."
        return 0
    fi
    if [[ " $hooks " == *" plymouth "* ]]; then
        log_ok "el hook plymouth ya está en mkinitcpio.conf"
        return 0
    fi
    if [[ " $hooks " != *" udev "* ]]; then
        log_warn "no hay hook 'udev' en HOOKS; no sé dónde insertar plymouth"
        add_warning "mkinitcpio.conf sin hook udev: plymouth no se agregó."
        return 0
    fi

    log_warn "se va a modificar /etc/mkinitcpio.conf y a regenerar las imágenes de arranque."
    log_warn "Si algo sale mal, el sistema podría no arrancar. Se hará respaldo previo."
    if ! confirm "¿Continuar con plymouth en mkinitcpio?" no; then
        log_info "plymouth omitido"
        return 0
    fi

    backup_file "$conf" || return 1
    if is_true "$DRY_RUN"; then
        log_info "(dry-run) mkinitcpio.conf: insertar 'plymouth' tras 'udev'"
        return 0
    fi

    local tmp; tmp="$(mktemp)"
    # Solo se toca la línea HOOKS=(...): ahí 'udev' -> 'udev plymouth'
    sed -E '/^HOOKS=\(/ s/\budev\b/udev plymouth/' "$conf" > "$tmp"
    if ! grep -q 'udev plymouth' "$tmp"; then
        rm -f "$tmp"
        log_error "no se pudo insertar el hook plymouth; $conf queda intacto"
        add_warning "Hook plymouth no insertado en mkinitcpio.conf."
        return 0
    fi

    run_root install -D -m 0644 "$tmp" "$conf" && log_ok "hook plymouth agregado"
    rm -f "$tmp"

    log_info "regenerando imágenes initramfs (mkinitcpio -P)..."
    if run_root mkinitcpio -P; then
        log_ok "initramfs regenerado"
        log_warn "recuerda actualizar el cargador de arranque si tu setup lo requiere:"
        log_warn "    sudo grub-mkconfig -o /boot/grub/grub.cfg   (GRUB)"
    else
        log_error "mkinitcpio -P falló: revisa $conf y restaura el respaldo"
        add_warning "mkinitcpio -P falló tras agregar plymouth. ¡Verifica el arranque antes de reiniciar!"
    fi
}

# --- 9. chwd ---------------------------------------------------------------
_system_chwd() {
    is_true "$DOTFILE_CHWD" || { log_info "chwd desactivado por configuración"; return 0; }
    have chwd || { log_info "chwd no instalado (es propio de CachyOS); se omite"; return 0; }

    if [[ "$HW_DISTRO" != "cachyos" ]]; then
        log_info "chwd solo tiene sentido en CachyOS; se omite"
        return 0
    fi

    if confirm "¿Ejecutar 'sudo chwd' (detección de hardware de CachyOS)?" si; then
        run_root chwd || add_warning "chwd devolvió un error; revisa el log."
    else
        log_info "chwd omitido"
    fi
}

main() {
    if is_false "$DOTFILE_SYSTEM"; then
        log_info "etapa de sistema desactivada (--no-system / DOTFILE_SYSTEM=no)"
        return 0
    fi

    if is_root; then
        log_warn "ejecutando como root: los grupos se aplicarán al usuario SUDO_USER si existe"
        TARGET_USER="${SUDO_USER:-root}"
    fi

    if [[ "${#SUDO_CMD[@]}" -eq 0 ]] && ! is_root; then
        log_error "sudo no está disponible y no eres root: no se puede configurar el sistema"
        add_warning "Sin sudo: la etapa de sistema no hizo nada."
        return 1
    fi

    log_step "Zona horaria, teclado e idioma"
    _system_timezone
    _system_keymap
    _system_locale

    echo
    log_step "Grupos del usuario"
    _system_groups

    echo
    log_step "Servicios del sistema"
    _system_services

    echo
    log_step "Firewall (ufw)"
    _system_ufw

    echo
    log_step "Archivos de configuración en /etc"
    _apply_etc_tree

    echo
    log_step "Regla de sudo para cpupower"
    _system_sudoers_cpupower

    echo
    log_step "informant"
    _system_informant

    echo
    log_step "plymouth / mkinitcpio"
    _system_plymouth

    echo
    log_step "Detección de hardware (chwd)"
    _system_chwd

    run_or_warn "${SUDO_CMD[@]}" systemctl daemon-reload
    log_ok "configuración del sistema terminada"
}

run_step "system"
