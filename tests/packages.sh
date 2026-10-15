#!/usr/bin/env bash
# Pruebas sin pacman real ni cambios al sistema.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/packages.sh"

pacman() {
    case "$1" in
        -Slq) printf '%s\n' foot hyprland chezmoi ;;
        -Qq) printf '%s\n' foot ;;
        *) return 1 ;;
    esac
}
HW_TAGS="amd laptop"
list="$(mktemp)"
trap 'rm -f "$list"' EXIT
cat > "$list" <<'EOF'
# comentario
foot
hyprland   # hw:amd
nvidia-utils # hw:nvidia
chezmoi
EOF
pkg_load_catalogs
mapfile -t selected < <(pkg_select "$list")
[[ "${#selected[@]}" -eq 2 ]]
[[ "${selected[0]}" == hyprland && "${selected[1]}" == chezmoi ]]

pkg_classify < <(printf '%s\n' "${selected[@]}")
[[ "${#PKG_FROM_OFFICIAL[@]}" -eq 2 ]]
[[ "${#PKG_FROM_AUR[@]}" -eq 0 ]]
echo 'packages: OK'
