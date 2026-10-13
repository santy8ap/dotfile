function server_mode
    echo "Reduciendo consumo del CPU..."
    sudo cpupower frequency-set -g powersave
    echo "Apagando pantalla en 3 segundos..."
    sleep 3
    hyprctl dispatch dpms off
end
