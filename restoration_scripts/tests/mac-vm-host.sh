#!/usr/bin/env bash
# Regression tests for the office iMac VM-host setup: keeping the UTM VM that
# hosts sandbox-hclaro up 24/7 across sleep, reboot and power cuts.
#
# Nothing here touches a real Mac. Every mutating/network command
# (sudo, pmset, systemsetup, launchctl, defaults, fdesetup, utmctl, uname) is
# stubbed onto PATH inside a disposable HOME; `uname -s` is stubbed to report
# Darwin so scripts/setup-mac-vm-host runs its real logic on this Linux box.
#
# Run by hand:
#
#     ./restoration_scripts/tests/mac-vm-host.sh
#
# Exits non-zero if any case fails.

set -u
DOTFILES_PATH="${DOTFILES_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
export DOTFILES_PATH
WATCHDOG="$DOTFILES_PATH/os/mac/vm-host/utm-autostart"
TEMPLATE="$DOTFILES_PATH/os/mac/vm-host/dotfiles.utm-autostart.plist.template"
SETUP="$DOTFILES_PATH/scripts/setup-mac-vm-host"

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
not_contains() {
	case "$3" in
	*"$2"*) fail "$1" "no occurrence of: $2" "$3" ;;
	*) pass "$1" ;;
	esac
}

echo "mac-vm-host regression tests"
echo

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
STUBBIN="$SANDBOX/stubbin"
mkdir -p "$STUBBIN"
STUB_PATH="$STUBBIN:/usr/bin:/bin"

# ==============================================================================
# Stub binaries shared by both scripts under test.
# ==============================================================================

cat >"$STUBBIN/uname" <<'STUB'
#!/usr/bin/env bash
echo "${UNAME_S:-Darwin}"
STUB
chmod +x "$STUBBIN/uname"

cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$SUDO_LOG"
"$@"
STUB
chmod +x "$STUBBIN/sudo"

cat >"$STUBBIN/pmset" <<'STUB'
#!/usr/bin/env bash
echo "pmset $*" >>"$PMSET_LOG"
if [ "$1" = "-g" ]; then
	cat "$PMSET_G_OUTPUT"
fi
exit 0
STUB
chmod +x "$STUBBIN/pmset"

cat >"$STUBBIN/systemsetup" <<'STUB'
#!/usr/bin/env bash
echo "systemsetup $*" >>"$SYSTEMSETUP_LOG"
if [ "$1" = "-getrestartfreeze" ]; then
	echo "Restart After Freeze: ${SYSTEMSETUP_RESTARTFREEZE:-On}"
fi
exit 0
STUB
chmod +x "$STUBBIN/systemsetup"

cat >"$STUBBIN/defaults" <<'STUB'
#!/usr/bin/env bash
echo "defaults $*" >>"$DEFAULTS_LOG"
if [ "$1" = "read" ] && [ "$3" = "autoLoginUser" ]; then
	if [ -n "${DEFAULTS_AUTOLOGIN_USER:-}" ]; then
		echo "$DEFAULTS_AUTOLOGIN_USER"
		exit 0
	fi
	exit 1
fi
exit 1
STUB
chmod +x "$STUBBIN/defaults"

cat >"$STUBBIN/fdesetup" <<'STUB'
#!/usr/bin/env bash
echo "fdesetup $*" >>"$FDESETUP_LOG"
echo "${FDESETUP_STATUS:-FileVault is Off.}"
exit 0
STUB
chmod +x "$STUBBIN/fdesetup"

cat >"$STUBBIN/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "launchctl $*" >>"$LAUNCHCTL_LOG"
state="$HOME/.launchctl-state"
case "$1" in
print)
	[ -f "$state" ] && exit 0 || exit 1
	;;
bootstrap)
	touch "$state"
	exit 0
	;;
bootout)
	rm -f "$state"
	exit 0
	;;
esac
exit 0
STUB
chmod +x "$STUBBIN/launchctl"

cat >"$STUBBIN/utmctl" <<'STUB'
#!/usr/bin/env bash
echo "utmctl $*" >>"$UTMCTL_LOG"
case "$1" in
status)
	echo "${UTMCTL_STATUS-stopped}"
	exit "${UTMCTL_STATUS_EXIT:-0}"
	;;
start)
	exit "${UTMCTL_START_EXIT:-0}"
	;;
resume)
	exit "${UTMCTL_RESUME_EXIT:-0}"
	;;
list)
	echo "${UTMCTL_LIST_OUTPUT-sandbox-hclaro}"
	;;
esac
exit 0
STUB
chmod +x "$STUBBIN/utmctl"

GOOD_PMSET="$SANDBOX/pmset-good.txt"
cat >"$GOOD_PMSET" <<'EOF'
Currently in use:
 standby              0
 womp                 1
 networkoversleep     0
 disksleep            0
 sleep                0
 autopoweroffdelay    28800
 autopoweroff         0
 hibernatefile        /var/vm/sleepimage
 powernap             0
 gpuswitch            2
 ttyskeepawake        1
 displaysleep         10
 autorestart          1
EOF

BAD_PMSET="$SANDBOX/pmset-bad.txt"
cat >"$BAD_PMSET" <<'EOF'
Currently in use:
 standby              0
 womp                 1
 networkoversleep     0
 disksleep            0
 sleep                1
 autopoweroffdelay    28800
 autopoweroff         0
 hibernatefile        /var/vm/sleepimage
 powernap             0
 gpuswitch            2
 ttyskeepawake        1
 displaysleep         10
 autorestart          0
EOF

# ==============================================================================
# os/mac/vm-host/utm-autostart -- launchd watchdog.
# ==============================================================================
echo "os/mac/vm-host/utm-autostart"

run_watchdog() {
	shell_bin="$1"
	home_dir="$2"
	mkdir -p "$home_dir"
	(
		HOME="$home_dir"
		PATH="$STUB_PATH"
		UTMCTL="$STUBBIN/utmctl"
		export HOME PATH UTMCTL UTM_VM_NAME UTM_START_RETRIES UTM_RETRY_SECONDS \
			UTMCTL_LOG UTMCTL_STATUS UTMCTL_STATUS_EXIT UTMCTL_START_EXIT UTMCTL_RESUME_EXIT
		"$shell_bin" "$WATCHDOG"
	) >"$SANDBOX/wd-out" 2>&1
	echo $?
}

for SHELL_BIN in bash sh; do
	echo "  (running under $SHELL_BIN)"

	# disabled flag -> no utmctl call, logged, exit 0
	HOME_D="$SANDBOX/wd-disabled-$SHELL_BIN"
	rm -rf "$HOME_D"; mkdir -p "$HOME_D"
	touch "$HOME_D/.utm-autostart-disabled"
	UTMCTL_LOG="$SANDBOX/utmctl-disabled-$SHELL_BIN.log"; : >"$UTMCTL_LOG"
	export UTMCTL_LOG UTM_VM_NAME=sandbox-hclaro UTM_START_RETRIES=3 UTM_RETRY_SECONDS=0
	status=$(run_watchdog "$SHELL_BIN" "$HOME_D")
	check "$SHELL_BIN: disabled flag -> exit 0" "0" "$status"
	utmctl_calls=$(wc -l <"$UTMCTL_LOG" | tr -d ' ')
	check "$SHELL_BIN: disabled flag -> no utmctl call" "0" "$utmctl_calls"
	contains "$SHELL_BIN: disabled flag -> logged" "disabled" "$(cat "$HOME_D/Library/Logs/utm-autostart.log")"

	# utmctl not executable -> exit 0, logged, no crash
	HOME_M="$SANDBOX/wd-missing-$SHELL_BIN"
	rm -rf "$HOME_M"; mkdir -p "$HOME_M"
	MISSING_UTMCTL="$SANDBOX/no-such-utmctl-$SHELL_BIN"
	rm -f "$MISSING_UTMCTL"
	UTMCTL_LOG="$SANDBOX/utmctl-missing-$SHELL_BIN.log"; : >"$UTMCTL_LOG"
	status=$(
		HOME="$HOME_M"
		PATH="$STUB_PATH"
		UTMCTL="$MISSING_UTMCTL"
		export HOME PATH UTMCTL UTMCTL_LOG UTM_VM_NAME=sandbox-hclaro
		"$SHELL_BIN" "$WATCHDOG" >"$SANDBOX/wd-out" 2>&1
		echo $?
	)
	check "$SHELL_BIN: utmctl missing -> exit 0" "0" "$status"
	contains "$SHELL_BIN: utmctl missing -> logged" "utmctl" "$(cat "$HOME_M/Library/Logs/utm-autostart.log")"

	# status started -> no start, OK, exit 0
	HOME_S="$SANDBOX/wd-started-$SHELL_BIN"
	rm -rf "$HOME_S"; mkdir -p "$HOME_S"
	UTMCTL_LOG="$SANDBOX/utmctl-started-$SHELL_BIN.log"; : >"$UTMCTL_LOG"
	export UTMCTL_STATUS=started UTMCTL_STATUS_EXIT=0
	status=$(run_watchdog "$SHELL_BIN" "$HOME_S")
	check "$SHELL_BIN: status started -> exit 0" "0" "$status"
	start_calls=$(grep -c '^utmctl start ' "$UTMCTL_LOG" || true)
	check "$SHELL_BIN: status started -> no start call" "0" "$start_calls"

	# status paused -> resume, no start
	HOME_P="$SANDBOX/wd-paused-$SHELL_BIN"
	rm -rf "$HOME_P"; mkdir -p "$HOME_P"
	UTMCTL_LOG="$SANDBOX/utmctl-paused-$SHELL_BIN.log"; : >"$UTMCTL_LOG"
	export UTMCTL_STATUS=paused UTMCTL_STATUS_EXIT=0 UTMCTL_RESUME_EXIT=0
	status=$(run_watchdog "$SHELL_BIN" "$HOME_P")
	check "$SHELL_BIN: status paused -> exit 0" "0" "$status"
	resume_calls=$(grep -c '^utmctl resume ' "$UTMCTL_LOG" || true)
	check "$SHELL_BIN: status paused -> resume called once" "1" "$resume_calls"
	start_calls=$(grep -c '^utmctl start ' "$UTMCTL_LOG" || true)
	check "$SHELL_BIN: status paused -> no start call" "0" "$start_calls"

	# status stopped -> start called, succeeds first try
	HOME_T="$SANDBOX/wd-stopped-$SHELL_BIN"
	rm -rf "$HOME_T"; mkdir -p "$HOME_T"
	UTMCTL_LOG="$SANDBOX/utmctl-stopped-$SHELL_BIN.log"; : >"$UTMCTL_LOG"
	export UTMCTL_STATUS=stopped UTMCTL_STATUS_EXIT=0 UTMCTL_START_EXIT=0
	status=$(run_watchdog "$SHELL_BIN" "$HOME_T")
	check "$SHELL_BIN: status stopped -> exit 0" "0" "$status"
	start_calls=$(grep -c '^utmctl start ' "$UTMCTL_LOG" || true)
	check "$SHELL_BIN: status stopped -> start called once" "1" "$start_calls"

	# start failing every time -> exactly UTM_START_RETRIES attempts
	HOME_F="$SANDBOX/wd-failing-$SHELL_BIN"
	rm -rf "$HOME_F"; mkdir -p "$HOME_F"
	UTMCTL_LOG="$SANDBOX/utmctl-failing-$SHELL_BIN.log"; : >"$UTMCTL_LOG"
	export UTMCTL_STATUS=stopped UTMCTL_STATUS_EXIT=0 UTMCTL_START_EXIT=1 \
		UTM_START_RETRIES=3 UTM_RETRY_SECONDS=0
	status=$(run_watchdog "$SHELL_BIN" "$HOME_F")
	check "$SHELL_BIN: start always fails -> exit 0" "0" "$status"
	start_calls=$(grep -c '^utmctl start ' "$UTMCTL_LOG" || true)
	check "$SHELL_BIN: start always fails -> exactly UTM_START_RETRIES attempts" "3" "$start_calls"
	unset UTMCTL_START_EXIT UTM_START_RETRIES UTM_RETRY_SECONDS UTMCTL_RESUME_EXIT UTMCTL_STATUS UTMCTL_STATUS_EXIT
done

# log truncation keeps it bounded
HOME_L="$SANDBOX/wd-log"
rm -rf "$HOME_L"; mkdir -p "$HOME_L/Library/Logs"
BIG_LOG="$HOME_L/Library/Logs/utm-autostart.log"
i=0
: >"$BIG_LOG"
while [ "$i" -lt 20000 ]; do
	echo "old log line $i" >>"$BIG_LOG"
	i=$((i + 1))
done
python3 -c "print('x'*1100000, end='')" >>"$BIG_LOG" 2>/dev/null || printf '%01100000d' 0 >>"$BIG_LOG"
touch "$HOME_L/.utm-autostart-disabled"
UTMCTL_LOG="$SANDBOX/utmctl-log-truncate.log"; : >"$UTMCTL_LOG"
export UTMCTL_LOG
run_watchdog bash "$HOME_L" >/dev/null
lines_after=$(wc -l <"$BIG_LOG" | tr -d ' ')
[ "$lines_after" -le 2100 ] && trunc_ok=yes || trunc_ok=no
check "log truncation keeps the file bounded" "yes" "$trunc_ok"

unset UTMCTL_LOG UTM_VM_NAME

# ==============================================================================
# os/mac/vm-host/dotfiles.utm-autostart.plist.template -- static shape.
# ==============================================================================
echo
echo "os/mac/vm-host/dotfiles.utm-autostart.plist.template"

[ -f "$TEMPLATE" ] && tpl_exists=yes || tpl_exists=no
check "template exists" "yes" "$tpl_exists"
if [ "$tpl_exists" = yes ]; then
	tpl_content=$(cat "$TEMPLATE")
	contains "template references @SCRIPT@" "@SCRIPT@" "$tpl_content"
	contains "template references @VM_NAME@" "@VM_NAME@" "$tpl_content"
	contains "template references @HOME@" "@HOME@" "$tpl_content"
	contains "template Label is dotfiles.utm-autostart" "dotfiles.utm-autostart" "$tpl_content"
fi

# ==============================================================================
# scripts/setup-mac-vm-host
# ==============================================================================
echo
echo "scripts/setup-mac-vm-host"

[ -x "$SETUP" ] && setup_exec=yes || setup_exec=no
check "setup-mac-vm-host is executable" "yes" "$setup_exec"

SETUP_HOME="$SANDBOX/setup-home"
UTM_APP_DIR="$SANDBOX/UTM.app"
mkdir -p "$UTM_APP_DIR/Contents/MacOS"
cp "$STUBBIN/utmctl" "$UTM_APP_DIR/Contents/MacOS/utmctl"

run_setup() {
	# args: $1=home $2.. = extra args to setup-mac-vm-host
	home_dir="$1"; shift
	mkdir -p "$home_dir"
	(
		HOME="$home_dir"
		PATH="$STUB_PATH"
		UTM_APP_DIR="$UTM_APP_DIR"
		UTMCTL="$UTM_APP_DIR/Contents/MacOS/utmctl"
		export HOME PATH UTM_APP_DIR UTMCTL \
			SUDO_LOG PMSET_LOG PMSET_G_OUTPUT SYSTEMSETUP_LOG SYSTEMSETUP_RESTARTFREEZE \
			DEFAULTS_LOG DEFAULTS_AUTOLOGIN_USER FDESETUP_LOG FDESETUP_STATUS \
			LAUNCHCTL_LOG UTMCTL_LOG UTMCTL_LIST_OUTPUT UNAME_S
		bash "$SETUP" "$@"
	) >"$SANDBOX/setup-out" 2>&1
	echo $?
}

# refuses on Linux
UNAME_S=Linux
export UNAME_S
status=$(run_setup "$SANDBOX/setup-home-linux" --check)
check "refuses on non-Darwin -> exit 1" "1" "$status"
out=$(cat "$SANDBOX/setup-out")
contains "refuses on non-Darwin -> message" "macOS" "$out"
UNAME_S=Darwin
export UNAME_S

# common env for the "golden" (all good) scenario
CURRENT_USER=$(id -un)
export DEFAULTS_AUTOLOGIN_USER="$CURRENT_USER"
export FDESETUP_STATUS="FileVault is Off."
export SYSTEMSETUP_RESTARTFREEZE=On
export PMSET_G_OUTPUT="$GOOD_PMSET"
export UTMCTL_LIST_OUTPUT="sandbox-hclaro"

# first apply run: renders + bootstraps the LaunchAgent from scratch
SUDO_LOG="$SANDBOX/sudo-1.log"; : >"$SUDO_LOG"
PMSET_LOG="$SANDBOX/pmset-1.log"; : >"$PMSET_LOG"
SYSTEMSETUP_LOG="$SANDBOX/systemsetup-1.log"; : >"$SYSTEMSETUP_LOG"
DEFAULTS_LOG="$SANDBOX/defaults-1.log"; : >"$DEFAULTS_LOG"
FDESETUP_LOG="$SANDBOX/fdesetup-1.log"; : >"$FDESETUP_LOG"
LAUNCHCTL_LOG="$SANDBOX/launchctl-1.log"; : >"$LAUNCHCTL_LOG"
UTMCTL_LOG="$SANDBOX/utmctl-1.log"; : >"$UTMCTL_LOG"
status=$(run_setup "$SETUP_HOME" --vm sandbox-hclaro)
check "apply (golden path) -> exit 0" "0" "$status"
bootstrap_calls=$(grep -c '^launchctl bootstrap ' "$LAUNCHCTL_LOG" || true)
check "first apply -> bootstrap called once" "1" "$bootstrap_calls"
bootout_calls=$(grep -c '^launchctl bootout ' "$LAUNCHCTL_LOG" || true)
check "first apply -> bootout called once (ignored errors)" "1" "$bootout_calls"

PLIST_PATH="$SETUP_HOME/Library/LaunchAgents/dotfiles.utm-autostart.plist"
[ -f "$PLIST_PATH" ] && plist_written=yes || plist_written=no
check "LaunchAgent plist written" "yes" "$plist_written"
plist_content=$(cat "$PLIST_PATH" 2>/dev/null || echo "MISSING")
not_contains "LaunchAgent has no @SCRIPT@ placeholder left" "@SCRIPT@" "$plist_content"
not_contains "LaunchAgent has no @VM_NAME@ placeholder left" "@VM_NAME@" "$plist_content"
not_contains "LaunchAgent has no @HOME@ placeholder left" "@HOME@" "$plist_content"
contains "LaunchAgent has the correct absolute script path" "$DOTFILES_PATH/os/mac/vm-host/utm-autostart" "$plist_content"
contains "LaunchAgent has the VM name from --vm" "sandbox-hclaro" "$plist_content"

if command -v python3 >/dev/null 2>&1; then
	plist_check=$(python3 -c "
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
assert d['Label'] == 'dotfiles.utm-autostart', d.get('Label')
assert d['RunAtLoad'] is True, d.get('RunAtLoad')
assert d['StartInterval'] == 300, d.get('StartInterval')
print('OK')
" "$PLIST_PATH" 2>&1)
	contains "LaunchAgent parses as valid plist with Label/RunAtLoad/StartInterval 300" "OK" "$plist_check"
fi

# second apply run, nothing changed: no new bootout/bootstrap
SUDO_LOG="$SANDBOX/sudo-2.log"; : >"$SUDO_LOG"
LAUNCHCTL_LOG="$SANDBOX/launchctl-2.log"; : >"$LAUNCHCTL_LOG"
status=$(run_setup "$SETUP_HOME" --vm sandbox-hclaro)
check "second identical apply -> exit 0" "0" "$status"
bootstrap_calls=$(grep -c '^launchctl bootstrap ' "$LAUNCHCTL_LOG" || true)
check "identical + loaded -> bootstrap NOT called again" "0" "$bootstrap_calls"
bootout_calls=$(grep -c '^launchctl bootout ' "$LAUNCHCTL_LOG" || true)
check "identical + loaded -> bootout NOT called again" "0" "$bootout_calls"

# third apply run with a different VM name: content changed -> bootout+bootstrap again
LAUNCHCTL_LOG="$SANDBOX/launchctl-3.log"; : >"$LAUNCHCTL_LOG"
status=$(run_setup "$SETUP_HOME" --vm other-vm)
check "changed content apply -> exit 0" "0" "$status"
bootstrap_calls=$(grep -c '^launchctl bootstrap ' "$LAUNCHCTL_LOG" || true)
check "changed content -> bootstrap called again" "1" "$bootstrap_calls"

# --check, everything good -> exit 0, nothing mutating called
SUDO_LOG="$SANDBOX/sudo-check-good.log"; : >"$SUDO_LOG"
LAUNCHCTL_LOG="$SANDBOX/launchctl-check-good.log"; : >"$LAUNCHCTL_LOG"
UTMCTL_LIST_OUTPUT="other-vm"
export UTMCTL_LIST_OUTPUT
status=$(run_setup "$SETUP_HOME" --vm other-vm --check)
check "--check all good -> exit 0" "0" "$status"
sudo_calls=$(wc -l <"$SUDO_LOG" | tr -d ' ')
check "--check all good -> no sudo calls" "0" "$sudo_calls"
launchctl_mut=$(grep -Ec '^launchctl (bootout|bootstrap) ' "$LAUNCHCTL_LOG" || true)
check "--check all good -> no launchctl bootout/bootstrap" "0" "$launchctl_mut"
out=$(cat "$SANDBOX/setup-out")
not_contains "--check all good -> no pending lines" "pending" "$out"
UTMCTL_LIST_OUTPUT="sandbox-hclaro"
export UTMCTL_LIST_OUTPUT

# --check with sleep=1/autorestart=0 -> pending, exit 1, no sudo
SUDO_LOG="$SANDBOX/sudo-check-bad.log"; : >"$SUDO_LOG"
PMSET_G_OUTPUT="$BAD_PMSET"
export PMSET_G_OUTPUT
status=$(run_setup "$SANDBOX/setup-home-checkbad" --check)
check "--check bad power -> exit 1" "1" "$status"
sudo_calls=$(wc -l <"$SUDO_LOG" | tr -d ' ')
check "--check bad power -> no sudo calls" "0" "$sudo_calls"
out=$(cat "$SANDBOX/setup-out")
contains "--check bad power -> reports pending" "pending" "$out"

# apply with bad power -> exactly one sudo pmset -a call with the exact args
SUDO_LOG="$SANDBOX/sudo-apply-bad.log"; : >"$SUDO_LOG"
PMSET_LOG="$SANDBOX/pmset-apply-bad.log"; : >"$PMSET_LOG"
status=$(run_setup "$SANDBOX/setup-home-applybad" --vm sandbox-hclaro)
check "apply bad power -> exit 0" "0" "$status"
pmset_a_calls=$(grep -c '^sudo pmset -a ' "$SUDO_LOG" || true)
check "apply bad power -> exactly one sudo pmset -a call" "1" "$pmset_a_calls"
exact_call=$(grep '^sudo pmset -a ' "$SUDO_LOG" || true)
check "apply bad power -> exact args" \
	"sudo pmset -a sleep 0 disksleep 0 standby 0 autopoweroff 0 powernap 0 autorestart 1 womp 1" \
	"$exact_call"
PMSET_G_OUTPUT="$GOOD_PMSET"
export PMSET_G_OUTPUT

# already correct power -> no pmset -a write
SUDO_LOG="$SANDBOX/sudo-apply-good.log"; : >"$SUDO_LOG"
status=$(run_setup "$SANDBOX/setup-home-applygood" --vm sandbox-hclaro)
check "apply good power -> exit 0" "0" "$status"
pmset_a_calls=$(grep -c '^sudo pmset -a ' "$SUDO_LOG" || true)
check "apply good power -> no pmset -a write" "0" "$pmset_a_calls"

# restartfreeze already On -> not applied again
SUDO_LOG="$SANDBOX/sudo-freeze-on.log"; : >"$SUDO_LOG"
SYSTEMSETUP_RESTARTFREEZE=On
export SYSTEMSETUP_RESTARTFREEZE
status=$(run_setup "$SANDBOX/setup-home-freezeon" --vm sandbox-hclaro)
check "restartfreeze already On -> exit 0" "0" "$status"
freeze_calls=$(grep -c '^sudo systemsetup -setrestartfreeze ' "$SUDO_LOG" || true)
check "restartfreeze already On -> not applied again" "0" "$freeze_calls"

# restartfreeze Off -> applied
SUDO_LOG="$SANDBOX/sudo-freeze-off.log"; : >"$SUDO_LOG"
SYSTEMSETUP_RESTARTFREEZE=Off
export SYSTEMSETUP_RESTARTFREEZE
status=$(run_setup "$SANDBOX/setup-home-freezeoff" --vm sandbox-hclaro)
check "restartfreeze Off -> exit 0" "0" "$status"
freeze_calls=$(grep -c '^sudo systemsetup -setrestartfreeze on' "$SUDO_LOG" || true)
check "restartfreeze Off -> applied exactly once" "1" "$freeze_calls"
SYSTEMSETUP_RESTARTFREEZE=On
export SYSTEMSETUP_RESTARTFREEZE

# autologin missing -> manual steps printed, FileVault status reported
DEFAULTS_AUTOLOGIN_USER=""
FDESETUP_STATUS="FileVault is On."
export DEFAULTS_AUTOLOGIN_USER FDESETUP_STATUS
status=$(run_setup "$SANDBOX/setup-home-autologin" --vm sandbox-hclaro)
out=$(cat "$SANDBOX/setup-out")
contains "autologin missing -> manual steps" "Login Options" "$out"
contains "autologin missing -> FileVault status reported" "FileVault is On." "$out"
DEFAULTS_AUTOLOGIN_USER="$CURRENT_USER"
FDESETUP_STATUS="FileVault is Off."
export DEFAULTS_AUTOLOGIN_USER FDESETUP_STATUS

# ==============================================================================
# Portability: forbidden bashisms/GNU-isms in the two Mac scripts.
# ==============================================================================
echo
echo "portability"

for f in "$WATCHDOG" "$SETUP"; do
	name=$(basename "$f")
	for pattern in mapfile 'declare -A' 'readlink -f' 'sed -i'; do
		hit=$(grep -c -- "$pattern" "$f" 2>/dev/null || true)
		check "$name does not use: $pattern" "0" "$hit"
	done
done

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
