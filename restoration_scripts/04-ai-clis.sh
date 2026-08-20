#!/usr/bin/env bash
# Install the AI CLIs that deliberately do not come from the Brewfile.
#
# Claude Code and opencode are installed from their vendors' own scripts instead
# of Homebrew, for currency: the homebrew-cask claude-code measured nine patch
# versions behind the native install (2.1.228 vs 2.1.237), and the brew opencode
# comes from a third-party tap rather than the vendor. Both native installers
# keep themselves current, which a formula cannot promise.
#
# codex is absent here on purpose - it comes from the Brewfile, where it is the
# only install and needs no second source.
#
# Both URLs are the vendors' documented install endpoints.
#
# Sourced by `dot self install`, so it uses return rather than exit, and every
# network call is guarded so a failure never aborts the restore.

ai_cli_install() {
	local name="$1" bin="$2" url="$3"

	if [ -x "$bin" ]; then
		echo " > $name already installed ($("$bin" --version 2>/dev/null | head -1))"
		return 0
	fi

	echo " > Installing $name"
	if curl -fsSL "$url" | bash; then
		echo " > $name installed"
	else
		echo " > $name install failed, continuing without it"
	fi
}

ai_cli_install "Claude Code" "$HOME/.local/bin/claude" "https://claude.ai/install.sh"
ai_cli_install "opencode" "$HOME/.opencode/bin/opencode" "https://opencode.ai/install"

# Installed tools are left alone rather than reinstalled, so this stays cheap to
# re-run. To force a fresh install, remove the binary and run it again.
unset -f ai_cli_install
