#!/usr/bin/env bash
# Fix Dotly's `sudo chsh -s "$(command -v zsh)"` at
# modules/dotly/scripts/self/install:34 -- that command passes NO username, so
# under sudo, chsh changes ROOT's login shell, never the invoking user's.
# Verified on a fresh Ubuntu 24.04 VM: after `dot self install`, `getent
# passwd` showed `root:...:/home/linuxbrew/.linuxbrew/bin/zsh` and
# `hclaro:...:/bin/bash`. The user's login shell stayed bash, so zsh-only
# config (starship prompt, atuin, herdr autostart) never loaded on login.
# Upstream Dotly HEAD still has the same bug.
#
# This script (sorting first, 00-) sets the invoking user's login shell
# instead, and also undoes the side effect line 34 left behind: a root shell
# pointed at a Homebrew prefix owned by a regular user, which breaks root
# logins entirely if that Homebrew installation ever breaks.
#
# Sourced by `dot self install`, so it uses return rather than exit.

zsh_path="$(command -v zsh)"
if [ -z "$zsh_path" ]; then
	echo " > zsh is not installed, skipping login shell setup"
	unset zsh_path
	return 0
fi

# macOS has no getent; its directory service answers instead. Without this,
# every `dot self install` on a Mac would prompt for sudo to chsh a user who
# is already on zsh.
login_shell_of() {
	if [ "$(uname -s)" = "Darwin" ]; then
		dscl . -read "/Users/$1" UserShell 2>/dev/null | awk '{print $2}'
	else
		getent passwd "$1" 2>/dev/null | awk -F: '{print $7}'
	fi
}

user_name="${USER:-$(id -un)}"
current_shell=$(login_shell_of "$user_name")
shells_file="${SHELLS_FILE:-/etc/shells}"

already_zsh=false
if [ "$current_shell" = "$zsh_path" ]; then
	already_zsh=true
elif [[ "$current_shell" == */zsh ]] && grep -Fxq "$current_shell" "$shells_file" 2>/dev/null; then
	already_zsh=true
fi

if [ "$already_zsh" = true ]; then
	echo " > Login shell already zsh"
else
	if ! grep -Fxq "$zsh_path" "$shells_file" 2>/dev/null; then
		if ! echo "$zsh_path" | sudo tee -a "$shells_file" >/dev/null; then
			echo " > Could not add $zsh_path to $shells_file automatically."
			echo " > Run manually: echo \"$zsh_path\" | sudo tee -a \"$shells_file\" && sudo chsh -s \"$zsh_path\" \"$user_name\""
			unset zsh_path user_name current_shell shells_file already_zsh
			return 0
		fi
	fi

	if sudo chsh -s "$zsh_path" "$user_name"; then
		echo " > Login shell for $user_name set to $zsh_path (takes effect on next login)"
	else
		echo " > Could not set the login shell automatically."
		echo " > Run manually: sudo chsh -s \"$zsh_path\" \"$user_name\""
		unset zsh_path user_name current_shell shells_file already_zsh
		return 0
	fi
fi

if [ "$(uname -s)" != "Darwin" ]; then
	root_shell=$(login_shell_of root)
	case "$root_shell" in
	*/linuxbrew/* | */homebrew/*)
		if sudo chsh -s /bin/bash root; then
			echo " > Reset root's login shell from $root_shell to /bin/bash: a root shell under a user-owned Homebrew prefix breaks root logins if that Homebrew installation ever breaks"
		else
			echo " > Could not reset root's login shell automatically."
			echo " > Run manually: sudo chsh -s /bin/bash root"
		fi
		;;
	esac
	unset root_shell
fi

unset zsh_path user_name current_shell shells_file already_zsh
unset -f login_shell_of
return 0
