export DOTFILES_PATH="$HOME/.dotfiles"
export DOTLY_PATH="$DOTFILES_PATH/modules/dotly"

# This file replaces the one rustup writes, so cargo has to be sourced here.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
