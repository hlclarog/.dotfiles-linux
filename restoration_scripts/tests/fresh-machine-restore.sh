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
SCRIPT_04="$DOTFILES_PATH/restoration_scripts/04-brew-packages.sh"
SCRIPT_04_CLAUDE="$DOTFILES_PATH/restoration_scripts/04-claude-code.sh"
SCRIPT_17="$DOTFILES_PATH/restoration_scripts/17-default-shell.sh"
SCRIPT_08="$DOTFILES_PATH/restoration_scripts/08-pi.sh"
SCRIPT_09="$DOTFILES_PATH/restoration_scripts/09-gentle-ai-sync.sh"
SCRIPT_11="$DOTFILES_PATH/restoration_scripts/11-codegraph.sh"
SCRIPT_12="$DOTFILES_PATH/restoration_scripts/12-agent-integrations.sh"
SCRIPT_14="$DOTFILES_PATH/restoration_scripts/14-claude-statusline.sh"
SCRIPT_15="$DOTFILES_PATH/restoration_scripts/15-rust.sh"
SCRIPT_16="$DOTFILES_PATH/restoration_scripts/16-tailscale.sh"

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

[ -n "$(grep -F 'brew "shellcheck"' "$BREWFILE")" ] && shellcheck_declared=yes || shellcheck_declared=no
check "shellcheck is declared in the Brewfile" "yes" "$shellcheck_declared"

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
# Fix 1 -- 11-codegraph.sh must register the codegraph MCP server in a fresh
# opencode.json when gentle-ai only wrote opencode.jsonc (JSON with comments,
# which jq cannot parse), merging rather than replacing it.
# ==============================================================================
echo
echo "11-codegraph.sh -- opencode MCP registration"

setup_wrapper_and_shim() {
	setup_wrapper "$1"
	mkdir -p "$1/.local/share/fnm/aliases/default/bin"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$1/.local/share/fnm/aliases/default/bin/codegraph"
	chmod +x "$1/.local/share/fnm/aliases/default/bin/codegraph"
}

expected_opencode_json=$(jq -S -n '{"$schema":"https://opencode.ai/config.json","mcp":{"codegraph":{"type":"local","command":["codegraph","serve","--mcp"],"enabled":true}}}')

# Case: only opencode.jsonc present -> opencode.json is created with exactly
# the codegraph MCP entry, and the .jsonc is left byte-identical.
HOME_OC1="$SANDBOX/home-oc1"
mkdir -p "$HOME_OC1/.config/opencode"
setup_wrapper_and_shim "$HOME_OC1"
printf '{\n  // a comment jq cannot parse\n  "theme": "dark"\n}\n' >"$HOME_OC1/.config/opencode/opencode.jsonc"
jsonc_before=$(sha256sum "$HOME_OC1/.config/opencode/opencode.jsonc" | awk '{print $1}')
status_oc1=$(run11 "$HOME_OC1" "$NO_FNM_PATH")
out_oc1=$(cat "$SANDBOX/out")
check "only .jsonc present: returns success" "0" "$status_oc1"
contains "only .jsonc present: reports opencode.json created, merged with jsonc" \
	"opencode MCP server registered (new opencode.json, merged with gentle-ai's opencode.jsonc)" "$out_oc1"
opencode_json_content=$(jq -S '.' "$HOME_OC1/.config/opencode/opencode.json" 2>/dev/null)
check "only .jsonc present: opencode.json has exactly the expected content" \
	"$expected_opencode_json" "$opencode_json_content"
jsonc_after=$(sha256sum "$HOME_OC1/.config/opencode/opencode.jsonc" | awk '{print $1}')
check "only .jsonc present: opencode.jsonc is left byte-identical" "$jsonc_before" "$jsonc_after"

# Case: rerun -> already registers, file unchanged.
json_before_oc1=$(sha256sum "$HOME_OC1/.config/opencode/opencode.json" | awk '{print $1}')
status_oc1b=$(run11 "$HOME_OC1" "$NO_FNM_PATH")
out_oc1b=$(cat "$SANDBOX/out")
check "rerun: returns success" "0" "$status_oc1b"
contains "rerun: reports already registers" "opencode already registers the codegraph MCP server" "$out_oc1b"
json_after_oc1=$(sha256sum "$HOME_OC1/.config/opencode/opencode.json" | awk '{print $1}')
check "rerun: opencode.json unchanged" "$json_before_oc1" "$json_after_oc1"

# Case: existing opencode.json without codegraph -> key added, other keys
# preserved (existing behaviour).
HOME_OC2="$SANDBOX/home-oc2"
mkdir -p "$HOME_OC2/.config/opencode"
setup_wrapper_and_shim "$HOME_OC2"
printf '{"theme": "light", "mcp": {"context7": {"type": "local", "command": ["context7"], "enabled": true}}}' \
	>"$HOME_OC2/.config/opencode/opencode.json"
status_oc2=$(run11 "$HOME_OC2" "$NO_FNM_PATH")
check "existing opencode.json: returns success" "0" "$status_oc2"
theme_kept=$(jq -r '.theme' "$HOME_OC2/.config/opencode/opencode.json")
context7_kept=$(jq -r '.mcp.context7.type' "$HOME_OC2/.config/opencode/opencode.json")
jq -e '.mcp.codegraph' "$HOME_OC2/.config/opencode/opencode.json" >/dev/null 2>&1 && codegraph_added=yes || codegraph_added=no
check "existing opencode.json: other keys preserved, codegraph key added" \
	"light|local|yes" "$theme_kept|$context7_kept|$codegraph_added"

# Case: no ~/.config/opencode at all -> nothing created.
HOME_OC3="$SANDBOX/home-oc3"
mkdir -p "$HOME_OC3"
setup_wrapper_and_shim "$HOME_OC3"
status_oc3=$(run11 "$HOME_OC3" "$NO_FNM_PATH")
check "no opencode dir: returns success" "0" "$status_oc3"
[ -e "$HOME_OC3/.config/opencode" ] && opencode_dir_created=yes || opencode_dir_created=no
check "no opencode dir: nothing is created" "no" "$opencode_dir_created"

# ==============================================================================
# Fix 2 -- 12-agent-integrations.sh must install Codex's engram plugin,
# independently of herdr, before the herdr-gated section of the script.
# ==============================================================================
echo
echo "12-agent-integrations.sh -- Codex engram plugin"

CODEX_LOG="$SANDBOX/codex12.log"
export CODEX_LOG
mkdir -p "$SANDBOX/stub-12" "$SANDBOX/stub-12-nocodex"

cat >"$SANDBOX/stub-12/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex $*" >>"$CODEX_LOG"
if [ "$1" = plugin ] && [ "$2" = marketplace ] && [ "$3" = add ]; then
	if [ "${CODEX_MARKETPLACE_EXIT:-0}" != 0 ]; then
		exit "$CODEX_MARKETPLACE_EXIT"
	fi
	printf '\n[marketplaces.engram]\nsource_type = "git"\nsource = "https://github.com/Gentleman-Programming/engram.git"\n' >>"$HOME/.codex/config.toml"
	exit 0
fi
if [ "$1" = plugin ] && [ "$2" = add ]; then
	printf '\n[plugins."engram@engram"]\nenabled = true\n' >>"$HOME/.codex/config.toml"
	exit 0
fi
exit 0
STUB
chmod +x "$SANDBOX/stub-12/codex"

cat >"$SANDBOX/stub-12/timeout" <<'STUB'
#!/usr/bin/env bash
echo "timeout $*" >>"$CODEX_LOG"
shift
exec "$@"
STUB
chmod +x "$SANDBOX/stub-12/timeout"
ln -s "$SANDBOX/stub-12/timeout" "$SANDBOX/stub-12-nocodex/timeout"

WITH_CODEX_PATH="$SANDBOX/stub-12:/usr/bin:/bin"
NO_CODEX_PATH="$SANDBOX/stub-12-nocodex:/usr/bin:/bin"

run12() {
	(
		HOME="$1"
		PATH="$2"
		CODEX_MARKETPLACE_EXIT="${3:-0}"
		export HOME PATH CODEX_MARKETPLACE_EXIT CODEX_LOG
		. "$SCRIPT_12"
	) >"$SANDBOX/out12" 2>&1
	echo $?
}

# Case e: fresh config.toml -> both commands, in that order, exact args.
HOME_CX1="$SANDBOX/home-cx1"
mkdir -p "$HOME_CX1/.codex"
: >"$HOME_CX1/.codex/config.toml"
: >"$CODEX_LOG"
status_cx1=$(run12 "$HOME_CX1" "$WITH_CODEX_PATH")
out_cx1=$(cat "$SANDBOX/out12")
check "case e: returns success" "0" "$status_cx1"
codex_calls_cx1=$(grep '^codex ' "$CODEX_LOG")
expected_calls_cx1="codex plugin marketplace add https://github.com/Gentleman-Programming/engram.git
codex plugin add engram@engram"
check "case e: codex gets marketplace add then plugin add, in that order" \
	"$expected_calls_cx1" "$codex_calls_cx1"
timeout_calls_cx1=$(grep -c '^timeout 120 codex ' "$CODEX_LOG")
check "case e: both calls go through timeout 120" "2" "$timeout_calls_cx1"
contains "case e: reports the plugin installed" "Codex engram plugin installed" "$out_cx1"

# Case f: marketplace present but plugin absent -> only plugin add runs.
HOME_CX2="$SANDBOX/home-cx2"
mkdir -p "$HOME_CX2/.codex"
printf '[marketplaces.engram]\nsource_type = "git"\nsource = "https://github.com/Gentleman-Programming/engram.git"\n' \
	>"$HOME_CX2/.codex/config.toml"
: >"$CODEX_LOG"
status_cx2=$(run12 "$HOME_CX2" "$WITH_CODEX_PATH")
check "case f: returns success" "0" "$status_cx2"
codex_calls_cx2=$(grep '^codex ' "$CODEX_LOG")
check "case f: only plugin add runs" "codex plugin add engram@engram" "$codex_calls_cx2"

# Case g: plugin already present -> no codex plugin calls at all.
HOME_CX3="$SANDBOX/home-cx3"
mkdir -p "$HOME_CX3/.codex"
printf '[plugins."engram@engram"]\nenabled = true\n' >"$HOME_CX3/.codex/config.toml"
: >"$CODEX_LOG"
status_cx3=$(run12 "$HOME_CX3" "$WITH_CODEX_PATH")
out_cx3=$(cat "$SANDBOX/out12")
check "case g: returns success" "0" "$status_cx3"
codex_calls_cx3=$(wc -l <"$CODEX_LOG" | tr -d ' ')
check "case g: no codex calls at all" "0" "$codex_calls_cx3"
contains "case g: reports already installed" "Codex engram plugin already installed" "$out_cx3"

# Case h1: codex missing -> nothing invoked.
HOME_CX4="$SANDBOX/home-cx4"
mkdir -p "$HOME_CX4/.codex"
: >"$HOME_CX4/.codex/config.toml"
: >"$CODEX_LOG"
status_cx4=$(run12 "$HOME_CX4" "$NO_CODEX_PATH")
check "case h1: codex missing: returns success" "0" "$status_cx4"
calls_cx4=$(wc -l <"$CODEX_LOG" | tr -d ' ')
check "case h1: codex missing: nothing is invoked" "0" "$calls_cx4"

# Case h2: config.toml missing -> nothing invoked.
HOME_CX5="$SANDBOX/home-cx5"
mkdir -p "$HOME_CX5"
: >"$CODEX_LOG"
status_cx5=$(run12 "$HOME_CX5" "$WITH_CODEX_PATH")
check "case h2: config.toml missing: returns success" "0" "$status_cx5"
calls_cx5=$(wc -l <"$CODEX_LOG" | tr -d ' ')
check "case h2: config.toml missing: nothing is invoked" "0" "$calls_cx5"

# Case i: marketplace add fails -> failure hint, no plugin add, script still
# returns 0 and the rest of its output is intact.
HOME_CX6="$SANDBOX/home-cx6"
mkdir -p "$HOME_CX6/.codex"
: >"$HOME_CX6/.codex/config.toml"
: >"$CODEX_LOG"
status_cx6=$(run12 "$HOME_CX6" "$WITH_CODEX_PATH" 1)
out_cx6=$(cat "$SANDBOX/out12")
check "case i: still returns success" "0" "$status_cx6"
contains "case i: prints the failure hint" \
	"Codex engram plugin install failed; rerun: codex plugin marketplace add https://github.com/Gentleman-Programming/engram.git && codex plugin add engram@engram" \
	"$out_cx6"
codex_calls_cx6=$(grep '^codex ' "$CODEX_LOG")
check "case i: only the marketplace add call is made" \
	"codex plugin marketplace add https://github.com/Gentleman-Programming/engram.git" "$codex_calls_cx6"
contains "case i: the rest of the script's output is intact" "herdr is not installed" "$out_cx6"

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
# Bug 5 -- 17-default-shell.sh must fix the invoking user's login shell,
# since modules/dotly/scripts/self/install:34 runs `sudo chsh -s "$(command -v
# zsh)"` with no username and so only ever changes root's shell. It must also
# undo the side effect: a root shell left pointing at zsh (typically a
# user-owned Homebrew prefix).
#
# This script sorts LAST (17-), after 04-brew-packages.sh installs Homebrew's
# zsh, so it can prefer a Homebrew zsh from ZSH_CANDIDATES over whatever
# `command -v zsh` finds first, and it treats the shell as already correct
# only when it exactly matches that preferred path.
# ==============================================================================
echo
echo "17-default-shell.sh"

SUDO_LOG="$SANDBOX/sudo00.log"
GETENT_LOG="$SANDBOX/getent00.log"
export SUDO_LOG GETENT_LOG

mkdir -p "$SANDBOX/stub-00" "$SANDBOX/empty-bin" "$SANDBOX/stub-00-brew"

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

# The fallback zsh found via `command -v zsh` on PATH (e.g. /usr/bin/zsh).
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/stub-00/zsh"
chmod +x "$SANDBOX/stub-00/zsh"

# A Homebrew zsh listed in ZSH_CANDIDATES, never found via a PATH lookup.
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/stub-00-brew/zsh"
chmod +x "$SANDBOX/stub-00-brew/zsh"

STUB_ZSH="$SANDBOX/stub-00/zsh"
BREW_ZSH="$SANDBOX/stub-00-brew/zsh"
NO_BREW_ZSH="$SANDBOX/empty-bin/zsh"
WITH_STUB_PATH="$SANDBOX/stub-00:/usr/bin:/bin"
NO_ZSH_PATH="$SANDBOX/empty-bin"

run00() {
	(
		USER="$1"
		PATH="$2"
		SHELLS_FILE="$3"
		USER_SHELL="$4"
		ROOT_SHELL="$5"
		ZSH_CANDIDATES="$6"
		export USER PATH SHELLS_FILE USER_SHELL ROOT_SHELL ZSH_CANDIDATES
		. "$SCRIPT_17"
	) >"$SANDBOX/out00" 2>&1
	echo $?
}

# Case (a): user is on the PATH zsh and a Homebrew zsh candidate exists ->
# chsh to the Homebrew zsh, not the PATH one.
SHELLS_FILE_A="$SANDBOX/shells-a"
printf '/bin/sh\n/bin/bash\n%s\n%s\n' "$STUB_ZSH" "$BREW_ZSH" >"$SHELLS_FILE_A"
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_a=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_A" "$STUB_ZSH" /bin/bash "$BREW_ZSH")
out_a=$(cat "$SANDBOX/out00")
check "case a: returns success" "0" "$status_a"
check "case a: chshes the user to the Homebrew zsh, not the PATH one" "chsh -s $BREW_ZSH hclaro" "$(cat "$SUDO_LOG")"
contains "case a: reports the user's new shell" "Login shell for hclaro set to $BREW_ZSH" "$out_a"

# Case (b): user is already on the Homebrew zsh -> already, no chsh.
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_b=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_A" "$BREW_ZSH" /bin/bash "$BREW_ZSH")
out_b=$(cat "$SANDBOX/out00")
check "case b: returns success" "0" "$status_b"
check "case b: no chsh calls" "" "$(cat "$SUDO_LOG")"
contains "case b: reports login shell already zsh" "Login shell already zsh" "$out_b"

# Case (c): no Homebrew zsh candidate exists -> falls back to `command -v
# zsh`, and a user already on that fallback zsh is left alone.
SHELLS_FILE_C="$SANDBOX/shells-c"
printf '/bin/sh\n/bin/bash\n%s\n' "$STUB_ZSH" >"$SHELLS_FILE_C"
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_c=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_C" "$STUB_ZSH" /bin/bash "$NO_BREW_ZSH")
out_c=$(cat "$SANDBOX/out00")
check "case c: returns success" "0" "$status_c"
check "case c: no chsh calls" "" "$(cat "$SUDO_LOG")"
contains "case c: reports login shell already zsh" "Login shell already zsh" "$out_c"

# Case (d): the resolved zsh is missing from /etc/shells -> it is appended
# BEFORE chsh runs.
SHELLS_FILE_D="$SANDBOX/shells-d"
printf '/bin/sh\n/bin/bash\n' >"$SHELLS_FILE_D"
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_d=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_D" /bin/bash /bin/bash "$NO_BREW_ZSH")
out_d=$(cat "$SANDBOX/out00")
check "case d: returns success" "0" "$status_d"
expected_sudo_d="tee -a $SHELLS_FILE_D
chsh -s $STUB_ZSH hclaro"
check "case d: appends to the shells file before chsh" "$expected_sudo_d" "$(cat "$SUDO_LOG")"
check "case d: the zsh path ends up in the shells file" "$STUB_ZSH" "$(tail -n1 "$SHELLS_FILE_D")"

# Case (e): no zsh anywhere -> skip message, status 0, nothing called.
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_e=$(run00 hclaro "$NO_ZSH_PATH" "$SANDBOX/shells-e" /bin/bash /bin/bash "$NO_BREW_ZSH")
out_e=$(cat "$SANDBOX/out00")
contains "case e: prints a skip message" "zsh is not installed" "$out_e"
check "case e: returns success" "0" "$status_e"
check "case e: no sudo calls" "" "$(cat "$SUDO_LOG")"
check "case e: getent is never called" "" "$(cat "$GETENT_LOG")"

# Case (f): root is on a plain zsh, not under any Homebrew prefix -> reset to
# /bin/bash anyway, since ANY zsh on root is the same Dotly bug.
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_f=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_A" "$BREW_ZSH" /usr/bin/zsh "$BREW_ZSH")
out_f=$(cat "$SANDBOX/out00")
check "case f: returns success" "0" "$status_f"
check "case f: resets root from a non-Homebrew zsh to /bin/bash" "chsh -s /bin/bash root" "$(cat "$SUDO_LOG")"

# Case (g): root is already /bin/bash -> left untouched.
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_g=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_A" "$BREW_ZSH" /bin/bash "$BREW_ZSH")
out_g=$(cat "$SANDBOX/out00")
check "case g: returns success" "0" "$status_g"
check "case g: root's bash shell is left untouched" "" "$(cat "$SUDO_LOG")"

# Case (h): root is under a Homebrew prefix -> reset to /bin/bash (existing).
: >"$SUDO_LOG"
: >"$GETENT_LOG"
status_h=$(run00 hclaro "$WITH_STUB_PATH" "$SHELLS_FILE_A" "$BREW_ZSH" /home/linuxbrew/.linuxbrew/bin/zsh "$BREW_ZSH")
out_h=$(cat "$SANDBOX/out00")
check "case h: returns success" "0" "$status_h"
check "case h: resets root from a Homebrew prefix to /bin/bash" "chsh -s /bin/bash root" "$(cat "$SUDO_LOG")"

# Case (i): 17 must sort after 04 and be committed executable; 00 must be gone.
ordered_17=$(cd "$DOTFILES_PATH/restoration_scripts" && ls -- *.sh | sort | grep -E '^(04|17)-')
expected_order_17="04-brew-packages.sh
04-claude-code.sh
17-default-shell.sh"
check "case i: 17 sorts after 04-brew-packages.sh" "$expected_order_17" "$ordered_17"
[ -x "$SCRIPT_17" ] && script_17_exec=yes || script_17_exec=no
check "case i: 17-default-shell.sh is executable" "yes" "$script_17_exec"
[ -e "$DOTFILES_PATH/restoration_scripts/00-default-shell.sh" ] && script_00_present=yes || script_00_present=no
check "case i: 00-default-shell.sh is absent" "no" "$script_00_present"

# Case (j)/(k): macOS has no getent, so the login shell must come from dscl.
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
status_j=$(run00 hclaro "$MAC_PATH" "$SHELLS_FILE_A" "$BREW_ZSH" /bin/bash "$BREW_ZSH")
out_j=$(cat "$SANDBOX/out00")
check "case j: macOS, already zsh: returns success" "0" "$status_j"
check "case j: macOS, already zsh: no sudo calls" "" "$(cat "$SUDO_LOG")"
check "case j: macOS: getent is never called" "" "$(cat "$GETENT_LOG")"
contains "case j: macOS: reports login shell already zsh" "Login shell already zsh" "$out_j"

: >"$SUDO_LOG"
status_k=$(run00 hclaro "$MAC_PATH" "$SHELLS_FILE_A" /bin/bash /home/linuxbrew/.linuxbrew/bin/zsh "$BREW_ZSH")
check "case k: macOS, user on bash: returns success" "0" "$status_k"
check "case k: macOS, user on bash: chsh the user only, never root" \
	"chsh -s $BREW_ZSH hclaro" "$(cat "$SUDO_LOG")"

# ==============================================================================
# Bug 6 -- Dotly's restoration loop (modules/dotly/scripts/self/install:46-52)
# feeds the list of remaining restoration script names to its `while read`
# loop on stdin. Any restoration script that reads stdin itself (brew bundle
# and its cask/formula installers, apt, npm install, etc.) swallows the rest
# of that list, so every later script is silently skipped -- and the loop's
# own error handling never fires, because `read` just hits EOF instead of
# failing. Measured on a fresh Ubuntu VM: during 04-brew-packages.sh, `brew
# bundle` read stdin and scripts 05..17 never ran; `dot self install` still
# printed "dotfiles restored". Every restoration_scripts/*.sh must
# `exec </dev/null` right after its header, before any other command, so it
# can no longer consume that shared stdin.
# ==============================================================================
echo
echo "exec </dev/null guard"

for _guard_script in "$DOTFILES_PATH"/restoration_scripts/*.sh; do
	_guard_name=$(basename "$_guard_script")
	_guard_first_line=$(awk '
		/^#!/ { next }
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{ print; exit }
	' "$_guard_script")
	check "$_guard_name: first real line is exec </dev/null" "exec </dev/null" "$_guard_first_line"
done
unset _guard_script _guard_name _guard_first_line

echo
echo "Dotly restoration loop -- stdin reproduction"

# Reproduces modules/dotly/scripts/self/install:46-52 exactly, with
# log::file replaced by `cat >/dev/null` and output::error replaced by echo.
dotly_loop() {
	find "$1" -mindepth 1 -maxdepth 1 -type l,f -name '*.sh' | sort |
		while read -r install_script; do
			{ [[ -x $install_script ]] && . "$install_script" | cat >/dev/null; } || echo "loop error: $install_script"
		done
}

LOOP_DIR="$SANDBOX/loop-repro"
mkdir -p "$LOOP_DIR"
LOOP_LOG="$SANDBOX/loop.log"
export LOOP_LOG

cat >"$LOOP_DIR/01-a.sh" <<'EOF'
#!/usr/bin/env bash
echo 01 >>"$LOOP_LOG"
EOF
cat >"$LOOP_DIR/03-c.sh" <<'EOF'
#!/usr/bin/env bash
echo 03 >>"$LOOP_LOG"
EOF
chmod +x "$LOOP_DIR/01-a.sh" "$LOOP_DIR/03-c.sh"

# 02-reader.sh WITHOUT the guard -- reads stdin like brew bundle would,
# swallowing the rest of the script list.
cat >"$LOOP_DIR/02-reader.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 02 >>"$LOOP_LOG"
EOF
chmod +x "$LOOP_DIR/02-reader.sh"

: >"$LOOP_LOG"
dotly_loop "$LOOP_DIR"
log_without_guard=$(cat "$LOOP_LOG")
contains "without exec </dev/null: 01 runs" "01" "$log_without_guard"
contains "without exec </dev/null: 02 runs" "02" "$log_without_guard"
case "$log_without_guard" in
*03*) reproduces_bug=no ;;
*) reproduces_bug=yes ;;
esac
check "without exec </dev/null: 03 is swallowed (reproduces the bug)" "yes" "$reproduces_bug"

# 02-reader.sh WITH the guard -- exec </dev/null before it reads stdin.
cat >"$LOOP_DIR/02-reader.sh" <<'EOF'
#!/usr/bin/env bash
exec </dev/null
cat >/dev/null
echo 02 >>"$LOOP_LOG"
EOF
chmod +x "$LOOP_DIR/02-reader.sh"

: >"$LOOP_LOG"
dotly_loop "$LOOP_DIR"
log_with_guard=$(cat "$LOOP_LOG")
contains "with exec </dev/null: 01 runs" "01" "$log_with_guard"
contains "with exec </dev/null: 02 runs" "02" "$log_with_guard"
contains "with exec </dev/null: 03 runs (bug fixed)" "03" "$log_with_guard"

echo
echo "04-brew-packages.sh via the real Dotly loop"

LOOP04_DIR="$SANDBOX/loop-04"
mkdir -p "$LOOP04_DIR"
ln -s "$SCRIPT_04" "$LOOP04_DIR/04-brew-packages.sh"
cat >"$LOOP04_DIR/05-marker.sh" <<'EOF'
#!/usr/bin/env bash
echo marker >>"$LOOP_LOG"
EOF
chmod +x "$LOOP04_DIR/05-marker.sh"

mkdir -p "$SANDBOX/stub-brew-stdin"
cat >"$SANDBOX/stub-brew-stdin/brew" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "$*" >>"$BREW_LOG"
if [ "$1" = bundle ]; then
	exit "${BREW_BUNDLE_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$SANDBOX/stub-brew-stdin/brew"

HOME_LOOP04="$SANDBOX/home-loop04"
mkdir -p "$HOME_LOOP04"
: >"$LOOP_LOG"
: >"$BREW_LOG"
(
	HOME="$HOME_LOOP04"
	PATH="$SANDBOX/stub-brew-stdin:/usr/bin:/bin"
	export HOME PATH LOOP_LOG BREW_LOG
	dotly_loop "$LOOP04_DIR"
) >"$SANDBOX/out-loop04" 2>&1
log_loop04=$(cat "$LOOP_LOG")
contains "real 04-brew-packages.sh via the loop: the marker script after it still runs" "marker" "$log_loop04"

# ==============================================================================
# 04-claude-code.sh -- installs Claude Code from Anthropic's native installer
# instead of the lagging Homebrew cask, and retires that cask once the
# native binary works.
# ==============================================================================
echo
echo "04-claude-code.sh"

CLAUDE_LOG="$SANDBOX/claude-install.log"
export CLAUDE_LOG
mkdir -p "$SANDBOX/stub04claude"

cat >"$SANDBOX/stub04claude/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$CLAUDE_LOG"
[ "${CLAUDE_CURL_FAIL:-0}" = "1" ] && exit 1
dest=""
prev=""
for arg in "$@"; do
	[ "$prev" = "-o" ] && dest="$arg"
	prev="$arg"
done
cat >"$dest" <<'INSTALLER'
#!/usr/bin/env bash
echo "installer $*" >>"$CLAUDE_LOG"
echo "BASH_VERSINFO:${BASH_VERSINFO[0]:-unset}" >>"$CLAUDE_LOG"
if [ -t 0 ]; then
	echo "stdin-tty:yes" >>"$CLAUDE_LOG"
else
	echo "stdin-tty:no" >>"$CLAUDE_LOG"
fi
if [ "${CLAUDE_INSTALLER_INSTALLS:-1}" = "1" ]; then
	mkdir -p "$HOME/.local/bin"
	printf '#!/usr/bin/env bash\necho "1.2.283 (Claude Code)"\n' >"$HOME/.local/bin/claude"
	chmod +x "$HOME/.local/bin/claude"
fi
INSTALLER
chmod +x "$dest"
STUB
chmod +x "$SANDBOX/stub04claude/curl"

cat >"$SANDBOX/stub04claude/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$CLAUDE_LOG"
exit 1
STUB
chmod +x "$SANDBOX/stub04claude/sudo"

cat >"$SANDBOX/stub04claude/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >>"$CLAUDE_LOG"
if [ "$1" = list ] && [ "$2" = "--cask" ] && [ "$3" = "claude-code" ]; then
	exit "${CLAUDE_BREW_CASK_EXIT:-1}"
fi
if [ "$1" = uninstall ] && [ "$2" = "--cask" ] && [ "$3" = "claude-code" ]; then
	exit "${CLAUDE_BREW_UNINSTALL_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$SANDBOX/stub04claude/brew"

BASE_CLAUDE_PATH="$SANDBOX/stub04claude:/usr/bin:/bin"

run04claude() {
	(
		HOME="$1"
		PATH="$2"
		CLAUDE_INSTALL_URL="${3:-https://example.test/claude-install.sh}"
		CLAUDE_CURL_FAIL="${4:-0}"
		CLAUDE_INSTALLER_INSTALLS="${5:-1}"
		CLAUDE_BREW_CASK_EXIT="${6:-1}"
		CLAUDE_BREW_UNINSTALL_EXIT="${7:-0}"
		export HOME PATH CLAUDE_INSTALL_URL CLAUDE_CURL_FAIL CLAUDE_INSTALLER_INSTALLS \
			CLAUDE_BREW_CASK_EXIT CLAUDE_BREW_UNINSTALL_EXIT CLAUDE_LOG
		. "$SCRIPT_04_CLAUDE"
	) >"$SANDBOX/out04claude" 2>&1
	echo $?
}

# Case (a): native already installed -> no curl, message reports the version.
HOME_CLAUDE_A="$SANDBOX/home-claude-a"
mkdir -p "$HOME_CLAUDE_A/.local/bin"
printf '#!/usr/bin/env bash\necho "1.2.283 (Claude Code)"\n' >"$HOME_CLAUDE_A/.local/bin/claude"
chmod +x "$HOME_CLAUDE_A/.local/bin/claude"
: >"$CLAUDE_LOG"
status_claude_a=$(run04claude "$HOME_CLAUDE_A" "$SANDBOX/stub04claude:/usr/bin:/bin")
out_claude_a=$(cat "$SANDBOX/out04claude")
check "case a: returns success" "0" "$status_claude_a"
curl_calls_claude_a=$(grep -c '^curl ' "$CLAUDE_LOG")
check "case a: curl is not called" "0" "$curl_calls_claude_a"
contains "case a: reports already installed with the version" \
	" > Claude Code already installed natively (1.2.283 (Claude Code))" "$out_claude_a"

# Case (b): fresh machine -> curl fetches CLAUDE_INSTALL_URL, the installer
# runs with bash (not sudo) and stdin not a tty, success message with version.
HOME_CLAUDE_B="$SANDBOX/home-claude-b"
mkdir -p "$HOME_CLAUDE_B"
: >"$CLAUDE_LOG"
status_claude_b=$(run04claude "$HOME_CLAUDE_B" "$BASE_CLAUDE_PATH" "https://example.test/claude-install.sh")
out_claude_b=$(cat "$SANDBOX/out04claude")
check "case b: returns success" "0" "$status_claude_b"
curl_call_claude_b=$(grep '^curl ' "$CLAUDE_LOG")
contains "case b: curl uses -fsSL" "-fsSL" "$curl_call_claude_b"
contains "case b: curl fetches CLAUDE_INSTALL_URL" "https://example.test/claude-install.sh" "$curl_call_claude_b"
bash_versinfo_b=$(grep '^BASH_VERSINFO:' "$CLAUDE_LOG")
if [ "$bash_versinfo_b" = "BASH_VERSINFO:unset" ]; then
	claude_ran_as_bash_b=no
else
	claude_ran_as_bash_b=yes
fi
check "case b: installer runs under bash, not plain sh" "yes" "$claude_ran_as_bash_b"
stdin_tty_claude_b=$(grep '^stdin-tty:' "$CLAUDE_LOG")
check "case b: installer's stdin is not a tty" "stdin-tty:no" "$stdin_tty_claude_b"
sudo_calls_claude_b=$(grep -c '^sudo ' "$CLAUDE_LOG")
check "case b: sudo is never called" "0" "$sudo_calls_claude_b"
contains "case b: reports installed with the version" \
	" > Claude Code installed natively (1.2.283 (Claude Code))" "$out_claude_b"

# Case (c): download fails -> failure hint, status 0, no brew uninstall.
HOME_CLAUDE_C="$SANDBOX/home-claude-c"
mkdir -p "$HOME_CLAUDE_C"
: >"$CLAUDE_LOG"
status_claude_c=$(run04claude "$HOME_CLAUDE_C" "$BASE_CLAUDE_PATH" "" 1 1 0 0)
out_claude_c=$(cat "$SANDBOX/out04claude")
check "case c: returns success" "0" "$status_claude_c"
contains "case c: prints a failure hint" \
	"curl -fsSL https://claude.ai/install.sh | bash" "$out_claude_c"
brew_uninstall_calls_c=$(grep -c '^brew uninstall' "$CLAUDE_LOG")
check "case c: brew uninstall is never called" "0" "$brew_uninstall_calls_c"

# Case (d): native OK, and the Homebrew cask is present -> it is removed with
# exactly `brew uninstall --cask claude-code`.
HOME_CLAUDE_D="$SANDBOX/home-claude-d"
mkdir -p "$HOME_CLAUDE_D/.local/bin"
printf '#!/usr/bin/env bash\necho "1.2.283 (Claude Code)"\n' >"$HOME_CLAUDE_D/.local/bin/claude"
chmod +x "$HOME_CLAUDE_D/.local/bin/claude"
: >"$CLAUDE_LOG"
status_claude_d=$(run04claude "$HOME_CLAUDE_D" "$BASE_CLAUDE_PATH" "" 0 1 0 0)
out_claude_d=$(cat "$SANDBOX/out04claude")
check "case d: returns success" "0" "$status_claude_d"
uninstall_calls_d=$(grep -c '^brew uninstall --cask claude-code$' "$CLAUDE_LOG")
check "case d: brew uninstall --cask claude-code runs exactly once" "1" "$uninstall_calls_d"
contains "case d: reports the cask removed" \
	" > Removed the Homebrew claude-code cask (the native install replaces it)" "$out_claude_d"

# Case (e): native OK, no cask present -> no uninstall attempted.
HOME_CLAUDE_E="$SANDBOX/home-claude-e"
mkdir -p "$HOME_CLAUDE_E/.local/bin"
printf '#!/usr/bin/env bash\necho "1.2.283 (Claude Code)"\n' >"$HOME_CLAUDE_E/.local/bin/claude"
chmod +x "$HOME_CLAUDE_E/.local/bin/claude"
: >"$CLAUDE_LOG"
status_claude_e=$(run04claude "$HOME_CLAUDE_E" "$BASE_CLAUDE_PATH" "" 0 1 1 0)
check "case e: returns success" "0" "$status_claude_e"
list_calls_e=$(grep -c '^brew list --cask claude-code$' "$CLAUDE_LOG")
check "case e: brew list --cask claude-code is checked" "1" "$list_calls_e"
uninstall_calls_e=$(grep -c '^brew uninstall' "$CLAUDE_LOG")
check "case e: brew uninstall is never called" "0" "$uninstall_calls_e"

# Case (f): the installer ran but the binary is still missing -> failure
# hint, and brew is never consulted.
HOME_CLAUDE_F="$SANDBOX/home-claude-f"
mkdir -p "$HOME_CLAUDE_F"
: >"$CLAUDE_LOG"
status_claude_f=$(run04claude "$HOME_CLAUDE_F" "$BASE_CLAUDE_PATH" "" 0 0 0 0)
out_claude_f=$(cat "$SANDBOX/out04claude")
check "case f: returns success" "0" "$status_claude_f"
contains "case f: prints a failure hint" \
	"curl -fsSL https://claude.ai/install.sh | bash" "$out_claude_f"
brew_calls_f=$(grep -c '^brew ' "$CLAUDE_LOG")
check "case f: brew is never called" "0" "$brew_calls_f"

# ==============================================================================
# 08-pi.sh -- installs Pi itself and seeds it to match the reference machine.
# ==============================================================================
echo
echo "08-pi.sh"

PI_LOG="$SANDBOX/pi-install.log"
export PI_LOG
mkdir -p "$SANDBOX/stub-08pi" "$SANDBOX/stub-08pi-nosetsid"

cat >"$SANDBOX/stub-08pi/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$PI_LOG"
dest=""
prev=""
for arg in "$@"; do
	[ "$prev" = "-o" ] && dest="$arg"
	prev="$arg"
done
[ "${CURL_FAIL:-0}" = "1" ] && exit 1
cat >"$dest" <<'INSTALLER'
#!/usr/bin/env sh
echo "installer $*" >>"$PI_LOG"
printf 'path-head:%s\n' "$(echo "$PATH" | cut -d: -f1)" >>"$PI_LOG"
if [ -t 0 ]; then
	echo "stdin-tty:yes" >>"$PI_LOG"
else
	echo "stdin-tty:no" >>"$PI_LOG"
fi
mkdir -p "$HOME/.pi/agent/bin" "$HOME/bin"
cat >"$HOME/.pi/agent/bin/pi" <<'PISTUB'
#!/usr/bin/env bash
echo "pi $*" >>"$PI_LOG"
if [ "$1" = "install" ]; then
	name="${2#npm:}"
	case "$name" in
	@*)
		rest="${name#@}"
		pkg="@${rest%@*}"
		;;
	*)
		pkg="${name%%@*}"
		;;
	esac
	mkdir -p "$HOME/.pi/agent/npm/node_modules/$pkg"
fi
if [ "$1" = "-p" ]; then
	exit "${PI_SDD_EXIT:-${PI_EXIT:-0}}"
fi
exit "${PI_EXIT:-0}"
PISTUB
chmod +x "$HOME/.pi/agent/bin/pi"
ln -sf "$HOME/.pi/agent/bin/pi" "$HOME/bin/pi"
INSTALLER
chmod +x "$dest"
STUB
chmod +x "$SANDBOX/stub-08pi/curl"

cat >"$SANDBOX/stub-08pi/fnm" <<'STUB'
#!/usr/bin/env bash
echo "fnm $*" >>"$PI_LOG"
if [ "$1" = exec ] && [ "$2" = "--using=default" ]; then
	shift 2
	exec "$@"
fi
exit 0
STUB

cat >"$SANDBOX/stub-08pi/setsid" <<'STUB'
#!/usr/bin/env bash
echo "setsid $*" >>"$PI_LOG"
[ "$1" = "-w" ] && shift
exec "$@"
STUB

cat >"$SANDBOX/stub-08pi/timeout" <<'STUB'
#!/usr/bin/env bash
echo "timeout $*" >>"$PI_LOG"
shift
exec "$@"
STUB

cat >"$SANDBOX/stub-08pi/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >>"$PI_LOG"
if [ "$1" = "--prefix" ]; then
	echo "${SANDBOX_BREW_PREFIX:-/sandbox/brew}"
	exit 0
fi
exit 0
STUB

chmod +x "$SANDBOX/stub-08pi/fnm" "$SANDBOX/stub-08pi/setsid" \
	"$SANDBOX/stub-08pi/timeout" "$SANDBOX/stub-08pi/brew"
ln -s "$(command -v jq)" "$SANDBOX/stub-08pi/jq"

for _bin in curl fnm timeout brew jq; do
	ln -s "$SANDBOX/stub-08pi/$_bin" "$SANDBOX/stub-08pi-nosetsid/$_bin"
done
unset _bin

BASE_PI_PATH="$SANDBOX/stub-08pi:/usr/bin:/bin"
NO_SETSID_PI_PATH="$SANDBOX/stub-08pi-nosetsid:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-08pi-with-claude"
for _bin in curl fnm setsid timeout brew jq; do
	ln -s "$SANDBOX/stub-08pi/$_bin" "$SANDBOX/stub-08pi-with-claude/$_bin"
done
unset _bin
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/stub-08pi-with-claude/claude"
chmod +x "$SANDBOX/stub-08pi-with-claude/claude"
WITH_CLAUDE_PI_PATH="$SANDBOX/stub-08pi-with-claude:/usr/bin:/bin"

run08pi() {
	(
		HOME="$1"
		PATH="$2"
		PI_INSTALL_URL="${3:-https://example.test/install.sh}"
		BREW_PREFIX_CANDIDATES="${4:-/no/such/brew-a /no/such/brew-b}"
		CURL_FAIL="${5:-0}"
		PI_EXIT="${6:-0}"
		PI_SDD_EXIT="${7:-}"
		export HOME PATH PI_INSTALL_URL BREW_PREFIX_CANDIDATES CURL_FAIL PI_EXIT PI_SDD_EXIT PI_LOG DOTFILES_PATH
		. "$SCRIPT_08"
	) >"$SANDBOX/out08pi" 2>&1
	echo $?
}

# Case (a): fresh machine.
HOME_PI_A="$SANDBOX/home-pi-a"
mkdir -p "$HOME_PI_A/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_PI_A/.local/bin/claude"
chmod +x "$HOME_PI_A/.local/bin/claude"
printf 'sentinel-zshrc-content\n' >"$HOME_PI_A/.zshrc"
zshrc_before=$(sha256sum "$HOME_PI_A/.zshrc" | awk '{print $1}')
: >"$PI_LOG"
status_pi_a=$(run08pi "$HOME_PI_A" "$BASE_PI_PATH")
out_pi_a=$(cat "$SANDBOX/out08pi")
check "case a: returns success" "0" "$status_pi_a"

zshrc_after=$(sha256sum "$HOME_PI_A/.zshrc" | awk '{print $1}')
check "case a: .zshrc is left untouched" "$zshrc_before" "$zshrc_after"

curl_call=$(grep '^curl ' "$PI_LOG")
contains "case a: curl fetches PI_INSTALL_URL" "https://example.test/install.sh" "$curl_call"
setsid_call=$(grep '^setsid ' "$PI_LOG")
contains "case a: setsid runs the installer with -w" "setsid -w sh " "$setsid_call"
path_head=$(grep '^path-head:' "$PI_LOG" | sed 's/^path-head://')
check "case a: \$HOME/bin is first on PATH for the installer" "$HOME_PI_A/bin" "$path_head"

for _f in settings subagents claude-bridge mcp; do
	_dst="$HOME_PI_A/.pi/agent/$_f.json"
	[ -f "$_dst" ] && _present=yes || _present=no
	check "case a: $_f.json is seeded" "yes" "$_present"
	_perm=$(stat -c '%a' "$_dst" 2>/dev/null)
	check "case a: $_f.json mode is 600" "600" "$_perm"
	_placeholder=$(grep -c -E '@HOME@|@BREW_PREFIX@' "$_dst")
	check "case a: $_f.json has no leftover placeholder" "0" "$_placeholder"
done
unset _f _dst _present _perm _placeholder

claude_bridge_path=$(jq -r '.provider.pathToClaudeCodeExecutable' "$HOME_PI_A/.pi/agent/claude-bridge.json")
check "case a: claude-bridge.json has \$HOME substituted" "$HOME_PI_A/.local/bin/claude" "$claude_bridge_path"
mcp_engram_cmd=$(jq -r '.mcpServers.engram.command' "$HOME_PI_A/.pi/agent/mcp.json")
check "case a: mcp.json has the brew prefix substituted" "/sandbox/brew/bin/engram" "$mcp_engram_cmd"

profiles_file="$HOME_PI_A/.pi/gentle-ai/profiles.json"
active=$(jq -r '.active' "$profiles_file")
check "case a: profiles.json active is claude-full.autogen" "claude-full.autogen" "$active"
key_order=$(jq -r 'keys_unsorted | join(",")' "$profiles_file")
check "case a: profiles.json top-level key order" "kind,version,profiles,active" "$key_order"
profile_count=$(jq -r '.profiles | keys | length' "$profiles_file")
check "case a: profiles.json has exactly 4 profiles" "4" "$profile_count"
claude_match=$(jq -S '.profiles | del(."open-ai-full.autogen")' "$profiles_file")
claude_expected=$(jq -S '.' "$DOTFILES_PATH/config/pi/claude-profiles.json")
check "case a: claude profiles match the repo snapshot" "$claude_expected" "$claude_match"
openai_match=$(jq -S '.profiles["open-ai-full.autogen"]' "$profiles_file")
openai_expected=$(jq -S '.' "$DOTFILES_PATH/config/pi/open-ai-full.autogen.json")
check "case a: open-ai-full.autogen matches the repo snapshot" "$openai_expected" "$openai_match"
gentle_ai_dir_perm=$(stat -c '%a' "$HOME_PI_A/.pi/gentle-ai")
check "case a: ~/.pi/gentle-ai mode is 700" "700" "$gentle_ai_dir_perm"

models_file="$HOME_PI_A/.pi/gentle-ai/models.json"
models_match=$(jq -S '.' "$models_file")
active_profile_obj=$(jq -S '.profiles["claude-full.autogen"]' "$profiles_file")
check "case a: models.json equals the active profile" "$active_profile_obj" "$models_match"

install_calls=$(grep '^pi install ' "$PI_LOG")
expected_installs=$(jq -r '.packages[] | "pi install " + .' "$DOTFILES_PATH/config/pi/agent/settings.json")
check "case a: pi install runs once per package with the exact sources" "$expected_installs" "$install_calls"

sdd_first_line=$(grep -n '^pi -p /gentle:install-sdd$' "$PI_LOG" | head -n1 | cut -d: -f1)
last_install_line=$(grep -n '^pi install ' "$PI_LOG" | tail -n1 | cut -d: -f1)
if [ -n "$sdd_first_line" ] && [ -n "$last_install_line" ] && [ "$sdd_first_line" -gt "$last_install_line" ]; then
	sdd_order_ok=yes
else
	sdd_order_ok=no
fi
check "case a: both SDD install runs happen after every package install" "yes" "$sdd_order_ok"
sdd_calls_a=$(grep -c '^pi -p /gentle:install-sdd$' "$PI_LOG")
check "case a: install-sdd runs exactly twice" "2" "$sdd_calls_a"
success_msg_count_a=$(printf '%s\n' "$out_pi_a" | grep -c 'Pi agent assets installed')
check "case a: success message is reported once" "1" "$success_msg_count_a"
contains "case a: reports the SDD assets installed" "Pi agent assets installed" "$out_pi_a"

# Case (b): rerun -- Pi and the seed files already exist.
HOME_PI_B="$SANDBOX/home-pi-b"
mkdir -p "$HOME_PI_B/.pi/agent/bin" "$HOME_PI_B/.pi/agent/npm/node_modules"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_PI_B/.pi/agent/bin/pi"
chmod +x "$HOME_PI_B/.pi/agent/bin/pi"
for _f in settings subagents claude-bridge mcp; do
	printf 'sentinel-%s\n' "$_f" >"$HOME_PI_B/.pi/agent/$_f.json"
done
for _pkg in gentle-pi gentle-engram pi-claude-bridge pi-mcp-adapter; do
	mkdir -p "$HOME_PI_B/.pi/agent/npm/node_modules/$_pkg"
done
unset _f _pkg
: >"$PI_LOG"
status_pi_b=$(run08pi "$HOME_PI_B" "$BASE_PI_PATH")
check "case b: returns success" "0" "$status_pi_b"
curl_calls_b=$(grep -c '^curl ' "$PI_LOG")
check "case b: curl is not called" "0" "$curl_calls_b"
install_calls_b=$(grep -c '^pi install ' "$PI_LOG")
check "case b: no packages are installed again" "0" "$install_calls_b"
for _f in settings subagents claude-bridge mcp; do
	_content=$(cat "$HOME_PI_B/.pi/agent/$_f.json")
	check "case b: $_f.json sentinel is left untouched" "sentinel-$_f" "$_content"
done
unset _f _content

# Case (c): fnm missing -> skip message mentions 07-node.sh, nothing invoked.
HOME_PI_C="$SANDBOX/home-pi-c"
mkdir -p "$HOME_PI_C"
: >"$PI_LOG"
status_pi_c=$(run08pi "$HOME_PI_C" "$SANDBOX/empty-bin")
out_pi_c=$(cat "$SANDBOX/out08pi")
check "case c: returns success" "0" "$status_pi_c"
contains "case c: skip message mentions 07-node.sh" "07-node.sh" "$out_pi_c"
calls_pi_c=$(wc -l <"$PI_LOG" | tr -d ' ')
check "case c: nothing is invoked" "0" "$calls_pi_c"

# Case (d): the installer download fails -> failure hint, status 0, no installs.
HOME_PI_D="$SANDBOX/home-pi-d"
mkdir -p "$HOME_PI_D"
: >"$PI_LOG"
status_pi_d=$(run08pi "$HOME_PI_D" "$BASE_PI_PATH" "" "" 1)
out_pi_d=$(cat "$SANDBOX/out08pi")
check "case d: returns success" "0" "$status_pi_d"
contains "case d: prints a failure hint" "curl -fsSL https://pi.dev/install.sh | sh" "$out_pi_d"
install_calls_d=$(grep -c '^pi install ' "$PI_LOG")
check "case d: no packages are installed" "0" "$install_calls_d"

# Case (e): setsid absent -> the python3 fallback still detaches the installer.
HOME_PI_E="$SANDBOX/home-pi-e"
mkdir -p "$HOME_PI_E"
: >"$PI_LOG"
status_pi_e=$(run08pi "$HOME_PI_E" "$NO_SETSID_PI_PATH")
check "case e: returns success" "0" "$status_pi_e"
stdin_tty_line=$(grep '^stdin-tty:' "$PI_LOG")
check "case e: the installer still ran detached (stdin not a tty)" "stdin-tty:no" "$stdin_tty_line"
[ -x "$HOME_PI_E/.pi/agent/bin/pi" ] && pi_installed_e=yes || pi_installed_e=no
check "case e: Pi ends up installed via the python3 fallback" "yes" "$pi_installed_e"
setsid_calls_e=$(grep -c '^setsid ' "$PI_LOG")
check "case e: setsid is never invoked" "0" "$setsid_calls_e"

# Case (f): an existing profiles.json lacking open-ai-full.autogen is left
# untouched, with a hint to run scripts/restore-pi-openai-profile.
HOME_PI_F="$SANDBOX/home-pi-f"
mkdir -p "$HOME_PI_F/.pi/agent/bin" "$HOME_PI_F/.pi/gentle-ai"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_PI_F/.pi/agent/bin/pi"
chmod +x "$HOME_PI_F/.pi/agent/bin/pi"
cat >"$HOME_PI_F/.pi/gentle-ai/profiles.json" <<'JSON'
{"kind":"gentle-pi.agent_model_profiles","version":1,"profiles":{"current":{}},"active":"current"}
JSON
profiles_before_f=$(cat "$HOME_PI_F/.pi/gentle-ai/profiles.json")
: >"$PI_LOG"
status_pi_f=$(run08pi "$HOME_PI_F" "$BASE_PI_PATH")
out_pi_f=$(cat "$SANDBOX/out08pi")
check "case f: returns success" "0" "$status_pi_f"
profiles_after_f=$(cat "$HOME_PI_F/.pi/gentle-ai/profiles.json")
check "case f: the existing profiles.json is left untouched" "$profiles_before_f" "$profiles_after_f"
contains "case f: hint mentions scripts/restore-pi-openai-profile" "scripts/restore-pi-openai-profile" "$out_pi_f"

# Case (g): the first install-sdd attempt fails -> no second attempt is made,
# the existing failure message style is kept, status is still 0.
HOME_PI_G="$SANDBOX/home-pi-g"
mkdir -p "$HOME_PI_G"
: >"$PI_LOG"
status_pi_g=$(run08pi "$HOME_PI_G" "$BASE_PI_PATH" "" "" 0 0 7)
out_pi_g=$(cat "$SANDBOX/out08pi")
check "case g: returns success" "0" "$status_pi_g"
sdd_calls_g=$(grep -c '^pi -p /gentle:install-sdd$' "$PI_LOG")
check "case g: install-sdd is attempted only once" "1" "$sdd_calls_g"
contains "case g: reports the install-sdd failure" "Pi agent asset install failed (exit 7)" "$out_pi_g"

# ==============================================================================
# claude-bridge.json path repair -- pathToClaudeCodeExecutable must point at
# an executable Claude binary, both for a freshly seeded file and for an
# existing one from an earlier restore.
# ==============================================================================
echo
echo "claude-bridge.json path repair"

# Case bridge-i: freshly seeded path is missing, claude is on PATH -> the
# value is rewritten to the resolved claude path; every other key is intact.
HOME_BRIDGE_I="$SANDBOX/home-bridge-i"
mkdir -p "$HOME_BRIDGE_I"
: >"$PI_LOG"
status_bridge_i=$(run08pi "$HOME_BRIDGE_I" "$WITH_CLAUDE_PI_PATH")
check "case bridge-i: returns success" "0" "$status_bridge_i"
bridge_i_file="$HOME_BRIDGE_I/.pi/agent/claude-bridge.json"
bridge_i_path=$(jq -r '.provider.pathToClaudeCodeExecutable' "$bridge_i_file")
check "case bridge-i: path is rewritten to the resolved claude binary" \
	"$SANDBOX/stub-08pi-with-claude/claude" "$bridge_i_path"
bridge_i_perm=$(stat -c '%a' "$bridge_i_file")
check "case bridge-i: mode stays 600" "600" "$bridge_i_perm"
bridge_i_seed=$(sed -e "s|@HOME@|$HOME_BRIDGE_I|g" -e "s|@BREW_PREFIX@|/sandbox/brew|g" \
	"$DOTFILES_PATH/config/pi/agent/claude-bridge.json" | jq -S 'del(.provider.pathToClaudeCodeExecutable)')
bridge_i_actual=$(jq -S 'del(.provider.pathToClaudeCodeExecutable)' "$bridge_i_file")
check "case bridge-i: every other key is unchanged" "$bridge_i_seed" "$bridge_i_actual"

# Case bridge-ii: no claude anywhere on PATH -> the key is removed, falling
# back to the SDK's default Claude lookup.
HOME_BRIDGE_II="$SANDBOX/home-bridge-ii"
mkdir -p "$HOME_BRIDGE_II"
: >"$PI_LOG"
status_bridge_ii=$(run08pi "$HOME_BRIDGE_II" "$BASE_PI_PATH")
out_bridge_ii=$(cat "$SANDBOX/out08pi")
check "case bridge-ii: returns success" "0" "$status_bridge_ii"
bridge_ii_file="$HOME_BRIDGE_II/.pi/agent/claude-bridge.json"
bridge_ii_has_key=$(jq -r '.provider | has("pathToClaudeCodeExecutable")' "$bridge_ii_file")
check "case bridge-ii: pathToClaudeCodeExecutable is removed" "false" "$bridge_ii_has_key"
bridge_ii_seed_provider=$(sed -e "s|@HOME@|$HOME_BRIDGE_II|g" -e "s|@BREW_PREFIX@|/sandbox/brew|g" \
	"$DOTFILES_PATH/config/pi/agent/claude-bridge.json" | jq -S '.provider | del(.pathToClaudeCodeExecutable)')
bridge_ii_actual_provider=$(jq -S '.provider' "$bridge_ii_file")
check "case bridge-ii: every other provider key is unchanged" "$bridge_ii_seed_provider" "$bridge_ii_actual_provider"
contains "case bridge-ii: reports the default Claude lookup" "default Claude lookup" "$out_bridge_ii"

# Case bridge-iii: an existing file already points at an executable Claude
# binary -> left byte-identical.
HOME_BRIDGE_III="$SANDBOX/home-bridge-iii"
mkdir -p "$HOME_BRIDGE_III/.pi/agent/bin" "$HOME_BRIDGE_III/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_BRIDGE_III/.pi/agent/bin/pi"
chmod +x "$HOME_BRIDGE_III/.pi/agent/bin/pi"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_BRIDGE_III/bin/claude"
chmod +x "$HOME_BRIDGE_III/bin/claude"
jq --arg p "$HOME_BRIDGE_III/bin/claude" \
	'.provider.pathToClaudeCodeExecutable = $p' "$DOTFILES_PATH/config/pi/agent/claude-bridge.json" \
	>"$HOME_BRIDGE_III/.pi/agent/claude-bridge.json"
chmod 600 "$HOME_BRIDGE_III/.pi/agent/claude-bridge.json"
bridge_iii_before=$(sha256sum "$HOME_BRIDGE_III/.pi/agent/claude-bridge.json" | awk '{print $1}')
: >"$PI_LOG"
status_bridge_iii=$(run08pi "$HOME_BRIDGE_III" "$BASE_PI_PATH")
check "case bridge-iii: returns success" "0" "$status_bridge_iii"
bridge_iii_after=$(sha256sum "$HOME_BRIDGE_III/.pi/agent/claude-bridge.json" | awk '{print $1}')
check "case bridge-iii: an already-executable path is left byte-identical" \
	"$bridge_iii_before" "$bridge_iii_after"

# Case bridge-iv: an existing file has a stale path (rerun on a machine whose
# Claude moved) and claude is now on PATH -> the path is repaired in place.
HOME_BRIDGE_IV="$SANDBOX/home-bridge-iv"
mkdir -p "$HOME_BRIDGE_IV/.pi/agent/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_BRIDGE_IV/.pi/agent/bin/pi"
chmod +x "$HOME_BRIDGE_IV/.pi/agent/bin/pi"
jq --arg p "$HOME_BRIDGE_IV/.local/bin/claude" \
	'.provider.pathToClaudeCodeExecutable = $p | .customTopLevelField = true' \
	"$DOTFILES_PATH/config/pi/agent/claude-bridge.json" \
	>"$HOME_BRIDGE_IV/.pi/agent/claude-bridge.json"
chmod 600 "$HOME_BRIDGE_IV/.pi/agent/claude-bridge.json"
: >"$PI_LOG"
status_bridge_iv=$(run08pi "$HOME_BRIDGE_IV" "$WITH_CLAUDE_PI_PATH")
check "case bridge-iv: returns success" "0" "$status_bridge_iv"
bridge_iv_file="$HOME_BRIDGE_IV/.pi/agent/claude-bridge.json"
bridge_iv_path=$(jq -r '.provider.pathToClaudeCodeExecutable' "$bridge_iv_file")
check "case bridge-iv: the stale path is repaired" \
	"$SANDBOX/stub-08pi-with-claude/claude" "$bridge_iv_path"
bridge_iv_custom=$(jq -r '.customTopLevelField' "$bridge_iv_file")
check "case bridge-iv: unrelated top-level keys are preserved" "true" "$bridge_iv_custom"
bridge_iv_perm=$(stat -c '%a' "$bridge_iv_file")
check "case bridge-iv: mode stays 600" "600" "$bridge_iv_perm"

# ==============================================================================
# config/pi/agent seed files -- no leftover /home/ literal, valid JSON, and
# settings.json declares exactly the 4 pinned packages.
# ==============================================================================
echo
echo "config/pi/agent seed files"

for _f in settings subagents claude-bridge mcp; do
	_seed="$DOTFILES_PATH/config/pi/agent/$_f.json"
	_no_home=$(grep -c '/home/' "$_seed")
	check "config/pi/agent/$_f.json has no /home/ literal" "0" "$_no_home"
	jq empty "$_seed" >/dev/null 2>&1 && _valid=yes || _valid=no
	check "config/pi/agent/$_f.json is valid JSON" "yes" "$_valid"
done
unset _f _seed _no_home _valid
pkg_count=$(jq '.packages | length' "$DOTFILES_PATH/config/pi/agent/settings.json")
check "settings.json packages list has exactly 4 entries" "4" "$pkg_count"

# ==============================================================================
# 09-gentle-ai-sync.sh -- nothing in the restore ever ran gentle-ai to turn the
# state 06-gentle-ai-state.sh seeds into the actual agent assets, and gentle-ai
# sync fails on opencode's cold first start (measured 97s bootstrap) unless
# something warms it up first.
# ==============================================================================
echo
echo "09-gentle-ai-sync.sh"

SYNC_LOG="$SANDBOX/gentle-ai-sync.log"
export SYNC_LOG
mkdir -p "$SANDBOX/stub-09"

cat >"$SANDBOX/stub-09/gentle-ai" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
exit "${GENTLE_AI_SYNC_EXIT:-0}"
STUB

cat >"$SANDBOX/stub-09/opencode" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
exit 0
STUB

cat >"$SANDBOX/stub-09/fnm" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
if [ "$1" = exec ] && [ "$2" = "--using=default" ]; then
	shift 2
	exec "$@"
fi
exit 0
STUB

cat >"$SANDBOX/stub-09/timeout" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$SYNC_LOG"
shift
exec "$@"
STUB

chmod +x "$SANDBOX/stub-09/gentle-ai" "$SANDBOX/stub-09/opencode" \
	"$SANDBOX/stub-09/fnm" "$SANDBOX/stub-09/timeout"

FULL_PATH_09="$SANDBOX/stub-09:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-09-no-opencode"
ln -s "$SANDBOX/stub-09/gentle-ai" "$SANDBOX/stub-09-no-opencode/gentle-ai"
ln -s "$SANDBOX/stub-09/fnm" "$SANDBOX/stub-09-no-opencode/fnm"
ln -s "$SANDBOX/stub-09/timeout" "$SANDBOX/stub-09-no-opencode/timeout"
NO_OPENCODE_PATH_09="$SANDBOX/stub-09-no-opencode:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-09-no-gentle-ai"
ln -s "$SANDBOX/stub-09/opencode" "$SANDBOX/stub-09-no-gentle-ai/opencode"
ln -s "$SANDBOX/stub-09/fnm" "$SANDBOX/stub-09-no-gentle-ai/fnm"
ln -s "$SANDBOX/stub-09/timeout" "$SANDBOX/stub-09-no-gentle-ai/timeout"
NO_GENTLE_AI_PATH_09="$SANDBOX/stub-09-no-gentle-ai:/usr/bin:/bin"

mkdir -p "$SANDBOX/stub-09-no-fnm"
ln -s "$SANDBOX/stub-09/gentle-ai" "$SANDBOX/stub-09-no-fnm/gentle-ai"
ln -s "$SANDBOX/stub-09/opencode" "$SANDBOX/stub-09-no-fnm/opencode"
NO_FNM_PATH_09="$SANDBOX/stub-09-no-fnm:/usr/bin:/bin"

run09() {
	(
		HOME="$1"
		PATH="$2"
		GENTLE_AI_SYNC_EXIT="${3:-0}"
		GENTLE_AI_CANDIDATES="${4-/no/such/gentle-ai-a /no/such/gentle-ai-b}"
		export HOME PATH GENTLE_AI_SYNC_EXIT GENTLE_AI_CANDIDATES SYNC_LOG
		. "$SCRIPT_09"
	) >"$SANDBOX/out09" 2>&1
	echo $?
}

# Case (a): everything present -> opencode is warmed up BEFORE the fnm exec
# gentle-ai sync call, with the exact args, and the sync succeeds.
HOME_J="$SANDBOX/home-j"
mkdir -p "$HOME_J/.gentle-ai"
: >"$HOME_J/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_j=$(run09 "$HOME_J" "$FULL_PATH_09")
out_j=$(cat "$SANDBOX/out09")
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
status_k=$(run09 "$HOME_K" "$NO_OPENCODE_PATH_09")
out_k=$(cat "$SANDBOX/out09")
check "case b: returns success" "0" "$status_k"
warmup_calls_k=$(grep -c 'opencode debug config' "$SYNC_LOG")
check "case b: no opencode warm-up call is made" "0" "$warmup_calls_k"
contains "case b: sync still runs" "gentle-ai agent assets synced" "$out_k"

# Case (c): state.json missing -> skip, nothing on PATH is ever invoked.
HOME_L="$SANDBOX/home-l"
mkdir -p "$HOME_L"
: >"$SYNC_LOG"
status_l=$(run09 "$HOME_L" "$FULL_PATH_09")
out_l=$(cat "$SANDBOX/out09")
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
status_m=$(run09 "$HOME_M" "$NO_GENTLE_AI_PATH_09")
out_m=$(cat "$SANDBOX/out09")
check "case d: returns success" "0" "$status_m"
contains "case d: prints a skip message" "gentle-ai is not installed" "$out_m"
calls_m=$(wc -l <"$SYNC_LOG" | tr -d ' ')
check "case d: nothing is invoked" "0" "$calls_m"

# Case (e): fnm missing -> skip message mentions 07-node.sh, nothing is invoked.
HOME_N="$SANDBOX/home-n"
mkdir -p "$HOME_N/.gentle-ai"
: >"$HOME_N/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_n=$(run09 "$HOME_N" "$NO_FNM_PATH_09")
out_n=$(cat "$SANDBOX/out09")
check "case e: returns success" "0" "$status_n"
contains "case e: skip message mentions 07-node.sh" "07-node.sh" "$out_n"
calls_n=$(wc -l <"$SYNC_LOG" | tr -d ' ')
check "case e: nothing is invoked" "0" "$calls_n"

# Case (f): sync fails -> failure message naming the rerun command, status 0.
HOME_O="$SANDBOX/home-o"
mkdir -p "$HOME_O/.gentle-ai"
: >"$HOME_O/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_o=$(run09 "$HOME_O" "$FULL_PATH_09" 3)
out_o=$(cat "$SANDBOX/out09")
check "case f: still returns success" "0" "$status_o"
contains "case f: prints a failure message" "gentle-ai sync failed" "$out_o"
contains "case f: failure message names the rerun command" \
	"fnm exec --using=default gentle-ai sync" "$out_o"

# Case (g): pi is also runnable (via PATH or the agent bin path) -> after the
# plain sync, 09 also runs `gentle-ai sync --agents pi`, same message style.
mkdir -p "$SANDBOX/stub-09-with-pi"
ln -s "$SANDBOX/stub-09/gentle-ai" "$SANDBOX/stub-09-with-pi/gentle-ai"
ln -s "$SANDBOX/stub-09/opencode" "$SANDBOX/stub-09-with-pi/opencode"
ln -s "$SANDBOX/stub-09/fnm" "$SANDBOX/stub-09-with-pi/fnm"
ln -s "$SANDBOX/stub-09/timeout" "$SANDBOX/stub-09-with-pi/timeout"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/stub-09-with-pi/pi"
chmod +x "$SANDBOX/stub-09-with-pi/pi"
WITH_PI_PATH_09="$SANDBOX/stub-09-with-pi:/usr/bin:/bin"

HOME_P="$SANDBOX/home-p"
mkdir -p "$HOME_P/.gentle-ai"
: >"$HOME_P/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_p=$(run09 "$HOME_P" "$WITH_PI_PATH_09")
out_p=$(cat "$SANDBOX/out09")
check "case g1: returns success" "0" "$status_p"
contains "case g1: reports the Pi sync succeeded" "gentle-ai Pi assets synced" "$out_p"
pi_fnm_call=$(grep '^fnm exec --using=default gentle-ai sync --agents pi$' "$SYNC_LOG")
check "case g1: fnm gets the exact Pi sync args" \
	"fnm exec --using=default gentle-ai sync --agents pi" "$pi_fnm_call"
base_sync_line=$(grep -n '^fnm exec --using=default gentle-ai sync$' "$SYNC_LOG" | head -n1 | cut -d: -f1)
pi_sync_line=$(grep -n '^fnm exec --using=default gentle-ai sync --agents pi$' "$SYNC_LOG" | head -n1 | cut -d: -f1)
if [ -n "$base_sync_line" ] && [ -n "$pi_sync_line" ] && [ "$base_sync_line" -lt "$pi_sync_line" ]; then
	pi_order_ok=yes
else
	pi_order_ok=no
fi
check "case g1: the Pi sync runs after the plain sync" "yes" "$pi_order_ok"

# Case (g2): pi is not on PATH but the agent bin launcher is executable.
HOME_Q="$SANDBOX/home-q"
mkdir -p "$HOME_Q/.gentle-ai" "$HOME_Q/.pi/agent/bin"
: >"$HOME_Q/.gentle-ai/state.json"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_Q/.pi/agent/bin/pi"
chmod +x "$HOME_Q/.pi/agent/bin/pi"
: >"$SYNC_LOG"
status_q=$(run09 "$HOME_Q" "$FULL_PATH_09")
out_q=$(cat "$SANDBOX/out09")
check "case g2: returns success" "0" "$status_q"
contains "case g2: reports the Pi sync succeeded" "gentle-ai Pi assets synced" "$out_q"

# Case (g3): pi is not runnable at all -> no Pi sync call is made.
HOME_R="$SANDBOX/home-r"
mkdir -p "$HOME_R/.gentle-ai"
: >"$HOME_R/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_r=$(run09 "$HOME_R" "$FULL_PATH_09")
out_r=$(cat "$SANDBOX/out09")
check "case g3: returns success" "0" "$status_r"
pi_calls_r=$(grep -c -- '--agents pi' "$SYNC_LOG")
check "case g3: no Pi sync call is made" "0" "$pi_calls_r"

# Case (g4): pi runnable but the Pi sync fails -> failure message names the
# rerun command, status still 0.
HOME_S="$SANDBOX/home-s"
mkdir -p "$HOME_S/.gentle-ai"
: >"$HOME_S/.gentle-ai/state.json"
: >"$SYNC_LOG"
status_s=$(run09 "$HOME_S" "$WITH_PI_PATH_09" 3)
out_s=$(cat "$SANDBOX/out09")
check "case g4: still returns success" "0" "$status_s"
contains "case g4: prints a Pi sync failure message" "gentle-ai Pi asset sync failed" "$out_s"
contains "case g4: failure message names the rerun command" \
	"fnm exec --using=default gentle-ai sync --agents pi" "$out_s"

# ==============================================================================
# 15-rust.sh -- installs rustup (stable, default profile) via the official
# installer, order-independent, needing only curl.
# ==============================================================================
echo
echo "15-rust.sh"

mkdir -p "$SANDBOX/stub15"
RUST_LOG="$SANDBOX/rust-install.log"
export RUST_LOG

cat > "$SANDBOX/stub15/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$RUST_LOG"
dest="" prev=""
for arg in "$@"; do
	[ "$prev" = "-o" ] && dest="$arg"
	prev="$arg"
done
[ "${RUST_CURL_FAIL:-0}" = "1" ] && exit 1
cat >"$dest" <<'INSTALLER'
#!/usr/bin/env sh
echo "installer $*" >>"$RUST_LOG"
mkdir -p "$HOME/.cargo/bin"
cat >"$HOME/.cargo/bin/rustup" <<'RUSTUPSTUB'
#!/usr/bin/env bash
exit 0
RUSTUPSTUB
chmod +x "$HOME/.cargo/bin/rustup"
INSTALLER
chmod +x "$dest"
STUB
chmod +x "$SANDBOX/stub15/curl"
STUB15_PATH="$SANDBOX/stub15:/usr/bin:/bin"

run15() {
	(
		HOME="$1"
		PATH="$2"
		RUSTUP_INIT_URL="${3:-https://example.test/rustup-init.sh}"
		RUST_CURL_FAIL="${4:-0}"
		export HOME PATH RUSTUP_INIT_URL RUST_CURL_FAIL RUST_LOG
		. "$SCRIPT_15"
	) >"$SANDBOX/out15" 2>&1
	echo $?
}

# Case (h): rustup already present -> no curl call.
HOME_15H="$SANDBOX/home15h"
mkdir -p "$HOME_15H/.cargo/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_15H/.cargo/bin/rustup"
chmod +x "$HOME_15H/.cargo/bin/rustup"
: >"$RUST_LOG"
status_15h=$(run15 "$HOME_15H" "$STUB15_PATH")
out_15h=$(cat "$SANDBOX/out15")
check "case h: returns success" "0" "$status_15h"
contains "case h: reports already installed" "Rust already installed" "$out_15h"
curl_calls_15h=$(wc -l <"$RUST_LOG" | tr -d ' ')
check "case h: no curl call" "0" "$curl_calls_15h"

# Case (i): fresh install -> curl uses the right TLS flags and RUSTUP_INIT_URL,
# the installer gets exactly the documented args, and the sentinel .zshenv
# (a symlink into this repository in the real machine) is left untouched.
HOME_15I="$SANDBOX/home15i"
mkdir -p "$HOME_15I"
printf 'sentinel-zshenv-content\n' > "$HOME_15I/.zshenv"
zshenv_before_i=$(sha256sum "$HOME_15I/.zshenv" | awk '{print $1}')
: >"$RUST_LOG"
status_15i=$(run15 "$HOME_15I" "$STUB15_PATH" "https://example.test/rustup-init.sh")
out_15i=$(cat "$SANDBOX/out15")
check "case i: returns success" "0" "$status_15i"
contains "case i: reports installed" "Rust installed (rustup, stable, default profile)" "$out_15i"
curl_call_15i=$(grep '^curl ' "$RUST_LOG")
contains "case i: curl uses --proto =https" "--proto =https" "$curl_call_15i"
contains "case i: curl uses --tlsv1.2" "--tlsv1.2" "$curl_call_15i"
contains "case i: curl uses -sSf" "-sSf" "$curl_call_15i"
contains "case i: curl fetches RUSTUP_INIT_URL" "https://example.test/rustup-init.sh" "$curl_call_15i"
installer_call_15i=$(grep '^installer ' "$RUST_LOG")
check "case i: the installer gets exactly the documented args" \
	"installer -y --no-modify-path --profile default" "$installer_call_15i"
zshenv_after_i=$(sha256sum "$HOME_15I/.zshenv" | awk '{print $1}')
check "case i: .zshenv sentinel is left untouched" "$zshenv_before_i" "$zshenv_after_i"
[ -x "$HOME_15I/.cargo/bin/rustup" ] && rustup_installed_i=yes || rustup_installed_i=no
check "case i: rustup ends up installed" "yes" "$rustup_installed_i"

# Case (j): download failure -> hint, status 0.
HOME_15J="$SANDBOX/home15j"
mkdir -p "$HOME_15J"
: >"$RUST_LOG"
status_15j=$(run15 "$HOME_15J" "$STUB15_PATH" "" 1)
out_15j=$(cat "$SANDBOX/out15")
check "case j: returns success" "0" "$status_15j"
contains "case j: prints a failure hint" \
	"curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default" "$out_15j"

# ==============================================================================
# 16-tailscale.sh -- installs Tailscale via the official installer on a
# non-WSL Linux machine (order-independent, needs curl + passwordless sudo),
# skips on Darwin and WSL, and never blocks on manual authentication.
# ==============================================================================
echo
echo "16-tailscale.sh"

mkdir -p "$SANDBOX/stub16" "$SANDBOX/tsbin16"
TS_LOG="$SANDBOX/tailscale-install.log"
TS_BIN_DIR="$SANDBOX/tsbin16"
export TS_LOG TS_BIN_DIR

cat > "$SANDBOX/stub16/uname" <<'STUB'
#!/usr/bin/env bash
echo "${TS_UNAME_S:-Linux}"
STUB
chmod +x "$SANDBOX/stub16/uname"

cat > "$SANDBOX/stub16/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$TS_LOG"
if [ "$1" = "-n" ]; then
	[ "${TS_SUDO_PASSWORDLESS:-1}" = "1" ] && exit 0 || exit 1
fi
exit 0
STUB
chmod +x "$SANDBOX/stub16/sudo"

cat > "$SANDBOX/stub16/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$TS_LOG"
dest="" prev=""
for arg in "$@"; do
	[ "$prev" = "-o" ] && dest="$arg"
	prev="$arg"
done
[ "${TS_CURL_FAIL:-0}" = "1" ] && exit 1
cat >"$dest" <<'INSTALLER'
#!/usr/bin/env sh
if [ -t 0 ]; then
	echo "installer-stdin-tty" >>"$TS_LOG"
else
	echo "installer-stdin-not-tty" >>"$TS_LOG"
fi
mkdir -p "$TS_BIN_DIR"
cat >"$TS_BIN_DIR/tailscale" <<'TSSTUB'
#!/usr/bin/env bash
echo "tailscale $*" >>"$TS_LOG"
case "$1" in
status) exit "${TS_STATUS_EXIT:-1}" ;;
ip) echo "100.64.0.1" ;;
esac
TSSTUB
chmod +x "$TS_BIN_DIR/tailscale"
INSTALLER
chmod +x "$dest"
STUB
chmod +x "$SANDBOX/stub16/curl"

write_tailscale_stub() {
	cat > "$TS_BIN_DIR/tailscale" <<'TSSTUB'
#!/usr/bin/env bash
echo "tailscale $*" >>"$TS_LOG"
case "$1" in
status) exit "${TS_STATUS_EXIT:-1}" ;;
ip) echo "100.64.0.1" ;;
esac
TSSTUB
	chmod +x "$TS_BIN_DIR/tailscale"
}

# The system tools, minus any real tailscale: with Tailscale installed on the
# machine running this suite, /usr/bin/tailscale leaked into the "not
# installed" cases and they all reported "Tailscale is up".
mkdir -p "$SANDBOX/sysbin16"
for sys_tool in /usr/bin/* /bin/*; do
	case "$(basename "$sys_tool")" in tailscale | tailscaled) continue ;; esac
	[ -e "$SANDBOX/sysbin16/$(basename "$sys_tool")" ] || [ -L "$SANDBOX/sysbin16/$(basename "$sys_tool")" ] ||
		ln -s "$sys_tool" "$SANDBOX/sysbin16/$(basename "$sys_tool")"
done
unset sys_tool
STUB16_PATH="$SANDBOX/tsbin16:$SANDBOX/stub16:$SANDBOX/sysbin16"

printf 'Linux version 6.8.0-49-generic (buildd@lcy02) #49-Ubuntu\n' > "$SANDBOX/proc-version-linux16"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' > "$SANDBOX/proc-version-wsl16"

run16() {
	(
		HOME="$1"
		PATH="$2"
		TAILSCALE_PROC_VERSION_FILE="$3"
		TAILSCALE_INSTALL_URL="${4:-https://tailscale.com/install.sh}"
		TS_UNAME_S="${5:-Linux}"
		export HOME PATH TAILSCALE_PROC_VERSION_FILE TAILSCALE_INSTALL_URL TS_UNAME_S \
			TS_LOG TS_BIN_DIR TS_SUDO_PASSWORDLESS TS_CURL_FAIL TS_STATUS_EXIT
		. "$SCRIPT_16"
	) >"$SANDBOX/out16" 2>&1
	echo $?
}

# Case (a): Darwin -> skip, nothing called.
HOME_16A="$SANDBOX/home16a"
mkdir -p "$HOME_16A"
rm -f "$TS_BIN_DIR/tailscale"
: >"$TS_LOG"
export TS_SUDO_PASSWORDLESS=1 TS_STATUS_EXIT=1 TS_CURL_FAIL=0
status_16a=$(run16 "$HOME_16A" "$STUB16_PATH" "$SANDBOX/proc-version-linux16" "" "Darwin")
out_16a=$(cat "$SANDBOX/out16")
check "case a: returns success" "0" "$status_16a"
contains "case a: skips with the macOS message" \
	" > Tailscale on macOS comes from its app; skipping" "$out_16a"
calls_16a=$(wc -l <"$TS_LOG" | tr -d ' ')
check "case a: nothing is called" "0" "$calls_16a"

# Case (b): WSL -> skip, nothing called.
HOME_16B="$SANDBOX/home16b"
mkdir -p "$HOME_16B"
rm -f "$TS_BIN_DIR/tailscale"
: >"$TS_LOG"
status_16b=$(run16 "$HOME_16B" "$STUB16_PATH" "$SANDBOX/proc-version-wsl16" "" "Linux")
out_16b=$(cat "$SANDBOX/out16")
check "case b: returns success" "0" "$status_16b"
contains "case b: skips with the WSL message" \
	" > WSL: use the Tailscale Windows client instead; skipping" "$out_16b"
calls_16b=$(wc -l <"$TS_LOG" | tr -d ' ')
check "case b: nothing is called" "0" "$calls_16b"

# Case (c): Linux, no tailscale, passwordless sudo -> installer fetched from
# TAILSCALE_INSTALL_URL, run with stdin redirected away from a tty, reports
# installed, then prints the not-logged-in auth steps (status fails).
HOME_16C="$SANDBOX/home16c"
mkdir -p "$HOME_16C"
rm -f "$TS_BIN_DIR/tailscale"
: >"$TS_LOG"
export TS_SUDO_PASSWORDLESS=1 TS_STATUS_EXIT=1 TS_CURL_FAIL=0
status_16c=$(run16 "$HOME_16C" "$STUB16_PATH" "$SANDBOX/proc-version-linux16" \
	"https://example.test/tailscale-install.sh" "Linux")
out_16c=$(cat "$SANDBOX/out16")
check "case c: returns success" "0" "$status_16c"
curl_call_16c=$(grep '^curl ' "$TS_LOG")
contains "case c: curl uses -fsSL" "-fsSL" "$curl_call_16c"
contains "case c: curl fetches TAILSCALE_INSTALL_URL" "https://example.test/tailscale-install.sh" "$curl_call_16c"
contains "case c: installer runs with stdin not a tty" "installer-stdin-not-tty" "$(cat "$TS_LOG")"
contains "case c: reports installed" " > Tailscale installed" "$out_16c"
contains "case c: prints the not-logged-in auth steps" \
	" > Tailscale is installed but not logged in. Authenticate once (opens a browser URL):" "$out_16c"
contains "case c: auth steps include sudo tailscale up" "sudo tailscale up" "$out_16c"
contains "case c: auth steps include the operator line" \
	"sudo tailscale set --operator=" "$out_16c"
contains "case c: auth steps mention disabling key expiry" \
	"disable key expiry for this machine so it stays reachable 24/7" "$out_16c"

# Case (d): no tailscale, sudo needs a password -> manual curl command
# printed, curl NOT called.
HOME_16D="$SANDBOX/home16d"
mkdir -p "$HOME_16D"
rm -f "$TS_BIN_DIR/tailscale"
: >"$TS_LOG"
export TS_SUDO_PASSWORDLESS=0
status_16d=$(run16 "$HOME_16D" "$STUB16_PATH" "$SANDBOX/proc-version-linux16" "" "Linux")
out_16d=$(cat "$SANDBOX/out16")
check "case d: returns success" "0" "$status_16d"
contains "case d: reports sudo needs a password" \
	" > Tailscale is not installed and sudo needs a password here. Run by hand:" "$out_16d"
contains "case d: prints the manual install command" \
	"curl -fsSL https://tailscale.com/install.sh | sh" "$out_16d"
curl_calls_16d=$(grep -c '^curl ' "$TS_LOG")
check "case d: curl is not called" "0" "$curl_calls_16d"

# Case (e): tailscale present and status ok -> reports the tailnet IP, no curl.
HOME_16E="$SANDBOX/home16e"
mkdir -p "$HOME_16E"
write_tailscale_stub
: >"$TS_LOG"
export TS_SUDO_PASSWORDLESS=1 TS_STATUS_EXIT=0
status_16e=$(run16 "$HOME_16E" "$STUB16_PATH" "$SANDBOX/proc-version-linux16" "" "Linux")
out_16e=$(cat "$SANDBOX/out16")
check "case e: returns success" "0" "$status_16e"
contains "case e: reports the tailnet IP" " > Tailscale is up: 100.64.0.1" "$out_16e"
curl_calls_16e=$(grep -c '^curl ' "$TS_LOG")
check "case e: curl is not called" "0" "$curl_calls_16e"

# Case (f): tailscale present, status fails -> auth steps with sudo tailscale
# up and the operator line.
HOME_16F="$SANDBOX/home16f"
mkdir -p "$HOME_16F"
write_tailscale_stub
: >"$TS_LOG"
export TS_STATUS_EXIT=1
status_16f=$(run16 "$HOME_16F" "$STUB16_PATH" "$SANDBOX/proc-version-linux16" "" "Linux")
out_16f=$(cat "$SANDBOX/out16")
check "case f: returns success" "0" "$status_16f"
contains "case f: prints the not-logged-in auth steps" \
	" > Tailscale is installed but not logged in. Authenticate once (opens a browser URL):" "$out_16f"
contains "case f: auth steps include sudo tailscale up" "sudo tailscale up" "$out_16f"
contains "case f: auth steps include the operator line" \
	"sudo tailscale set --operator=" "$out_16f"
curl_calls_16f=$(grep -c '^curl ' "$TS_LOG")
check "case f: curl is not called" "0" "$curl_calls_16f"

# Case (g): curl fails -> failure hint, status 0.
HOME_16G="$SANDBOX/home16g"
mkdir -p "$HOME_16G"
rm -f "$TS_BIN_DIR/tailscale"
: >"$TS_LOG"
export TS_SUDO_PASSWORDLESS=1 TS_CURL_FAIL=1 TS_STATUS_EXIT=1
status_16g=$(run16 "$HOME_16G" "$STUB16_PATH" "$SANDBOX/proc-version-linux16" "" "Linux")
out_16g=$(cat "$SANDBOX/out16")
check "case g: returns success" "0" "$status_16g"
contains "case g: prints a failure hint" \
	"curl -fsSL https://tailscale.com/install.sh | sh" "$out_16g"
export TS_CURL_FAIL=0

# ==============================================================================
# Case (h) / ordering -- 04-brew-packages.sh must sort before 06-gentle-ai-
# state.sh, 07-node.sh, 08-pi.sh, 09-gentle-ai-sync.sh, 10-moshi-remote.sh,
# 11-codegraph.sh, 12-agent-integrations.sh and 14-claude-statusline.sh, the
# renamed/new scripts must be committed executable, and every old name must be
# gone.
# ==============================================================================
echo
echo "restoration_scripts ordering"

ordered=$(cd "$DOTFILES_PATH/restoration_scripts" && ls -- *.sh | sort | grep -E '^(04|06|07|08|09|10|11|12|14|15|16)-')
expected_order="04-brew-packages.sh
04-claude-code.sh
06-gentle-ai-state.sh
07-node.sh
08-pi.sh
09-gentle-ai-sync.sh
10-moshi-remote.sh
11-codegraph.sh
12-agent-integrations.sh
14-claude-statusline.sh
15-rust.sh
16-tailscale.sh"
check "case h: 04 sorts before 06, 07, 08, 09, 10, 11, 12, 14, 15 and 16-tailscale.sh sorts last" "$expected_order" "$ordered"
[ -x "$SCRIPT_15" ] && script_15_exec=yes || script_15_exec=no
check "15-rust.sh is executable" "yes" "$script_15_exec"
[ -x "$SCRIPT_16" ] && script_16_exec=yes || script_16_exec=no
check "case h: 16-tailscale.sh is executable" "yes" "$script_16_exec"
[ -x "$SCRIPT_04" ] && script_04_exec=yes || script_04_exec=no
check "04-brew-packages.sh is executable" "yes" "$script_04_exec"
[ -x "$SCRIPT_04_CLAUDE" ] && script_04_claude_exec=yes || script_04_claude_exec=no
check "case g: 04-claude-code.sh sorts after 04-brew-packages.sh and before 08-pi.sh, and is executable" "yes" "$script_04_claude_exec"

claude_cask_in_brewfile=$(grep -c 'cask "claude-code"' "$BREWFILE")
check "case h: the Brewfile no longer declares cask \"claude-code\"" "0" "$claude_cask_in_brewfile"
[ -x "$SCRIPT_08" ] && script_08_exec=yes || script_08_exec=no
check "08-pi.sh is executable" "yes" "$script_08_exec"
[ -x "$SCRIPT_09" ] && script_09_exec=yes || script_09_exec=no
check "09-gentle-ai-sync.sh is executable" "yes" "$script_09_exec"
[ -x "$DOTFILES_PATH/restoration_scripts/01-wslconfig.sh" ] && script_01_exec=yes || script_01_exec=no
check "01-wslconfig.sh is executable" "yes" "$script_01_exec"

for _old_name in 06-claude-statusline.sh 07-gentle-ai-state.sh 08-node.sh \
	01-sample_script.sh 09-wslconfig.sh 08-gentle-ai-sync.sh; do
	[ -e "$DOTFILES_PATH/restoration_scripts/$_old_name" ] && old_present=yes || old_present=no
	check "$_old_name no longer exists" "no" "$old_present"
done
unset _old_name old_present

# --- shell/zsh/.zshenv: Homebrew on PATH for non-interactive sessions ---------
# mosh and the Moshi app start mosh-server through `ssh host mosh-server ...`,
# a non-interactive zsh that reads only .zshenv. Measured on the VM: with brew's
# bin missing there, `command -v mosh-server` failed over SSH.
if command -v zsh >/dev/null 2>&1; then
	ZSHENV="$DOTFILES_PATH/shell/zsh/.zshenv"
	fake_brew="$SANDBOX/zshenv-brew/bin"
	mkdir -p "$fake_brew"
	printf '#!/bin/sh\n' >"$fake_brew/mosh-server"
	chmod +x "$fake_brew/mosh-server"
	zshenv_found=$(env -i HOME="$SANDBOX" PATH=/usr/bin:/bin ZSHENV_BREW_BINS="$fake_brew" \
		zsh -fc ". \"$ZSHENV\"; command -v mosh-server" 2>/dev/null)
	check ".zshenv puts Homebrew's bin on PATH for non-interactive zsh" "$fake_brew/mosh-server" "$zshenv_found"
	zshenv_path=$(env -i HOME="$SANDBOX" PATH="$fake_brew:/usr/bin:/bin" ZSHENV_BREW_BINS="$fake_brew" \
		zsh -fc ". \"$ZSHENV\"; . \"$ZSHENV\"; print -r -- \$PATH" 2>/dev/null)
	check ".zshenv does not duplicate a PATH entry" "$fake_brew:/usr/bin:/bin" "$zshenv_path"
	zshenv_missing=$(env -i HOME="$SANDBOX" PATH=/usr/bin:/bin ZSHENV_BREW_BINS="$SANDBOX/no-such-brew/bin" \
		zsh -fc ". \"$ZSHENV\"; print -r -- \$PATH" 2>/dev/null)
	check ".zshenv skips a Homebrew prefix that does not exist" "/usr/bin:/bin" "$zshenv_missing"
	unset ZSHENV fake_brew zshenv_found zshenv_path zshenv_missing
fi

echo
if [ "$tests_failed" -eq 0 ]; then
	echo "$tests_run passed"
else
	echo "$tests_failed of $tests_run failed"
fi
exit $((tests_failed > 0))
