# Tacit's zsh setup for everyone (tacit-session, /usr/share/tacit/zsh/tacit.zsh), matching fish's
# (/usr/share/fish/vendor_conf.d/tacit.fish). Loaded from /etc/zsh/zshenv, which tacit-session writes only where there is
# none: /etc/zsh/zshrc belongs to grml-zsh-config and /etc/zsh/zprofile to zsh. A person's own ~/.zshrc runs after this
# and can change any of it.
if [[ -o interactive ]]; then
    # Ctrl+S stops freezing the terminal and # starts a comment, as in fish
    setopt no_flow_control
    setopt interactive_comments

    # oh-my-zsh, where installed (a person's own ~/.oh-my-zsh first): its compinit and the git plugin. No theme,
    # so the prompt stays Tacit's Starship below, and no auto-update (that belongs to the packages)
    for tacit_omz in "$HOME/.oh-my-zsh" /usr/share/oh-my-zsh; do
        if [[ -r "$tacit_omz/oh-my-zsh.sh" ]]; then
            export ZSH="$tacit_omz"
            ZSH_THEME=""
            DISABLE_AUTO_UPDATE=true
            plugins=(git)
            source "$ZSH/oh-my-zsh.sh"
            break
        fi
    done
    unset tacit_omz

    # a completion system even without oh-my-zsh (grml normally brings one); -i keeps a first start from asking
    # about directories compaudit dislikes
    if (( ! $+functions[compdef] )); then
        autoload -Uz compinit && compinit -i
    fi

    # suggestions from history as you type, as fish has; oh-my-zsh does not ship it
    for tacit_suggestions in \
        /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
        "${ZSH_CUSTOM:-$ZSH/custom}/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" \
        "$ZSH/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
        if [[ -r "$tacit_suggestions" ]]; then
            source "$tacit_suggestions"
            break
        fi
    done
    unset tacit_suggestions

    # the prompt: Tacit's Starship (design D, /usr/share/tacit/starship.toml) unless the person has their own
    if [[ "$TERM" != "linux" ]] && (( $+commands[starship] )); then
        if [[ -z "$STARSHIP_CONFIG" && ! -f "$HOME/.config/starship.toml" ]]; then
            export STARSHIP_CONFIG="/usr/share/tacit/starship.toml"
        fi
        eval "$(starship init zsh)"
    fi

    # the wallpaper's colours (switchwall.sh writes them). kitty takes the see-through background ([alpha]#rrggbb,
    # foot's form) for no colour and goes back to black, so it is left out there
    if [[ -r "$HOME/.local/state/quickshell/user/generated/terminal/sequences.txt" ]]; then
        if [[ -n "$KITTY_WINDOW_ID" ]]; then
            sed 's/\x1b\]11;\[[0-9]*\][^\x1b]*\x1b\\//g' "$HOME/.local/state/quickshell/user/generated/terminal/sequences.txt"
        else
            cat "$HOME/.local/state/quickshell/user/generated/terminal/sequences.txt"
        fi
    fi

    alias clear="printf '\033[2J\033[3J\033[1;1H'"
    if [[ "$TERM" != "linux" ]] && (( $+commands[eza] )); then
        # eza with icons everywhere; --icons=auto keeps them out of pipes and scripts
        alias ls='eza --icons=auto --group-directories-first'
        alias ll='eza --icons=auto --group-directories-first -l --git'
        alias la='eza --icons=auto --group-directories-first -la --git'
        alias lt='eza --icons=auto --group-directories-first --tree --level=2'
        alias tree='eza --icons=auto --group-directories-first --tree'
    fi
fi
