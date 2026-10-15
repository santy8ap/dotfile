#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hardware.sh — detección de hardware y de la distro.
#
# Sirve para filtrar paquetes etiquetados con `# hw:...` en packages/*.txt y
# para decidir qué servicios/tweaks tienen sentido en esta máquina.
#
# Deja estas globales tras llamar a hw_detect:
#   HW_GPU_VENDOR   amd | intel | nvidia | desconocida
#   HW_CPU_VENDOR   amd | intel | otro
#   HW_IS_LAPTOP    yes | no
#   HW_IS_FRAMEWORK yes | no
#   HW_DISTRO       cachyos | arch | otro
#   HW_TAGS         lista separada por espacios: "amd laptop framework"
# ---------------------------------------------------------------------------

[[ -n "${_DOTFILE_HARDWARE_SH:-}" ]] && return 0
_DOTFILE_HARDWARE_SH=1

HW_GPU_VENDOR="desconocida"
HW_CPU_VENDOR="otro"
HW_IS_LAPTOP="no"
HW_IS_FRAMEWORK="no"
HW_DISTRO="otro"
HW_TAGS=""

# --- GPU -------------------------------------------------------------------
# 1) sysfs (no requiere pciutils): /sys/class/drm/cardN/device/vendor
#    0x1002 = AMD/ATI, 0x8086 = Intel, 0x10de = NVIDIA
_hw_gpu_from_sysfs() {
    local f vendor
    for f in /sys/class/drm/card*/device/vendor; do
        [[ -r "$f" ]] || continue
        vendor="$(cat "$f" 2> /dev/null || true)"
        case "$vendor" in
            0x1002) echo "amd";    return 0 ;;
            0x8086) echo "intel";  return 0 ;;
            0x10de) echo "nvidia"; return 0 ;;
        esac
    done
    return 1
}

# 2) lspci como respaldo
_hw_gpu_from_lspci() {
    command -v lspci > /dev/null 2>&1 || return 1
    local out
    out="$(lspci 2> /dev/null | grep -iE 'vga|3d|display' || true)"
    [[ -n "$out" ]] || return 1
    if grep -qiE 'amd|ati|radeon' <<< "$out"; then echo "amd"; return 0; fi
    if grep -qi 'nvidia' <<< "$out"; then echo "nvidia"; return 0; fi
    if grep -qi 'intel' <<< "$out"; then echo "intel"; return 0; fi
    return 1
}

# --- CPU -------------------------------------------------------------------
_hw_cpu_vendor() {
    if [[ -r /proc/cpuinfo ]]; then
        if grep -qi 'AuthenticAMD' /proc/cpuinfo; then echo "amd"; return 0; fi
        if grep -qi 'GenuineIntel' /proc/cpuinfo; then echo "intel"; return 0; fi
    fi
    echo "otro"
}

# --- Portátil --------------------------------------------------------------
_hw_is_laptop() {
    # Batería presente
    local b
    for b in /sys/class/power_supply/BAT*; do
        [[ -e "$b" ]] && { echo "yes"; return 0; }
    done
    # chassis_type: 8=portable 9=laptop 10=notebook 14=subnotebook 31=convertible 32=detachable
    local ct=""
    [[ -r /sys/class/dmi/id/chassis_type ]] && ct="$(cat /sys/class/dmi/id/chassis_type 2> /dev/null || true)"
    case "$ct" in
        8|9|10|14|31|32) echo "yes"; return 0 ;;
    esac
    echo "no"
}

# --- Framework -------------------------------------------------------------
_hw_is_framework() {
    local v="" p=""
    [[ -r /sys/class/dmi/id/sys_vendor ]] && v="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    [[ -r /sys/class/dmi/id/product_name ]] && p="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    if grep -qi 'framework' <<< "$v" || grep -qi 'framework' <<< "$p"; then
        echo "yes"; return 0
    fi
    echo "no"
}

# --- Distro ----------------------------------------------------------------
_hw_distro() {
    [[ -r /etc/os-release ]] || { echo "otro"; return 0; }
    # shellcheck disable=SC1091
    local ID="" ID_LIKE="" NAME=""
    source /etc/os-release
    case "${ID:-}" in
        cachyos) echo "cachyos"; return 0 ;;
        arch)    echo "arch";    return 0 ;;
    esac
    case "${ID_LIKE:-}" in
        *arch*) echo "arch"; return 0 ;;
    esac
    echo "otro"
}

# --- API -------------------------------------------------------------------
hw_detect() {
    local gpu=""
    gpu="$(_hw_gpu_from_sysfs || true)"
    [[ -n "$gpu" ]] || gpu="$(_hw_gpu_from_lspci || true)"
    HW_GPU_VENDOR="${gpu:-desconocida}"

    HW_CPU_VENDOR="$(_hw_cpu_vendor)"
    HW_IS_LAPTOP="$(_hw_is_laptop)"
    HW_IS_FRAMEWORK="$(_hw_is_framework)"
    HW_DISTRO="$(_hw_distro)"

    HW_TAGS="$HW_GPU_VENDOR $HW_CPU_VENDOR"
    [[ "$HW_IS_LAPTOP" == "yes" ]] && HW_TAGS+=" laptop" || HW_TAGS+=" desktop"
    [[ "$HW_IS_FRAMEWORK" == "yes" ]] && HW_TAGS+=" framework"
    [[ "$HW_DISTRO" == "cachyos" ]] && HW_TAGS+=" cachyos"

    # Multilib: solo x86_64
    [[ "$(uname -m)" == "x86_64" ]] && HW_TAGS+=" multilib"

    export HW_GPU_VENDOR HW_CPU_VENDOR HW_IS_LAPTOP HW_IS_FRAMEWORK HW_DISTRO HW_TAGS
}

# hw_matches <etiquetas del paquete separadas por coma>
# Devuelve 0 si el paquete aplica a esta máquina.
# Sin etiqueta -> siempre aplica. Etiquetas separadas por coma = "cualquiera de".
hw_matches() {
    local tags="${1:-}"
    [[ -z "$tags" ]] && return 0
    local t
    local IFS=','
    for t in $tags; do
        t="$(echo "$t" | tr -d '[:space:]')"
        [[ -z "$t" ]] && continue
        case " ${HW_TAGS} " in
            *" ${t} "*) return 0 ;;
        esac
    done
    return 1
}

hw_summary() {
    printf '%-18s %s\n' "Distro:"        "$HW_DISTRO"
    printf '%-18s %s\n' "GPU:"           "$HW_GPU_VENDOR"
    printf '%-18s %s\n' "CPU:"           "$HW_CPU_VENDOR"
    printf '%-18s %s\n' "Portátil:"      "$HW_IS_LAPTOP"
    printf '%-18s %s\n' "Framework:"     "$HW_IS_FRAMEWORK"
    printf '%-18s %s\n' "Arquitectura:"  "$(uname -m)"
    printf '%-18s %s\n' "Kernel:"        "$(uname -r)"
    printf '%-18s %s\n' "Hostname:"      "$(hostname)"
    printf '%-18s %s\n' "Etiquetas hw:"  "$HW_TAGS"
}

# Permite correrlo directo para depurar:  scripts/lib/hardware.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    hw_detect
    hw_summary
fi
