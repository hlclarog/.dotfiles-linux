#!/usr/bin/env bash
# Register herdr's agent-state integration with every agent present, then repair
# moshi's hooks.
#
# THE ORDER IS THE WHOLE POINT. These tools write into the same per-agent config
# files -- ~/.claude/settings.json, ~/.codex/hooks.json, the opencode plugins
# directory -- and each one rewrites the hook arrays in its own shape. Nothing is
# deleted, but after herdr touches an array moshi no longer recognises its own
# entry and reports it `stale`. A stale `Stop` entry means no notification when
# an agent finishes, and nothing announces the breakage.
#
# Observed on this machine three times:
#   * `codegraph install` wrote hooks but registered the MCP server nowhere.
#   * brew installing herdr 0.9.0 staled moshi's claude hooks for a week.
#   * installing the herdr codex integration staled moshi's codex hook instantly.
#   * pi went stale the same way and stayed that way: step 2 creates
#     ~/.pi/agent/extensions/ for herdr, moshi's extension is not written
#     there, and the step 3 guard below used to check only the other three.
#
# So: herdr first, moshi LAST, then restart the moshi daemon so it reloads the
# hook config it just wrote.
#
# The integration files themselves are generated, so they are NOT vendored here
# -- the same reason ~/.claude and the opencode plugins stay out of the repo.
#
# Sourced by `dot self install`, so it uses return rather than exit.
#
# Covered by restoration_scripts/tests/agent-hooks-regression.sh -- run it after
# touching any of this; the failures it catches are otherwise silent.

# --- 1. Codex: engram memory plugin -----------------------------------------
# Deliberately independent of herdr below: it must still run on a machine
# that has Codex but not herdr. `codex plugin add` is the only way to get
# engram's memory skill and its session hooks (session-start,
# user-prompt-submit, post-compaction, subagent-stop, session-end) onto
# Codex -- nothing else in the restore writes them. Both timeout branches
# mirror 09-gentle-ai-sync.sh: an unquoted "$timeout_cmd codex ..." would rely
# on word splitting, which zsh (this file's possible caller shell, since it
# is sourced) does not do by default.
codex_config_toml="$HOME/.codex/config.toml"
if command -v codex >/dev/null 2>&1 && [ -f "$codex_config_toml" ]; then
	if grep -q '^\[plugins\."engram@engram"\]' "$codex_config_toml"; then
		echo " > Codex engram plugin already installed"
	else
		codex_engram_ok=1
		if ! grep -q '^\[marketplaces\.engram\]' "$codex_config_toml"; then
			if command -v timeout >/dev/null 2>&1; then
				(cd "$HOME" && timeout 120 codex plugin marketplace add \
					https://github.com/Gentleman-Programming/engram.git </dev/null) ||
					codex_engram_ok=0
			else
				(cd "$HOME" && codex plugin marketplace add \
					https://github.com/Gentleman-Programming/engram.git </dev/null) ||
					codex_engram_ok=0
			fi
		fi
		if [ "$codex_engram_ok" = 1 ]; then
			if command -v timeout >/dev/null 2>&1; then
				(cd "$HOME" && timeout 120 codex plugin add engram@engram </dev/null) ||
					codex_engram_ok=0
			else
				(cd "$HOME" && codex plugin add engram@engram </dev/null) ||
					codex_engram_ok=0
			fi
		fi
		if [ "$codex_engram_ok" = 1 ]; then
			echo " > Codex engram plugin installed"
		else
			echo " > Codex engram plugin install failed; rerun: codex plugin marketplace add https://github.com/Gentleman-Programming/engram.git && codex plugin add engram@engram"
		fi
	fi
fi
unset codex_config_toml codex_engram_ok

command -v herdr >/dev/null 2>&1 || {
	echo " > herdr is not installed; skipping agent integrations"
	return 0
}

# --- 2. herdr agent-state integrations --------------------------------------
# Only targets whose agent actually exists here. herdr knows 17; installing one
# for an absent agent just litters a directory nothing reads.
#
# The target and its marker directory are paired in one list and split on ":".
# An unquoted "$list" would rely on word splitting, which zsh does not do by
# default -- and this file gets sourced, so it inherits the caller's shell.
for agent_int_pair in \
	"claude:$HOME/.claude" \
	"codex:$HOME/.codex" \
	"opencode:$HOME/.config/opencode" \
	"pi:$HOME/.pi/agent"; do
	agent_int_t=${agent_int_pair%%:*}
	agent_int_d=${agent_int_pair#*:}
	[ -d "$agent_int_d" ] || continue

	if herdr integration status 2>/dev/null | grep -q "^${agent_int_t}: current"; then
		echo " > herdr integration for ${agent_int_t} is current"
	else
		herdr integration install "$agent_int_t" >/dev/null 2>&1 &&
			echo " > herdr integration installed for ${agent_int_t}" ||
			echo " > WARNING: herdr integration failed for ${agent_int_t}"
	fi
done

# --- 3. moshi-hook, LAST ----------------------------------------------------
# Reinstalling is cheap and idempotent, and it is the only way to undo the
# staling that step 2 causes. Do not reorder these two blocks.
if command -v moshi-hook >/dev/null 2>&1; then
	if moshi-hook status 2>/dev/null | grep -qE '^\s+(claude|codex|opencode|pi)\s+stale'; then
		moshi-hook install >/dev/null 2>&1 &&
			echo " > moshi-hook hooks reinstalled after the herdr integrations"
		# The daemon reads the hook config at startup and does not notice a
		# rewrite, so without this the repair does not take effect.
		systemctl --user restart moshi-hook.service >/dev/null 2>&1 &&
			echo " > moshi-hook daemon restarted"
	else
		echo " > moshi-hook hooks are current"
	fi
fi

cat <<'MSG'
 > After ANY agent-tool install or upgrade, re-check both. Neither warns you:
     moshi-hook status | grep -E 'claude|codex|opencode|pi'
     herdr integration status
MSG

unset agent_int_pair agent_int_t agent_int_d
