#!/usr/bin/env bash
# No escribe en /etc ni requiere sudo. Comprueba fail-closed del respaldo.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/common.sh"
tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
BACKUP_DIR="$tmp/backups"
printf 'dato importante\n' > "$tmp/original"
backup_file "$tmp/original"
mapfile -t copies < <(find "$BACKUP_DIR" -type f)
[[ "${#copies[@]}" -eq 1 ]]
cmp -s "$tmp/original" "${copies[0]}"
# Forzar un destino imposible: NO debe afirmar que respaldó.
BACKUP_DIR="$tmp/original/no-se-puede-crear"
if backup_file "$tmp/original" 2>/dev/null; then
    echo 'ERROR: un respaldo imposible se reportó como correcto' >&2
    exit 1
fi
echo 'backup: OK'
