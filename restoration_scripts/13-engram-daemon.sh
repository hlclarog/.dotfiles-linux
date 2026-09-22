#!/usr/bin/env bash
# Start the engram daemon that the Brewfile installs but nothing else launches.
#
# `brew "gentleman-programming/tap/engram"` puts the binary on PATH and stops
# there -- without a running daemon, memory never persists across sessions. This
# installs the unit as a systemd user service, enabled with linger so it
# survives logout, and points it at ENGRAM_PORT=7438 rather than the default
# because the Windows-side engram already holds 7437 and mirrored WSL
# networking shares that port namespace. Two daemons on 7437 is a clash that
# fails silently: whichever binds second just never receives a connection.
#
# Sourced by `dot self install`, so it uses return rather than exit.

command -v engram >/dev/null 2>&1 || {
	echo " > engram is not installed yet; skipping the daemon"
	return 0
}

# `systemctl --user` needs systemd as PID 1, which WSL only has with
# `systemd=true` in /etc/wsl.conf (script 03). Without it the command fails
# outright, so degrade with a clear message instead of erroring.
if ! systemctl --user status >/dev/null 2>&1; then
	echo " > systemd user services are not available here (check /etc/wsl.conf);"
	echo " > skipping the engram daemon"
	return 0
fi

engram_unit_src="$DOTFILES_PATH/os/linux/systemd/engram-serve.service"
engram_unit_dst="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/engram-serve.service"
engram_bin=$(command -v engram)

mkdir -p "$(dirname "$engram_unit_dst")"

engram_rendered=$(sed "s|^ExecStart=.*|ExecStart=$engram_bin serve|" "$engram_unit_src")

if [ -f "$engram_unit_dst" ] && printf '%s\n' "$engram_rendered" | cmp -s - "$engram_unit_dst"; then
	echo " > engram-serve unit already matches the repository"
else
	printf '%s\n' "$engram_rendered" >"$engram_unit_dst"
	# restart rather than "enable --now": start is a no-op on an already-running
	# daemon, which would leave the updated unit file on disk without ever
	# applying it to the running process.
	systemctl --user daemon-reload
	systemctl --user enable engram-serve.service
	systemctl --user restart engram-serve.service
	echo " > engram-serve unit installed and restarted (port 7438)"
fi

# Linger keeps the daemon alive without an active login session, otherwise it
# dies with the last shell and memory stops persisting between them.
loginctl enable-linger "$(id -un)" >/dev/null 2>&1

unset engram_unit_src engram_unit_dst engram_bin engram_rendered
