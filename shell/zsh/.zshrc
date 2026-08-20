#!/usr/bin/env zsh
# ------------------------------------------------------------------------------
# Interactive zsh configuration.
#
# Managed in $DOTFILES_PATH and symlinked to ~/.zshrc by dotly.
# Base taken from Gentleman.Dots, with oh-my-zsh and powerlevel10k removed in
# favour of starship, plus the dotly integration (aliases, exports, functions).
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Homebrew — first, because everything below resolves inside its prefix
# ------------------------------------------------------------------------------
BREW_BIN=""
if [[ "$(uname)" == "Darwin" ]]; then
	[[ -x /opt/homebrew/bin/brew ]] && BREW_BIN=/opt/homebrew/bin
	[[ -z $BREW_BIN && -x /usr/local/bin/brew ]] && BREW_BIN=/usr/local/bin
else
	[[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] && BREW_BIN=/home/linuxbrew/.linuxbrew/bin
fi
[[ -n $BREW_BIN ]] && eval "$($BREW_BIN/brew shellenv)"

source_if_exists() { [[ -f "$1" ]] && source "$1" }

# ------------------------------------------------------------------------------
# dotly — shared aliases, exports and functions (also used by bash)
# ------------------------------------------------------------------------------
source_if_exists "$DOTFILES_PATH/shell/init.sh"

# ------------------------------------------------------------------------------
# Shell options
# ------------------------------------------------------------------------------
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FCNTL_LOCK
setopt +o nomatch

export EDITOR="nvim"
export VISUAL="nvim"

export LS_COLORS="di=38;5;67:ow=48;5;60:ex=38;5;132:ln=38;5;144:*.tar=38;5;180:*.zip=38;5;180:*.jpg=38;5;175:*.png=38;5;175:*.mp3=38;5;175:*.wav=38;5;175:*.txt=38;5;223:*.sh=38;5;132"

# ------------------------------------------------------------------------------
# Plugins — order matters: autocomplete first, syntax highlighting last
# ------------------------------------------------------------------------------
ZSH_AUTOSUGGEST_USE_ASYNC=true
ZSH_HIGHLIGHT_MAXLENGTH=300
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)

if [[ -n $BREW_BIN ]]; then
	BREW_SHARE="$(dirname $BREW_BIN)/share"
	source_if_exists "$BREW_SHARE/zsh-autocomplete/zsh-autocomplete.plugin.zsh"
	source_if_exists "$BREW_SHARE/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# Native package layouts, for machines without brew
source_if_exists "/usr/share/zsh/plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh"
source_if_exists "/usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
source_if_exists "/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"

# Debian/Ubuntu ship this natively. It replaces the oh-my-zsh
# command-not-found plugin, which was the only reason oh-my-zsh was loaded.
source_if_exists /etc/zsh_command_not_found

# ------------------------------------------------------------------------------
# Completions — oh-my-zsh used to run compinit, so we do it ourselves now
# ------------------------------------------------------------------------------
fpath=(
	"$DOTFILES_PATH/shell/zsh/completions"
	"$DOTLY_PATH/shell/zsh/completions"
	$fpath
)
autoload -Uz compinit && compinit -C

source_if_exists "$DOTLY_PATH/shell/zsh/bindings/dot.zsh"
source_if_exists "$DOTLY_PATH/shell/zsh/bindings/reverse_search.zsh"
source_if_exists "$DOTFILES_PATH/shell/zsh/key-bindings.zsh"

# ------------------------------------------------------------------------------
# Tooling
# ------------------------------------------------------------------------------
export CARAPACE_BRIDGES='zsh,fish,bash,inshellisense'
zstyle ':completion:*' format $'\e[2;37mCompleting %d\e[m'
command -v carapace >/dev/null 2>&1 && source <(carapace _carapace)

command -v fzf >/dev/null 2>&1 && eval "$(fzf --zsh)"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v atuin >/dev/null 2>&1 && eval "$(atuin init zsh)"

# Syntax highlighting must be sourced after everything that binds widgets
if [[ -n $BREW_BIN ]]; then
	source_if_exists "$BREW_SHARE/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
source_if_exists "/usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
source_if_exists "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# ------------------------------------------------------------------------------
# Prompt
# ------------------------------------------------------------------------------
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

# ------------------------------------------------------------------------------
# Multiplexer autostart
# ------------------------------------------------------------------------------
WM_CMD="herdr"

start_if_needed() {
	[[ $- == *i* ]] || return 0
	[[ -t 1 ]] || return 0
	command -v "$WM_CMD" >/dev/null 2>&1 || return 0
	[[ -n $HERDR_ENV || -n $TMUX || -n $ZELLIJ ]] && return 0
	exec "$WM_CMD"
}

start_if_needed
