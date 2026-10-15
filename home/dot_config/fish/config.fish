# ~/.config/fish/config.fish
#
# Gestionado por chezmoi. Para cambiarlo:
#   1. editar aquí y `chezmoi --source ~/dotfile-nuevo add <archivo-modificado>`   (lo devuelve al repo), o
#   2. editar en el repo y `make apply`.

# ---------------------------------------------------------------------------
# Variables de entorno
# Antes vivían en fish_variables, pero fish reescribe ese archivo solo ante
# cualquier variable universal, así que ya no se versiona (ver .chezmoiignore).
# ---------------------------------------------------------------------------
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less

# XDG: solo si el entorno no los definió ya (no pisar lo que ponga el DM).
set -q XDG_CONFIG_HOME; or set -gx XDG_CONFIG_HOME $HOME/.config
set -q XDG_DATA_HOME; or set -gx XDG_DATA_HOME $HOME/.local/share
set -q XDG_STATE_HOME; or set -gx XDG_STATE_HOME $HOME/.local/state
set -q XDG_CACHE_HOME; or set -gx XDG_CACHE_HOME $HOME/.cache

# fish_add_path es idempotente: no duplica entradas entre sesiones.
fish_add_path --prepend $HOME/.local/bin

if status is-interactive
    # Starship custom prompt
    command -v starship &> /dev/null && starship init fish | source

    # Direnv + Zoxide
    command -v direnv &> /dev/null && direnv hook fish | source
    command -v zoxide &> /dev/null && zoxide init fish --cmd cd | source

    # mise: sin esto los toolchains (node, python, go...) no aparecen en el PATH
    command -v mise &> /dev/null && mise activate fish | source

    # Better ls
    command -v eza &> /dev/null && alias ls='eza --icons --group-directories-first -1'

    # Abbrs
    abbr lg 'lazygit'
    abbr gd 'git diff'
    abbr ga 'git add .'
    abbr gc 'git commit -am'
    abbr gl 'git log'
    abbr gs 'git status'
    abbr gst 'git stash'
    abbr gsp 'git stash pop'
    abbr gp 'git push'
    abbr gpl 'git pull'
    abbr gsw 'git switch'
    abbr gsm 'git switch main'
    abbr gb 'git branch'
    abbr gbd 'git branch -d'
    abbr gco 'git checkout'
    abbr gsh 'git show'

    abbr l 'ls'
    abbr ll 'ls -l'
    abbr la 'ls -a'
    abbr lla 'ls -la'

    # Custom colours
    cat ~/.local/state/caelestia/sequences.txt 2> /dev/null

    # For jumping between prompts in foot terminal
    function mark_prompt_start --on-event fish_prompt
        echo -en "\e]133;A\e\\"
    end

    # Custom fish config
    set -q XDG_CONFIG_HOME && set -l cConf $XDG_CONFIG_HOME/caelestia || set -l cConf $HOME/.config/caelestia
    source $cConf/user-config.fish 2> /dev/null
end

# ---------------------------------------------------------------------------
# ssh-agent
#
# Antes se ejecutaba `eval (ssh-agent -c)` en cada shell sin SSH_AUTH_SOCK, lo
# que dejaba un agente huérfano por terminal abierta. Ahora se reutiliza un
# socket fijo en $XDG_RUNTIME_DIR: un solo agente por sesión gráfica.
# ---------------------------------------------------------------------------
if status is-interactive
    set -q XDG_RUNTIME_DIR; or set -l XDG_RUNTIME_DIR "/run/user/(id -u)"

    if not set -q SSH_AUTH_SOCK
        set -l socket "$XDG_RUNTIME_DIR/ssh-agent.socket"

        if test -S $socket
            set -gx SSH_AUTH_SOCK $socket
        else
            eval (ssh-agent -a $socket -c) > /dev/null
            set -gx SSH_AUTH_SOCK $socket
        end

        # Cargar las llaves que existan (sin fallar si piden passphrase)
        for key in $HOME/.ssh/id_ed25519 $HOME/.ssh/id_rsa $HOME/.ssh/id_ecdsa
            test -f $key; and ssh-add -q $key 2> /dev/null
        end
    end
end
