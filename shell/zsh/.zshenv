export DOTFILES_PATH="$HOME/.dotfiles"
export DOTLY_PATH="$DOTFILES_PATH/modules/dotly"

# This file replaces the one rustup writes, so cargo has to be sourced here.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Non-interactive sessions (mosh and the Moshi app start mosh-server through
# `ssh host mosh-server ...`) read only this file, so Homebrew's bin has to be on
# PATH here or mosh-server is not found. ZSHENV_BREW_BINS is a test override.
for zshenv_brew_bin in ${=ZSHENV_BREW_BINS:-/home/linuxbrew/.linuxbrew/bin /opt/homebrew/bin}; do
	[ -d "$zshenv_brew_bin" ] || continue
	case ":$PATH:" in
	*":$zshenv_brew_bin:"*) ;;
	*) PATH="$zshenv_brew_bin:$PATH" ;;
	esac
done
unset zshenv_brew_bin
export PATH
