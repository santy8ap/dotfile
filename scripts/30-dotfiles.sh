#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 30-dotfiles.sh — aplicar las configuraciones con chezmoi.
#
# El estado fuente de chezmoi es este repo. La carpeta que cae en $HOME es
# `home/` (lo indica el archivo .chezmoiroot de la raíz), así que scripts/,
# docs/, packages/ y demás NO se copian a tu directorio personal.
#
# Prefijos de chezmoi usados en home/:
#   dot_        -> el archivo/carpeta empieza por punto (dot_config -> ~/.config)
#   executable_ -> bit de ejecución                     (executable_rotar-fondo)
#   private_    -> permisos 0600                        (private_current.lua)
#   create_     -> se crea si no existe y NUNCA se pisa (create_user-config.fish)
#   *.tmpl      -> plantilla Go ({{ .chezmoi.homeDir }}, {{ .chezmoi.hostname }})
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

CHEZMOI_SRC_DIR="${REPO_ROOT}"

# Directorio que chezmoi considera raíz del estado fuente (respeta .chezmoiroot)
_chezmoi_root_subdir() {
    cat "${CHEZMOI_SRC_DIR}/.chezmoiroot" 2> /dev/null | tr -d '[:space:]' || true
}

_chezmoi_source_actual() {
    have chezmoi || return 1
    local src
    src="$(chezmoi source-path 2> /dev/null || true)"
    [[ -n "$src" ]] || return 1
    readlink -f "$src" 2> /dev/null || printf '%s' "$src"
}

# ¿El source actual ya es este repo (o su subdir .chezmoiroot)?
_chezmoi_source_matches() { # <ruta-actual>
    local current="$1" want sub
    want="$(readlink -f "$CHEZMOI_SRC_DIR")"
    [[ "$current" == "$want" ]] && return 0
    sub="$(_chezmoi_root_subdir)"
    [[ -n "$sub" && "$current" == "${want}/${sub}" ]] && return 0
    return 1
}

main() {
    if ! need_cmd chezmoi; then
        log_info "intentando instalar chezmoi..."
        if have pacman; then
            local flags=(-S --needed --asexplicit chezmoi)
            is_true "$YES" && flags+=(--noconfirm)
            run_root pacman "${flags[@]}" || true
        fi
        if ! need_cmd chezmoi; then
            add_warning "chezmoi no está instalado: los dotfiles no se aplicaron. Instálalo y corre: ./install.sh dotfiles --force"
            return 1
        fi
    fi

    log_info "$(chezmoi --version 2>/dev/null | head -1 || echo 'chezmoi (versión desconocida)')"
    log_info "estado fuente : ${CHEZMOI_SRC_DIR}"
    log_info "raíz de chezmoi: $(_chezmoi_root_subdir || echo '(repo completo)')/"
    log_info "destino       : ${HOME}"

    local mode="${DOTFILE_CHEZMOI_MODE:-apply}"
    case "$mode" in
        apply|diff|none) : ;;
        *) log_warn "DOTFILE_CHEZMOI_MODE='$mode' no es válido (apply|diff|none); se usa apply"; mode="apply" ;;
    esac

    # No cambiar el source global de chezmoi: en la máquina original apunta a
    # ~/.local/share/chezmoi y ~/dotfiles es OTRO repositorio. Usar siempre
    # --source explícito para este repo; no ejecutar `chezmoi init --force`.
    local current_src
    current_src="$(_chezmoi_source_actual || true)"
    local source_conflict="no"
    if [[ -n "$current_src" && -d "$current_src" ]] && ! _chezmoi_source_matches "$current_src"; then
        source_conflict="yes"
        log_warn "chezmoi global usa $current_src (NO se modificará)"
        log_info "este repo se aplica aislado con: chezmoi --source '$CHEZMOI_SRC_DIR' apply"
    fi

    # --- Validar el estado fuente -----------------------------------------
    log_step "Validando plantillas y estado fuente"
    if is_false "$DRY_RUN"; then
        # Comprobar que las plantillas se pueden evaluar (detecta .tmpl rotos)
        if chezmoi --source "$CHEZMOI_SRC_DIR" execute-template '{{ .chezmoi.homeDir }}' > /dev/null 2>&1; then
            log_ok "plantillas OK (homeDir=$(chezmoi --source "$CHEZMOI_SRC_DIR" execute-template '{{ .chezmoi.homeDir }}' 2>/dev/null))"
        else
            log_warn "no se pudieron evaluar las plantillas de chezmoi"
            add_warning "Error al evaluar plantillas; revisa home/**/*.tmpl y home/.chezmoiignore"
        fi

        # Listar lo que chezmoi va a gestionar (sanity check de .chezmoiroot)
        local n_targets=0
        n_targets="$(chezmoi --source "$CHEZMOI_SRC_DIR" managed 2>/dev/null | wc -l || echo 0)"
        log_info "objetivos gestionados: ${n_targets}"
        if [[ "$n_targets" -eq 0 ]]; then
            log_warn "chezmoi no gestiona ningún archivo: ¿está bien .chezmoiroot?"
            add_warning "El estado fuente de este repo no gestiona archivos; no se aplicó nada."
            return 1
        fi
        if is_true "$VERBOSE"; then
            chezmoi --source "$CHEZMOI_SRC_DIR" managed 2>/dev/null | sed 's/^/      /'
        fi

        # doctor: informativo, nunca bloquea
        local doctor_flags=()
        chezmoi doctor --help 2>&1 | grep -q -- '--no-network' && doctor_flags+=(--no-network)
        log_debug "ejecutando 'chezmoi doctor ${doctor_flags[*]-}'"
        chezmoi doctor ${doctor_flags[@]+"${doctor_flags[@]}"} 2>&1 | sed 's/^/      | /' || true
    fi

    if [[ "$mode" == "none" ]]; then
        log_info "DOTFILE_CHEZMOI_MODE=none: no se aplica ni se muestra nada"
        return 0
    fi

    # --- Previsualizar cambios --------------------------------------------
    log_step "Cambios pendientes en \$HOME"
    if is_false "$DRY_RUN"; then
        local diff_out="" n_files=0
        diff_out="$(chezmoi --source "$CHEZMOI_SRC_DIR" diff 2>&1 || true)"
        if [[ -z "$diff_out" ]]; then
            log_ok "sin cambios: \$HOME ya coincide con el repo"
        else
            n_files="$(printf '%s\n' "$diff_out" | grep -c '^diff ' || true)"
            log_info "${n_files} archivo(s) con cambios"
            if is_true "$VERBOSE"; then
                printf '%s\n' "$diff_out" | sed 's/^/      | /'
            else
                printf '%s\n' "$diff_out" | grep '^diff ' | sed 's/^diff /      /' | head -40
                if [[ "$n_files" -gt 40 ]]; then
                    log_info "... y $(( n_files - 40 )) más"
                fi
                log_info "detalle completo: chezmoi --source '$CHEZMOI_SRC_DIR' diff"
            fi
        fi
    fi

    if [[ "$mode" == "diff" ]]; then
        log_info "DOTFILE_CHEZMOI_MODE=diff: solo se muestran los cambios, no se aplica"
        return 0
    fi

    if [[ "$source_conflict" == "yes" ]] && is_false "$DRY_RUN"; then
        # --yes no salta esta confirmación, incluso en ejecuciones automáticas.
        if [[ ! -t 0 ]]; then
            log_warn "sin terminal: no se aplica sobre un source de chezmoi distinto"
            return 1
        fi
        local reply=""
        printf 'Source global diferente. Tras revisar el diff, escribe APLICAR para continuar: ' >&2
        read -r reply
        if [[ "$reply" != "APLICAR" ]]; then
            log_warn "cancelado; el source global y $HOME permanecen intactos"
            return 1
        fi
    fi

    # --- Aplicar -----------------------------------------------------------
    log_step "Aplicando dotfiles sobre \$HOME"
    if ! confirm "¿Aplicar los dotfiles?" si; then
        log_info "aplicación cancelada por el usuario"
        return 0
    fi

    local rc=0
    if is_true "$DRY_RUN"; then
        run chezmoi --source "$CHEZMOI_SRC_DIR" apply --dry-run --verbose || rc=$?
    else
        run chezmoi --source "$CHEZMOI_SRC_DIR" apply || rc=$?
    fi

    if [[ "$rc" -ne 0 ]]; then
        log_error "chezmoi apply falló (código $rc)"
        add_warning "chezmoi apply devolvió $rc. Revisa el log y ejecuta chezmoi --source '$CHEZMOI_SRC_DIR' diff."
        return 1
    fi

    # --- Post-aplicación ---------------------------------------------------
    if have systemctl && [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        run_or_warn systemctl --user daemon-reload
    fi

    log_info "recuerda: caelestia y fish reescriben algunos archivos en vivo"
    log_info "(scheme/current.lua, shell.json, user-config.fish, foot.ini)."
    log_info "Tras cambiarlos, usa: chezmoi --source '$CHEZMOI_SRC_DIR' add <archivo>"

    log_ok "dotfiles aplicados"
}

run_step "dotfiles"
