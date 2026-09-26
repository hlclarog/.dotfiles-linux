#!/usr/bin/env bash
# Install Pi itself, then seed it to match the reference machine, so a fresh
# restore needs no manual step except logging in.
#
# WHY DETACHED: the official installer (curl -fsSL https://pi.dev/install.sh
# | sh) checks /dev/tty. Reachable, it shows an interactive action menu and
# offers to append a PATH line to ~/.zshrc -- which here is a symlink into
# this repository, so the install would mutate a tracked file. Detaching with
# setsid -w (or the python3 fallback below, for hosts without setsid, such as
# macOS) and redirecting stdin from /dev/null removes the tty entirely, so the
# installer runs unattended and exits 0. Measured on a fresh Ubuntu 24.04 VM:
# 67s, managed Pi under ~/.pi/agent, ~/.zshrc untouched.
#
# WHY $HOME/bin FIRST ON PATH: the installer's own launcher-location probe
# picks the first of ~/.pi/agent/bin, ~/.local/bin, ~/bin... it finds on PATH.
# shell/exports.sh puts $HOME/bin ahead of $HOME/.local/bin, so putting it
# first here reproduces the exact launcher location used on the reference
# machine (~/bin/pi -> ../.pi/agent/bin/pi).
#
# WHY `pi install <source>` PER PACKAGE INSTEAD OF `pi update --extensions`:
# measured on the VM, `pi update --extensions` silently skipped every pinned
# spec in settings.json -- npm:gentle-engram@0.1.8 was never installed that
# way. `pi install <source>` for each entry does not duplicate an existing
# one, so it is safe to rerun.
#
# ORDERING: must sort after 07-node.sh, which installs fnm -- Pi's installer
# only runs through `fnm exec`, never directly. Must sort before
# 09-gentle-ai-sync.sh (which also syncs Pi's agent assets once this script
# has installed it), 10-moshi-remote.sh and 12-agent-integrations.sh (which
# installs herdr's pi integration only when ~/.pi/agent already exists, which
# this script is what creates on a fresh machine).
#
# WHY INSTALL-SDD RUNS TWICE: gentle-pi applies the saved models
# (~/.pi/gentle-ai/models.json) to installed agents only at session_start.
# The first `pi -p "/gentle:install-sdd"` run creates the 12 sdd-*.md agents
# AFTER that point in the same session, so they end up without model/thinking
# frontmatter. Measured on a fresh Ubuntu VM: a second run's session_start
# reapplies the saved models to the agents the first run just created, fixing
# every one of them.
#
# WHY THE CLAUDE-BRIDGE PATH IS REPAIRED: the seed's pathToClaudeCodeExecutable
# assumes Claude's native installer (~/.local/bin/claude), matching the
# reference machine. On the VM Claude comes from Homebrew instead, so that
# path does not exist and pi-claude-bridge would try to spawn a missing
# binary. After seeding, this script rewrites the path to whatever `claude`
# resolves to on PATH, or drops the key (falling back to the SDK's own lookup)
# when no `claude` is found -- repairing a freshly seeded file and an
# existing one from an earlier restore alike.
#
# Sourced by `dot self install`, so it uses return rather than exit.

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

if ! command -v fnm >/dev/null 2>&1; then
	echo " > fnm is not on PATH yet (it comes from 07-node.sh), skipping Pi"
	return 0
fi

# Detach helper: an array command PREFIX inserted between `fnm exec
# --using=default` and the real command, never a wrapper around the whole
# call -- fnm needs to see the real command as its own trailing argv.
if command -v setsid >/dev/null 2>&1; then
	pi_detach=(setsid -w)
elif command -v python3 >/dev/null 2>&1; then
	pi_detach=(python3 -c '
import os, sys
pid = os.fork()
if pid == 0:
	os.setsid()
	os.execvp(sys.argv[1], sys.argv[1:])
else:
	_, status = os.waitpid(pid, 0)
	sys.exit(status >> 8 if os.WIFEXITED(status) else 1)
')
else
	pi_detach=()
fi

# --- 3. install ---------------------------------------------------------------
if [ -x "$HOME/.pi/agent/bin/pi" ] || command -v pi >/dev/null 2>&1; then
	echo " > Pi already installed"
else
	mkdir -p "$HOME/bin"
	pi_tmp=$(mktemp)
	if curl -fsSL "${PI_INSTALL_URL:-https://pi.dev/install.sh}" -o "$pi_tmp"; then
		PATH="$HOME/bin:$PATH" fnm exec --using=default "${pi_detach[@]}" sh "$pi_tmp" </dev/null
	fi
	rm -f "$pi_tmp"
	unset pi_tmp
fi

case ":$PATH:" in
*":$HOME/bin:"*) ;;
*) PATH="$HOME/bin:$PATH" ;;
esac
case ":$PATH:" in
*":$HOME/.pi/agent/bin:"*) ;;
*) PATH="$HOME/.pi/agent/bin:$PATH" ;;
esac

if [ ! -x "$HOME/.pi/agent/bin/pi" ] && ! command -v pi >/dev/null 2>&1; then
	echo " > Pi install failed; rerun: curl -fsSL https://pi.dev/install.sh | sh"
	unset pi_detach
	return 0
fi

# --- 4. seed config, copy-only-if-missing -------------------------------------
mkdir -p "$HOME/.pi/agent"

pi_brew_prefix=""
if command -v brew >/dev/null 2>&1; then
	pi_brew_prefix="$(brew --prefix)"
else
	for pi_brew_candidate in ${BREW_PREFIX_CANDIDATES:-/home/linuxbrew/.linuxbrew /opt/homebrew /usr/local}; do
		if [ -d "$pi_brew_candidate" ]; then
			pi_brew_prefix="$pi_brew_candidate"
			break
		fi
	done
	unset pi_brew_candidate
fi

for pi_seed in settings subagents claude-bridge mcp; do
	pi_seed_dst="$HOME/.pi/agent/$pi_seed.json"
	if [ -f "$pi_seed_dst" ]; then
		echo " > $pi_seed_dst already present, left untouched"
	else
		sed -e "s|@HOME@|$HOME|g" -e "s|@BREW_PREFIX@|$pi_brew_prefix|g" \
			"$DOTFILES_PATH/config/pi/agent/$pi_seed.json" >"$pi_seed_dst"
		chmod 600 "$pi_seed_dst"
	fi
done
unset pi_seed pi_seed_dst pi_brew_prefix

# The seed's pathToClaudeCodeExecutable assumes Claude's native installer
# (~/.local/bin/claude), matching the reference machine. Repair it here --
# both for the file just seeded above and for one left over from an earlier
# restore -- when it points at a binary that turns out not to exist, such as
# when Claude is installed through Homebrew instead.
pi_bridge_file="$HOME/.pi/agent/claude-bridge.json"
if [ -f "$pi_bridge_file" ]; then
	pi_bridge_claude=$(jq -r '.provider.pathToClaudeCodeExecutable // empty' "$pi_bridge_file" 2>/dev/null)
	if [ -n "$pi_bridge_claude" ] && [ ! -x "$pi_bridge_claude" ]; then
		pi_bridge_tmp=$(mktemp "$HOME/.pi/agent/claude-bridge.json.XXXXXX")
		if pi_bridge_new_claude=$(command -v claude 2>/dev/null); then
			jq --arg p "$pi_bridge_new_claude" '.provider.pathToClaudeCodeExecutable = $p' \
				"$pi_bridge_file" >"$pi_bridge_tmp"
			echo " > Pi claude-bridge now uses $pi_bridge_new_claude"
		else
			jq 'del(.provider.pathToClaudeCodeExecutable)' "$pi_bridge_file" >"$pi_bridge_tmp"
			echo " > Pi claude-bridge found no claude on PATH; it will use the default Claude lookup"
		fi
		chmod 600 "$pi_bridge_tmp"
		mv "$pi_bridge_tmp" "$pi_bridge_file"
		unset pi_bridge_new_claude pi_bridge_tmp
	fi
	unset pi_bridge_claude
fi
unset pi_bridge_file

if [ ! -d "$HOME/.pi/gentle-ai" ]; then
	mkdir -p "$HOME/.pi/gentle-ai"
	chmod 700 "$HOME/.pi/gentle-ai"
fi

# --- 5. profile registry -------------------------------------------------------
# Mirrors the reference machine's active selection; switch profiles from
# inside Pi with /gentle:profiles.
pi_active_profile="claude-medium"

pi_profiles="$HOME/.pi/gentle-ai/profiles.json"
if [ ! -f "$pi_profiles" ]; then
	jq -n \
		--slurpfile pi_claude "$DOTFILES_PATH/config/pi/claude-profiles.json" \
		--slurpfile pi_codex_medium "$DOTFILES_PATH/config/pi/codex-medium.json" \
		--slurpfile pi_codex_low "$DOTFILES_PATH/config/pi/codex-low.json" \
		--arg pi_active "$pi_active_profile" \
		'{kind: "gentle-pi.agent_model_profiles", version: 1,
		  profiles: ($pi_claude[0] + {"codex-medium": $pi_codex_medium[0], "codex-low": $pi_codex_low[0]}),
		  active: $pi_active}' >"$pi_profiles"
	chmod 600 "$pi_profiles"
elif ! jq -e '.profiles["codex-medium"] and .profiles["codex-low"]' "$pi_profiles" >/dev/null 2>&1; then
	echo " > ~/.pi/gentle-ai/profiles.json lacks codex-medium or codex-low; run"
	echo "   scripts/restore-pi-openai-profile to add it"
fi

pi_models="$HOME/.pi/gentle-ai/models.json"
if [ ! -f "$pi_models" ] && [ -f "$pi_profiles" ]; then
	pi_registry_active=$(jq -r '.active' "$pi_profiles")
	jq --arg pi_active "$pi_registry_active" '.profiles[$pi_active]' "$pi_profiles" >"$pi_models"
	chmod 600 "$pi_models"
	unset pi_registry_active
fi
unset pi_active_profile pi_profiles pi_models

# --- 6. packages ---------------------------------------------------------------
pi_pkg_name() {
	case "$1" in
	npm:@*)
		pi_pkg_rest="${1#npm:@}"
		printf '@%s\n' "${pi_pkg_rest%@*}"
		unset pi_pkg_rest
		;;
	npm:*)
		pi_pkg_rest="${1#npm:}"
		printf '%s\n' "${pi_pkg_rest%%@*}"
		unset pi_pkg_rest
		;;
	esac
}

pi_settings="$HOME/.pi/agent/settings.json"
if [ -f "$pi_settings" ]; then
	while IFS= read -r pi_pkg_src; do
		[ -z "$pi_pkg_src" ] && continue
		case "$pi_pkg_src" in
		npm:*)
			pi_pkg_dir_name=$(pi_pkg_name "$pi_pkg_src")
			if [ -d "$HOME/.pi/agent/npm/node_modules/$pi_pkg_dir_name" ]; then
				unset pi_pkg_dir_name
				continue
			fi
			unset pi_pkg_dir_name
			;;
		esac
		if ! (cd "$HOME" && fnm exec --using=default "${pi_detach[@]}" pi install "$pi_pkg_src" </dev/null); then
			echo " > pi install $pi_pkg_src failed; rerun: fnm exec --using=default pi install \"$pi_pkg_src\""
		fi
	done < <(jq -r '.packages[]? // empty' "$pi_settings" 2>/dev/null)
fi
unset -f pi_pkg_name
unset pi_settings pi_pkg_src

# --- 7. assets -----------------------------------------------------------------
pi_install_sdd_once() {
	if command -v timeout >/dev/null 2>&1; then
		(cd "$HOME" && fnm exec --using=default "${pi_detach[@]}" timeout 180 pi -p "/gentle:install-sdd" </dev/null >/dev/null 2>&1)
	else
		(cd "$HOME" && fnm exec --using=default "${pi_detach[@]}" pi -p "/gentle:install-sdd" </dev/null >/dev/null 2>&1)
	fi
}

if [ -d "$HOME/.pi/agent/npm/node_modules/gentle-pi" ]; then
	pi_sdd_status=0
	pi_install_sdd_once || pi_sdd_status=$?
	if [ "$pi_sdd_status" -eq 0 ]; then
		# Run install-sdd a second time: gentle-pi applies the saved models
		# (~/.pi/gentle-ai/models.json) to installed agents only at
		# session_start, and the first run's install-sdd creates the 12
		# sdd-*.md agents AFTER that point in the same session, leaving them
		# without model/thinking frontmatter. The second session's
		# session_start reapplies the saved models to the agents the first
		# run just created.
		pi_install_sdd_once || pi_sdd_status=$?
	fi
	if [ "$pi_sdd_status" -eq 0 ]; then
		echo " > Pi agent assets installed"
	else
		echo " > Pi agent asset install failed (exit $pi_sdd_status); rerun: fnm exec --using=default pi -p \"/gentle:install-sdd\""
	fi
	unset -f pi_install_sdd_once
	unset pi_sdd_status
fi

unset pi_detach
return 0
