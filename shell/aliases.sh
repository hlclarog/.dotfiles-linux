# Enable aliases to be sudo'ed
alias sudo='sudo '

# ------------------------------------------------------------------------------
# Navigation
# ------------------------------------------------------------------------------
alias ..="cd .."
alias ...="cd ../.."
alias cls='clear'
alias ~="cd ~"
alias dotfiles='cd $DOTFILES_PATH'

# ------------------------------------------------------------------------------
# Listing
#
# GNU coreutils installs its tools with a "g" prefix outside of Linux, so gls is
# preferred when present and plain ls is the fallback.
# ------------------------------------------------------------------------------
if command -v gls >/dev/null 2>&1; then
	alias ls='gls --color=auto'
else
	alias ls='ls --color=auto'
fi
alias ll="ls -l"
alias la="ls -la"

# ------------------------------------------------------------------------------
# bat
#
# Debian and Ubuntu ship the binary as batcat because the name bat was already
# taken; Homebrew ships it as bat.
# ------------------------------------------------------------------------------
if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
	alias bat='batcat'
	alias batp='batcat --style=plain'
elif command -v bat >/dev/null 2>&1; then
	alias batp='bat --style=plain'
fi

# ------------------------------------------------------------------------------
# Git
# ------------------------------------------------------------------------------
alias gaa="git add -A"
alias gc='$DOTLY_PATH/bin/dot git commit'
alias gca="git add --all && git commit --amend --no-edit"
alias gco="git checkout"
alias gd='$DOTLY_PATH/bin/dot git pretty-diff'
alias gl='$DOTLY_PATH/bin/dot git pretty-log'
alias gs="git status -sb"
alias gf="git fetch --all -p"
alias gps="git push"
alias gpsf="git push --force"
alias gpl="git pull --rebase --autostash"
alias gb="git branch"
alias lg='lazygit'

# ------------------------------------------------------------------------------
# dotly
# ------------------------------------------------------------------------------
alias up='dot package update_all'

# ------------------------------------------------------------------------------
# Projects
# ------------------------------------------------------------------------------
alias cdp='cd $HOME/Projects'
alias cdc='cd $HOME/Projects/code && la'
alias cdw='cd $HOME/Projects/work'

# ------------------------------------------------------------------------------
# Utils
# ------------------------------------------------------------------------------
alias k='kill -9'
alias fzfbat='fzf --preview="bat --theme=gruvbox-dark --color=always {}"'
alias fzfnvim='nvim $(fzf --preview="bat --theme=gruvbox-dark --color=always {}")'

# Opening a path in the host file manager, under WSL
if command -v explorer.exe >/dev/null 2>&1; then
	alias o.='explorer.exe .'
fi

# ------------------------------------------------------------------------------
# SSH
# ------------------------------------------------------------------------------
alias ssh-start='. $DOTFILES_PATH/tools/git/ssh-start-agent.sh'

# VS Code, reachable through Windows interop under WSL
if command -v code >/dev/null 2>&1; then
	alias c.='(code $PWD &>/dev/null &)'
fi
