function normal_mode
    hyprctl dispatch dpms on
    sudo cpupower frequency-set -g schedutil
    echo "Rendimiento del CPU restaurado a normal."
end
