#!/usr/bin/env bash
# Regression tests for scripts/bootstrap-linux, the standalone script that
# prepares a fresh Ubuntu 24.04 Server VM (or WSL) to receive the dotfiles,
# run BEFORE the dotfiles are cloned.
#
# Nothing here touches the real machine. Every command bootstrap-linux could
# call (sudo, apt-get, dpkg, findmnt, lvs, vgs, pvs, lsblk, growpart,
# pvresize, lvextend, resize2fs, df, systemctl, sysctl, swapon, ss,
# timedatectl, curl, git, id, uname) is stubbed onto PATH and records its
# arguments into one shared log, inside a disposable HOME. `setsid` detaches
# the test process from any controlling terminal so the script's own
# /dev/tty probe (for the restore step's y/n prompt) reliably falls back to
# the piped stdin used to feed answers.
#
# THIS FILE IS NOT PART OF THE RESTORE. Run it by hand:
#
#     ./restoration_scripts/tests/bootstrap-linux.sh
#
# Exits non-zero if any case fails.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/bootstrap-linux"

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

echo "bootstrap-linux tests"
echo

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
STUBBIN="$SANDBOX/stubbin"
mkdir -p "$STUBBIN"
STUB_PATH="$STUBBIN:/usr/bin:/bin"

CMD_LOG="$SANDBOX/cmd.log"

# ==============================================================================
# Stub binaries. All of them append "<name> $*" to one shared CMD_LOG.
# ==============================================================================

cat >"$STUBBIN/uname" <<'STUB'
#!/usr/bin/env bash
echo "uname $*" >>"$CMD_LOG"
echo "${UNAME_S:-Linux}"
STUB

cat >"$STUBBIN/id" <<'STUB'
#!/usr/bin/env bash
echo "id $*" >>"$CMD_LOG"
[ "$1" = "-u" ] && echo "${ID_U:-1000}"
exit 0
STUB

cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$CMD_LOG"
if [ "$1" = "-v" ]; then exit 0; fi
if [ "$1" = "-n" ]; then
	shift
	if [ "${SUDO_N_FAILS:-0}" = "1" ]; then exit 1; fi
	VIA_SUDO=1 "$@"
	exit $?
fi
while [ $# -gt 0 ]; do
	case "$1" in
	*=*) export "${1?}"; shift ;;
	*) break ;;
	esac
done
VIA_SUDO=1 "$@"
STUB

cat >"$STUBBIN/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >>"$CMD_LOG"
exit 0
STUB

cat >"$STUBBIN/dpkg" <<'STUB'
#!/usr/bin/env bash
echo "dpkg $*" >>"$CMD_LOG"
if [ "$1" = "-s" ]; then
	pkg="$2"
	case " ${DPKG_MISSING:-} " in
	*" $pkg "*) exit 1 ;;
	*) exit 0 ;;
	esac
fi
exit 0
STUB

cat >"$STUBBIN/findmnt" <<'STUB'
#!/usr/bin/env bash
echo "findmnt $*" >>"$CMD_LOG"
case "$2" in
SOURCE) echo "${FINDMNT_SOURCE:-/dev/sda2}" ;;
FSTYPE) echo "${FINDMNT_FSTYPE:-ext4}" ;;
esac
exit 0
STUB

cat >"$STUBBIN/lvs" <<'STUB'
#!/usr/bin/env bash
echo "lvs $*" >>"$CMD_LOG"
if [ -z "${VIA_SUDO:-}" ]; then
	echo "  /run/lock/lvm/P_global:aux: open failed: Permission denied" >&2
	exit 5
fi
if [ $# -eq 0 ]; then
	exit "${LVS_BARE_EXIT:-0}"
fi
echo "${LVS_VG_NAME:-ubuntu-vg}"
exit 0
STUB

cat >"$STUBBIN/vgs" <<'STUB'
#!/usr/bin/env bash
echo "vgs $*" >>"$CMD_LOG"
if [ -z "${VIA_SUDO:-}" ]; then
	echo "  /run/lock/lvm/P_global:aux: open failed: Permission denied" >&2
	exit 5
fi
if [ "${VGS_UNREADABLE:-0}" = "1" ]; then
	echo "  Volume group \"${LVS_VG_NAME:-ubuntu-vg}\" not found" >&2
	exit 5
fi
echo "  ${VGS_FREE_B:-0B}"
exit 0
STUB

cat >"$STUBBIN/pvs" <<'STUB'
#!/usr/bin/env bash
echo "pvs $*" >>"$CMD_LOG"
if [ -z "${VIA_SUDO:-}" ]; then
	echo "  /run/lock/lvm/P_global:aux: open failed: Permission denied" >&2
	exit 5
fi
echo "  ${PVS_PV_NAME:-/dev/sda3}"
exit 0
STUB

# Mirrors what lsblk printed on the real Ubuntu 24.04 VM, including its two
# traps: without -d a query on a partition also lists its LVM child (so PKNAME
# prints "sda" then "sda3"), and PKNAME of a device-mapper node is empty.
cat >"$STUBBIN/lsblk" <<'STUB'
#!/usr/bin/env bash
echo "lsblk $*" >>"$CMD_LOG"
pv_part="${LSBLK_PV_PART:-sda3}"
disk="${LSBLK_PKNAME:-sda}"
partn="${LSBLK_PARTN:-3}"
case "$1 $2" in
"-no PKNAME")
	case "$3" in
	/dev/mapper/*) echo "" ;;
	*) printf '%s\n%s\n' "$disk" "$pv_part" ;;
	esac
	;;
"-ndo PKNAME")
	case "$3" in
	/dev/mapper/*) echo "" ;;
	*) echo "$disk" ;;
	esac
	;;
"-no PARTN") printf '    %s\n\n' "$partn" ;;
"-ndo PARTN") printf '    %s\n' "$partn" ;;
"-slno NAME,TYPE")
	printf 'ubuntu--vg-ubuntu--lv lvm\n%-21s part\n%-21s disk\n' "$pv_part" "$disk"
	;;
"-bndo SIZE") echo "${LSBLK_PV_SIZE_B:-157784473600}" ;;
"-bno SIZE,TYPE")
	printf '%s part\n' "${LSBLK_PV_SIZE_B:-157784473600}"
	printf '%s\n' "${LSBLK_LVM_CHILDREN:- 78890663936 lvm}"
	;;
esac
exit 0
STUB

cat >"$STUBBIN/growpart" <<'STUB'
#!/usr/bin/env bash
echo "growpart $*" >>"$CMD_LOG"
if [ -z "${VIA_SUDO:-}" ]; then
	echo "growpart: could not open '/dev/sda': Permission denied" >&2
	exit 1
fi
if [ "$1" = "--dry-run" ]; then
	echo "${GROWPART_DRYRUN_OUTPUT:-NOCHANGE: partition already at capacity}"
	exit "${GROWPART_DRYRUN_EXIT:-1}"
fi
exit 0
STUB

cat >"$STUBBIN/pvresize" <<'STUB'
#!/usr/bin/env bash
echo "pvresize $*" >>"$CMD_LOG"
exit 0
STUB

cat >"$STUBBIN/lvextend" <<'STUB'
#!/usr/bin/env bash
echo "lvextend $*" >>"$CMD_LOG"
exit 0
STUB

cat >"$STUBBIN/resize2fs" <<'STUB'
#!/usr/bin/env bash
echo "resize2fs $*" >>"$CMD_LOG"
exit 0
STUB

cat >"$STUBBIN/df" <<'STUB'
#!/usr/bin/env bash
echo "df $*" >>"$CMD_LOG"
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/mapper/x    73G   10G   60G  15% /"
exit 0
STUB

cat >"$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$CMD_LOG"
mkdir -p "$SYSTEMCTL_STATE_DIR"
action="$1"
svc="${*: -1}"
case "$action" in
is-active)
	[ -f "$SYSTEMCTL_STATE_DIR/$svc.active" ] && exit 0 || exit 3
	;;
start)
	if [ "${SYSTEMCTL_START_FAIL:-}" = "$svc" ]; then exit 1; fi
	touch "$SYSTEMCTL_STATE_DIR/$svc.active"
	exit 0
	;;
enable | restart)
	touch "$SYSTEMCTL_STATE_DIR/$svc.active"
	exit 0
	;;
*) exit 0 ;;
esac
STUB

cat >"$STUBBIN/sysctl" <<'STUB'
#!/usr/bin/env bash
echo "sysctl $*" >>"$CMD_LOG"
if [ "$1" = "-n" ] && [ "$2" = "kernel.panic" ]; then
	echo "${SYSCTL_KERNEL_PANIC:-0}"
fi
exit 0
STUB

cat >"$STUBBIN/swapon" <<'STUB'
#!/usr/bin/env bash
echo "swapon $*" >>"$CMD_LOG"
cat "${SWAPON_SHOW_FILE:-/dev/null}" 2>/dev/null
exit 0
STUB

cat >"$STUBBIN/ss" <<'STUB'
#!/usr/bin/env bash
echo "ss $*" >>"$CMD_LOG"
cat "${SS_OUTPUT_FILE:-/dev/null}" 2>/dev/null
exit 0
STUB

cat >"$STUBBIN/timedatectl" <<'STUB'
#!/usr/bin/env bash
echo "timedatectl $*" >>"$CMD_LOG"
case "$1" in
show)
	cat "${TIMEDATECTL_STATE:-/dev/null}" 2>/dev/null || echo "Etc/UTC"
	;;
list-timezones)
	cat "${TIMEDATECTL_ZONES_FILE:-/dev/null}" 2>/dev/null
	;;
set-timezone)
	echo "$2" >"${TIMEDATECTL_STATE:?}"
	;;
esac
exit 0
STUB

cat >"$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$CMD_LOG"
out=""
prev=""
for a in "$@"; do
	[ "$prev" = "-o" ] && out="$a"
	prev="$a"
done
if [ -n "$out" ]; then
	cp "${CURL_WRITE_SRC:?}" "$out"
	chmod +x "$out"
fi
exit 0
STUB

cat >"$STUBBIN/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >>"$CMD_LOG"
exit 0
STUB

chmod +x "$STUBBIN"/*

FAKE_INSTALLER="$SANDBOX/fake-installer.sh"
cat >"$FAKE_INSTALLER" <<'EOF'
#!/usr/bin/env bash
echo "fake-download-ran NONINTERACTIVE=${NONINTERACTIVE:-} args=$*"
EOF
chmod +x "$FAKE_INSTALLER"

# ==============================================================================
# Shared fixtures and defaults (real values measured on the target VM:
# Ubuntu 24.04.5 server on qemu -- / is ubuntu-vg/ubuntu-lv 73.5G, its PV
# /dev/sda3 is 146.9G and already fills the 150G disk).
# ==============================================================================

PROC_LINUX="$SANDBOX/proc-linux"
printf 'Linux version 6.6.0\n' >"$PROC_LINUX"
PROC_WSL="$SANDBOX/proc-wsl"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' >"$PROC_WSL"

ZONES_FILE="$SANDBOX/zones.txt"
printf 'UTC\nAmerica/Bogota\nEurope/Madrid\nAmerica/New_York\n' >"$ZONES_FILE"

LINUXBREW_PREFIX="$SANDBOX/linuxbrew-missing"

export CMD_LOG UNAME_S ID_U BOOTSTRAP_PROC_VERSION_FILE DPKG_MISSING \
	FINDMNT_SOURCE FINDMNT_FSTYPE LVS_BARE_EXIT LVS_VG_NAME VGS_FREE_B VGS_UNREADABLE PVS_PV_NAME \
	LSBLK_PKNAME LSBLK_PARTN LSBLK_PV_PART LSBLK_PV_SIZE_B LSBLK_LVM_CHILDREN \
	GROWPART_DRYRUN_OUTPUT GROWPART_DRYRUN_EXIT SUDO_N_FAILS \
	ZRAM_DEFAULTS_FILE SYSCTL_ZRAM_FILE SWAPON_SHOW_FILE SS_OUTPUT_FILE \
	SYSCTL_PANIC_FILE SYSCTL_KERNEL_PANIC \
	SYSTEMCTL_STATE_DIR SYSTEMCTL_START_FAIL TIMEDATECTL_STATE TIMEDATECTL_ZONES_FILE \
	LINUXBREW_PREFIX CURL_WRITE_SRC BOOTSTRAP_TIMEZONE

reset_common() {
	UNAME_S=Linux
	ID_U=1000
	BOOTSTRAP_PROC_VERSION_FILE="$PROC_LINUX"
	DPKG_MISSING=""
	# real-VM main case: LV already fills the disk, only lvextend is needed.
	FINDMNT_SOURCE="/dev/mapper/ubuntu--vg-ubuntu--lv"
	FINDMNT_FSTYPE="ext4"
	LVS_BARE_EXIT=0
	LVS_VG_NAME="ubuntu-vg"
	VGS_FREE_B="78894314496B" # ~73.4 GiB free, matches 146.9G PV - 73.5G LV
	VGS_UNREADABLE=0
	PVS_PV_NAME="/dev/sda3"
	LSBLK_PKNAME="sda"
	LSBLK_PARTN="3"
	LSBLK_PV_PART="sda3"
	LSBLK_PV_SIZE_B=157814338560 # 146.9G PV: 73.5G LV + 73.4G free
	LSBLK_LVM_CHILDREN="78920024064 lvm" # 73.5G LV, matches VGS_FREE_B's remainder
	GROWPART_DRYRUN_OUTPUT="NOCHANGE: partition 3 is size 308004864. it cannot be grown"
	GROWPART_DRYRUN_EXIT=1
	SUDO_N_FAILS=0
	ZRAM_DEFAULTS_FILE="$SANDBOX/etc-default-zramswap-$RANDOM"
	SYSCTL_ZRAM_FILE="$SANDBOX/etc-sysctl-zram-$RANDOM.conf"
	SYSCTL_PANIC_FILE="$SANDBOX/etc-sysctl-panic-$RANDOM.conf"
	SYSCTL_KERNEL_PANIC=0
	SWAPON_SHOW_FILE="$SANDBOX/swapon-show-$RANDOM.txt"
	: >"$SWAPON_SHOW_FILE"
	SS_OUTPUT_FILE="$SANDBOX/ss-output-$RANDOM.txt"
	: >"$SS_OUTPUT_FILE"
	SYSTEMCTL_STATE_DIR="$SANDBOX/systemctl-state-$RANDOM"
	SYSTEMCTL_START_FAIL=""
	TIMEDATECTL_STATE="$SANDBOX/timedatectl-state-$RANDOM.txt"
	echo "Etc/UTC" >"$TIMEDATECTL_STATE"
	TIMEDATECTL_ZONES_FILE="$ZONES_FILE"
	LINUXBREW_PREFIX="$SANDBOX/linuxbrew-$RANDOM"
	CURL_WRITE_SRC="$FAKE_INSTALLER"
	BOOTSTRAP_TIMEZONE=""
	: >"$CMD_LOG"
}

# run_bootstrap <stdin> <home-dir> [args...] -- sets $OUT and $RC.
run_bootstrap() {
	local input="$1" home_dir="$2"
	shift 2
	mkdir -p "$home_dir"
	OUT=$(HOME="$home_dir" PATH="$STUB_PATH" \
		printf '%s' "$input" | HOME="$home_dir" PATH="$STUB_PATH" setsid bash "$SCRIPT" "$@" 2>&1)
	RC=$?
}

count() { grep -c -- "$1" "$CMD_LOG" 2>/dev/null || true; }
exact_count() { grep -c -x -- "$1" "$CMD_LOG" 2>/dev/null || true; }

# ==============================================================================
# Basic refusals.
# ==============================================================================
echo "refusals"

[ -x "$SCRIPT" ] && script_exec=yes || script_exec=no
check "bootstrap-linux is executable" "yes" "$script_exec"

reset_common
ID_U=0
run_bootstrap "" "$SANDBOX/home-root" --check
check "refuses as root -> exit 1" "1" "$RC"
contains "refuses as root -> message" "root" "$OUT"
mut=$(count 'apt-get install')
check "refuses as root -> no apt-get install" "0" "$mut"

reset_common
UNAME_S=Darwin
run_bootstrap "" "$SANDBOX/home-darwin" --check
check "refuses on non-Linux -> exit 1" "1" "$RC"
contains "refuses on non-Linux -> message" "Linux" "$OUT"

# ==============================================================================
# --check on a fresh machine: everything pending, exit 1, nothing mutating.
# ==============================================================================
echo
echo "--check fresh"

reset_common
DPKG_MISSING="build-essential curl file git zsh unzip python-is-python3 openssh-server zram-tools cloud-guest-utils qemu-guest-agent"
FINDMNT_SOURCE="/dev/sda2" # plain partition, not LVM, for a simple "not filled" fixture
GROWPART_DRYRUN_OUTPUT="CHANGE: partition=2 start=2050048 old: size=307197952 end=309248000 new: size=310000000 end=312050048"
GROWPART_DRYRUN_EXIT=0
SS_OUTPUT_FILE="$SANDBOX/ss-empty.txt"
: >"$SS_OUTPUT_FILE"
run_bootstrap "" "$SANDBOX/home-check-fresh" --check
check "--check fresh -> exit 1" "1" "$RC"
for step in apt disk zram panic guest-agent timezone sshd brew; do
	contains "--check fresh -> $step pending" "$step" "$OUT"
done
zram_line=$(printf '%s\n' "$OUT" | grep -n '^zram ' | head -1 | cut -d: -f1)
panic_line=$(printf '%s\n' "$OUT" | grep -n '^panic ' | head -1 | cut -d: -f1)
guestagent_line=$(printf '%s\n' "$OUT" | grep -n '^guest-agent ' | head -1 | cut -d: -f1)
order_ok=no
if [ -n "$zram_line" ] && [ -n "$panic_line" ] && [ -n "$guestagent_line" ] &&
	[ "$zram_line" -lt "$panic_line" ] && [ "$panic_line" -lt "$guestagent_line" ]; then
	order_ok=yes
fi
check "summary table -> panic between zram and guest-agent" "yes" "$order_ok"
mut=$(count 'apt-get install\|apt-get full-upgrade')
check "--check fresh -> no apt-get install/upgrade" "0" "$mut"
mut=$(count '^lvextend ')
check "--check fresh -> no lvextend" "0" "$mut"
mut=$(count '^growpart /dev/sda2 2$')
check "--check fresh -> no real growpart (only dry-run)" "0" "$mut"
mut=$(count 'sudo install -m 644')
check "--check fresh -> no install to /etc paths" "0" "$mut"
mut=$(count '^systemctl enable')
check "--check fresh -> no systemctl enable" "0" "$mut"
mut=$(count '^curl ')
check "--check fresh -> no curl" "0" "$mut"
mut=$(count '^git clone')
check "--check fresh -> no git clone" "0" "$mut"
not_contains "--check fresh -> no restore prompt printed" "Launch Dotly's restorer" "$OUT"

# ==============================================================================
# disk: main real-VM case -- LV already fills the disk, only lvextend needed.
# ==============================================================================
echo
echo "disk: real-VM main case (lvextend only)"

reset_common
run_bootstrap "n" "$SANDBOX/home-disk-main"
n=$(exact_count 'lvextend -r -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv')
check "main case -> exactly one lvextend with the real LV path" "1" "$n"
n=$(count '^growpart /dev/sda 3$')
check "main case -> no real growpart (PV already fills the disk)" "0" "$n"
n=$(count '^pvresize ')
check "main case -> no pvresize" "0" "$n"
n=$(exact_count 'sudo -n lvs --noheadings -o vg_name /dev/mapper/ubuntu--vg-ubuntu--lv')
check "main case -> lvs invoked via sudo" "1" "$n"
n=$(exact_count 'sudo -n vgs --noheadings --units b -o vg_free ubuntu-vg')
check "main case -> vgs invoked via sudo" "1" "$n"
n=$(exact_count 'sudo -n pvs --noheadings -o pv_name --select vg_name=ubuntu-vg')
check "main case -> pvs invoked via sudo" "1" "$n"
n=$(exact_count 'sudo -n growpart --dry-run /dev/sda 3')
check "main case -> growpart --dry-run invoked via sudo" "1" "$n"

# ==============================================================================
# disk: --check without cached sudo -- lsblk-only estimate, never "grow it by hand".
# ==============================================================================
echo
echo "disk: --check without cached sudo"

reset_common
SUDO_N_FAILS=1
run_bootstrap "" "$SANDBOX/home-disk-nosudo" --check
contains "--check no sudo -> disk pending" "disk" "$OUT"
contains "--check no sudo -> mentions ubuntu-vg" "ubuntu-vg" "$OUT"
not_contains "--check no sudo -> no 'grow it by hand'" "grow it by hand" "$OUT"
mut=$(count '^lvextend ')
check "--check no sudo -> no lvextend" "0" "$mut"
mut=$(count '^growpart /dev/sda 3$')
check "--check no sudo -> no real growpart" "0" "$mut"
mut=$(count '^pvresize ')
check "--check no sudo -> no pvresize" "0" "$mut"

# Measured on the VM after the extension: the LV fills the PV except LVM's
# few MiB of metadata. lsblk confirms that without sudo, so it is done.
reset_common
SUDO_N_FAILS=1
LSBLK_LVM_CHILDREN="157781327872 lvm"
run_bootstrap "" "$SANDBOX/home-disk-nosudo-full" --check
disk_summary_line=$(printf '%s\n' "$OUT" | grep '^disk ')
contains "--check no sudo, VG already full -> disk done" "done" "$disk_summary_line"

# ==============================================================================
# disk: vgs output unreadable even with sudo -- pending, never a false ok.
# ==============================================================================
echo
echo "disk: vgs unreadable even with sudo"

reset_common
VGS_UNREADABLE=1
run_bootstrap "n" "$SANDBOX/home-disk-vgsbad"
not_contains "vgs unreadable -> no false whole-disk ok" "root logical volume already uses the whole disk" "$OUT"
mut=$(count '^lvextend ')
check "vgs unreadable -> no lvextend" "0" "$mut"
mut=$(count '^growpart /dev/sda 3$')
check "vgs unreadable -> no real growpart" "0" "$mut"
mut=$(count '^pvresize ')
check "vgs unreadable -> no pvresize" "0" "$mut"

# ==============================================================================
# disk: LVM with (effectively) no free space -- no lvextend.
# ==============================================================================
echo
echo "disk: LVM with no free space"

reset_common
VGS_FREE_B="524288B" # well under 1 GiB
run_bootstrap "n" "$SANDBOX/home-disk-nofree"
n=$(count '^lvextend ')
check "no free space -> no lvextend" "0" "$n"

# ==============================================================================
# disk: PV does not fill the disk -- growpart + pvresize BEFORE lvextend.
# ==============================================================================
echo
echo "disk: PV needs growing first"

reset_common
GROWPART_DRYRUN_OUTPUT="CHANGE: partition=3 start=6293504 old: size=300000000 end=306293504 new: size=314566656 end=320860160"
GROWPART_DRYRUN_EXIT=0
run_bootstrap "n" "$SANDBOX/home-disk-growpv"
n=$(exact_count 'growpart /dev/sda 3')
check "PV needs growing -> growpart called for real" "1" "$n"
n=$(exact_count 'pvresize /dev/sda3')
check "PV needs growing -> pvresize called" "1" "$n"
n=$(exact_count 'lvextend -r -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv')
check "PV needs growing -> lvextend still runs after" "1" "$n"
growpart_line=$(grep -n '^growpart /dev/sda 3$' "$CMD_LOG" | head -1 | cut -d: -f1)
pvresize_line=$(grep -n '^pvresize /dev/sda3$' "$CMD_LOG" | head -1 | cut -d: -f1)
lvextend_line=$(grep -n '^lvextend -r -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv$' "$CMD_LOG" | head -1 | cut -d: -f1)
order_ok=no
if [ -n "$growpart_line" ] && [ -n "$pvresize_line" ] && [ -n "$lvextend_line" ] &&
	[ "$growpart_line" -lt "$pvresize_line" ] && [ "$pvresize_line" -lt "$lvextend_line" ]; then
	order_ok=yes
fi
check "PV needs growing -> order is growpart, pvresize, lvextend" "yes" "$order_ok"

# ==============================================================================
# disk: plain ext4 partition, no LVM.
# ==============================================================================
echo
echo "disk: plain ext4 partition"

reset_common
FINDMNT_SOURCE="/dev/sda2"
LSBLK_PKNAME="sda"
LSBLK_PARTN="2"
GROWPART_DRYRUN_OUTPUT="CHANGE: partition=2 start=2050048 old: size=307197952 end=309248000 new: size=310000000 end=312050048"
GROWPART_DRYRUN_EXIT=0
run_bootstrap "n" "$SANDBOX/home-disk-plain"
n=$(exact_count 'growpart /dev/sda 2')
check "plain partition -> growpart called" "1" "$n"
n=$(exact_count 'resize2fs /dev/sda2')
check "plain partition -> resize2fs called" "1" "$n"
n=$(count '^lvextend ')
check "plain partition -> no lvextend" "0" "$n"

# ==============================================================================
# zram: files written with exact keys/values, unrelated lines preserved.
# ==============================================================================
echo
echo "zram"

reset_common
cat >"$ZRAM_DEFAULTS_FILE" <<'EOF'
# comment kept as-is
SOME_OTHER_KEY=yes
ALGO=lz4
EOF
run_bootstrap "n" "$SANDBOX/home-zram-1"
contains "zram defaults -> ALGO=zstd written" "ALGO=zstd" "$(cat "$ZRAM_DEFAULTS_FILE")"
contains "zram defaults -> PERCENT=50 written" "PERCENT=50" "$(cat "$ZRAM_DEFAULTS_FILE")"
contains "zram defaults -> PRIORITY=100 written" "PRIORITY=100" "$(cat "$ZRAM_DEFAULTS_FILE")"
contains "zram defaults -> unrelated line preserved" "SOME_OTHER_KEY=yes" "$(cat "$ZRAM_DEFAULTS_FILE")"
contains "zram defaults -> unrelated comment preserved" "# comment kept as-is" "$(cat "$ZRAM_DEFAULTS_FILE")"
contains "zram sysctl -> vm.swappiness=180 written" "vm.swappiness=180" "$(cat "$SYSCTL_ZRAM_FILE")"
contains "zram sysctl -> vm.page-cluster=0 written" "vm.page-cluster=0" "$(cat "$SYSCTL_ZRAM_FILE")"
n=$(count '^systemctl restart zramswap.service$')
check "zram first run -> restart called (config changed)" "1" "$n"

# rerun: files already correct, zram already active -> no rewrite/restart.
echo "zram0 4096 4194304 512 0 1024" >"$SWAPON_SHOW_FILE"
: >"$CMD_LOG"
zram_before=$(cat "$ZRAM_DEFAULTS_FILE")
sysctl_before=$(cat "$SYSCTL_ZRAM_FILE")
run_bootstrap "n" "$SANDBOX/home-zram-1"
check "zram rerun -> defaults file unchanged" "$zram_before" "$(cat "$ZRAM_DEFAULTS_FILE")"
check "zram rerun -> sysctl file unchanged" "$sysctl_before" "$(cat "$SYSCTL_ZRAM_FILE")"
n=$(count '^systemctl restart zramswap.service$')
check "zram rerun -> no restart" "0" "$n"
n=$(count 'sudo install -m 644')
check "zram rerun -> no install/rewrite" "0" "$n"

# ==============================================================================
# panic: kernel.panic=10 reboots the VM instead of leaving it hung forever.
# ==============================================================================
echo
echo "panic"

reset_common
run_bootstrap "" "$SANDBOX/home-panic-check-fresh" --check
check "panic --check fresh -> file not written" "" "$(cat "$SYSCTL_PANIC_FILE" 2>/dev/null)"
n=$(count "$SYSCTL_PANIC_FILE")
check "panic --check fresh -> panic file never referenced" "0" "$n"
n=$(count '^sysctl -p')
check "panic --check fresh -> no sysctl -p" "0" "$n"

reset_common
run_bootstrap "n" "$SANDBOX/home-panic-apply"
expected_panic=$'# Reboot 10 s after a kernel panic instead of hanging (written by bootstrap-linux).\nkernel.panic = 10'
check "panic apply -> file content exact" "$expected_panic" "$(cat "$SYSCTL_PANIC_FILE")"
n=$(grep -F "$SYSCTL_PANIC_FILE" "$CMD_LOG" | grep -c 'install -m 644')
check "panic apply -> installed via sudo install" "1" "$n"
n=$(grep -F "$SYSCTL_PANIC_FILE" "$CMD_LOG" | grep -c '^sysctl -p')
check "panic apply -> sysctl -p run on the panic file" "1" "$n"

reset_common
cat >"$SYSCTL_PANIC_FILE" <<'EOF'
# Reboot 10 s after a kernel panic instead of hanging (written by bootstrap-linux).
kernel.panic = 10
EOF
SYSCTL_KERNEL_PANIC=10
run_bootstrap "n" "$SANDBOX/home-panic-done"
panic_summary_line=$(printf '%s\n' "$OUT" | grep '^panic ')
contains "panic already configured -> summary shows done" "done" "$panic_summary_line"
n=$(grep -F "$SYSCTL_PANIC_FILE" "$CMD_LOG" | grep -c 'install -m 644')
check "panic already configured -> no rewrite" "0" "$n"
n=$(grep -F "$SYSCTL_PANIC_FILE" "$CMD_LOG" | grep -c '^sysctl -p')
check "panic already configured -> no sysctl -p call" "0" "$n"

reset_common
cat >"$SYSCTL_PANIC_FILE" <<'EOF'
# Reboot 10 s after a kernel panic instead of hanging (written by bootstrap-linux).
kernel.panic = 10
EOF
SYSCTL_KERNEL_PANIC=0
content_before=$(cat "$SYSCTL_PANIC_FILE")
run_bootstrap "n" "$SANDBOX/home-panic-live-stale"
check "panic file correct, live stale -> file unchanged" "$content_before" "$(cat "$SYSCTL_PANIC_FILE")"
n=$(grep -F "$SYSCTL_PANIC_FILE" "$CMD_LOG" | grep -c 'install -m 644')
check "panic file correct, live stale -> no rewrite" "0" "$n"
n=$(grep -F "$SYSCTL_PANIC_FILE" "$CMD_LOG" | grep -c '^sysctl -p')
check "panic file correct, live stale -> sysctl -p applied" "1" "$n"

# Measured on the VM: the setting was applied by hand with only the setting
# line. It is configured and active, so it must count as done, not pending.
reset_common
printf 'kernel.panic = 10\n' >"$SYSCTL_PANIC_FILE"
SYSCTL_KERNEL_PANIC=10
run_bootstrap "" "$SANDBOX/home-panic-byhand" --check
panic_summary_line=$(printf '%s\n' "$OUT" | grep '^panic ')
contains "panic set by hand without the comment -> done" "done" "$panic_summary_line"

# A file that sets another value is not done.
reset_common
printf 'kernel.panic = 0\n' >"$SYSCTL_PANIC_FILE"
SYSCTL_KERNEL_PANIC=10
run_bootstrap "" "$SANDBOX/home-panic-wrongvalue" --check
panic_summary_line=$(printf '%s\n' "$OUT" | grep '^panic ')
contains "panic file with another value -> pending" "pending" "$panic_summary_line"

# ==============================================================================
# guest-agent.
# ==============================================================================
echo
echo "guest-agent"

reset_common
run_bootstrap "n" "$SANDBOX/home-ga-1"
n=$(exact_count 'systemctl start qemu-guest-agent')
check "guest-agent inactive -> start called" "1" "$n"
contains "guest-agent inactive -> becomes done" "guest-agent" "$OUT"

reset_common
mkdir -p "$SYSTEMCTL_STATE_DIR"
touch "$SYSTEMCTL_STATE_DIR/qemu-guest-agent.active"
run_bootstrap "n" "$SANDBOX/home-ga-2"
n=$(count '^systemctl start qemu-guest-agent$')
check "guest-agent already active -> no start call" "0" "$n"

reset_common
SYSTEMCTL_START_FAIL="qemu-guest-agent"
run_bootstrap "n" "$SANDBOX/home-ga-3"
contains "guest-agent still fails -> hint about UTM virtio serial" "UTM" "$OUT"

# ==============================================================================
# timezone.
# ==============================================================================
echo
echo "timezone"

reset_common
echo "America/Bogota" >"$TIMEDATECTL_STATE"
run_bootstrap "n" "$SANDBOX/home-tz-1"
n=$(count '^timedatectl set-timezone')
check "timezone already correct -> no set-timezone call" "0" "$n"

reset_common
run_bootstrap "n" "$SANDBOX/home-tz-2"
n=$(exact_count 'timedatectl set-timezone America/Bogota')
check "timezone default -> set to America/Bogota" "1" "$n"

reset_common
run_bootstrap "n" "$SANDBOX/home-tz-3" --timezone Europe/Madrid
n=$(exact_count 'timedatectl set-timezone Europe/Madrid')
check "timezone --timezone flag honoured" "1" "$n"

reset_common
BOOTSTRAP_TIMEZONE="America/New_York"
run_bootstrap "n" "$SANDBOX/home-tz-4"
n=$(exact_count 'timedatectl set-timezone America/New_York')
check "timezone BOOTSTRAP_TIMEZONE env honoured" "1" "$n"

reset_common
run_bootstrap "n" "$SANDBOX/home-tz-5" --timezone Not/AZone
n=$(count '^timedatectl set-timezone')
check "timezone invalid zone -> no set-timezone call" "0" "$n"
contains "timezone invalid zone -> hint printed" "not a recognized zone" "$OUT"

# ==============================================================================
# sshd.
# ==============================================================================
echo
echo "sshd"

reset_common
run_bootstrap "n" "$SANDBOX/home-sshd-1"
n=$(exact_count 'systemctl enable --now ssh')
check "sshd not listening -> enable --now ssh" "1" "$n"

reset_common
echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*" >"$SS_OUTPUT_FILE"
run_bootstrap "n" "$SANDBOX/home-sshd-2"
n=$(count 'systemctl enable --now ssh')
check "sshd already listening -> no enable call" "0" "$n"
contains "sshd -> no hardening message" "Not hardening" "$OUT"

# ==============================================================================
# WSL: disk, zram, guest-agent and timezone skipped; others still run.
# ==============================================================================
echo
echo "WSL"

reset_common
BOOTSTRAP_PROC_VERSION_FILE="$PROC_WSL"
run_bootstrap "n" "$SANDBOX/home-wsl" --skip-brew
for step in disk zram panic guest-agent timezone; do
	contains "WSL -> $step skipped" "skip" "$OUT"
done
n=$(count '^lvextend \|^growpart /dev\|sudo install -m 644\|^sysctl -p\|^systemctl start qemu-guest-agent$\|^timedatectl set-timezone')
check "WSL -> no server-only mutating calls" "0" "$n"
n=$(count '^apt-get update$')
check "WSL -> apt still runs" "1" "$n"

# ==============================================================================
# brew.
# ==============================================================================
echo
echo "brew"

reset_common
printf 'SENTINEL-ZSHRC\n' >"$SANDBOX/home-brew-1-zshrc-src"
run_bootstrap "n" "$SANDBOX/home-brew-1" --skip-brew
n=$(count '^curl ')
check "--skip-brew -> no curl at all" "0" "$n"
contains "--skip-brew -> reported as skipped" "skip" "$OUT"

reset_common
HOME_BREW_MISSING="$SANDBOX/home-brew-missing"
mkdir -p "$HOME_BREW_MISSING"
printf 'SENTINEL-ZSHRC\n' >"$HOME_BREW_MISSING/.zshrc"
printf 'SENTINEL-BASHRC\n' >"$HOME_BREW_MISSING/.bashrc"
run_bootstrap "n" "$HOME_BREW_MISSING"
contains "brew missing -> installer downloaded and run NONINTERACTIVE=1" "NONINTERACTIVE=1" "$OUT"
check "brew missing -> .zshrc untouched" "SENTINEL-ZSHRC" "$(cat "$HOME_BREW_MISSING/.zshrc")"
check "brew missing -> .bashrc untouched" "SENTINEL-BASHRC" "$(cat "$HOME_BREW_MISSING/.bashrc")"

reset_common
mkdir -p "$LINUXBREW_PREFIX/bin"
cat >"$LINUXBREW_PREFIX/bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "shellenv() { :; }"
EOF
chmod +x "$LINUXBREW_PREFIX/bin/brew"
run_bootstrap "n" "$SANDBOX/home-brew-present"
n=$(count '^curl ')
check "brew present -> no curl at all" "0" "$n"

# ==============================================================================
# restore: default (no) -> no restorer curl; instructions printed.
# ==============================================================================
echo
echo "restore"

reset_common
mkdir -p "$LINUXBREW_PREFIX/bin"
touch "$LINUXBREW_PREFIX/bin/brew"
chmod +x "$LINUXBREW_PREFIX/bin/brew"
run_bootstrap "" "$SANDBOX/home-restore-default"
n=$(count 'raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer')
check "restore default (empty answer) -> no restorer download" "0" "$(grep -c 'curl -fsSL https://raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer' "$CMD_LOG" 2>/dev/null || true)"
contains "restore default -> GitHub user printed" "GitHub user: hlclarog" "$OUT"
contains "restore default -> repository printed" "repository: .dotfiles-linux" "$OUT"
contains "restore default -> package import reminder" "package import" "$OUT"
contains "restore default -> post-restore-secrets mentioned" "post-restore-secrets" "$OUT"
contains "restore default -> log out reminder" "log out" "$OUT"
contains "restore default -> restorer command printed" "bash <(curl -fsSL https://raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer)" "$OUT"

reset_common
mkdir -p "$LINUXBREW_PREFIX/bin"
touch "$LINUXBREW_PREFIX/bin/brew"
chmod +x "$LINUXBREW_PREFIX/bin/brew"
run_bootstrap "n
" "$SANDBOX/home-restore-explicit-no"
n=$(grep -c 'curl -fsSL https://raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer' "$CMD_LOG" 2>/dev/null || true)
check "restore explicit no -> no restorer download" "0" "$n"

# yes, without an existing ~/.dotfiles -> no --continue.
reset_common
mkdir -p "$LINUXBREW_PREFIX/bin"
touch "$LINUXBREW_PREFIX/bin/brew"
chmod +x "$LINUXBREW_PREFIX/bin/brew"
HOME_RESTORE_YES="$SANDBOX/home-restore-yes"
run_bootstrap "y
" "$HOME_RESTORE_YES"
n=$(grep -c 'curl -fsSL https://raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer -o' "$CMD_LOG" 2>/dev/null || true)
check "restore yes -> restorer downloaded" "1" "$n"
contains "restore yes, no ~/.dotfiles -> ran without --continue" "fake-download-ran" "$OUT"
not_contains "restore yes, no ~/.dotfiles -> --continue NOT passed" "args=--continue" "$OUT"

# yes, with an existing ~/.dotfiles -> --continue is added.
reset_common
mkdir -p "$LINUXBREW_PREFIX/bin"
touch "$LINUXBREW_PREFIX/bin/brew"
chmod +x "$LINUXBREW_PREFIX/bin/brew"
HOME_RESTORE_CONT="$SANDBOX/home-restore-continue"
mkdir -p "$HOME_RESTORE_CONT/.dotfiles/.git"
run_bootstrap "y
" "$HOME_RESTORE_CONT"
contains "restore yes, existing ~/.dotfiles -> --continue passed" "args=--continue" "$OUT"

# never runs in --check.
reset_common
run_bootstrap "y
" "$SANDBOX/home-restore-check" --check
n=$(count 'raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer')
check "restore -> never runs in --check" "0" "$n"
not_contains "restore -> no prompt text in --check" "Launch Dotly's restorer" "$OUT"

# ==============================================================================
# Self-containment: never reads/sources another repository file.
# ==============================================================================
echo
echo "self-containment"

script_body=$(cat "$SCRIPT")
source_hits=$(grep -cE '(^|[^[:alnum:]_])source[[:space:]]' "$SCRIPT" 2>/dev/null || true)
check "no 'source' of another file" "0" "$source_hits"
dot_hits=$(grep -cE '^[[:space:]]*\.[[:space:]]+[^.]' "$SCRIPT" 2>/dev/null || true)
check "no '. <file>' sourcing" "0" "$dot_hits"
not_contains "no DOTFILES_PATH reference" "DOTFILES_PATH" "$script_body"
not_contains "no restoration_scripts reference" "restoration_scripts" "$script_body"
not_contains "never clones the dotfiles repo" ".dotfiles-linux.git" "$script_body"

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
