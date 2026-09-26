#!/usr/bin/env bash
# Claude Code drives Pi's claude-bridge. Homebrew's stable cask lagged at
# 2.1.274 while the model in use required >= 2.1.280: claude-bridge failed
# with "API Error: 400 Claude Code 2.1.274 does not support this model;
# version 2.1.280 or newer is required. Run 'claude update'", and `claude
# update` refuses to run on a brew install. Anthropic's own installer places
# the binary at ~/.local/bin/claude -> ~/.local/share/claude/versions/<ver>,
# which auto-updates on every launch instead, and
# config/pi/agent/claude-bridge.json already seeds that exact path. Installing
# it natively on the reference VM gave 2.1.283 and fixed claude-bridge; an
# interactive zsh resolves ~/.local/bin/claude before any brew shim on PATH.
#
# Sourced by `dot self install`, so it uses return rather than exit.

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

claude_code_bin="$HOME/.local/bin/claude"

if [ -x "$claude_code_bin" ]; then
	echo " > Claude Code already installed natively ($("$claude_code_bin" --version | head -1))"
else
	claude_code_tmp=$(mktemp)
	if curl -fsSL "${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}" -o "$claude_code_tmp"; then
		bash "$claude_code_tmp"
	fi
	rm -f "$claude_code_tmp"
	unset claude_code_tmp

	if [ -x "$claude_code_bin" ]; then
		echo " > Claude Code installed natively ($("$claude_code_bin" --version | head -1))"
	else
		echo " > Claude Code native install failed; rerun: curl -fsSL https://claude.ai/install.sh | bash"
		unset claude_code_bin
		return 0
	fi
fi

if command -v brew >/dev/null 2>&1 && brew list --cask claude-code >/dev/null 2>&1; then
	if brew uninstall --cask claude-code >/dev/null 2>&1; then
		echo " > Removed the Homebrew claude-code cask (the native install replaces it)"
	else
		echo " > Could not remove the Homebrew claude-code cask; rerun: brew uninstall --cask claude-code"
	fi
fi

unset claude_code_bin
return 0
