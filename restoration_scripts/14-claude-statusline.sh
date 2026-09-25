#!/usr/bin/env bash
# Point Claude Code at the statusline script shipped in this repository.
#
# ~/.claude/settings.json is written by Claude Code itself, so it is NOT
# symlinked from here — that would fight the application for ownership of the
# file. Only the statusLine key is set; everything else is left untouched.
#
# On a fresh machine the file does not exist yet -- Claude Code only writes it
# on first launch, and script 12 creates one later in the restore -- so this
# used to silently skip via `[ -f ... ] || return 0`, leaving the statusline
# unconfigured forever (11-codegraph.sh's Claude hook has the same guard, for
# the same reason). A missing file is now treated as an empty `{}` settings
# file and merged exactly like an existing one.
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

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

claude_settings="$HOME/.claude/settings.json"
claude_statusline="bash $HOME/.claude/statusline-command.sh"
claude_refresh=60

if ! command -v jq >/dev/null 2>&1; then
	echo " > jq is missing, skipping the Claude Code statusline"
	return 0
fi

if [ ! -f "$claude_settings" ]; then
	mkdir -p "$HOME/.claude"
	echo '{}' >"$claude_settings"
fi

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
