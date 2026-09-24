#!/usr/bin/env bash
# Regression tests for problems that only show up on a genuinely fresh
# machine, found by running the official dotly `dot self install` restorer
# on a clean Ubuntu 24.04 VM.
#
# WHY THIS EXISTS
# ----------------
# Three failures survive `dot self install` silently on a fresh machine:
#
#   1. os/linux/brew/Brewfile: Homebrew 7 refuses to load ANY entry from an
#      untrusted third-party tap, and only trusts a FULLY QUALIFIED name
#      (tap/name), so a bare `cask "openai"` stays refused even with the tap
#      declared. `brew bundle install` then aborts on the first refused cask.
#
#   2. restoration_scripts/06-claude-statusline.sh (and, for the same reason,
#      11-codegraph.sh's Claude hook) does `[ -f "$claude_settings" ] ||
#      return 0`. On a fresh machine ~/.claude/settings.json does not exist
#      yet -- Claude Code only writes it on first launch, and script 12
#      creates one later in the restore -- so the statusline is never
#      configured.
#
#   3. restoration_scripts/11-codegraph.sh gates itself on `command -v
#      codegraph`, but nothing in the restore ever installs the npm shim the
#      wrapper needs, and `dot self install` runs every script in its own
#      subshell (`. "$script" | log::file ...`), so 08-node.sh's
#      `eval "$(fnm env)"` never carries to this script either. The result is
#      an install that always prints "run npm i -g @colbymchenry/codegraph"
#      and never runs it.
#
# Nothing here touches the real machine. Bug 1 is checked by parsing the
# Brewfile text offline -- no `brew` involved. Bugs 2 and 3 source the
# restoration scripts inside a disposable HOME with every mutating/network
# command (fnm) stubbed onto PATH; jq is the real one from PATH, since the
# scripts depend on its actual merge behaviour.
#
# THIS FILE IS NOT PART OF THE RESTORE. `dot self install` collects
# restoration scripts with `find -mindepth 1 -maxdepth 1`, so a subdirectory
# is never sourced. Run it by hand:
#
#     ./restoration_scripts/tests/fresh-machine-restore.sh
#
# Exits non-zero if any case fails.

set -u
DOTFILES_PATH="${DOTFILES_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
export DOTFILES_PATH
BREWFILE="$DOTFILES_PATH/os/linux/brew/Brewfile"
SCRIPT_06="$DOTFILES_PATH/restoration_scripts/06-claude-statusline.sh"
SCRIPT_11="$DOTFILES_PATH/restoration_scripts/11-codegraph.sh"

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

echo "fresh-machine restore regression tests"
echo

# ==============================================================================
# Bug 1 -- every tap-qualified Brewfile entry must be trusted and every
# declared tap must have at least one fully qualified entry.
# ==============================================================================
echo "os/linux/brew/Brewfile"

untrusted=$(grep -E '^(brew|cask) "[^"]+/[^"]+"' "$BREWFILE" | grep -v 'trusted: *true')
check "every tap-qualified brew/cask entry is trusted: true" "" "$untrusted"

unqualified_taps=""
while IFS= read -r tap_name; do
	[ -z "$tap_name" ] && continue
	if ! grep -qE "^(brew|cask) \"${tap_name}/" "$BREWFILE"; then
		unqualified_taps="$unqualified_taps $tap_name"
	fi
done < <(grep -oE '^tap "[^"]+"' "$BREWFILE" | sed -E 's/^tap "([^"]+)"$/\1/')
check "every declared tap has a fully qualified brew/cask entry" "" "$unqualified_taps"

# --- the sandbox --------------------------------------------------------------
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# ==============================================================================
# Bug 2 -- 06-claude-statusline.sh must not skip when settings.json is missing.
# ==============================================================================
echo
echo "06-claude-statusline.sh"

run06() { ( HOME="$1"; export HOME; . "$SCRIPT_06" ) 2>&1; }

# Case: missing settings.json -> created with the statusLine key.
HOME_A="$SANDBOX/home-a"
mkdir -p "$HOME_A"
run06 "$HOME_A" >/dev/null
expected_cmd="bash $HOME_A/.claude/statusline-command.sh"
actual_cmd=$(jq -r '.statusLine.command // ""' "$HOME_A/.claude/settings.json" 2>/dev/null)
actual_interval=$(jq -r '.statusLine.refreshInterval // 0' "$HOME_A/.claude/settings.json" 2>/dev/null)
check "missing settings.json is created with the statusline command" "$expected_cmd" "$actual_cmd"
check "missing settings.json is created with the refresh interval" "60" "$actual_interval"

# Case: existing file with other keys -> keys preserved, statusLine added, .bak kept.
HOME_B="$SANDBOX/home-b"
mkdir -p "$HOME_B/.claude"
cat >"$HOME_B/.claude/settings.json" <<'JSON'
{"model": "opus", "permissions": {"allow": ["Bash"]}}
JSON
run06 "$HOME_B" >/dev/null
model_kept=$(jq -r '.model' "$HOME_B/.claude/settings.json" 2>/dev/null)
perm_kept=$(jq -r '.permissions.allow[0]' "$HOME_B/.claude/settings.json" 2>/dev/null)
statusline_type=$(jq -r '.statusLine.type' "$HOME_B/.claude/settings.json" 2>/dev/null)
check "existing keys are preserved and statusLine is added" "opus|Bash|command" "$model_kept|$perm_kept|$statusline_type"
[ -f "$HOME_B/.claude/settings.json.bak" ] && bak_present=yes || bak_present=no
check "a .bak of the prior settings is kept" "yes" "$bak_present"

# Case: second run -> already configured, file byte-for-byte unchanged.
before_hash=$(sha256sum "$HOME_B/.claude/settings.json" | awk '{print $1}')
second_out=$(run06 "$HOME_B")
after_hash=$(sha256sum "$HOME_B/.claude/settings.json" | awk '{print $1}')
contains "second run reports already configured" "already configured" "$second_out"
check "second run leaves settings.json unchanged" "$before_hash" "$after_hash"

# ==============================================================================
# Bug 3 -- 11-codegraph.sh must install the npm shim through fnm instead of
# only checking `command -v codegraph`.
# ==============================================================================
echo
echo "11-codegraph.sh"

FNM_LOG="$SANDBOX/fnm.log"
export FNM_LOG
: >"$FNM_LOG"
mkdir -p "$SANDBOX/stub-fnm" "$SANDBOX/stub-nofnm"
cat >"$SANDBOX/stub-fnm/fnm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FNM_LOG"
if [ "$1" = exec ] && [ "$2" = "--using=default" ] && [ "$3" = npm ] &&
	[ "$4" = i ] && [ "$5" = -g ] && [ "$6" = "@colbymchenry/codegraph" ]; then
	mkdir -p "$(dirname "$FNM_SHIM")"
	printf '#!/usr/bin/env bash\necho fake-codegraph\n' >"$FNM_SHIM"
	chmod +x "$FNM_SHIM"
fi
STUB
chmod +x "$SANDBOX/stub-fnm/fnm"
ln -s "$(command -v jq)" "$SANDBOX/stub-nofnm/jq"

WITH_FNM_PATH="$SANDBOX/stub-fnm:$SANDBOX/stub-nofnm:/usr/bin:/bin"
NO_FNM_PATH="$SANDBOX/stub-nofnm:/usr/bin:/bin"

setup_wrapper() {
	mkdir -p "$1/.local/bin"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$1/.local/bin/codegraph"
	chmod +x "$1/.local/bin/codegraph"
}

run11() {
	(
		HOME="$1"
		PATH="$2"
		FNM_SHIM="$1/.local/share/fnm/aliases/default/bin/codegraph"
		export HOME PATH FNM_SHIM
		. "$SCRIPT_11"
	) >"$SANDBOX/out" 2>&1
	echo $?
}

# Case: wrapper present, shim absent -> fnm called exactly once with the
# exact install args, and the shim ends up executable.
HOME_C="$SANDBOX/home-c"
mkdir -p "$HOME_C"
setup_wrapper "$HOME_C"
: >"$FNM_LOG"
run11 "$HOME_C" "$WITH_FNM_PATH" >/dev/null
fnm_calls=$(wc -l <"$FNM_LOG" | tr -d ' ')
last_call=$(tail -n1 "$FNM_LOG")
check "wrapper present, shim absent: fnm is called exactly once" "1" "$fnm_calls"
check "wrapper present, shim absent: fnm gets the exact install args" \
	"exec --using=default npm i -g @colbymchenry/codegraph" "$last_call"
[ -x "$HOME_C/.local/share/fnm/aliases/default/bin/codegraph" ] && shim_ok=yes || shim_ok=no
check "wrapper present, shim absent: the shim ends up executable" "yes" "$shim_ok"

# Case: second run against the same HOME -> fnm is not called again.
: >"$FNM_LOG"
run11 "$HOME_C" "$WITH_FNM_PATH" >/dev/null
fnm_calls_2=$(wc -l <"$FNM_LOG" | tr -d ' ')
check "second run: fnm is not called once the shim already exists" "0" "$fnm_calls_2"

# Case: wrapper present, no fnm on PATH -> skip message, status 0, fnm untouched.
HOME_D="$SANDBOX/home-d"
mkdir -p "$HOME_D"
setup_wrapper "$HOME_D"
: >"$FNM_LOG"
status_d=$(run11 "$HOME_D" "$NO_FNM_PATH")
out_d=$(cat "$SANDBOX/out")
contains "wrapper present, no fnm: prints a skip message" "fnm is not on PATH" "$out_d"
check "wrapper present, no fnm: returns success" "0" "$status_d"
fnm_calls_3=$(wc -l <"$FNM_LOG" | tr -d ' ')
check "wrapper present, no fnm: fnm is never invoked" "0" "$fnm_calls_3"

# Case: wrapper absent -> symlink message, status 0, fnm untouched.
HOME_E="$SANDBOX/home-e"
mkdir -p "$HOME_E"
: >"$FNM_LOG"
status_e=$(run11 "$HOME_E" "$WITH_FNM_PATH")
out_e=$(cat "$SANDBOX/out")
contains "wrapper absent: prints a symlink message" "symlinks are not applied" "$out_e"
check "wrapper absent: returns success" "0" "$status_e"
fnm_calls_4=$(wc -l <"$FNM_LOG" | tr -d ' ')
check "wrapper absent: fnm is never invoked" "0" "$fnm_calls_4"

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
