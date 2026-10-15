#!/usr/bin/env bash
# Se ejecuta automáticamente después de `chezmoi apply` cuando este archivo
# cambia (chezmoi guarda su hash en el state). Deja listas las unidades de
# usuario sin necesidad de correr el instalador completo.
#
# Debe ser 100% tolerante a fallos: nunca romper un `chezmoi apply`.

set -uo pipefail

log() { printf '  [chezmoi] %s\n' "$*"; }

# systemd de usuario disponible?
if ! command -v systemctl > /dev/null 2>&1; then
    exit 0
fi

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -S "${XDG_RUNTIME_DIR}/systemd/private" ]; then
    log "sin instancia de usuario de systemd activa; salta la activación de servicios"
    exit 0
fi

log "recargando unidades de usuario"
systemctl --user daemon-reload > /dev/null 2>&1 || true

# Unidad propia del repo: rotación de fondo de pantalla.
if [ -f "${HOME}/.config/systemd/user/rotar-fondo.timer" ]; then
    log "habilitando rotar-fondo.timer"
    systemctl --user enable --now rotar-fondo.timer > /dev/null 2>&1 \
        || log "no se pudo habilitar rotar-fondo.timer (revisa: systemctl --user status rotar-fondo.timer)"
fi

exit 0
