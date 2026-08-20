# ------------------------------------------------------------------------------
# Languages
# ------------------------------------------------------------------------------
export GEM_HOME="$HOME/.gem"
export GOPATH="$HOME/.go"

# ------------------------------------------------------------------------------
# fzf
#
# The variable names matter: fzf reads FZF_CTRL_T_COMMAND and FZF_ALT_C_COMMAND.
# ------------------------------------------------------------------------------
export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"

fzf_colors="pointer:#ebdbb2,bg+:#3c3836,fg:#ebdbb2,fg+:#fbf1c7,hl:#8ec07c,info:#928374,header:#fb4934"
export FZF_DEFAULT_OPTS="--color=$fzf_colors --reverse"

# ------------------------------------------------------------------------------
# Path - the higher it is, the more priority it has
# ------------------------------------------------------------------------------
path=(
	"$HOME/bin"
	"$HOME/.local/bin"
	"$DOTFILES_PATH/bin"
	"$DOTLY_PATH/bin"
	"$HOME/.cargo/bin"
	"$HOME/.bun/bin"
	"$HOME/.opencode/bin"
	"$GEM_HOME/bin"
	"$GOPATH/bin"
	$path
)

export path
