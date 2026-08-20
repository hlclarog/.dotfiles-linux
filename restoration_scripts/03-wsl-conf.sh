#!/usr/bin/env bash
# Install /etc/wsl.conf from os/linux/wsl/wsl.conf.
#
# This file lives outside $HOME, so dotbot cannot symlink it and the repo has no
# other way to reproduce it. Everything here is idempotent: it compares first
# and only writes when the content actually differs.
#
# Sourced by `dot self install`, so it uses return rather than exit.

grep -qi microsoft /proc/version 2>/dev/null || return 0

wsl_template="$DOTFILES_PATH/os/linux/wsl/wsl.conf"
wsl_target="/etc/wsl.conf"

[ -f "$wsl_template" ] || return 0

wsl_render() { sed "s|__WSL_USER__|$(id -un)|" "$wsl_template"; }

if [ -f "$wsl_target" ] && wsl_render | cmp -s - "$wsl_target"; then
	echo " > $wsl_target already matches the repository"
	unset -f wsl_render
	return 0
fi

# Never block on a password prompt: a restoration script runs unattended.
if ! sudo -n true 2>/dev/null; then
	echo " > $wsl_target needs updating but sudo needs a password here."
	echo " > Run this, then restart the distribution:"
	echo "     sed \"s|__WSL_USER__|\$(id -un)|\" \"\$DOTFILES_PATH/os/linux/wsl/wsl.conf\" | sudo tee /etc/wsl.conf >/dev/null"
	unset -f wsl_render
	return 0
fi

wsl_render | sudo tee "$wsl_target" >/dev/null
unset -f wsl_render

echo " > $wsl_target updated"
echo " > Run 'wsl --shutdown' from Windows for it to take effect: wsl.conf is"
echo " > read when the distribution boots and is never reloaded in place."
