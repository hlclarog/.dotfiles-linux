#!/usr/bin/env bash
# Link the Windows projects folder into $HOME when running under WSL.
#
# The link is an indirection layer on purpose: every navigation alias points at
# ~/Projects, so moving the real folder later — for instance into the WSL
# filesystem, where 9p no longer slows git and file watchers down — only needs
# this one link repointed.
#
# Sourced by `dot self install`, so it uses return instead of exit.

WSL_PROJECTS="/mnt/d/Projects"
LINK="$HOME/Projects"

if [ ! -d "$WSL_PROJECTS" ]; then
	return 0
fi

if [ -L "$LINK" ]; then
	current="$(readlink "$LINK")"
	if [ "$current" = "$WSL_PROJECTS" ]; then
		return 0
	fi
	echo " > Repointing $LINK: $current -> $WSL_PROJECTS"
	rm -f "$LINK"
elif [ -e "$LINK" ]; then
	echo " > $LINK already exists and is not a symlink, leaving it alone"
	return 0
fi

ln -s "$WSL_PROJECTS" "$LINK"
echo " > Linked $LINK -> $WSL_PROJECTS"
