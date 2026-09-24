#!/usr/bin/env bash
# Regression tests for problems that only show up on a genuinely fresh
# machine, found by running the official dotly `dot self install` restorer
# on a clean Ubuntu 24.04 VM.
#
# WHY THIS EXISTS
# ----------------
# Four failures survive `dot self install` silently on a fresh machine:
#
#   1. os/linux/brew/Brewfile: Homebrew 7 refuses to load ANY entry from an
#      untrusted third-party tap, and only trusts a FULLY QUALIFIED name
#      (tap/name), so a bare `cask "openai"` stays refused even with the tap
#      declared. `brew bundle install` then aborts on the first refused cask.
#
#   2. restoration_scripts/14-claude-statusline.sh (and, for the same reason,
#      11-codegraph.sh's Claude hook) does `[ -f "$claude_settings" ] ||
#      return 0`. On a fresh machine ~/.claude/settings.json does not exist
#      yet -- Claude Code only writes it on first launch, and script 12
#      creates one later in the restore -- so the statusline is never
#      configured.
#
#   3. restoration_scripts/11-codegraph.sh gates itself on `command -v
#      codegraph`, but nothing in the restore ever installs the npm shim the
#      wrapper needs, and `dot self install` runs every script in its own
#      subshell (`. "$script" | log::file ...`), so 07-node.sh's
#      `eval "$(fnm env)"` never carries to this script either. The result is
#      an install that always prints "run npm i -g @colbymchenry/codegraph"
#      and never runs it.
#
#   4. `dot self install` sources restoration_scripts/*.sh BEFORE the
#      restorer's own `dot package import` (modules/dotly/restorer), and that
#      import throws away all output and always reports success regardless of
#      the real exit status (`dot package import >/dev/null 2>&1 | _log
#      ...`). So scripts 14 (jq), 07 (fnm), 11 (codegraph, via fnm) and 13
#      (engram) used to run before their packages existed, and a failed
#      import looked identical to a working one. Homebrew 7.0.6 also aborts
#      `brew bundle install` entirely on the first untrusted cask even when
#      the Brewfile already marks it `trusted: true` --
#      Cask::CaskLoader.load raises before installer.rb ever applies the
#      Brewfile's trust options. restoration_scripts/04-brew-packages.sh
#      (sorting before 07/11/13/14) installs the Brewfile itself, pre-trusting
#      every entry first.
#
# Nothing here touches the real machine. Bug 1 is checked by parsing the
# Brewfile text offline -- no `brew` involved. Bugs 2 and 3 source the
# restoration scripts inside a disposable HOME with every mutating/network
# command (fnm) stubbed onto PATH; jq is the real one from PATH, since the
# scripts depend on its actual merge behaviour. Bug 4 stubs `brew` the same
# way: the stub records every argv line to a log file instead of touching
# the real Homebrew.
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
SCRIPT_00="$DOTFILES_PATH/restoration_scripts/00-default-shell.sh"
SCRIPT_04="$DOTFILES_PATH/restoration_scripts/04-brew-packages.sh"
SCRIPT_08="$DOTFILES_PATH/restoration_scripts/08-gentle-ai-sync.sh"
SCRIPT_11="$DOTFILES_PATH/restoration_scripts/11-codegraph.sh"
SCRIPT_14="$DOTFILES_PATH/restoration_scripts/14-claude-statusline.sh"

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
# Bug 2 -- 14-claude-statusline.sh must not skip when settings.json is missing.
# ==============================================================================
echo
echo "14-claude-statusline.sh"

run14() { ( HOME="$1"; export HOME; . "$SCRIPT_14" ) 2>&1; }

# Case: missing settings.json -> created with the statusLine key.
HOME_A="$SANDBOX/home-a"
mkdir -p "$HOME_A"
run14 "$HOME_A" >/dev/null
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
run14 "$HOME_B" >/dev/null
model_kept=$(jq -r '.model' "$HOME_B/.claude/settings.json" 2>/dev/null)
perm_kept=$(jq -r '.permissions.allow[0]' "$HOME_B/.claude/settings.json" 2>/dev/null)
statusline_type=$(jq -r '.statusLine.type' "$HOME_B/.claude/settings.json" 2>/dev/null)
check "existing keys are preserved and statusLine is added" "opus|Bash|command" "$model_kept|$perm_kept|$statusline_type"
[ -f "$HOME_B/.claude/settings.json.bak" ] && bak_present=yes || bak_present=no
check "a .bak of the prior settings is kept" "yes" "$bak_present"

# Case: second run -> already configured, file byte-for-byte unchanged.
before_hash=$(sha256sum "$HOME_B/.claude/settings.json" | awk '{print $1}')
second_out=$(run14 "$HOME_B")
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

# ==============================================================================
# Bug 4 -- 04-brew-packages.sh must install the Brewfile itself, pre-trusting
# every trusted entry, before scripts 06/08/11/13 need jq/fnm.
# ==============================================================================
echo
echo "04-brew-packages.sh"

BREW_LOG="$SANDBOX/brew.log"
export BREW_LOG
mkdir -p "$SANDBOX/stub-brew"
cat >"$SANDBOX/stub-brew/brew" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$BREW_LOG"
if [ "$1" = bundle ]; then
	exit "${BREW_BUNDLE_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$SANDBOX/stub-brew/brew"

WITH_BREW_PATH="$SANDBOX/stub-brew:/usr/bin:/bin"
NO_BREW_PATH="/usr/bin:/bin"

run04() {
	(
		HOME="$1"
		PATH="$2"
		BREW_CANDIDATES="${3-/no/such/brew-a /no/such/brew-b}"
		BREW_BUNDLE_EXIT="${4:-0}"
		export HOME PATH BREW_CANDIDATES BREW_BUNDLE_EXIT
		. "$SCRIPT_04"
	) >"$SANDBOX/out04" 2>&1
	echo $?
}

# Case: no brew on PATH and no fallback candidates present -> skip message,
# status 0, nothing recorded. BREW_CANDIDATES is a test-only override so this
# does not depend on the real /home/linuxbrew existing.
HOME_F="$SANDBOX/home-f"
mkdir -p "$HOME_F"
: >"$BREW_LOG"
status_f=$(run04 "$HOME_F" "$NO_BREW_PATH")
out_f=$(cat "$SANDBOX/out04")
contains "no brew: prints a skip message" "Homebrew is not installed" "$out_f"
check "no brew: returns success" "0" "$status_f"
calls_f=$(wc -l <"$BREW_LOG" | tr -d ' ')
check "no brew: brew is never invoked" "0" "$calls_f"

# Case: real repo Brewfile -> every declared tap tapped (including the
# gentleman-programming custom URL), every trusted: true entry trusted, and
# `bundle install` is the LAST call, after every trust call.
HOME_G="$SANDBOX/home-g"
mkdir -p "$HOME_G"
: >"$BREW_LOG"
status_g=$(run04 "$HOME_G" "$WITH_BREW_PATH")
check "real Brewfile: returns success" "0" "$status_g"

tap_calls=$(grep -E '^tap ' "$BREW_LOG")
contains "real Brewfile: taps anomalyco/tap" "tap anomalyco/tap" "$tap_calls"
contains "real Brewfile: taps openai/tools" "tap openai/tools" "$tap_calls"
contains "real Brewfile: taps the gentleman-programming custom URL" \
	"tap gentleman-programming/tap https://github.com/Gentleman-Programming/homebrew-tap" "$tap_calls"
contains "real Brewfile: taps denisidoro/tools" "tap denisidoro/tools" "$tap_calls"

trust_calls=$(grep -E '^trust ' "$BREW_LOG")
contains "real Brewfile: trusts the openai cask" "trust --cask openai/tools/openai" "$trust_calls"
for _formula in engram gentle-ai gga opencode gentleman-dots docpars; do
	contains "real Brewfile: trusts formula $_formula" "$_formula" "$trust_calls"
done
unset _formula

last_call=$(tail -n1 "$BREW_LOG")
check "real Brewfile: bundle install is the last brew call" \
	"bundle install --no-upgrade --file=$BREWFILE" "$last_call"

last_tap_line=$(grep -n '^tap ' "$BREW_LOG" | tail -n1 | cut -d: -f1)
first_trust_line=$(grep -n '^trust ' "$BREW_LOG" | head -n1 | cut -d: -f1)
[ "${last_tap_line:-0}" -lt "${first_trust_line:-999}" ] && tap_before_trust=yes || tap_before_trust=no
check "real Brewfile: every tap happens before any trust call" "yes" "$tap_before_trust"

contains "real Brewfile: reports success" "Brewfile packages installed" "$(cat "$SANDBOX/out04")"

# Case: bundle install fails -> failure message, status 0.
: >"$BREW_LOG"
status_h=$(run04 "$HOME_G" "$WITH_BREW_PATH" "" 1)
out_h=$(cat "$SANDBOX/out04")
contains "bundle failure: prints a failure message" "brew bundle install failed" "$out_h"
check "bundle failure: still returns success" "0" "$status_h"

# Case: Brewfile missing for the platform -> skip, status 0, brew untouched.
HOME_I="$SANDBOX/home-i"
mkdir -p "$HOME_I"
MISSING_DOTFILES="$SANDBOX/no-brewfile-dotfiles"
mkdir -p "$MISSING_DOTFILES/os/linux/brew"
: >"$BREW_LOG"
status_i=$(
	(
		HOME="$HOME_I"
		PATH="$WITH_BREW_PATH"
		DOTFILES_PATH="$MISSING_DOTFILES"
		export HOME PATH DOTFILES_PATH
		. "$SCRIPT_04"
	) >"$SANDBOX/out04" 2>&1
	echo $?
)
out_i=$(cat "$SANDBOX/out04")
contains "missing Brewfile: prints a skip message" "skipping" "$out_i"
check "missing Brewfile: returns success" "0" "$status_i"
# brew shellenv is expected here -- it runs right after locating brew, before
# the Brewfile is even checked -- but no tap/trust/bundle call should follow.
calls_i=$(grep -vc '^shellenv$' "$BREW_LOG")
check "missing Brewfile: no tap/trust/bundle call is made" "0" "$calls_i"

# ==============================================================================
# Bug 5 -- 00-default-shell.sh must fix the invoking user's login shell,
# since modules/dotly/scripts/self/install:34 runs `sudo chsh -s "$(command -v
# zsh)"` with no username and so only ever changes root's shell. It must also
# undo the side effect: a root shell left pointing at a user-owned Homebrew
# zsh prefix.
# ==============================================================================
echo
echo "00-default-shell.sh"

SUDO_LOG="$SANDBOX/sudo00.log"
GETENT_LOG="$SANDBOX/getent00.log"
export SUDO_LOG GETENT_LOG

mkdir -p "$SANDBOX/stub-00" "$SANDBOX/empty-bin"

cat >"$SANDBOX/stub-00/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$SUDO_LOG"
exec "$@"
STUB
chmod +x "$SANDBOX/stub-00/sudo"

cat >"$SANDBOX/stub-00/chsh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SANDBOX/stub-00/chsh"

cat >"$SANDBOX/stub-00/getent" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GETENT_LOG"
if [ "$2" = root ]; then
	printf 'root:x:0:0:root:/root:%s\n' "${ROOT_SHELL:-/bin/bash}"
else
	printf '%s:x:1000:1000:User,,,:/home/%s:%s\n' "$2" "$2" "${USER_SHELL:-/bin/bash}"
fi
STUB
chmod +x "$SANDBOX/stub-00/getent"

cat >"$SANDBOX/stub-00/tee" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -a ]; then
	cat >>"$2"
else
	cat >"$1"
fi
STUB
chmod +x "$SANDBOX/stub-00/tee"

printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/stub-00/zsh"
chmod +x "$SANDBOX/stub-00/zsh"

STUB_ZSH="$SANDBOX/stub-00/zsh"
WITH_STUB_PATH="$SANDBOX/stub-00:/usr/bin:/bin"
NO_ZSH_PATH="$SANDBOX/empty-bin"

run00() {
	(
		USER="$1"
		PATH="$2"
		SHELLS_FILE="$3"
		USER_SHELL="$4"
		ROOT_SHELL="$5"
		export USER PATH SHELLS_FILE USER_SHELL ROOT_SHELL
		. "$SCRIPT_00"
	) >"$SANDBOX/out00" 2>&1
	echo $?
}

# Case (a): the invoking user is on bash and root's shell is a Homebrew zsh
# -> chsh the user to the resolved zsh, then reset root to /bin/bash.
SHELLS_FILE_A="$SANDBOX/shells-a"
printf '/bin/sh\n/bin/bash\n%s\n' "$STUB_ZSH" >"$SHELLS_FILE_A"
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_a=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_A" /bin/bash /home/linuxbrew/.linuxbrew/bin/zsh)
out_a=$(cat "$SANDBOX/out00")
check "case a: returns success" "0" "$status_a"
expected_sudo_a="chsh -s $STUB_ZSH hclaro
chsh -s /bin/bash root"
check "case a: chsh for the user then chsh for root, in that order" "$expected_sudo_a" "$(cat "$SUDO_LOG")"
contains "case a: reports the user's new shell" "Login shell for hclaro set to $STUB_ZSH" "$out_a"

# Case (b): the invoking user is already on the resolved zsh and root is
# already bash -> no chsh calls at all.
SHELLS_FILE_B="$SANDBOX/shells-b"
printf '/bin/sh\n/bin/bash\n%s\n' "$STUB_ZSH" >"$SHELLS_FILE_B"
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_b=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_B" "$STUB_ZSH" /bin/bash)
out_b=$(cat "$SANDBOX/out00")
check "case b: returns success" "0" "$status_b"
check "case b: no chsh or tee calls" "" "$(cat "$SUDO_LOG")"
contains "case b: reports login shell already zsh" "Login shell already zsh" "$out_b"

# Case (c): the resolved zsh is missing from /etc/shells -> it is appended
# BEFORE chsh runs.
SHELLS_FILE_C="$SANDBOX/shells-c"
printf '/bin/sh\n/bin/bash\n' >"$SHELLS_FILE_C"
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_c=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_C" /bin/bash /bin/bash)
out_c=$(cat "$SANDBOX/out00")
check "case c: returns success" "0" "$status_c"
expected_sudo_c="tee -a $SHELLS_FILE_C
chsh -s $STUB_ZSH hclaro"
check "case c: appends to the shells file before chsh" "$expected_sudo_c" "$(cat "$SUDO_LOG")"
check "case c: the zsh path ends up in the shells file" "$STUB_ZSH" "$(tail -n1 "$SHELLS_FILE_C")"

# Case (d): no zsh on PATH at all -> skip message, status 0, nothing called.
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_d=$(run00 hclaro "$NO_ZSH_PATH" "$SANDBOX/shells-d" /bin/bash /bin/bash)
out_d=$(cat "$SANDBOX/out00")
contains "case d: prints a skip message" "zsh is not installed" "$out_d"
check "case d: returns success" "0" "$status_d"
check "case d: no sudo calls" "" "$(cat "$SUDO_LOG")"
check "case d: getent is never called" "" "$(cat "$GETENT_LOG")"

# Case (e): 00 must sort before 04 and be committed executable.
ordered_00=$(cd "$DOTFILES_PATH/restoration_scripts" && ls -- *.sh | sort | grep -E '^(00|04)-')
expected_order_00="00-default-shell.sh
04-brew-packages.sh"
check "case e: 00 sorts before 04-brew-packages.sh" "$expected_order_00" "$ordered_00"
[ -x "$SCRIPT_00" ] && script_00_exec=yes || script_00_exec=no
check "case e: 00-default-shell.sh is executable" "yes" "$script_00_exec"

# Case (f)/(g): macOS has no getent, so the login shell must come from dscl.
# Otherwise every `dot self install` on a Mac would prompt for sudo to chsh a
# user who is already on zsh. Root is never touched on Darwin.
mkdir -p "$SANDBOX/stub-00-mac"
printf '#!/usr/bin/env bash\necho Darwin\n' >"$SANDBOX/stub-00-mac/uname"
cat >"$SANDBOX/stub-00-mac/dscl" <<'STUB'
#!/usr/bin/env bash
echo "UserShell: ${USER_SHELL:-/bin/bash}"
STUB
chmod +x "$SANDBOX/stub-00-mac/uname" "$SANDBOX/stub-00-mac/dscl"
MAC_PATH="$SANDBOX/stub-00-mac:$SANDBOX/stub-00:/usr/bin:/bin"

: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_f=$(run00 hclaro "$MAC_PATH" "$SHELLS_FILE_B" "$STUB_ZSH" /bin/bash)
out_f=$(cat "$SANDBOX/out00")
check "case f: macOS, already zsh: returns success" "0" "$status_f"
check "case f: macOS, already zsh: no sudo calls" "" "$(cat "$SUDO_LOG")"
check "case f: macOS: getent is never called" "" "$(cat "$GETENT_LOG")"
contains "case f: macOS: reports login shell already zsh" "Login shell already zsh" "$out_f"

: >"$SUDO_LOG"
status_g=$(run00 hclaro "$MAC_PATH" "$SHELLS_FILE_B" /bin/bash /home/linuxbrew/.linuxbrew/bin/zsh)
check "case g: macOS, user on bash: returns success" "0" "$status_g"
check "case g: macOS, user on bash: chsh the user only, never root" \
	"chsh -s $STUB_ZSH hclaro" "$(cat "$SUDO_LOG")"

# ==============================================================================
# 08-gentle-ai-sync.sh -- nothing in the restore ever ran gentle-ai to turn the
# state 06-gentle-ai-state.sh seeds into the actual agent assets, and gentle-ai
# sync fails on opencode's cold first start (measured 97s bootstrap) unless
# something warms it up first.
# ==============================================================================
echo
echo "08-gentle-ai-sync.sh"

SYNC_LOG="$SANDBOX/gentle-ai-sync.log"
export SYNC_LOG
mkdir -p "$SANDBOX/stub-08"

cat >"$SANDBOX/stub-08/gentle-ai" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
exit "${GENTLE_AI_SYNC_EXIT:-0}"
STUB

cat >"$SANDBOX/stub-08/opencode" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
exit 0
STUB

cat >"$SANDBOX/stub-08/fnm" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
if [ "$1" = exec ] && [ "$2" = "--using=default" ]; then
	shift 2
	exec "$@"
fi
exit 0
STUB

cat >"$SANDBOX/stub-08/timeout" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
shift
exec "$@"
STUB

chmod +x "$SANDBOX/stub-08/gentle-ai" "$SANDBOX/stub-08/opencode" \
	"$SANDBOX/stub-08/fnm" "$SANDBOX/stub-08/timeout"

FULL_PATH_08="$SANDBOX/stub-08:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-08-no-opencode"
ln -s "$SANDBOX/stub-08/gentle-ai" "$SANDBOX/stub-08-no-opencode/gentle-ai"
ln -s "$SANDBOX/stub-08/fnm" "$SANDBOX/stub-08-no-opencode/fnm"
ln -s "$SANDBOX/stub-08/timeout" "$SANDBOX/stub-08-no-opencode/timeout"
NO_OPENCODE_PATH_08="$SANDBOX/stub-08-no-opencode:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-08-no-gentle-ai"
ln -s "$SANDBOX/stub-08/opencode" "$SANDBOX/stub-08-no-gentle-ai/opencode"
ln -s "$SANDBOX/stub-08/fnm" "$SANDBOX/stub-08-no-gentle-ai/fnm"
ln -s "$SANDBOX/stub-08/timeout" "$SANDBOX/stub-08-no-gentle-ai/timeout"
NO_GENTLE_AI_PATH_08="$SANDBOX/stub-08-no-gentle-ai:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-08-no-fnm"
ln -s "$SANDBOX/stub-08/gentle-ai" "$SANDBOX/stub-08-no-fnm/gentle-ai"
ln -s "$SANDBOX/stub-08/opencode" "$SANDBOX/stub-08-no-fnm/opencode"
NO_FNM_PATH_08="$SANDBOX/stub-08-no-fnm:/usr/bin:/bin"

run08() {
	(
		HOME="$1"
		PATH="$2"
		GENTLE_AI_SYNC_EXIT="${3:-0}"
		GENTLE_AI_CANDIDATES="${4-/no/such/gentle-ai-a /no/such/gentle-ai-b}"
		export HOME PATH GENTLE_AI_SYNC_EXIT GENTLE_AI_CANDIDATES SYNC_LOG
		. "$SCRIPT_08"
	) >"$SANDBOX/out08" 2>&1
	echo $?
}

# Case (a): everything present -> opencode is warmed up BEFORE the fnm exec
# gentle-ai sync call, with the exact args, and the sync succeeds.
HOME_J="$SANDBOX/home-j"
mkdir -p "$HOME_J/.gentle-ai"
: >"$HOME_J/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_j=$(run08 "$HOME_J" "$FULL_PATH_08")
out_j=$(cat "$SANDBOX/out08")
check "case a: returns success" "0" "$status_j"
contains "case a: reports the sync succeeded" "gentle-ai agent assets synced" "$out_j"
fnm_call=$(grep '^fnm ' "$SYNC_LOG")
check "case a: fnm gets the exact sync args" "fnm exec --using=default gentle-ai sync" "$fnm_call"
gentle_ai_call=$(grep '^gentle-ai ' "$SYNC_LOG")
check "case a: gentle-ai gets the exact sync args" "gentle-ai sync" "$gentle_ai_call"
warmup_line=$(grep -n '^timeout 300 opencode debug config$' "$SYNC_LOG" | head -n1 | cut -d: -f1)
sync_line=$(grep -n '^fnm exec --using=default gentle-ai sync$' "$SYNC_LOG" | head -n1 | cut -d: -f1)
if [ -n "$warmup_line" ] && [ -n "$sync_line" ] && [ "$warmup_line" -lt "$sync_line" ]; then
	order_ok=yes
else
	order_ok=no
fi
check "case a: opencode warm-up happens before the fnm exec gentle-ai sync call" "yes" "$order_ok"

# Case (b): no opencode on PATH -> no warm-up call, sync still runs.
HOME_K="$SANDBOX/home-k"
mkdir -p "$HOME_K/.gentle-ai"
: >"$HOME_K/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_k=$(run08 "$HOME_K" "$NO_OPENCODE_PATH_08")
out_k=$(cat "$SANDBOX/out08")
check "case b: returns success" "0" "$status_k"
warmup_calls_k=$(grep -c 'opencode debug config' "$SYNC_LOG")
check "case b: no opencode warm-up call is made" "0" "$warmup_calls_k"
contains "case b: sync still runs" "gentle-ai agent assets synced" "$out_k"

# Case (c): state.json missing -> skip, nothing on PATH is ever invoked.
HOME_L="$SANDBOX/home-l"
mkdir -p "$HOME_L"
: >"$SYNC_LOG"
status_l=$(run08 "$HOME_L" "$FULL_PATH_08")
out_l=$(cat "$SANDBOX/out08")
check "case c: returns success" "0" "$status_l"
contains "case c: prints a skip message" "No gentle-ai state restored" "$out_l"
calls_l=$(wc -l <"$SYNC_LOG" | tr -d ' ')
check "case c: nothing is invoked" "0" "$calls_l"

# Case (d): gentle-ai missing (and not found via the fallback candidates) ->
# skip, nothing is invoked.
HOME_M="$SANDBOX/home-m"
mkdir -p "$HOME_M/.gentle-ai"
: >"$HOME_M/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_m=$(run08 "$HOME_M" "$NO_GENTLE_AI_PATH_08")
out_m=$(cat "$SANDBOX/out08")
check "case d: returns success" "0" "$status_m"
contains "case d: prints a skip message" "gentle-ai is not installed" "$out_m"
calls_m=$(wc -l <"$SYNC_LOG" | tr -d ' ')
check "case d: nothing is invoked" "0" "$calls_m"

# Case (e): fnm missing -> skip message mentions 07-node.sh, nothing is invoked.
HOME_N="$SANDBOX/home-n"
mkdir -p "$HOME_N/.gentle-ai"
: >"$HOME_N/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_n=$(run08 "$HOME_N" "$NO_FNM_PATH_08")
out_n=$(cat "$SANDBOX/out08")
check "case e: returns success" "0" "$status_n"
contains "case e: skip message mentions 07-node.sh" "07-node.sh" "$out_n"
calls_n=$(wc -l <"$SYNC_LOG" | tr -d ' ')
check "case e: nothing is invoked" "0" "$calls_n"

# Case (f): sync fails -> failure message naming the rerun command, status 0.
HOME_O="$SANDBOX/home-o"
mkdir -p "$HOME_O/.gentle-ai"
: >"$HOME_O/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_o=$(run08 "$HOME_O" "$FULL_PATH_08" 3)
out_o=$(cat "$SANDBOX/out08")
check "case f: still returns success" "0" "$status_o"
contains "case f: prints a failure message" "gentle-ai sync failed" "$out_o"
contains "case f: failure message names the rerun command" \
	"fnm exec --using=default gentle-ai sync" "$out_o"

# ==============================================================================
# Case (g) / ordering -- 04-brew-packages.sh must sort before 06-gentle-ai-
# state.sh, 07-node.sh, 08-gentle-ai-sync.sh, 11-codegraph.sh,
# 12-agent-integrations.sh and 14-claude-statusline.sh, all must be committed
# executable, and the renamed scripts' old names must be gone.
# ==============================================================================
echo
echo "restoration_scripts ordering"

ordered=$(cd "$DOTFILES_PATH/restoration_scripts" && ls -- *.sh | sort | grep -E '^(04|06|07|08|11|12|14)-')
expected_order="04-brew-packages.sh
06-gentle-ai-state.sh
07-node.sh
08-gentle-ai-sync.sh
11-codegraph.sh
12-agent-integrations.sh
14-claude-statusline.sh"
check "04 sorts before 06, 07, 08, 11, 12 and 14" "$expected_order" "$ordered"
[ -x "$SCRIPT_04" ] && script_04_exec=yes || script_04_exec=no
check "04-brew-packages.sh is executable" "yes" "$script_04_exec"
[ -x "$SCRIPT_08" ] && script_08_exec=yes || script_08_exec=no
check "08-gentle-ai-sync.sh is executable" "yes" "$script_08_exec"

for _old_name in 06-claude-statusline.sh 07-gentle-ai-state.sh 08-node.sh; do
	[ -e "$DOTFILES_PATH/restoration_scripts/$_old_name" ] && old_present=yes || old_present=no
	check "$_old_name no longer exists" "no" "$old_present"
done
unset _old_name old_present

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
