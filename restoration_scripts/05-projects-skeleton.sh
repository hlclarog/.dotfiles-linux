#!/usr/bin/env bash
# Create the ~/Projects directory skeleton from os/linux/projects-skeleton.txt.
#
# The layout is read from that file rather than derived from ~/Win, because the
# Windows folder disappears once migration finishes and does not exist at all on
# a fresh machine - deriving it would rebuild nothing exactly when it matters.
#
# Only the directories that hold repositories are created. The repositories
# themselves are cloned by hand, passing the destination explicitly, since
# several local names do not match their repository name.
#
# Sourced by `dot self install`, so it uses return instead of exit.

skeleton_file="$DOTFILES_PATH/os/linux/projects-skeleton.txt"
projects_root="$HOME/Projects"

[ -f "$skeleton_file" ] || return 0

created=0
while IFS= read -r line; do
	line="${line%%#*}"
	line="$(printf '%s' "$line" | tr -d '[:space:]')"
	[ -n "$line" ] || continue

	if [ ! -d "$projects_root/$line" ]; then
		mkdir -p "$projects_root/$line"
		created=$((created + 1))
	fi
done <"$skeleton_file"

if [ "$created" -gt 0 ]; then
	echo " > Created $created directories under $projects_root"
else
	echo " > $projects_root skeleton already in place"
fi
