#!/usr/bin/env bash
# Wire CodeGraph into every agent that can take it.
#
# CodeGraph is a local SQLite knowledge graph of a codebase, served to agents
# over MCP. It is per-project: `codegraph init` creates `.codegraph/`, and until
# it exists the graph tools have nothing to answer from. The goal here is that
# every agent tells the user to run `codegraph init` on an unindexed project
# BEFORE starting structural work, rather than silently falling back to grep.
#
# That reminder is a HOOK, not a skill, and the distinction is the whole design.
# A skill is model-invoked: the model decides whether to load it, so it can
# never guarantee "always, before starting work". A hook is harness-executed and
# deterministic. SessionStart is the right event.
#
# It cannot be delegated to CodeGraph's own bundled `codegraph prompt-hook`
# either, because that hook is SILENT on an unindexed project: piping a payload
# into it where no `.codegraph/` exists yields empty stdout and exit 0, recorded
# in its telemetry as `prompt-hook-gate-noop-no-index`. It never reports the
# missing index, which is precisely the case worth reporting.
#
# Three files carry the behaviour and are symlinked through symlinks/conf.yaml.
# What is left is per-agent configuration living in files the applications own,
# so it is merged key by key here rather than symlinked.
#
# Sourced by `dot self install`, so it uses return rather than exit.

if ! command -v jq >/dev/null 2>&1; then
	echo " > jq is missing, skipping the CodeGraph wiring"
	return 0
fi

codegraph_reminder="$HOME/.local/bin/codegraph-session-reminder"
codegraph_matcher="startup|resume|clear"

# --- 1. Resolve the wrapper, then install the npm shim it needs -------------
# This used to gate the whole script on `command -v codegraph`, but that
# depends on PATH state the install does not guarantee: ~/.local/bin (where
# the wrapper is symlinked) is not necessarily on PATH yet, and each
# restoration script runs in its own subshell (`. "$script" | log::file ...`),
# so 07-node.sh's `eval "$(fnm env)"` never carries into this one either. The
# net effect was that codegraph was never actually installed by the restore.
# The wrapper and the npm shim it needs (see the gotcha in doc/INSTALL.md: the
# shim lives under the fnm-scoped global prefix) are checked by exact path
# instead, and the shim is installed through fnm directly when missing.
codegraph_wrapper="$HOME/.local/bin/codegraph"
if [ ! -x "$codegraph_wrapper" ]; then
	echo " > codegraph symlinks are not applied yet; run \`dot self install\` again"
	return 0
fi

codegraph_shim="$HOME/.local/share/fnm/aliases/default/bin/codegraph"
if [ ! -x "$codegraph_shim" ]; then
	if command -v fnm >/dev/null 2>&1; then
		echo " > Installing codegraph under fnm's default Node"
		fnm exec --using=default npm i -g @colbymchenry/codegraph
	else
		echo " > fnm is not on PATH yet; run \`dot self install\` again once Node is installed"
		return 0
	fi
fi

if [ ! -x "$codegraph_shim" ]; then
	echo " > codegraph install did not produce a shim at $codegraph_shim; run manually:"
	echo " >   fnm exec --using=default npm i -g @colbymchenry/codegraph"
	return 0
fi

# --- 2. Claude Code: SessionStart hook --------------------------------------
# ~/.claude/settings.json is written by Claude Code itself, so only the one
# entry is added. Existing hooks are preserved.
claude_settings="$HOME/.claude/settings.json"
if [ -f "$claude_settings" ]; then
	if jq -e --arg r "$codegraph_reminder" \
		'[.hooks.SessionStart[]?.hooks[]?.command] | any(. | contains($r))' \
		"$claude_settings" >/dev/null 2>&1; then
		echo " > Claude Code already runs the CodeGraph reminder"
	else
		tmp=$(mktemp)
		jq --arg cmd "'$codegraph_reminder' --format claude" \
		   --arg m "$codegraph_matcher" \
		   '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{
		      matcher: $m,
		      hooks: [{ type: "command", command: $cmd, timeout: 10 }]
		    }])' "$claude_settings" >"$tmp" &&
			mv "$tmp" "$claude_settings" &&
			echo " > Claude Code SessionStart hook installed"
		rm -f "$tmp"
	fi
fi

# --- 3. Codex: SessionStart hook --------------------------------------------
# Same schema as Claude Code, minus --format: Codex takes plain stdout as
# context. `hooks = true` must already be set under [features] in config.toml.
codex_hooks="$HOME/.codex/hooks.json"
if [ -f "$codex_hooks" ]; then
	if jq -e --arg r "$codegraph_reminder" \
		'[.hooks.SessionStart[]?.hooks[]?.command] | any(. | contains($r))' \
		"$codex_hooks" >/dev/null 2>&1; then
		echo " > Codex already runs the CodeGraph reminder"
	else
		tmp=$(mktemp)
		jq --arg cmd "'$codegraph_reminder'" --arg m "$codegraph_matcher" \
		   '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{
		      matcher: $m,
		      hooks: [{ type: "command", command: $cmd, timeout: 10 }]
		    }])' "$codex_hooks" >"$tmp" &&
			mv "$tmp" "$codex_hooks" &&
			echo " > Codex SessionStart hook installed"
		rm -f "$tmp"
	fi
fi

# --- 4. MCP server registration, all three agents ---------------------------
# `codegraph install` writes hooks and a permission entry but registers the MCP
# server in NONE of them, leaving the allowlist pointing at tools that do not
# exist. Every registration below uses the bare name `codegraph`, which is safe
# only because the wrapper is on a stable PATH entry.
claude_json="$HOME/.claude.json"
if [ -f "$claude_json" ]; then
	if jq -e '.mcpServers.codegraph' "$claude_json" >/dev/null 2>&1; then
		echo " > Claude Code already registers the codegraph MCP server"
	else
		tmp=$(mktemp)
		jq '.mcpServers.codegraph = {
		      type: "stdio", command: "codegraph",
		      args: ["serve", "--mcp"], env: {}
		    }' "$claude_json" >"$tmp" &&
			mv "$tmp" "$claude_json" &&
			echo " > Claude Code MCP server registered"
		rm -f "$tmp"
	fi
fi

opencode_json="$HOME/.config/opencode/opencode.json"
if [ -f "$opencode_json" ]; then
	if jq -e '.mcp.codegraph' "$opencode_json" >/dev/null 2>&1; then
		echo " > opencode already registers the codegraph MCP server"
	else
		tmp=$(mktemp)
		jq '.mcp.codegraph = {
		      type: "local",
		      command: ["codegraph", "serve", "--mcp"],
		      enabled: true
		    }' "$opencode_json" >"$tmp" &&
			mv "$tmp" "$opencode_json" &&
			echo " > opencode MCP server registered"
		rm -f "$tmp"
	fi
fi

# TOML has no jq, and the table is a flat append, so a grep guard is enough.
codex_config="$HOME/.codex/config.toml"
if [ -f "$codex_config" ]; then
	if grep -q '^\[mcp_servers\.codegraph\]' "$codex_config"; then
		echo " > Codex already registers the codegraph MCP server"
	else
		printf '\n[mcp_servers.codegraph]\ncommand = "codegraph"\nargs = ["serve", "--mcp"]\n' \
			>>"$codex_config"
		echo " > Codex MCP server registered"
	fi
fi

# --- 5. Pi is excluded on purpose -------------------------------------------
# Pi has no hook system at all: nothing in ~/.pi/agent/settings.json, nothing in
# `pi --help`, only extensions and --append-system-prompt. It needs nothing
# anyway -- gentle-pi ships extensions/codegraph-tools.ts whose tool description
# already says to run `init` before querying an unindexed workspace. Adding a
# reminder would duplicate it. This is an exclusion, not an omission.

echo " > verify with: claude mcp list   (expect: codegraph ✔ Connected)"

unset codegraph_reminder codegraph_matcher codegraph_wrapper codegraph_shim
unset claude_settings codex_hooks claude_json opencode_json codex_config tmp
