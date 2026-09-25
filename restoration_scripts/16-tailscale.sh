#!/usr/bin/env bash
# Install Tailscale so this machine is reachable from anywhere without
# opening port 22 (or anything else) to the internet: Tailscale builds a
# private mesh network over WireGuard and the machine only ever dials OUT to
# it, so no inbound firewall rule is ever needed.
#
# The official installer adds Tailscale's own apt repository, so updates
# after this keep coming through the regular `apt upgrade` flow instead of a
# one-off binary this repository would have to track by hand.
#
# Authentication (`tailscale up`) is deliberately left manual: it needs a
# browser login, and a restoration script runs unattended and must never
# block on one.
#
# WSL is intentionally routed to the Windows client instead: tailscaled
# running inside WSL fights the Windows network stack for the same virtual
# adapter, so the supported setup is the Windows-side client with WSL traffic
# tunneled through it. macOS gets the Tailscale app, which is out of scope
# here.
#
# Sourced by `dot self install`, so it uses return rather than exit.

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

if [ "$(uname -s)" = "Darwin" ]; then
	echo " > Tailscale on macOS comes from its app; skipping"
	return 0
fi

if grep -qi microsoft "${TAILSCALE_PROC_VERSION_FILE:-/proc/version}" 2>/dev/null; then
	echo " > WSL: use the Tailscale Windows client instead; skipping"
	return 0
fi

tailscale_print_auth_hint() {
	echo " > ${1:-Tailscale is installed but not logged in}. Authenticate once (opens a browser URL):"
	echo "     sudo tailscale up"
	echo "     sudo tailscale set --operator=\"$(id -un)\"   # lets you run tailscale without sudo"
	echo " > Then, in the admin console, disable key expiry for this machine so it stays reachable 24/7."
}

if ! command -v tailscale >/dev/null 2>&1; then
	if sudo -n true 2>/dev/null; then
		tailscale_tmp=$(mktemp)
		if curl -fsSL "${TAILSCALE_INSTALL_URL:-https://tailscale.com/install.sh}" -o "$tailscale_tmp"; then
			sh "$tailscale_tmp" </dev/null
		fi
		rm -f "$tailscale_tmp"
		unset tailscale_tmp

		if command -v tailscale >/dev/null 2>&1; then
			echo " > Tailscale installed"
		else
			echo " > Tailscale install failed; rerun: curl -fsSL https://tailscale.com/install.sh | sh"
		fi
	else
		echo " > Tailscale is not installed and sudo needs a password here. Run by hand:"
		echo "     curl -fsSL https://tailscale.com/install.sh | sh"
		tailscale_print_auth_hint "Once installed, it still needs a login"
		unset -f tailscale_print_auth_hint
		return 0
	fi
fi

if command -v tailscale >/dev/null 2>&1; then
	if tailscale status >/dev/null 2>&1; then
		echo " > Tailscale is up: $(tailscale ip -4 2>/dev/null | head -1)"
	else
		tailscale_print_auth_hint
	fi
fi

unset -f tailscale_print_auth_hint
return 0
