#!/usr/bin/env bash
# Regression tests for the moshi/herdr agent-hook restoration logic.
#
# WHY THIS EXISTS
# ---------------
# 10-moshi-remote.sh and 12-agent-integrations.sh both repair state that nothing
# else announces when it breaks: a stale `Stop` hook means no notification when
# an agent finishes, and a daemon PATH that cannot reach herdr means the phone
# cannot drive the session. Both failures are silent, so they are exactly the
# kind that survive a restore unnoticed. These tests fail loudly instead.
#
# The scripts mutate the machine -- systemd units, agent config, sudo -- so the
# tests never run them for real. Every mutating command is stubbed onto PATH and
# the systemd unit is redirected with XDG_CONFIG_HOME. Nothing outside the
# temporary directory is touched.
#
# THIS FILE IS NOT PART OF THE RESTORE. `dot self install` collects restoration
# scripts with `find -mindepth 1 -maxdepth 1`, so a subdirectory is never
# sourced. Run it by hand:
#
#     ./restoration_scripts/tests/agent-hooks-regression.sh
#
# Exits non-zero if any case fails.

set -u
DOTFILES_PATH="${DOTFILES_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
export DOTFILES_PATH
SCRIPT_10="$DOTFILES_PATH/restoration_scripts/10-moshi-remote.sh"
SCRIPT_12="$DOTFILES_PATH/restoration_scripts/12-agent-integrations.sh"

tests_run=0 tests_failed=0
pass() { tests_run=$((tests_run + 1)); printf '  ok   %s\n' "$1"; }
fail() {
	tests_run=$((tests_run + 1))
	tests_failed=$((tests_failed + 1))
	printf '  FAIL %s\n' "$1"
	printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
}
check() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "$2" "$3"; }
contains() {
	case "$3" in
	*"$2"*) pass "$1" ;;
	*) fail "$1" "a message containing: $2" "$3" ;;
	esac
}

# --- the sandbox -------------------------------------------------------------
# Stubs stand in for every command that would change the machine. The stubbed
# `herdr integration install` reproduces the side effect the whole ordering
# exists to undo: it stales moshi's hook for that same agent.
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/stub" "$SANDBOX/xdg/systemd/user"

cat > "$SANDBOX/stub/moshi-hook" <<'STUB'
#!/usr/bin/env bash
S="$SANDBOX/state"
case "$1" in
status)
	echo "status:       paired"
	echo "multiplexers (daemon):"
	echo "  herdr:   $(command -v herdr 2>/dev/null || echo 'not found')"
	echo "hooks:"
	for a in claude codex opencode pi; do
		if grep -q "^$a=stale$" "$S" 2>/dev/null; then
			printf '  %-8s stale    missing: extension\n' "$a"
		else
			printf '  %-8s current  /fake/%s\n' "$a" "$a"
		fi
	done ;;
service)
	# The real `service install` REGENERATES the unit every run, stock PATH and
	# all. Reproducing that is the point: it is why the PATH fix has to be a
	# post-install patch and not a unit committed to the repository.
	[ "${2:-}" = install ] &&
		printf '[Service]\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin\n' \
			> "$XDG_CONFIG_HOME/systemd/user/moshi-hook.service" ;;
install)
	if [ "${2:-}" = "--target" ]; then sed -i "s/^$3=stale$/$3=current/" "$S"
	else sed -i 's/=stale$/=current/' "$S"; fi ;;
esac
STUB

cat > "$SANDBOX/stub/herdr" <<'STUB'
#!/usr/bin/env bash
S="$SANDBOX/state"
if [ "${1:-}" = integration ] && [ "${2:-}" = status ]; then
	grep '^herdr_' "$S" 2>/dev/null | sed 's/^herdr_//;s/=/: /'
elif [ "${1:-}" = integration ] && [ "${2:-}" = install ]; then
	sed -i "s/^herdr_$3=.*/herdr_$3=current/" "$S"
	sed -i "s/^$3=current$/$3=stale/" "$S"
fi
STUB

# `sudo -n` must fail so 10-moshi-remote.sh takes its print-instructions branch
# and no test ever needs real privileges.
for c in sudo systemctl loginctl; do
	printf '#!/usr/bin/env bash\n[ "${1:-}" = "-n" ] && exit 1\nexit 0\n' > "$SANDBOX/stub/$c"
done
chmod +x "$SANDBOX/stub"/*
export SANDBOX
export XDG_CONFIG_HOME="$SANDBOX/xdg"
PATH="$SANDBOX/stub:$PATH"
export PATH

# state <moshi-status> <herdr-status>: seed all four agents at once.
state() {
	: > "$SANDBOX/state"
	for a in claude codex opencode pi; do
		echo "$a=$1" >> "$SANDBOX/state"
		echo "herdr_$a=$2" >> "$SANDBOX/state"
	done
}
get() { sed -n "s/^$1=//p" "$SANDBOX/state"; }
unit_path() { sed -n 's/^Environment=PATH=//p' "$XDG_CONFIG_HOME/systemd/user/moshi-hook.service"; }
run() { ( . "$1" ) >/dev/null 2>&1; }

echo "agent-hook restoration regression tests"
echo

# --- 1. the regression --------------------------------------------------------
# pi used to be in the herdr target list and absent from the moshi repair guard.
# It only bites when pi is the ONLY stale agent: with another agent also stale
# the guard fires anyway and the bare `moshi-hook install` repairs pi in passing.
# So this case, and only this case, distinguishes the fix from the bug.
echo "12-agent-integrations.sh"
state current current
sed -i 's/^pi=current$/pi=stale/' "$SANDBOX/state"
run "$SCRIPT_12"
check "repairs pi when pi is the only stale agent" "current" "$(get pi)"

# Guard specificity: a run with nothing stale must not reinstall anything.
state current current
run "$SCRIPT_12"
check "leaves a fully converged machine alone" "current" "$(get claude)"

# The guard used to trigger only on the literal word `stale`. A fresh machine
# never had hooks installed at all, so nothing there reads `stale` either --
# it reads `missing` instead, and the guard has to catch that too.
cat > "$SANDBOX/stub/moshi-hook-fresh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
status)
	echo "status:       paired"
	echo "hooks:"
	echo "  claude   missing  hook file absent"
	echo "  codex    current  /fake/codex"
	echo "  opencode current  /fake/opencode"
	echo "  pi       current  /fake/pi" ;;
install) echo installed >> "$SANDBOX/moshi-fresh-install.log" ;;
esac
STUB
chmod +x "$SANDBOX/stub/moshi-hook-fresh"
: > "$SANDBOX/moshi-fresh-install.log"
(
	PATH="$SANDBOX/stub-fresh:$PATH"
	mkdir -p "$SANDBOX/stub-fresh"
	ln -sf "$SANDBOX/stub/moshi-hook-fresh" "$SANDBOX/stub-fresh/moshi-hook"
	export PATH
	. "$SCRIPT_12"
) >/dev/null 2>&1
check "installs on a fresh machine (missing, never stale)" "installed" "$(cat "$SANDBOX/moshi-fresh-install.log")"

# `not found` means the agent itself is not installed here -- no hook to
# install, so it must never trigger a reinstall on its own.
cat > "$SANDBOX/stub/moshi-hook-notfound" <<'STUB'
#!/usr/bin/env bash
case "$1" in
status)
	echo "status:       paired"
	echo "hooks:"
	echo "  claude   current  /fake/claude"
	echo "  codex    current  /fake/codex"
	echo "  opencode current  /fake/opencode"
	echo "  pi       not found" ;;
install) echo installed >> "$SANDBOX/moshi-notfound-install.log" ;;
esac
STUB
chmod +x "$SANDBOX/stub/moshi-hook-notfound"
: > "$SANDBOX/moshi-notfound-install.log"
(
	mkdir -p "$SANDBOX/stub-notfound"
	ln -sf "$SANDBOX/stub/moshi-hook-notfound" "$SANDBOX/stub-notfound/moshi-hook"
	PATH="$SANDBOX/stub-notfound:$PATH"
	export PATH
	. "$SCRIPT_12"
) >/dev/null 2>&1
check "leaves a 'not found' agent alone when everything else is current" "" "$(cat "$SANDBOX/moshi-notfound-install.log")"

# --- 2. ordering --------------------------------------------------------------
# herdr first, moshi last. If that order ever inverts, every agent herdr touches
# stays stale, because nothing runs afterwards to repair it.
state current missing
run "$SCRIPT_12"
for a in claude codex opencode pi; do
	check "converges $a after the herdr integrations stale it" "current" "$(get "$a")"
done

# --- 3. the daemon PATH -------------------------------------------------------
# 10-moshi-remote.sh now runs its sshd/daemon sections on any Linux, WSL or
# not, so this no longer needs to skip on a non-WSL host.
echo
echo "10-moshi-remote.sh"
state current current
run "$SCRIPT_10"
first=$(unit_path)
case "$first" in
/usr/local/bin:*) fail "extends the regenerated unit's PATH" "a prepend before /usr/local/bin" "$first" ;;
*) pass "extends the regenerated unit's PATH" ;;
esac

# Second pass: `service install` regenerates the unit, so the patch legitimately
# re-applies. What must never change is the result.
run "$SCRIPT_10"
check "reaches the same PATH on a second pass" "$first" "$(unit_path)"

# And patching an already-patched unit must not prepend twice.
run "$SCRIPT_10"
dupes=$(printf '%s' "$(unit_path)" | tr ':' '\n' | sort | uniq -d)
check "never duplicates an entry" "" "$dupes"

# --- 4. Linux-generic sections: sshd hardening, moshi-hook install, and the
# WSL-only Hyper-V rules -------------------------------------------------------
mkdir -p "$SANDBOX/stub10" "$SANDBOX/stub10-hook" "$SANDBOX/stub10-darwin"
MOSHI_LOG="$SANDBOX/moshi-install.log"
export MOSHI_LOG

cat > "$SANDBOX/stub10/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$MOSHI_LOG"
dest="" prev=""
for arg in "$@"; do
	[ "$prev" = "-o" ] && dest="$arg"
	prev="$arg"
done
[ "${MOSHI_CURL_FAIL:-0}" = "1" ] && exit 1
cat >"$dest" <<'INSTALLER'
#!/usr/bin/env sh
echo "installer $*" >>"$MOSHI_LOG"
echo "skip-first-run:${MOSHI_HOOK_SKIP_FIRST_RUN:-unset}" >>"$MOSHI_LOG"
if [ -t 0 ]; then echo "stdin-tty:yes" >>"$MOSHI_LOG"; else echo "stdin-tty:no" >>"$MOSHI_LOG"; fi
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/moshi-hook" <<'HOOKSTUB'
#!/usr/bin/env bash
case "$1" in
status) echo "status:       not paired" ;;
esac
HOOKSTUB
chmod +x "$HOME/.local/bin/moshi-hook"
INSTALLER
chmod +x "$dest"
STUB
chmod +x "$SANDBOX/stub10/curl"

cat > "$SANDBOX/stub10/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$MOSHI_LOG"
if [ "$1" = "-n" ]; then
	if [ "${MOSHI_SUDO_PASSWORDLESS:-0}" = "1" ]; then
		shift
		exec "$@"
	fi
	exit 1
fi
exit 0
STUB
chmod +x "$SANDBOX/stub10/sudo"

# Controls the `sudo -n sshd -T` verify step: sshd -T's real output is a full
# config dump, so only the one line 10-moshi-remote.sh greps for is faked.
cat > "$SANDBOX/stub10/sshd" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-T" ]; then
	echo "${MOSHI_SSHD_T_OUTPUT:-passwordauthentication no}"
fi
exit 0
STUB
chmod +x "$SANDBOX/stub10/sshd"

for c in systemctl loginctl; do
	printf '#!/usr/bin/env bash\necho "%s $*" >>"$MOSHI_LOG"\nexit 0\n' "$c" > "$SANDBOX/stub10/$c"
	chmod +x "$SANDBOX/stub10/$c"
done

cat > "$SANDBOX/stub10-hook/moshi-hook" <<'STUB'
#!/usr/bin/env bash
case "$1" in
status) echo "status:       paired" ;;
service) exit 0 ;;
esac
STUB
chmod +x "$SANDBOX/stub10-hook/moshi-hook"

printf '#!/usr/bin/env bash\necho Darwin\n' > "$SANDBOX/stub10-darwin/uname"
chmod +x "$SANDBOX/stub10-darwin/uname"

WSL_PROC="$SANDBOX/proc-version-wsl"
PLAIN_PROC="$SANDBOX/proc-version-plain"
printf 'Linux version 5.15.0 (Microsoft@Microsoft.com)\n' > "$WSL_PROC"
printf 'Linux version 6.6.0-generic\n' > "$PLAIN_PROC"

PATH10_WITH_HOOK="$SANDBOX/stub10-hook:$SANDBOX/stub10:/usr/sbin:/usr/bin:/bin"
PATH10_NO_HOOK="$SANDBOX/stub10:/usr/sbin:/usr/bin:/bin"
PATH10_DARWIN="$SANDBOX/stub10-darwin:$SANDBOX/stub10-hook:$SANDBOX/stub10:/usr/sbin:/usr/bin:/bin"

run10() {
	(
		HOME="$1"
		PATH="$2"
		DOTFILES_PATH="$DOTFILES_PATH"
		MOSHI_INSTALL_URL="${3:-https://example.test/moshi-install.sh}"
		MOSHI_PROC_VERSION_FILE="${4:-$PLAIN_PROC}"
		MOSHI_SUDO_PASSWORDLESS="${5:-0}"
		MOSHI_CURL_FAIL="${6:-0}"
		MOSHI_SSHD_T_OUTPUT="${7:-passwordauthentication no}"
		export HOME PATH DOTFILES_PATH MOSHI_INSTALL_URL MOSHI_PROC_VERSION_FILE MOSHI_SUDO_PASSWORDLESS MOSHI_CURL_FAIL MOSHI_LOG MOSHI_SSHD_T_OUTPUT
		. "$SCRIPT_10"
	) >"$SANDBOX/out10" 2>&1
	echo $?
}

# Case (a): non-WSL Linux, authorized_keys present, passwordless sudo -> the
# drop-in is installed via the sudo stub and no Hyper-V text appears.
HOME_10A="$SANDBOX/home10a"
mkdir -p "$HOME_10A/.ssh"
printf 'ssh-ed25519 AAAAtest test@device\n' > "$HOME_10A/.ssh/authorized_keys"
: > "$MOSHI_LOG"
status_10a=$(run10 "$HOME_10A" "$PATH10_WITH_HOOK" "" "$PLAIN_PROC" 1)
out_10a=$(cat "$SANDBOX/out10")
check "case a: returns success" "0" "$status_10a"
install_call_10a=$(grep '^sudo install ' "$MOSHI_LOG")
contains "case a: sudo installs the sshd drop-in" "sudo install" "$install_call_10a"
install_dest_10a=$(printf '%s\n' "$install_call_10a" | awk '{print $NF}')
check "case a: install targets 00-moshi.conf" "/etc/ssh/sshd_config.d/00-moshi.conf" "$install_dest_10a"
rm_call_10a=$(grep '^sudo rm -f ' "$MOSHI_LOG")
contains "case a: legacy 99-moshi.conf removal is issued" "/etc/ssh/sshd_config.d/99-moshi.conf" "$rm_call_10a"
contains "case a: prints the sshd effective line" " > sshd effective: passwordauthentication no" "$out_10a"
case "$out_10a" in
*NetFirewallHyperVRule*) fail "case a: no Hyper-V text on non-WSL" "no Hyper-V PowerShell text" "present" ;;
*) pass "case a: no Hyper-V text on non-WSL" ;;
esac

# Case (a2): same as case a, but the stubbed sshd -T reports passwords are
# still allowed (an earlier drop-in like 50-cloud-init.conf winning).
: > "$MOSHI_LOG"
status_10a2=$(run10 "$HOME_10A" "$PATH10_WITH_HOOK" "" "$PLAIN_PROC" 1 0 "passwordauthentication yes")
out_10a2=$(cat "$SANDBOX/out10")
check "case a2: returns success" "0" "$status_10a2"
contains "case a2: warns when sshd still allows passwords" "WARNING: sshd still allows passwords" "$out_10a2"

# Case (b): non-WSL Linux without authorized_keys -> no sudo install call, skip message.
HOME_10B="$SANDBOX/home10b"
mkdir -p "$HOME_10B"
: > "$MOSHI_LOG"
status_10b=$(run10 "$HOME_10B" "$PATH10_WITH_HOOK" "" "$PLAIN_PROC" 1)
out_10b=$(cat "$SANDBOX/out10")
check "case b: returns success" "0" "$status_10b"
install_calls_10b=$(grep -c '^sudo install ' "$MOSHI_LOG")
check "case b: no sudo install call" "0" "$install_calls_10b"
contains "case b: prints the no-authorized_keys skip message" "No ~/.ssh/authorized_keys" "$out_10b"

# Case (c): WSL -> Hyper-V text is still printed, regardless of authorized_keys.
HOME_10C="$SANDBOX/home10c"
mkdir -p "$HOME_10C"
: > "$MOSHI_LOG"
status_10c=$(run10 "$HOME_10C" "$PATH10_WITH_HOOK" "" "$WSL_PROC")
out_10c=$(cat "$SANDBOX/out10")
check "case c: returns success" "0" "$status_10c"
contains "case c: prints the Hyper-V text on WSL" "New-NetFirewallHyperVRule" "$out_10c"

# Case (d): Darwin -> skip message, nothing else runs.
HOME_10D="$SANDBOX/home10d"
mkdir -p "$HOME_10D"
: > "$MOSHI_LOG"
status_10d=$(run10 "$HOME_10D" "$PATH10_DARWIN")
out_10d=$(cat "$SANDBOX/out10")
check "case d: returns success" "0" "$status_10d"
contains "case d: prints the Darwin skip message" "Linux-only here, skipping" "$out_10d"
calls_10d=$(wc -l < "$MOSHI_LOG" | tr -d ' ')
check "case d: nothing is invoked on Darwin" "0" "$calls_10d"

# Case (e): moshi-hook missing -> installer fetched from MOSHI_INSTALL_URL and
# run with MOSHI_HOOK_SKIP_FIRST_RUN=1, stdin not a tty.
HOME_10E="$SANDBOX/home10e"
mkdir -p "$HOME_10E"
: > "$MOSHI_LOG"
status_10e=$(run10 "$HOME_10E" "$PATH10_NO_HOOK" "https://example.test/moshi-install.sh" "$PLAIN_PROC")
check "case e: returns success" "0" "$status_10e"
curl_call_10e=$(grep '^curl ' "$MOSHI_LOG")
contains "case e: curl fetches MOSHI_INSTALL_URL" "https://example.test/moshi-install.sh" "$curl_call_10e"
skip_line_10e=$(grep '^skip-first-run:' "$MOSHI_LOG")
check "case e: MOSHI_HOOK_SKIP_FIRST_RUN=1 reaches the installer" "skip-first-run:1" "$skip_line_10e"
stdin_line_10e=$(grep '^stdin-tty:' "$MOSHI_LOG")
check "case e: the installer runs with stdin not a tty" "stdin-tty:no" "$stdin_line_10e"

# Case (f): installer download fails -> hint, script continues and returns 0.
HOME_10F="$SANDBOX/home10f"
mkdir -p "$HOME_10F"
: > "$MOSHI_LOG"
status_10f=$(run10 "$HOME_10F" "$PATH10_NO_HOOK" "" "$PLAIN_PROC" 0 1)
out_10f=$(cat "$SANDBOX/out10")
check "case f: returns success" "0" "$status_10f"
contains "case f: prints a failure hint" "curl -fsSL https://getmoshi.app/install.sh | sh" "$out_10f"

# Case (g): moshi-hook already present -> curl is never called.
HOME_10G="$SANDBOX/home10g"
mkdir -p "$HOME_10G"
: > "$MOSHI_LOG"
status_10g=$(run10 "$HOME_10G" "$PATH10_WITH_HOOK" "" "$PLAIN_PROC")
check "case g: returns success" "0" "$status_10g"
curl_calls_10g=$(grep -c '^curl ' "$MOSHI_LOG")
check "case g: curl is not called" "0" "$curl_calls_10g"

# Case (h): authorized_keys present but sudo needs a password -> the printed
# manual commands cover installing 00-moshi.conf, removing the legacy
# 99-moshi.conf, restarting ssh, and verifying the effective value by hand.
HOME_10H="$SANDBOX/home10h"
mkdir -p "$HOME_10H/.ssh"
printf 'ssh-ed25519 AAAAtest test@device\n' > "$HOME_10H/.ssh/authorized_keys"
: > "$MOSHI_LOG"
status_10h=$(run10 "$HOME_10H" "$PATH10_WITH_HOOK" "" "$PLAIN_PROC" 0)
out_10h=$(cat "$SANDBOX/out10")
check "case h: returns success" "0" "$status_10h"
contains "case h: manual command installs 00-moshi.conf" "sudo install -m 644" "$out_10h"
contains "case h: manual command installs 00-moshi.conf" "00-moshi.conf" "$out_10h"
contains "case h: manual command removes legacy 99-moshi.conf" "sudo rm -f" "$out_10h"
contains "case h: manual command removes legacy 99-moshi.conf" "99-moshi.conf" "$out_10h"
contains "case h: manual command restarts ssh" "sudo systemctl restart ssh" "$out_10h"
contains "case h: manual command verifies effective value by hand" "sudo sshd -T | grep -i passwordauthentication" "$out_10h"
install_calls_10h=$(grep -c '^sudo install ' "$MOSHI_LOG")
check "case h: no sudo install actually attempted" "0" "$install_calls_10h"

# Case (k): an unpaired host. `status: unpaired` contains the word "paired",
# so a loose match treated it as paired: measured on a fresh VM, the script
# installed the service and enabled linger and never printed the pairing steps.
mkdir -p "$SANDBOX/stub10-unpaired"
cat > "$SANDBOX/stub10-unpaired/moshi-hook" <<'STUB'
#!/usr/bin/env bash
case "$1" in
status) echo "status: unpaired" ;;
service) echo "moshi-hook service $*" >>"$MOSHI_LOG"; exit 0 ;;
esac
STUB
chmod +x "$SANDBOX/stub10-unpaired/moshi-hook"
HOME_10K="$SANDBOX/home10k"
mkdir -p "$HOME_10K"
: > "$MOSHI_LOG"
status_10k=$(run10 "$HOME_10K" "$SANDBOX/stub10-unpaired:$SANDBOX/stub10:/usr/sbin:/usr/bin:/bin")
out_10k=$(cat "$SANDBOX/out10")
check "case k: returns success" "0" "$status_10k"
contains "case k: unpaired host gets the pairing steps" "NOT paired" "$out_10k"
check "case k: unpaired host installs no service" "0" "$(grep -c 'service' "$MOSHI_LOG")"
check "case k: unpaired host enables no linger" "0" "$(grep -c '^loginctl' "$MOSHI_LOG")"

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
