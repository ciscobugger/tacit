# Tacit's zsh setup for everyone (tacit-session, /usr/share/tacit/zsh/tacit.zsh), matching fish's
# (/usr/share/fish/vendor_conf.d/tacit.fish). Loaded from /etc/zsh/zshenv, which tacit-session writes only where there is
# none: /etc/zsh/zshrc belongs to grml-zsh-config and /etc/zsh/zprofile to zsh. A person's own ~/.zshrc runs after this
# and can change any of it.
if [[ -o interactive ]]; then
    # the prompt: Tacit's Starship (design D, /usr/share/tacit/starship.toml) unless the person has their own
    if [[ "$TERM" != "linux" ]] && (( $+commands[starship] )); then
        if [[ -z "$STARSHIP_CONFIG" && ! -f "$HOME/.config/starship.toml" ]]; then
            export STARSHIP_CONFIG="/usr/share/tacit/starship.toml"
        fi
        eval "$(starship init zsh)"
    fi

    # the wallpaper's colours (switchwall.sh writes them)
    if [[ -f "$HOME/.local/state/quickshell/user/generated/terminal/sequences.txt" ]]; then
        cat "$HOME/.local/state/quickshell/user/generated/terminal/sequences.txt"
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
