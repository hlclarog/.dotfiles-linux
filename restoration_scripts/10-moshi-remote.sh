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
else
	moshi-hook service install >/dev/null 2>&1 && echo " > moshi-hook service installed"
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

unset moshi_sshd_src moshi_sshd_dst
