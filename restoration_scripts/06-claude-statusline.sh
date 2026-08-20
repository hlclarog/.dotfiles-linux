#!/usr/bin/env bash
# Point Claude Code at the statusline script shipped in this repository.
#
# ~/.claude/settings.json is written by Claude Code itself, so it is NOT
# symlinked from here — that would fight the application for ownership of the
# file. Only the statusLine key is set; everything else is left untouched.
#
# The script itself IS symlinked, through symlinks/conf.yaml, so a git pull
# updates it.
#
# refreshInterval re-runs the command on a timer as well as on events. Without
# it the event triggers (new assistant message, /compact, permission or vim mode
# change) go quiet while the session is idle, and the time-based segments freeze:
# the rate-limit countdowns and the session duration. 60 seconds was chosen from
# measurement — the script takes 128ms in a small repository and 180ms in a large
# one, so a 1-second interval would burn about 18% of a core permanently, while
# the finest granularity actually displayed is the minute.
#
# Sourced by `dot self install`, so it uses return instead of exit.

claude_settings="$HOME/.claude/settings.json"
claude_statusline="bash $HOME/.claude/statusline-command.sh"
claude_refresh=60

if ! command -v jq >/dev/null 2>&1; then
	echo " > jq is missing, skipping the Claude Code statusline"
	return 0
fi

[ -f "$claude_settings" ] || return 0

claude_current="$(jq -r '[.statusLine.command // "", .statusLine.refreshInterval // 0] | @tsv' \
	"$claude_settings" 2>/dev/null)"

if [ "$claude_current" = "$(printf '%s\t%s' "$claude_statusline" "$claude_refresh")" ]; then
	echo " > Claude Code statusline already configured"
	return 0
fi

claude_tmp="$(mktemp)"
if jq --arg cmd "$claude_statusline" --argjson every "$claude_refresh" \
	'.statusLine = {type: "command", command: $cmd, refreshInterval: $every}' \
	"$claude_settings" >"$claude_tmp" 2>/dev/null; then
	cp "$claude_settings" "$claude_settings.bak"
	mv "$claude_tmp" "$claude_settings"
	echo " > Configured the Claude Code statusline; previous settings kept as settings.json.bak"
else
	rm -f "$claude_tmp"
	echo " > Could not update $claude_settings, left unchanged"
fi
