# Tacit's terminal for everyone (tacit-session, fish's vendor_conf.d): the owner's config.fish (2026-10-16) less what is
# only theirs. A person's own ~/.config/fish/config.fish runs after this and wins.
if status is-interactive
    set -g fish_greeting
    # the prompt: Tacit's Starship (design D, /usr/share/tacit/starship.toml) unless the person has their own
    if test "$TERM" != "linux"; and command -q starship
        set -q STARSHIP_CONFIG; or test -f ~/.config/starship.toml; or set -gx STARSHIP_CONFIG /usr/share/tacit/starship.toml
        function starship_transient_prompt_func
            starship module character
        end
        starship init fish | source
        enable_transience
    end
    # the wallpaper's colours (switchwall.sh writes them). kitty takes the see-through background ([alpha]#rrggbb,
    # foot's form) for no colour and goes back to black, so it is left out there
    if test -f ~/.local/state/quickshell/user/generated/terminal/sequences.txt
        if set -q KITTY_WINDOW_ID
            sed 's/\x1b\]11;\[[0-9]*\][^\x1b]*\x1b\\\\//g' ~/.local/state/quickshell/user/generated/terminal/sequences.txt
        else
            cat ~/.local/state/quickshell/user/generated/terminal/sequences.txt
        end
    end
    alias clear "printf '\033[2J\033[3J\033[1;1H'"
    if test "$TERM" != "linux"; and command -q eza
        # eza with icons everywhere; --icons=auto keeps them out of pipes and scripts
        alias ls   'eza --icons=auto --group-directories-first'
        alias ll   'eza --icons=auto --group-directories-first -l --git'
        alias la   'eza --icons=auto --group-directories-first -la --git'
        alias lt   'eza --icons=auto --group-directories-first --tree --level=2'
        alias tree 'eza --icons=auto --group-directories-first --tree'
    end
end
