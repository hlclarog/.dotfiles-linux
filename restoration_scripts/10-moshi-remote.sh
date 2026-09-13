#!/usr/bin/env bash
# Restore remote access to this machine from a phone or tablet through Moshi.
#
# Three pieces have to line up, and only two of them can be automated:
#
#   1. sshd, hardened to keys only. Moshi and Mosh both enter over SSH, so
#      without a listening sshd the paired keys in authorized_keys are inert.
#   2. The moshi-hook daemon, running as a systemd user service with linger, so
#      agent hooks can reach the phone and approvals can come back.
#   3. Inbound firewall rules at the Hyper-V layer. These need an elevated
#      PowerShell on the Windows side, so they are printed, never executed.
#
# Pairing itself is deliberately NOT automated: it mints host credentials and
# requires scanning a QR from the device.
#
# Sourced by `dot self install`, so it uses return rather than exit.
#
# Covered by restoration_scripts/tests/agent-hooks-regression.sh -- run it after
# touching any of this; the failures it catches are otherwise silent.

grep -qi microsoft /proc/version 2>/dev/null || return 0

# --- 1. sshd -----------------------------------------------------------------
# openssh-server comes from os/linux/apt/packages.txt; this only places the
# hardening drop-in and makes sure the service is enabled.
moshi_sshd_src="$DOTFILES_PATH/os/linux/ssh/99-moshi.conf"
moshi_sshd_dst="/etc/ssh/sshd_config.d/99-moshi.conf"

if ! command -v sshd >/dev/null 2>&1; then
	echo " > openssh-server is not installed yet; run the apt restore first"
elif [ -f "$moshi_sshd_dst" ] && cmp -s "$moshi_sshd_src" "$moshi_sshd_dst"; then
	echo " > sshd hardening already matches the repository"
elif ! sudo -n true 2>/dev/null; then
	# A restoration script runs unattended, so it must never block on a password.
	echo " > sshd hardening needs updating but sudo needs a password here."
	echo " > Run this by hand:"
	echo "     sudo install -m 644 \"$moshi_sshd_src\" \"$moshi_sshd_dst\""
	echo "     sudo systemctl enable --now ssh && sudo systemctl restart ssh"
else
	sudo install -D -m 644 "$moshi_sshd_src" "$moshi_sshd_dst"
	sudo systemctl enable --now ssh >/dev/null 2>&1
	sudo systemctl restart ssh >/dev/null 2>&1
	echo " > sshd hardening installed and service restarted"
fi

# Verify with ss, not `systemctl is-active ssh`: Ubuntu 24.04 activates sshd
# through ssh.socket, so the service unit can read inactive while the port is
# very much listening. Checking the unit gives a false negative.
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':22 '; then
	echo " > sshd is listening on :22"
else
	echo " > WARNING: nothing is listening on :22"
fi

# --- 2. moshi-hook daemon ----------------------------------------------------
if ! command -v moshi-hook >/dev/null 2>&1; then
	echo " > moshi-hook is not installed; see the Notion runbook to install and pair"
elif ! moshi-hook status 2>/dev/null | grep -q '^status:.*paired'; then
	echo " > moshi-hook is installed but NOT paired. Pair it from the device:"
	echo "     moshi-hook pair --token <token from the app> --store file"
	echo "     moshi-hook service install"
	# Pairing alone does not always provision the device SSH key, and without it
	# there is no terminal. Advertise the mDNS name: an IP dies on the next DHCP
	# lease, a name follows the machine.
	echo "   Then, in a terminal you can see (it draws a QR and blocks):"
	echo "     moshi-hook host setup --host \"\$(hostname).local\" --user \"\$(id -un)\" --port 22"
else
	moshi-hook service install >/dev/null 2>&1 && echo " > moshi-hook service installed"
	# `moshi-hook service install` pins Environment=PATH=/usr/local/bin:/usr/bin:/bin
	# into the unit and rewrites it on every run. The daemon resolves multiplexers
	# from that PATH, so anything installed outside it is invisible: herdr lives
	# under linuxbrew here, and `moshi-hook status` reported `herdr: not found`
	# while the client-side hook detected herdr perfectly from an interactive
	# shell. A client that sees herdr does not help -- the daemon is what drives
	# the session. Re-prepend the real locations after every install.
	moshi_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/moshi-hook.service"
	moshi_extra_path=""
	for moshi_bin in moshi-hook herdr tmux zellij; do
		moshi_dir=$(command -v "$moshi_bin" 2>/dev/null) || continue
		moshi_dir=$(dirname "$moshi_dir")
		# Skip anything the stock PATH already covers, and anything already queued.
		case ":$moshi_extra_path:/usr/local/bin:/usr/bin:/bin:" in
		*":$moshi_dir:"*) ;;
		*) moshi_extra_path="${moshi_extra_path:+$moshi_extra_path:}$moshi_dir" ;;
		esac
	done
	if [ -n "$moshi_extra_path" ] && grep -q '^Environment=PATH=' "$moshi_unit" 2>/dev/null &&
		! grep -q "^Environment=PATH=$moshi_extra_path:" "$moshi_unit"; then
		sed -i "s|^Environment=PATH=|Environment=PATH=$moshi_extra_path:|" "$moshi_unit"
		systemctl --user daemon-reload
		systemctl --user restart moshi-hook.service
		echo " > moshi-hook unit PATH extended with $moshi_extra_path"
	fi
	# Linger keeps the user service alive without an active login session,
	# otherwise the daemon dies with the last shell and approvals stop arriving.
	loginctl enable-linger "$(id -un)" >/dev/null 2>&1
	echo " > moshi-hook daemon running, linger enabled"
fi

# --- 3. Hyper-V inbound rules (manual, needs elevation) ----------------------
# Mirrored networking still blocks inbound at the Hyper-V firewall
# (DefaultInboundAction: Block). Two narrow rules are enough; do NOT flip
# DefaultInboundAction to Allow, that opens every port on the VM.
cat <<'MSG'
 > Inbound firewall rules cannot be set from here. In an ELEVATED PowerShell:
     $wsl = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
     New-NetFirewallHyperVRule -Name "WSL-SSH" -DisplayName "WSL SSH" `
       -Direction Inbound -VMCreatorId $wsl -Protocol TCP -LocalPorts 22 -Action Allow
     New-NetFirewallHyperVRule -Name "WSL-Mosh" -DisplayName "WSL Mosh" `
       -Direction Inbound -VMCreatorId $wsl -Protocol UDP -LocalPorts 60000-61000 -Action Allow
   If that GUID errors, get the right one from Get-NetFirewallHyperVVMCreator.
MSG

# --- 4. One daemon, and only one --------------------------------------------
# The Moshi app tells you to `pkill` the daemon and relaunch it with
# `moshi serve &`. That advice assumes a hand-started process. Here systemd owns
# it, so the kill trips Restart=on-failure while the manual serve adds a second
# daemon contending for the same socket and gateway port -- and that one dies at
# logout, taking approvals with it.
if command -v pgrep >/dev/null 2>&1; then
	moshi_daemons=$(pgrep -fc 'moshi-hook serve' 2>/dev/null || echo 0)
	if [ "$moshi_daemons" -gt 1 ]; then
		echo " > WARNING: $moshi_daemons moshi-hook daemons are running; there must be one."
		echo " >          Kill the strays and let systemd own it:"
		echo "     pkill -f 'moshi-hook serve'; systemctl --user restart moshi-hook.service"
	fi
fi

# A release can add hooks the installed one never had (0.3.19 introduced a
# Notification hook absent from 0.3.0), so `install` has to follow `update`.
cat <<'MSG'
 > To update Moshi later, use this and NOT the commands the app suggests:
     moshi-hook update
     systemctl --user restart moshi-hook.service
     moshi-hook install
     systemctl --user restart moshi-hook.service
MSG

unset moshi_sshd_src moshi_sshd_dst moshi_daemons moshi_unit moshi_extra_path moshi_bin moshi_dir
