# Pick a subdirectory with fzf and cd into it.
cdd() {
	local dir
	dir="$(ls -d -- */ 2>/dev/null | fzf)" || return 0
	[ -n "$dir" ] && cd "$dir" || return 0
}
