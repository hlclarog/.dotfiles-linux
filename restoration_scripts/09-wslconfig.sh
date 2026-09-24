#!/usr/bin/env bash
# Install %USERPROFILE%\.wslconfig from os/linux/wsl/.wslconfig.
#
# This file configures the WSL2 VM itself and lives on the Windows side, so
# neither dotbot nor anything inside the distribution can symlink it. Same
# situation as /etc/wsl.conf, handled the same way: compare first, write only on
# a real difference.
#
# The Windows profile path is read from PowerShell rather than guessed from the
# Linux user name — they do not always match, and %USERPROFILE% is authoritative.
#
# Sourced by `dot self install`, so it uses return rather than exit.

grep -qi microsoft /proc/version 2>/dev/null || return 0

wslcfg_template="$DOTFILES_PATH/os/linux/wsl/.wslconfig"
[ -f "$wslcfg_template" ] || return 0

wslcfg_ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
if [ ! -x "$wslcfg_ps" ]; then
	echo " > No PowerShell found, cannot locate the Windows profile. Skipping .wslconfig"
	unset wslcfg_template wslcfg_ps
	return 0
fi

wslcfg_winhome=$("$wslcfg_ps" -NoProfile -Command '$env:USERPROFILE' 2>/dev/null | tr -d '\r')
wslcfg_target=$(wslpath -u "$wslcfg_winhome" 2>/dev/null)/.wslconfig

if [ -z "$wslcfg_winhome" ] || [ ! -d "$(dirname "$wslcfg_target")" ]; then
	echo " > Could not resolve the Windows profile directory, skipping .wslconfig"
	unset wslcfg_template wslcfg_ps wslcfg_winhome wslcfg_target
	return 0
fi

if [ -f "$wslcfg_target" ] && cmp -s "$wslcfg_template" "$wslcfg_target"; then
	echo " > $wslcfg_target already matches the repository"
else
	cp "$wslcfg_template" "$wslcfg_target"
	echo " > $wslcfg_target updated"
	echo " > Run 'wsl --shutdown' from Windows for it to take effect, then wait"
	echo " > ~10 seconds before reopening: reconnecting sooner reuses the old VM"
	echo " > and the distribution stays on the NAT network."
fi

unset wslcfg_template wslcfg_ps wslcfg_winhome wslcfg_target
