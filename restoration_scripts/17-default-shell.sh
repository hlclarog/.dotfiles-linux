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
# This script sets the invoking user's login shell, and also undoes the side
# effect line 34 left behind: a root shell pointed at zsh, typically a
# Homebrew prefix owned by a regular user, which breaks root logins entirely
# if that Homebrew installation ever breaks.
#
# It used to sort first (00-), but that ran BEFORE
# restoration_scripts/04-brew-packages.sh installs Homebrew's zsh. Measured on
# a fresh Ubuntu 24.04 VM (reference machine uses Homebrew's zsh): running
# before 04 meant `command -v zsh` only ever found /usr/bin/zsh, so the login
# shell was set to the wrong zsh every time, and rerunning never fixed it --
# the old check treated ANY zsh listed in /etc/shells as already done.
# Sorting last (17-) only delays the next-login effect by one restore step,
# which costs nothing, and lets this script prefer a Homebrew zsh over
# whatever `command -v zsh` happens to find first.
#
# Sourced by `dot self install`, so it uses return rather than exit.

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

zsh_candidates="${ZSH_CANDIDATES:-/home/linuxbrew/.linuxbrew/bin/zsh /opt/homebrew/bin/zsh /usr/local/bin/zsh}"
zsh_path=""
for candidate in $zsh_candidates; do
	if [ -x "$candidate" ]; then
		zsh_path="$candidate"
		break
	fi
done
unset candidate zsh_candidates

if [ -z "$zsh_path" ]; then
	zsh_path="$(command -v zsh)"
fi

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

if [ "$current_shell" = "$zsh_path" ]; then
	echo " > Login shell already zsh"
else
	if ! grep -Fxq "$zsh_path" "$shells_file" 2>/dev/null; then
		if ! echo "$zsh_path" | sudo tee -a "$shells_file" >/dev/null; then
			echo " > Could not add $zsh_path to $shells_file automatically."
			echo " > Run manually: echo \"$zsh_path\" | sudo tee -a \"$shells_file\" && sudo chsh -s \"$zsh_path\" \"$user_name\""
			unset zsh_path user_name current_shell shells_file
			return 0
		fi
	fi

	if sudo chsh -s "$zsh_path" "$user_name"; then
		echo " > Login shell for $user_name set to $zsh_path (takes effect on next login)"
	else
		echo " > Could not set the login shell automatically."
		echo " > Run manually: sudo chsh -s \"$zsh_path\" \"$user_name\""
		unset zsh_path user_name current_shell shells_file
		return 0
	fi
fi

if [ "$(uname -s)" != "Darwin" ]; then
	root_shell=$(login_shell_of root)
	reset_root=false
	case "$root_shell" in
	*/linuxbrew/* | */homebrew/*) reset_root=true ;;
	esac
	[ "${root_shell##*/}" = zsh ] && reset_root=true
	if [ "$reset_root" = true ]; then
		if sudo chsh -s /bin/bash root; then
			echo " > Reset root's login shell from $root_shell to /bin/bash: Dotly's own \`sudo chsh -s zsh\` (no username) changes ROOT's shell, and a root shell left on zsh breaks root logins if that zsh (often a user-owned Homebrew prefix) ever becomes unavailable"
		else
			echo " > Could not reset root's login shell automatically."
			echo " > Run manually: sudo chsh -s /bin/bash root"
		fi
	fi
	unset root_shell reset_root
fi

unset zsh_path user_name current_shell shells_file
unset -f login_shell_of
return 0
