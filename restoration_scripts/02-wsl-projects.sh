#!/usr/bin/env bash
# Link the Windows projects folder into $HOME as ~/Win when running under WSL.
#
# ~/Projects is deliberately NOT this link: it is a real ext4 directory holding
# the repositories being worked on, because /mnt is a 9p mount where git and
# builds are two orders of magnitude slower and inotify does not fire at all, so
# no watch-based dev server sees a change. ~/Win is the same tree on the Windows
# drive, kept for the projects that have not been migrated yet.
#
# Sourced by `dot self install`, so it uses return instead of exit.

WIN_PROJECTS="/mnt/d/Projects"
LINK="$HOME/Win"

grep -qi microsoft /proc/version 2>/dev/null || return 0
[ -d "$WIN_PROJECTS" ] || return 0

# Migration from the two earlier layouts: this link first lived at ~/Projects,
# then at the lowercase ~/win. Only ever removes a symlink aimed at the same
# target, never a real directory. ext4 is case sensitive, so ~/win and ~/Win are
# genuinely different paths.
for stale in "$HOME/Projects" "$HOME/win"; do
	if [ -L "$stale" ] && [ "$(readlink "$stale")" = "$WIN_PROJECTS" ]; then
		rm -f "$stale"
		echo " > Removed the old $stale link; it now lives at $LINK"
	fi
done

if [ -L "$LINK" ]; then
	current="$(readlink "$LINK")"
	if [ "$current" != "$WIN_PROJECTS" ]; then
		echo " > Repointing $LINK: $current -> $WIN_PROJECTS"
		rm -f "$LINK"
		ln -s "$WIN_PROJECTS" "$LINK"
	fi
elif [ -e "$LINK" ]; then
	echo " > $LINK already exists and is not a symlink, leaving it alone"
else
	ln -s "$WIN_PROJECTS" "$LINK"
	echo " > Linked $LINK -> $WIN_PROJECTS"
fi

# The ext4 ~/Projects skeleton is owned by 05-projects-skeleton.sh, which reads
# it from os/linux/projects-skeleton.txt. Nothing to do here.
