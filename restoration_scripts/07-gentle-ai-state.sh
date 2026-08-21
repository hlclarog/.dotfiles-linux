#!/usr/bin/env bash
# Seed gentle-ai's saved selections so a fresh machine does not have to redo them
# by hand in the TUI.
#
# ~/.gentle-ai/state.json holds the preset, the SDD mode, the strict-TDD flag and
# roughly fifty per-phase model and effort assignments. `gentle-ai` reinstalls the
# generated assets under ~/.claude, ~/.config/opencode and ~/.codex from those
# selections, so this one small file is what makes the whole agent setup
# reproducible.
#
# It is copied rather than symlinked on purpose: gentle-ai owns this file and
# writes it with a lock, and a tool that replaces a file atomically would swap the
# symlink for a regular one and silently break the link. Re-export after changing
# settings in the TUI:
#
#     cp ~/.gentle-ai/state.json "$DOTFILES_PATH/os/linux/gentle-ai/state.json"
#
# Sourced by `dot self install`, so it uses return rather than exit.

_gentle_ai_src="$DOTFILES_PATH/os/linux/gentle-ai/state.json"
_gentle_ai_dst="$HOME/.gentle-ai/state.json"

if [ ! -f "$_gentle_ai_src" ]; then
	echo " > No gentle-ai state in the repo, skipping"
elif [ -f "$_gentle_ai_dst" ]; then
	if cmp -s "$_gentle_ai_src" "$_gentle_ai_dst"; then
		echo " > gentle-ai state already matches the repo"
	else
		echo " > gentle-ai state differs from the repo, leaving the live file alone"
		echo "   repo:  $_gentle_ai_src"
		echo "   live:  $_gentle_ai_dst"
		echo "   Compare with: diff \"$_gentle_ai_src\" \"$_gentle_ai_dst\""
	fi
else
	mkdir -p "$(dirname "$_gentle_ai_dst")"
	cp "$_gentle_ai_src" "$_gentle_ai_dst"
	echo " > gentle-ai state restored, run 'gentle-ai' to reinstall the assets"
fi

unset _gentle_ai_src _gentle_ai_dst
