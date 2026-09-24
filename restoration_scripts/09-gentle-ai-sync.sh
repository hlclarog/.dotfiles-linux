#!/usr/bin/env bash
# Run gentle-ai's sync so the agent assets are regenerated as part of the
# restore, instead of only ever being seeded by hand.
#
# Script 06 only seeds ~/.gentle-ai/state.json (the preset, the SDD mode, the
# strict-TDD flag and every per-phase model/effort assignment); nothing in the
# restore ever ran gentle-ai itself to turn that state into the actual agent
# assets it generates: ~/.claude/CLAUDE.md, its skills/agents/commands/
# output-styles, ~/.codex/AGENTS.md, config.toml and skills,
# ~/.config/opencode/* and ~/.config/gga/*. Measured on a fresh Ubuntu 24.04
# VM, `gentle-ai sync` failed on its first run there with:
#
#   Error: execute sync pipeline: OpenCode runtime version unavailable or
#   unsupported; managed runtime assets were not selected
#
# Cause: opencode bootstraps its own plugins/node_modules on its FIRST start,
# which took 97s (via `opencode debug config`); a second run took 7s. Once
# warmed up, `gentle-ai sync` succeeded in 19s (exit 0). This script warms
# opencode up first for exactly that reason.
#
# Ordering: this must sort AFTER 04 (brew: installs gentle-ai, opencode and
# fnm), 06 (writes the state gentle-ai reads) and 07 (installs the Node
# gentle-ai/opencode run on, via fnm) -- and BEFORE every script that edits
# the files this sync generates: 11-codegraph.sh (~/.claude/settings.json,
# ~/.codex/hooks.json, ~/.claude.json, ~/.config/opencode/opencode.json,
# ~/.codex/config.toml), 12-agent-integrations.sh and 14-claude-statusline.sh
# (~/.claude/settings.json). On the VM, 11 ran before ~/.codex/config.toml
# existed, so its codex MCP entry was silently never added.
#
# Sourced by `dot self install`, so it uses return rather than exit.

gentle_ai_bin=""
if command -v gentle-ai >/dev/null 2>&1; then
	gentle_ai_bin="$(command -v gentle-ai)"
else
	for gentle_ai_candidate in ${GENTLE_AI_CANDIDATES:-/home/linuxbrew/.linuxbrew/bin/gentle-ai /opt/homebrew/bin/gentle-ai}; do
		if [ -x "$gentle_ai_candidate" ]; then
			gentle_ai_bin="$gentle_ai_candidate"
			break
		fi
	done
	unset gentle_ai_candidate
fi

if [ -z "$gentle_ai_bin" ]; then
	echo " > gentle-ai is not installed, skipping the agent asset sync"
	unset gentle_ai_bin
	return 0
fi

# So a bare `gentle-ai` (used below through `fnm exec`) resolves even when it
# was only found via a fallback candidate above, not already on PATH.
case ":$PATH:" in
*":$(dirname "$gentle_ai_bin"):"*) ;;
*) PATH="$(dirname "$gentle_ai_bin"):$PATH" ;;
esac

if [ ! -f "$HOME/.gentle-ai/state.json" ]; then
	echo " > No gentle-ai state restored yet, skipping the agent asset sync"
	unset gentle_ai_bin
	return 0
fi

if ! command -v fnm >/dev/null 2>&1; then
	echo " > fnm is not on PATH yet (it comes from 07-node.sh), skipping the agent asset sync"
	unset gentle_ai_bin
	return 0
fi

if command -v opencode >/dev/null 2>&1; then
	echo " > Warming up opencode (its first start can take minutes)"
	if command -v timeout >/dev/null 2>&1; then
		(cd "$HOME" && timeout 300 opencode debug config >/dev/null 2>&1)
	else
		(cd "$HOME" && opencode debug config >/dev/null 2>&1)
	fi
fi

if fnm exec --using=default gentle-ai sync; then
	echo " > gentle-ai agent assets synced"
else
	gentle_ai_sync_status=$?
	echo " > gentle-ai sync failed (exit $gentle_ai_sync_status); rerun: fnm exec --using=default gentle-ai sync"
	unset gentle_ai_sync_status
fi

# 08-pi.sh installs Pi before this script runs; once it is runnable, sync its
# agent assets (the context7 MCP entry and ~/.pi/gentle-ai/persona.json) the
# same way, preserving any existing engram entry.
if [ -x "$HOME/.pi/agent/bin/pi" ] || command -v pi >/dev/null 2>&1; then
	if fnm exec --using=default gentle-ai sync --agents pi; then
		echo " > gentle-ai Pi assets synced"
	else
		gentle_ai_pi_sync_status=$?
		echo " > gentle-ai Pi asset sync failed (exit $gentle_ai_pi_sync_status); rerun: fnm exec --using=default gentle-ai sync --agents pi"
		unset gentle_ai_pi_sync_status
	fi
fi

unset gentle_ai_bin
return 0
