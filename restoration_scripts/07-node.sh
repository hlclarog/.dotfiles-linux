#!/usr/bin/env bash
# Install and pin the Node version this machine develops against.
#
# The pin itself lives in fnm's own state, at
# ~/.local/share/fnm/aliases/default, which is a symlink outside the repo. A
# clean restore therefore ends up with fnm installed and no Node at all, so the
# version is declared here instead and applied from the declaration.
#
# Sourced by `dot self install`, so it uses return rather than exit.

_node_version_file="$DOTFILES_PATH/os/linux/node-version"

if [ ! -f "$_node_version_file" ]; then
	echo " > No node-version declared, skipping"
elif ! command -v fnm >/dev/null 2>&1; then
	echo " > fnm is not installed yet, skipping (it comes from the Brewfile)"
else
	_node_version="$(tr -d '[:space:]' <"$_node_version_file")"

	eval "$(fnm env)"

	if fnm list 2>/dev/null | grep -q "$_node_version"; then
		echo " > Node $_node_version already installed"
	else
		echo " > Installing Node $_node_version"
		fnm install "$_node_version"
	fi

	fnm default "$_node_version"
	echo " > Node default set to $(fnm current 2>/dev/null || echo "$_node_version")"

	unset _node_version
fi

unset _node_version_file
