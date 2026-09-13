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

# --- 2. ordering --------------------------------------------------------------
# herdr first, moshi last. If that order ever inverts, every agent herdr touches
# stays stale, because nothing runs afterwards to repair it.
state current missing
run "$SCRIPT_12"
for a in claude codex opencode pi; do
	check "converges $a after the herdr integrations stale it" "current" "$(get "$a")"
done

# --- 3. the daemon PATH -------------------------------------------------------
echo
echo "10-moshi-remote.sh"
if ! grep -qi microsoft /proc/version 2>/dev/null; then
	echo "  skip  daemon PATH cases (not WSL; the script returns early by design)"
else
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
fi

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
