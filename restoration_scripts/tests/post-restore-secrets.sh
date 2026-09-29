#!/usr/bin/env bash
# Regression tests for scripts/post-restore-secrets, the guided walkthrough for
# the manual logins/keys/sudo steps that `dot self install` cannot do
# unattended.
#
# Nothing here touches the real machine or network. Every external command it
# could call (gh, ssh, ssh-keygen, pi, claude, codex, opencode, engram,
# tailscale, sudo, systemctl, getent, uname, hostname, curl) is stubbed onto
# PATH, driven by env vars and fixture files, inside a disposable HOME.
# `setsid` detaches the test process from any controlling terminal so the
# script's own /dev/tty probe reliably falls back to the piped stdin used to
# feed answers.
#
# THIS FILE IS NOT PART OF THE RESTORE. Run it by hand:
#
#     ./restoration_scripts/tests/post-restore-secrets.sh
#
# Exits non-zero if any case fails.

set -u
DOTFILES_PATH="${DOTFILES_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
export DOTFILES_PATH
SCRIPT="$DOTFILES_PATH/scripts/post-restore-secrets"

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

echo "post-restore-secrets tests"
echo

# --- the sandbox --------------------------------------------------------------
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/stub"

# Every stub logs its argv to "$LOG_DIR/<name>.log" (LOG_DIR is reset per
# test) and answers status queries from env vars, defaulting to "pending" so a
# test that forgets to set one fails loudly instead of silently passing.
cat >"$SANDBOX/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$LOG_DIR/gh.log"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
	if [ -n "${GH_ACCOUNT_NAME:-}" ]; then
		echo "✓ Logged in to github.com account ${GH_ACCOUNT_NAME} (keyring)"
	fi
	exit "${GH_STATUS:-1}"
fi
exit 0
STUB

cat >"$SANDBOX/stub/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex $*" >>"$LOG_DIR/codex.log"
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then exit "${CODEX_STATUS:-1}"; fi
exit 0
STUB

cat >"$SANDBOX/stub/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude $*" >>"$LOG_DIR/claude.log"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
	if [ "${CLAUDE_LOGGED_IN:-0}" = 1 ]; then
		if [ -n "${CLAUDE_ORG:-}" ]; then
			printf '{ "loggedIn": true, "email": "%s", "orgName": "%s" }\n' "${CLAUDE_EMAIL:-}" "${CLAUDE_ORG:-}"
		else
			printf '{ "loggedIn": true, "email": "%s" }\n' "${CLAUDE_EMAIL:-}"
		fi
	else
		echo '{ "loggedIn": false }'
	fi
	exit 0
fi
exit 0
STUB

cat >"$SANDBOX/stub/opencode" <<'STUB'
#!/usr/bin/env bash
echo "opencode $*" >>"$LOG_DIR/opencode.log"
exit 0
STUB

cat >"$SANDBOX/stub/engram" <<'STUB'
#!/usr/bin/env bash
echo "engram $*" >>"$LOG_DIR/engram.log"
if [ "${1:-}" = cloud ] && [ "${2:-}" = status ]; then
	if [ "${ENGRAM_READY:-0}" = 1 ]; then
		echo "Auth status: ready"
	else
		echo "Auth status: missing"
	fi
	exit 0
fi
exit 0
STUB

cat >"$SANDBOX/stub/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "tailscale $*" >>"$LOG_DIR/tailscale.log"
if [ "${1:-}" = status ]; then
	if printf '%s\n' "$*" | grep -q -- '--json'; then
		if [ -n "${TAILSCALE_LOGIN_NAME:-}" ]; then
			printf '{"Self":{"UserID":123},"User":{"123":{"LoginName":"%s"}}}\n' "${TAILSCALE_LOGIN_NAME}"
		else
			echo '{}'
		fi
		exit 0
	fi
	exit "${TAILSCALE_STATUS:-1}"
fi
exit 0
STUB

cat >"$SANDBOX/stub/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG_DIR/sudo.log"
if [ "${1:-}" = sshd ]; then echo "passwordauthentication no"; fi
exit 0
STUB

cat >"$SANDBOX/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG_DIR/systemctl.log"
if [ "${1:-}" = --user ] && [ "${2:-}" = list-unit-files ]; then
	[ "${ENGRAM_UNIT_EXISTS:-0}" = 1 ] && echo "engram-serve.service enabled"
fi
exit 0
STUB

cat >"$SANDBOX/stub/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh $*" >>"$LOG_DIR/ssh.log"
# Real ssh prints both messages on stderr, not stdout.
if [ "${SSH_GH_OK:-0}" = 1 ]; then
	echo "Hi ${SSH_HI_NAME:-test-user}! You've successfully authenticated, but GitHub does not provide shell access." >&2
else
	echo "Permission denied (publickey)." >&2
fi
exit 0
STUB

cat >"$SANDBOX/stub/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
echo "ssh-keygen $*" >>"$LOG_DIR/ssh-keygen.log"
prev=""
for a in "$@"; do
	if [ "$prev" = "-f" ]; then
		: >"$a"
		echo "ssh-ed25519 FAKEFAKEFAKE stub" >"$a.pub"
	fi
	prev="$a"
done
exit 0
STUB

cat >"$SANDBOX/stub/pi" <<'STUB'
#!/usr/bin/env bash
echo "pi $*" >>"$LOG_DIR/pi.log"
exit 0
STUB

cat >"$SANDBOX/stub/moshi-hook" <<'STUB'
#!/usr/bin/env bash
echo "moshi-hook $*" >>"$LOG_DIR/moshi-hook.log"
if [ "${1:-}" = status ]; then
	printf '%s\n' "${MOSHI_STATUS_LINE:-status: unpaired}"
	[ -n "${MOSHI_DISPLAY_NAME:-}" ] && printf 'display name: %s\n' "${MOSHI_DISPLAY_NAME}"
fi
exit 0
STUB

cat >"$SANDBOX/stub/getent" <<'STUB'
#!/usr/bin/env bash
echo "getent $*" >>"$LOG_DIR/getent.log"
if [ "${1:-}" = passwd ]; then
	echo "${2}:x:1000:1000::/home/${2}:${LOGIN_SHELL:-/bin/bash}"
fi
exit 0
STUB

cat >"$SANDBOX/stub/uname" <<'STUB'
#!/usr/bin/env bash
echo "${FAKE_UNAME:-Linux}"
STUB

cat >"$SANDBOX/stub/hostname" <<'STUB'
#!/usr/bin/env bash
echo "testhost"
STUB

cat >"$SANDBOX/stub/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$LOG_DIR/curl.log"
exit 0
STUB

chmod +x "$SANDBOX/stub"/*
PATH="$SANDBOX/stub:$PATH"
export PATH

# zerotier-cli lives in a separate directory, NOT on the default PATH: tests
# that need it "present" prepend $SANDBOX/stub-zt just for that one
# run_secrets call, so every other test keeps seeing it as genuinely missing.
mkdir -p "$SANDBOX/stub-zt"
cat >"$SANDBOX/stub-zt/zerotier-cli" <<'STUB'
#!/usr/bin/env bash
echo "zerotier-cli $*" >>"$LOG_DIR/zerotier-cli.log"
if [ "${1:-}" = listnetworks ]; then
	if [ "${ZT_NETWORK_STATUS:-NONE}" = OK ]; then
		echo "200 listnetworks 0123456789abcdef fakenet 00:00:00:00:00 OK PRIVATE zt0 10.147.17.5/24"
	else
		echo "200 listnetworks 0123456789abcdef fakenet 00:00:00:00:00 REQUESTING_CONFIGURATION PRIVATE zt0 -"
	fi
fi
exit 0
STUB
chmod +x "$SANDBOX/stub-zt/zerotier-cli"

# --- helpers -------------------------------------------------------------------
# Fresh, empty HOME/log dir/fixture DOTFILES_PATH per test so nothing leaks
# between cases; every controllable stub env var is reset to "unset" first so a
# test that forgets to set one gets the loud "pending" default, never a stale
# value from a previous case.
reset_test_env() {
	# Exported once as empty here so a later plain "VAR=value" assignment (no
	# `export` needed at each call site) still reaches the stub subprocesses --
	# an empty value is indistinguishable from unset to every "${VAR:-default}"
	# read in the script under test.
	export GH_STATUS="" CODEX_STATUS="" CLAUDE_LOGGED_IN="" ENGRAM_READY="" ENGRAM_UNIT_EXISTS=""
	export TAILSCALE_STATUS="" SSH_GH_OK="" LOGIN_SHELL="" FAKE_UNAME="" MOSHI_STATUS_LINE=""
	export ZT_NETWORK_STATUS=""
	export POST_RESTORE_ONLY="" POST_RESTORE_PROC_VERSION_FILE="" SSHD_DROPIN_DIR=""
	export GH_ACCOUNT_NAME="" CLAUDE_EMAIL="" CLAUDE_ORG="" SSH_HI_NAME=""
	export TAILSCALE_LOGIN_NAME="" MOSHI_DISPLAY_NAME="" NO_ACCOUNTS=""
	TEST_HOME=$(mktemp -d)
	LOG_DIR=$(mktemp -d)
	export LOG_DIR
	FIXTURE_DOTFILES=$(mktemp -d)
	mkdir -p "$FIXTURE_DOTFILES/ssh" "$FIXTURE_DOTFILES/os/linux/ssh" "$FIXTURE_DOTFILES/restoration_scripts"
	: >"$FIXTURE_DOTFILES/ssh/config"
	cat >"$FIXTURE_DOTFILES/os/linux/ssh/00-moshi.conf" <<'CONF'
PasswordAuthentication no
PubkeyAuthentication yes
CONF
	echo "exit 0" >"$FIXTURE_DOTFILES/restoration_scripts/11-codegraph.sh"
}

# run_secrets <stdin> [args...] -- sets $OUTPUT and $RC. setsid drops the
# controlling terminal so the script's /dev/tty probe reliably fails and it
# falls back to reading the piped stdin carrying the fed answers.
run_secrets() {
	local input="$1"
	shift
	OUTPUT=$(HOME="$TEST_HOME" DOTFILES_PATH="$FIXTURE_DOTFILES" \
		printf '%s' "$input" | HOME="$TEST_HOME" DOTFILES_PATH="$FIXTURE_DOTFILES" \
		setsid "$SCRIPT" "$@" 2>&1)
	RC=$?
}

log_of() { cat "$LOG_DIR/$1.log" 2>/dev/null; }

# Builds a syntactically valid but unsigned JWT (header.payload.SIGNATURE) from
# a JSON payload, purely so account-detection probes have something real to
# base64url-decode. Never a genuine credential.
make_jwt() {
	local payload_json="$1" header='{"alg":"none","typ":"JWT"}' h p
	h=$(printf '%s' "$header" | base64 | tr -d '\n=' | tr '+/' '-_')
	p=$(printf '%s' "$payload_json" | base64 | tr -d '\n=' | tr '+/' '-_')
	printf '%s.%s.FAKESIGNATURE' "$h" "$p"
}

# ==============================================================================
# --check: everything done -> every row is ✓, exit 0
# ==============================================================================
echo "--check: everything done"
reset_test_env
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
GH_STATUS=0
CODEX_STATUS=0
CLAUDE_LOGGED_IN=1
ENGRAM_READY=1
TAILSCALE_STATUS=0
SSH_GH_OK=1
LOGIN_SHELL=/usr/bin/zsh
MOSHI_STATUS_LINE="status: paired"
mkdir -p "$TEST_HOME/.pi/agent" "$TEST_HOME/.local/share/opencode" "$TEST_HOME/.engram" "$TEST_HOME/.ssh"
echo '{"openai-codex": {}}' >"$TEST_HOME/.pi/agent/auth.json"
echo '{"anthropic": "x"}' >"$TEST_HOME/.local/share/opencode/auth.json"
echo '{}' >"$TEST_HOME/.engram/cloud.json"
echo '{"mcpServers": {"codegraph": {}}}' >"$TEST_HOME/.claude.json"
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/id_github
CONF
: >"$TEST_HOME/.ssh/id_github"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/id_github.pub"
SSHD_DROPIN_DIR="$TEST_HOME/sshd-dropin"
mkdir -p "$SSHD_DROPIN_DIR"
cp "$FIXTURE_DOTFILES/os/linux/ssh/00-moshi.conf" "$SSHD_DROPIN_DIR/00-moshi.conf"
export SSHD_DROPIN_DIR
echo "some-key" >"$TEST_HOME/.ssh/authorized_keys"

run_secrets "" --check
check "everything-done exit code is 0" "0" "$RC"
done_count=$(printf '%s' "$OUTPUT" | grep -c '✓')
check "everything-done: every one of the 11 required steps shows ✓" "11" "$done_count"
not_contains "everything-done: no row says pending" "pending" "$OUTPUT"
contains "everything-done: zerotier is untouched and optional, not configured" \
	"optional (not configured)" "$OUTPUT"
check "everything-done: zerotier-cli was never even probed" "" "$(log_of zerotier-cli)"

# Same machine without cloud sync: engram-cloud is optional, so still done.
rm -f "$TEST_HOME/.engram/cloud.json"
ENGRAM_READY=0
run_secrets "" --check
contains "engram-cloud unconfigured shows optional" "engram-cloud      optional (not configured)" "$OUTPUT"
check "engram-cloud unconfigured does not fail --check" "0" "$RC"
ENGRAM_READY=1

echo
# ==============================================================================
# --check: everything pending -> every step listed pending, exit 1, only
# status probes ran (nothing that logs in or mutates).
# ==============================================================================
echo "--check: everything pending"
reset_test_env
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
GH_STATUS=1
CODEX_STATUS=1
CLAUDE_LOGGED_IN=0
TAILSCALE_STATUS=1
LOGIN_SHELL=/bin/bash
MOSHI_STATUS_LINE="status: unpaired"
mkdir -p "$TEST_HOME/.ssh"
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/id_github
CONF
echo "ssh-ed25519 AAAAFAKEKEY placeholder" >"$TEST_HOME/.ssh/authorized_keys"
SSHD_DROPIN_DIR="$TEST_HOME/sshd-dropin"
export SSHD_DROPIN_DIR

run_secrets "" --check
check "everything-pending exit code is 1" "1" "$RC"
pending_count=$(printf '%s' "$OUTPUT" | grep -c 'pending')
check "everything-pending: the 10 non-optional-cloud steps mention pending" "10" "$pending_count"
contains "everything-pending: engram-cloud is optional, not pending" "engram-cloud      optional (not configured)" "$OUTPUT"
check "no gh login was attempted" "" "$(log_of gh | grep -v 'auth status' || true)"
check "no ssh-keygen ran" "" "$(log_of ssh-keygen)"
check "no pi launch ran" "" "$(log_of pi)"
check "no claude login was attempted" "" "$(log_of claude | grep -v 'auth status' || true)"
check "no codex login was attempted" "" "$(log_of codex | grep -v 'login status' || true)"
check "no opencode login was attempted" "" "$(log_of opencode)"
check "no tailscale up was attempted" "" "$(log_of tailscale | grep -vE '^tailscale status( --json)?$' || true)"
check "sudo was never called" "" "$(log_of sudo)"
check "systemctl was never called" "" "$(log_of systemctl)"
check "moshi-hook pairing was never run" "" "$(log_of moshi-hook | grep -vE '^moshi-hook status$' || true)"
check "zerotier-cli was never touched" "" "$(log_of zerotier-cli)"

echo
# ==============================================================================
# Interactive: answering "y" for gh runs the exact login args
# ==============================================================================
echo "interactive: gh"
reset_test_env
GH_STATUS=1
POST_RESTORE_ONLY=gh
run_secrets "y
" 
contains "gh login command ran with the exact args" \
	"gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key --scopes admin:public_key" \
	"$(log_of gh)"

echo
# ==============================================================================
# ssh-keys: parses IdentityFile entries from a two-host fixture config,
# generates missing keys with exact args, and only offers `gh ssh-key add`
# for the github.com host.
# ==============================================================================
echo "ssh-keys: parsing and per-host behaviour"
reset_test_env
POST_RESTORE_ONLY=ssh-keys
GH_STATUS=0
SSH_GH_OK=1
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_github
  IdentitiesOnly yes

Host example.org
  HostName example.org
  User git
  IdentityFile ~/.ssh/id_example
CONF
# 4 prompts in order: generate(github), add-to-gh(github), generate(example.org),
# label for the example.org key (Enter = none, keeping the plain user@host
# comment so the exact-args assertions below stay unchanged).
run_secrets "y
y
y

"
expected_user="$(id -un)"
contains "keygen ran for the github.com key with the exact args" \
	"ssh-keygen -t ed25519 -f $TEST_HOME/.ssh/id_github -C ${expected_user}@testhost" \
	"$(log_of ssh-keygen)"
contains "keygen ran for the example.org key with the exact args" \
	"ssh-keygen -t ed25519 -f $TEST_HOME/.ssh/id_example -C ${expected_user}@testhost" \
	"$(log_of ssh-keygen)"
contains "gh ssh-key add ran for the github.com key" \
	"ssh-key add $TEST_HOME/.ssh/id_github.pub --title testhost" \
	"$(log_of gh)"
not_contains "gh ssh-key add did NOT run for the non-github host" \
	"id_example" "$(log_of gh)"

echo
# ==============================================================================
# ssh-keys: the summary/menu tables show one row per (host, IdentityFile) pair,
# never a single aggregate "ssh-keys" row.
# ==============================================================================
echo "ssh-keys: table shows one row per key, not one aggregate row"
reset_test_env
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
export POST_RESTORE_PROC_VERSION_FILE
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github-hlclarog
  IdentitiesOnly yes

Host bitbucket.org
  HostName bitbucket.org
  User git
  IdentityFile ~/.ssh/bit-hclaro
  IdentitiesOnly yes
CONF
mkdir -p "$TEST_HOME/.ssh"
: >"$TEST_HOME/.ssh/github-hlclarog"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/github-hlclarog.pub"
SSH_GH_OK=1
SSH_HI_NAME=testuser
run_secrets "" --check
not_contains "no row is literally named ssh-keys" "ssh-keys" "$OUTPUT"
gh_row=$(printf '%s\n' "$OUTPUT" | grep -E '^ssh:github\.com[[:space:]]')
contains "github.com row shows done" "✓" "$gh_row"
contains "github.com row account is the Hi-name, without a github: prefix" "testuser" "$gh_row"
not_contains "github.com row account has no github: prefix" "github:" "$gh_row"
bb_row=$(printf '%s\n' "$OUTPUT" | grep -E '^ssh:bitbucket\.org[[:space:]]')
contains "bitbucket.org row shows pending (key missing)" "pending" "$bb_row"
contains "bitbucket.org row account is a dash while the key is missing" "-" "$bb_row"

echo "ssh-keys: a non-github row's account comes from the .pub comment label"
reset_test_env
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
mkdir -p "$TEST_HOME/.ssh"
: >"$TEST_HOME/.ssh/bit-hclaro"
echo "ssh-ed25519 FAKE user@host personal" >"$TEST_HOME/.ssh/bit-hclaro.pub"
run_secrets "" --check
bb_row=$(printf '%s\n' "$OUTPUT" | grep -E '^ssh:bitbucket\.org[[:space:]]')
contains "bitbucket.org row account is the pub comment label" "personal" "$bb_row"

echo
# ==============================================================================
# --check: the exit code depends on the per-key ssh rows, not an aggregate.
# Scoped with POST_RESTORE_ONLY=ssh-keys so only the ssh rows affect $RC here.
# ==============================================================================
echo "--check: exit 1 when only the bitbucket row is pending"
reset_test_env
POST_RESTORE_ONLY=ssh-keys
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/github-hlclarog
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
mkdir -p "$TEST_HOME/.ssh"
: >"$TEST_HOME/.ssh/github-hlclarog"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/github-hlclarog.pub"
SSH_GH_OK=1
run_secrets "" --check
check "exit code is 1 with the bitbucket key missing" "1" "$RC"

echo "--check: exit 0 once both keys exist"
: >"$TEST_HOME/.ssh/bit-hclaro"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/bit-hclaro.pub"
run_secrets "" --check
check "exit code is 0 with both keys present" "0" "$RC"

echo
# ==============================================================================
# POST_RESTORE_ONLY=ssh:<host> processes only that one key.
# ==============================================================================
echo "POST_RESTORE_ONLY=ssh:bitbucket.org processes only the bitbucket key"
reset_test_env
POST_RESTORE_ONLY=ssh:bitbucket.org
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/github-hlclarog
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
run_secrets "y
personal
"
keygen_log=$(log_of ssh-keygen)
bit_calls=$(printf '%s\n' "$keygen_log" | grep -c -- "-f $TEST_HOME/.ssh/bit-hclaro " || true)
check "exactly one ssh-keygen call for the bitbucket key" "1" "$bit_calls"
not_contains "no ssh-keygen call touched the github key" "github-hlclarog" "$keygen_log"
contains "the keygen comment ends with the entered label" "-C $(id -un)@testhost personal" "$keygen_log"
contains "the new bitbucket public key is printed" "ssh-ed25519 FAKEFAKEFAKE stub" "$OUTPUT"
check "gh was never touched (not a github host)" "" "$(log_of gh)"

echo
# ==============================================================================
# claude: already logged in, ~/.claude.json exists without the codegraph MCP
# entry -> restoration script 11 is re-run to register it.
# ==============================================================================
echo "claude: triggers codegraph registration"
reset_test_env
POST_RESTORE_ONLY=claude
CLAUDE_LOGGED_IN=1
echo '{"foo": 1}' >"$TEST_HOME/.claude.json"
cat >"$FIXTURE_DOTFILES/restoration_scripts/11-codegraph.sh" <<STUB
echo "codegraph11 invoked" >>"$LOG_DIR/codegraph11.log"
STUB
run_secrets ""
check "script 11 was invoked to register the codegraph MCP server" \
	"codegraph11 invoked" "$(log_of codegraph11)"

echo
# ==============================================================================
# claude: already registers codegraph -> script 11 is NOT re-run
# ==============================================================================
echo "claude: codegraph already registered"
reset_test_env
POST_RESTORE_ONLY=claude
CLAUDE_LOGGED_IN=1
echo '{"mcpServers": {"codegraph": {}}}' >"$TEST_HOME/.claude.json"
cat >"$FIXTURE_DOTFILES/restoration_scripts/11-codegraph.sh" <<STUB
echo "codegraph11 invoked" >>"$LOG_DIR/codegraph11.log"
STUB
run_secrets ""
check "script 11 was left untouched" "" "$(log_of codegraph11)"

echo
# ==============================================================================
# engram: token is read silently, cloud.json is written with exact keys and
# mode 600, and the token never reaches stdout.
# ==============================================================================
echo "engram: credential capture"
reset_test_env
POST_RESTORE_ONLY=engram-cloud
TOKEN="s3cret-test-token-value"
run_secrets "y
https://example.test/engram
$TOKEN
"
check "cloud.json was written" "yes" "$([ -f "$TEST_HOME/.engram/cloud.json" ] && echo yes || echo no)"
mode=$(stat -c '%a' "$TEST_HOME/.engram/cloud.json" 2>/dev/null)
check "cloud.json mode is 600" "600" "$mode"
keys=$(jq -c -S 'keys' "$TEST_HOME/.engram/cloud.json" 2>/dev/null)
check "cloud.json has exactly server_url and token" '["server_url","token"]' "$keys"
server_url=$(jq -r '.server_url' "$TEST_HOME/.engram/cloud.json" 2>/dev/null)
check "cloud.json stores the entered server URL" "https://example.test/engram" "$server_url"
not_contains "the token never appears in the script output" "$TOKEN" "$OUTPUT"

# The step id is what --check prints, so it names the cloud sync explicitly.
reset_test_env
run_secrets "" --check
contains "--check names the step engram-cloud" "engram-cloud" "$OUTPUT"


echo
# ==============================================================================
# tailscale: skipped on WSL and on Darwin, in both cases without exit 1
# ==============================================================================
echo "tailscale: platform skip"
reset_test_env
POST_RESTORE_ONLY=tailscale
printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' >"$SANDBOX/proc-version-wsl"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-wsl"
export POST_RESTORE_PROC_VERSION_FILE
run_secrets "" --check
contains "tailscale is skipped on WSL" "skip" "$OUTPUT"
check "WSL skip does not fail --check" "0" "$RC"
check "tailscale status was never even probed on WSL" "" "$(log_of tailscale)"

reset_test_env
POST_RESTORE_ONLY=tailscale
FAKE_UNAME=Darwin
run_secrets "" --check
contains "tailscale is skipped on Darwin" "skip" "$OUTPUT"
check "Darwin skip does not fail --check" "0" "$RC"

echo
# ==============================================================================
# zerotier: strictly optional fallback. It must never be counted as pending
# and must never affect the exit code, whether or not zerotier-cli is even
# installed.
# ==============================================================================
echo "zerotier: --check without zerotier-cli is optional, not pending"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
run_secrets "" --check
contains "zerotier reports optional, not configured" "optional (not configured)" "$OUTPUT"
not_contains "zerotier is never reported as pending" "pending" "$OUTPUT"
check "a missing zerotier-cli does not fail --check" "0" "$RC"

echo "zerotier: --check with an OK network shows ✓"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
ZT_NETWORK_STATUS=OK
PATH="$SANDBOX/stub-zt:$PATH" run_secrets "" --check
contains "zerotier shows ✓ once an OK network is joined" "✓" "$OUTPUT"
check "an OK network keeps --check at exit 0" "0" "$RC"

echo
# ==============================================================================
# zerotier: skipped on WSL and Darwin, exactly like tailscale, with no calls
# ==============================================================================
echo "zerotier: platform skip"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' >"$SANDBOX/proc-version-wsl"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-wsl"
export POST_RESTORE_PROC_VERSION_FILE
run_secrets "" --check
contains "zerotier is skipped on WSL" "skip" "$OUTPUT"
check "WSL skip does not fail --check" "0" "$RC"
check "zerotier-cli was never even probed on WSL" "" "$(log_of zerotier-cli)"

reset_test_env
POST_RESTORE_ONLY=zerotier
FAKE_UNAME=Darwin
run_secrets "" --check
contains "zerotier is skipped on Darwin" "skip" "$OUTPUT"
check "Darwin skip does not fail --check" "0" "$RC"
check "zerotier-cli was never even probed on Darwin" "" "$(log_of zerotier-cli)"

echo
# ==============================================================================
# zerotier: interactive Enter/"n" -- the default is NO, and nothing at all
# runs: no curl, no sudo, no zerotier-cli.
# ==============================================================================
echo "zerotier: Enter (default) declines"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
run_secrets "
"
check "no curl ran" "" "$(log_of curl)"
check "no sudo ran" "" "$(log_of sudo)"
check "no zerotier-cli ran" "" "$(log_of zerotier-cli)"

echo "zerotier: explicit 'n' declines"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
run_secrets "n
"
check "no curl ran" "" "$(log_of curl)"
check "no sudo ran" "" "$(log_of sudo)"
check "no zerotier-cli ran" "" "$(log_of zerotier-cli)"

echo
# ==============================================================================
# zerotier: 'y' with zerotier-cli missing offers the official installer,
# downloaded with curl -fsSL to a temp file and run with `sudo bash`.
# ==============================================================================
echo "zerotier: 'y' + missing zerotier-cli runs the official installer"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
run_secrets "y
y
"
contains "the official installer is fetched with curl -fsSL" \
	"curl -fsSL https://install.zerotier.com" "$(log_of curl)"
sudo_bash_line=$(log_of sudo | grep -E '^sudo bash /' || true)
check "sudo bash ran against the downloaded installer file" "yes" "$([ -n "$sudo_bash_line" ] && echo yes || echo no)"
check "zerotier-cli itself was never invoked (still not installed)" "" "$(log_of zerotier-cli)"

echo
# ==============================================================================
# zerotier: a valid 16-hex-digit network ID runs exactly one join command
# ==============================================================================
echo "zerotier: valid network ID joins"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
PATH="$SANDBOX/stub-zt:$PATH" run_secrets "y
0123456789abcdef
"
contains "sudo zerotier-cli join ran with the exact network ID" \
	"sudo zerotier-cli join 0123456789abcdef" "$(log_of sudo)"

echo
# ==============================================================================
# zerotier: an invalid network ID, re-asked once and still invalid, never
# joins anything
# ==============================================================================
echo "zerotier: invalid network ID twice skips the join"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
PATH="$SANDBOX/stub-zt:$PATH" run_secrets "y
not-hex
still-not-hex
"
not_contains "no join command was ever attempted" "join" "$(log_of sudo)"

echo
# ==============================================================================
# POST_RESTORE_ONLY=zerotier runs only zerotier, nothing else is even probed
# ==============================================================================
echo "POST_RESTORE_ONLY=zerotier"
reset_test_env
POST_RESTORE_ONLY=zerotier
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
run_secrets "n
"
check "gh was never touched" "" "$(log_of gh)"
check "tailscale was never touched" "" "$(log_of tailscale)"
check "claude was never touched" "" "$(log_of claude)"
check "moshi-hook was never touched" "" "$(log_of moshi-hook)"

echo
# ==============================================================================
# sshd: skipped with a warning when authorized_keys is empty/missing, and
# never calls sudo -- applying hardening first could lock the user out.
# ==============================================================================
echo "sshd: skipped without authorized_keys"
reset_test_env
POST_RESTORE_ONLY=sshd
SSHD_DROPIN_DIR="$TEST_HOME/sshd-dropin"
mkdir -p "$SSHD_DROPIN_DIR"
export SSHD_DROPIN_DIR
# ~/.ssh/authorized_keys deliberately absent
run_secrets ""
contains "sshd step reports a skip warning" "authorized_keys" "$OUTPUT"
check "sudo was never called" "" "$(log_of sudo)"

echo
# ==============================================================================
# moshi: "status: unpaired" must NOT be treated as paired (the substring
# "paired" appears inside "unpaired").
# ==============================================================================
echo "moshi: unpaired is not paired"
reset_test_env
POST_RESTORE_ONLY=moshi
MOSHI_STATUS_LINE="status: unpaired"
run_secrets "" --check
not_contains "moshi is not reported done while unpaired" "✓" "$OUTPUT"
contains "moshi still reports pending information" "pending" "$OUTPUT"
check "an unpaired-but-optional moshi does not fail --check" "0" "$RC"

echo
# ==============================================================================
# POST_RESTORE_ONLY=codex runs only codex, nothing else is even probed.
# ==============================================================================
echo "POST_RESTORE_ONLY=codex"
reset_test_env
POST_RESTORE_ONLY=codex
CODEX_STATUS=1
run_secrets "n
"
contains "codex step ran its status check" "login status" "$(log_of codex)"
check "gh was never touched" "" "$(log_of gh)"
check "claude was never touched" "" "$(log_of claude)"
check "opencode was never touched" "" "$(log_of opencode)"
check "ssh-keygen was never touched" "" "$(log_of ssh-keygen)"

echo
# ==============================================================================
# Answering "n" skips the action; the step stays pending in the summary.
# ==============================================================================
echo "interactive: answering n leaves the step pending"
reset_test_env
POST_RESTORE_ONLY=gh
GH_STATUS=1
run_secrets "n
"
check "gh login was never run" "" "$(log_of gh | grep -v 'auth status' || true)"
contains "the final summary still lists gh as pending" "pending" "$OUTPUT"

echo
# ==============================================================================
# table: ACCOUNT column is populated by default and --no-accounts skips every
# account probe (fast mode), while leaving --check's exit-code semantics and
# status probes untouched.
# ==============================================================================
echo "table: ACCOUNT column and --no-accounts fast mode"
reset_test_env
POST_RESTORE_ONLY=tailscale
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
export POST_RESTORE_PROC_VERSION_FILE
TAILSCALE_STATUS=0
TAILSCALE_LOGIN_NAME="account.probe@example.test"
run_secrets "" --check
account_probe_calls=$(log_of tailscale | grep -c -- '--json' || true)
check "the account probe (tailscale status --json) ran once by default" "1" "$account_probe_calls"
contains "the ACCOUNT column shows the detected login name" "account.probe@example.test" "$OUTPUT"

reset_test_env
POST_RESTORE_ONLY=tailscale
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
export POST_RESTORE_PROC_VERSION_FILE
TAILSCALE_STATUS=0
TAILSCALE_LOGIN_NAME="account.probe@example.test"
run_secrets "" --check --no-accounts
account_probe_calls=$(log_of tailscale | grep -c -- '--json' || true)
check "--no-accounts skips the account probe entirely" "0" "$account_probe_calls"
not_contains "--no-accounts never shows a detected account" "account.probe@example.test" "$OUTPUT"
contains "--no-accounts shows a dash instead" "tailscale" "$OUTPUT"

reset_test_env
GH_STATUS=0
CODEX_STATUS=0
CLAUDE_LOGGED_IN=1
ENGRAM_READY=1
TAILSCALE_STATUS=0
SSH_GH_OK=1
LOGIN_SHELL=/usr/bin/zsh
MOSHI_STATUS_LINE="status: paired"
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
export POST_RESTORE_PROC_VERSION_FILE
mkdir -p "$TEST_HOME/.pi/agent" "$TEST_HOME/.local/share/opencode" "$TEST_HOME/.engram" "$TEST_HOME/.ssh"
echo '{"openai-codex": {}}' >"$TEST_HOME/.pi/agent/auth.json"
echo '{"anthropic": "x"}' >"$TEST_HOME/.local/share/opencode/auth.json"
echo '{}' >"$TEST_HOME/.engram/cloud.json"
echo '{"mcpServers": {"codegraph": {}}}' >"$TEST_HOME/.claude.json"
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/id_github
CONF
: >"$TEST_HOME/.ssh/id_github"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/id_github.pub"
SSHD_DROPIN_DIR="$TEST_HOME/sshd-dropin"
mkdir -p "$SSHD_DROPIN_DIR"
cp "$FIXTURE_DOTFILES/os/linux/ssh/00-moshi.conf" "$SSHD_DROPIN_DIR/00-moshi.conf"
export SSHD_DROPIN_DIR
echo "some-key" >"$TEST_HOME/.ssh/authorized_keys"
run_secrets "" --check --no-accounts
check "--no-accounts keeps --check's exit-code semantics (all done -> 0)" "0" "$RC"

echo
# ==============================================================================
# accounts: per-service detection from fixtures (gh, ssh-keys, claude, codex,
# pi, opencode, engram-cloud, tailscale, moshi, shell); zerotier and sshd are
# always "-".
# ==============================================================================
echo "accounts: per-service detection from fixtures"
reset_test_env
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
export POST_RESTORE_PROC_VERSION_FILE
GH_STATUS=0
GH_ACCOUNT_NAME="octocat"
CODEX_STATUS=0
CLAUDE_LOGGED_IN=1
CLAUDE_EMAIL="claude.user@example.test"
CLAUDE_ORG="Acme Corp"
ENGRAM_READY=1
TAILSCALE_STATUS=0
TAILSCALE_LOGIN_NAME="ts.user@example.test"
SSH_GH_OK=1
SSH_HI_NAME=testuser
LOGIN_SHELL=/usr/bin/zsh
MOSHI_STATUS_LINE="status: paired"
MOSHI_DISPLAY_NAME="My Phone"
mkdir -p "$TEST_HOME/.pi/agent" "$TEST_HOME/.local/share/opencode" "$TEST_HOME/.engram" "$TEST_HOME/.ssh" "$TEST_HOME/.codex"
CODEX_JWT=$(make_jwt '{"email":"codex.user@example.test"}')
jq -n --arg t "$CODEX_JWT" '{tokens: {id_token: $t}}' >"$TEST_HOME/.codex/auth.json"
PI_JWT=$(make_jwt '{"https://api.openai.com/profile":{"email":"pi.user@example.test"}}')
jq -n --arg t "$PI_JWT" '{"openai-codex": {access: $t}}' >"$TEST_HOME/.pi/agent/auth.json"
jq -n '{"anthropic": "x", "openai": "y"}' >"$TEST_HOME/.local/share/opencode/auth.json"
jq -n '{server_url: "https://cloud.example.test:1234/api", token: "unused"}' >"$TEST_HOME/.engram/cloud.json"
echo '{"mcpServers": {"codegraph": {}}}' >"$TEST_HOME/.claude.json"
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/id_github
CONF
: >"$TEST_HOME/.ssh/id_github"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/id_github.pub"
SSHD_DROPIN_DIR="$TEST_HOME/sshd-dropin"
mkdir -p "$SSHD_DROPIN_DIR"
cp "$FIXTURE_DOTFILES/os/linux/ssh/00-moshi.conf" "$SSHD_DROPIN_DIR/00-moshi.conf"
export SSHD_DROPIN_DIR
echo "some-key" >"$TEST_HOME/.ssh/authorized_keys"

run_secrets "" --check
contains "gh account is detected" "octocat" "$OUTPUT"
contains "the ssh:github.com row shows the Hi-name account, without a github: prefix" "testuser" "$OUTPUT"
not_contains "no row is literally named ssh-keys" "ssh-keys" "$OUTPUT"
contains "claude account shows email and org" "claude.user@example.test (Acme Corp)" "$OUTPUT"
contains "codex account shows the JWT email claim" "codex.user@example.test" "$OUTPUT"
contains "pi account shows the JWT profile email claim" "pi.user@example.test" "$OUTPUT"
contains "opencode account lists the provider keys" "anthropic, openai" "$OUTPUT"
contains "engram-cloud account shows only the host" "cloud.example.test" "$OUTPUT"
not_contains "engram-cloud account never shows the port" "cloud.example.test:1234" "$OUTPUT"
contains "tailscale account shows the tailnet login name" "ts.user@example.test" "$OUTPUT"
contains "moshi account shows the display name" "My Phone" "$OUTPUT"
contains "shell account shows the login shell path" "/usr/bin/zsh" "$OUTPUT"
zerotier_line=$(printf '%s\n' "$OUTPUT" | grep -E '^zerotier[[:space:]]')
contains "zerotier account is always -" "-" "$zerotier_line"
sshd_line=$(printf '%s\n' "$OUTPUT" | grep -E '^sshd[[:space:]]')
contains "sshd account is always -" "-" "$sshd_line"

echo
# ==============================================================================
# security: raw tokens (JWTs, engram token) never appear in any output, only
# the extracted emails.
# ==============================================================================
echo "security: secrets never appear in any output"
reset_test_env
SECRET_MARK="SECRET_TOKEN_MUST_NOT_LEAK_9f8a"
mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/.pi/agent" "$TEST_HOME/.engram"
CODEX_JWT=$(make_jwt '{"email":"codex.sec@example.test"}')
jq -n --arg t "$CODEX_JWT" --arg rt "${SECRET_MARK}-codex-refresh" --arg at "${SECRET_MARK}-codex-access" \
	'{tokens: {id_token: $t, refresh_token: $rt, access_token: $at}}' >"$TEST_HOME/.codex/auth.json"
PI_JWT=$(make_jwt '{"https://api.openai.com/profile":{"email":"pi.sec@example.test"}}')
jq -n --arg t "$PI_JWT" --arg at "${SECRET_MARK}-pi-refresh" \
	'{"openai-codex": {access: $t, refresh: $at}}' >"$TEST_HOME/.pi/agent/auth.json"
jq -n --arg tok "${SECRET_MARK}-engram" '{server_url: "https://cloud.example.test", token: $tok}' >"$TEST_HOME/.engram/cloud.json"
ENGRAM_READY=0
run_secrets "" --check
not_contains "the raw codex id_token JWT never leaks into output" "$CODEX_JWT" "$OUTPUT"
not_contains "the raw pi access JWT never leaks into output" "$PI_JWT" "$OUTPUT"
not_contains "no secret marker leaks into output" "$SECRET_MARK" "$OUTPUT"
contains "the codex email IS shown" "codex.sec@example.test" "$OUTPUT"
contains "the pi email IS shown" "pi.sec@example.test" "$OUTPUT"

echo
# ==============================================================================
# --menu: navigation basics (quit, EOF, invalid input, scoping)
# ==============================================================================
echo "menu: q exits 0 without actions"
reset_test_env
POST_RESTORE_ONLY=gh
GH_STATUS=1
run_secrets "q
" --menu
check "menu q exits 0" "0" "$RC"
check "no gh login was attempted" "" "$(log_of gh | grep -v 'auth status' || true)"

echo "menu: EOF exits 0"
reset_test_env
POST_RESTORE_ONLY=gh
run_secrets "" --menu
check "menu EOF exits 0" "0" "$RC"

echo "menu: invalid choice then q"
reset_test_env
POST_RESTORE_ONLY=gh
run_secrets "zz
q
" --menu
contains "menu reports an invalid choice" "Invalid" "$OUTPUT"
check "menu exits 0 after q" "0" "$RC"

echo "menu: POST_RESTORE_ONLY restricts the menu to one step"
reset_test_env
POST_RESTORE_ONLY=gh
GH_STATUS=1
run_secrets "q
" --menu
not_contains "menu does not list unrelated steps" "ssh-keys" "$OUTPUT"
contains "menu lists the gh step" "gh" "$OUTPUT"

echo
# ==============================================================================
# --menu: running a pending step, and declining to reconfigure a done step
# ==============================================================================
echo "menu: choosing a pending step runs its flow"
reset_test_env
POST_RESTORE_ONLY=gh
GH_STATUS=1
run_secrets "1
y
q
" --menu
contains "gh login command ran from the menu" \
	"gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key --scopes admin:public_key" \
	"$(log_of gh)"

echo "menu: choosing a done step then N does nothing"
reset_test_env
POST_RESTORE_ONLY=gh
GH_STATUS=0
GH_ACCOUNT_NAME=octocat
run_secrets "1
n
q
" --menu
contains "menu shows the configured account before asking" "octocat" "$OUTPUT"
check "no gh auth logout ran" "" "$(log_of gh | grep -v 'auth status' || true)"

echo
# ==============================================================================
# --menu: switching accounts for claude and codex logs out, then logs back in
# ==============================================================================
echo "menu: + y on claude runs logout then login"
reset_test_env
POST_RESTORE_ONLY=claude
CLAUDE_LOGGED_IN=1
CLAUDE_EMAIL="claude.user@example.test"
run_secrets "1
y
q
" --menu
claude_log=$(log_of claude)
contains "claude logout ran" "claude auth logout" "$claude_log"
contains "claude login ran" "claude auth login" "$claude_log"
logout_line=$(printf '%s\n' "$claude_log" | grep -n 'auth logout' | head -1 | cut -d: -f1)
login_line=$(printf '%s\n' "$claude_log" | grep -n 'auth login' | tail -1 | cut -d: -f1)
check "logout ran before the fresh login" "yes" "$([ "${logout_line:-0}" -lt "${login_line:-0}" ] && echo yes || echo no)"

echo "menu: + y on codex runs logout then login --device-auth"
reset_test_env
POST_RESTORE_ONLY=codex
CODEX_STATUS=0
run_secrets "1
y
q
" --menu
codex_log=$(log_of codex)
contains "codex logout ran" "codex logout" "$codex_log"
contains "codex device-auth login ran" "codex login --device-auth" "$codex_log"

echo
# ==============================================================================
# --menu: ssh-keys replace moves the old key into retired/ (never deletes),
# regenerates it with a label in the comment, and follows the right per-host
# path (gh ssh-key add for github.com, printed instructions otherwise).
# ==============================================================================
echo "menu: ssh-keys replace - github.com regenerates and uploads via gh"
reset_test_env
POST_RESTORE_ONLY=ssh-keys
SSH_GH_OK=1
SSH_HI_NAME=testuser
GH_STATUS=0
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/id_github
CONF
mkdir -p "$TEST_HOME/.ssh"
echo "ORIGINAL-PRIVATE-KEY-MARKER" >"$TEST_HOME/.ssh/id_github"
echo "ssh-ed25519 OLDKEYDATA $(id -un)@testhost" >"$TEST_HOME/.ssh/id_github.pub"
run_secrets "1
y
label-x
q
" --menu
retired_priv=$(find "$TEST_HOME/.ssh/retired" -maxdepth 1 -type f -name 'id_github.[0-9]*' ! -name '*.pub.*' 2>/dev/null | head -1)
check "a timestamp-suffixed retired private key exists" "yes" "$([ -n "$retired_priv" ] && echo yes || echo no)"
contains "the retired private key keeps its original content (moved, not deleted)" \
	"ORIGINAL-PRIVATE-KEY-MARKER" "$(cat "$retired_priv" 2>/dev/null)"
check "the new key at the original path no longer has the old content" "" \
	"$(grep -F 'ORIGINAL-PRIVATE-KEY-MARKER' "$TEST_HOME/.ssh/id_github" 2>/dev/null || true)"
keygen_log=$(log_of ssh-keygen)
contains "ssh-keygen regenerated the same path" "-f $TEST_HOME/.ssh/id_github" "$keygen_log"
contains "ssh-keygen ran with an empty passphrase" "-N" "$keygen_log"
contains "ssh-keygen embedded the chosen label in the comment" "-C $(id -un)@testhost label-x" "$keygen_log"
contains "gh ssh-key add uploaded the regenerated github.com key" \
	"ssh-key add $TEST_HOME/.ssh/id_github.pub --title testhost" "$(log_of gh)"
contains "a fingerprint hint for the retired key is printed" "fingerprint" "$OUTPUT"

echo "menu: ssh-keys replace - bitbucket.org prints the pub and settings hint"
reset_test_env
POST_RESTORE_ONLY=ssh-keys
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host bitbucket.org
  IdentityFile ~/.ssh/id_bitbucket
CONF
mkdir -p "$TEST_HOME/.ssh"
echo "ORIGINAL-BB-PRIVATE-KEY-MARKER" >"$TEST_HOME/.ssh/id_bitbucket"
echo "ssh-ed25519 OLDKEYDATA $(id -un)@testhost bitbucket personal" >"$TEST_HOME/.ssh/id_bitbucket.pub"
run_secrets "1
y
work
q
" --menu
retired_priv_bb=$(find "$TEST_HOME/.ssh/retired" -maxdepth 1 -type f -name 'id_bitbucket.[0-9]*' ! -name '*.pub.*' 2>/dev/null | head -1)
check "a timestamp-suffixed retired bitbucket key exists" "yes" "$([ -n "$retired_priv_bb" ] && echo yes || echo no)"
contains "the retired bitbucket key keeps its original content" \
	"ORIGINAL-BB-PRIVATE-KEY-MARKER" "$(cat "$retired_priv_bb" 2>/dev/null)"
contains "the new bitbucket.org public key is printed for the user to add by hand" \
	"ssh-ed25519 FAKEFAKEFAKE stub" "$OUTPUT"
contains "the Bitbucket settings hint is printed" "Bitbucket" "$OUTPUT"
contains "a fingerprint hint for the old key is printed" "fingerprint" "$OUTPUT"
check "gh ssh-key add was never used for a non-github host" "" "$(log_of gh | grep id_bitbucket || true)"

echo
# ==============================================================================
# --menu: tailscale is never logged out from the menu -- only warned about.
# ==============================================================================
echo "menu: tailscale switch never logs out, only warns"
reset_test_env
POST_RESTORE_ONLY=tailscale
printf 'Linux version 6.6.0\n' >"$SANDBOX/proc-version-bare"
POST_RESTORE_PROC_VERSION_FILE="$SANDBOX/proc-version-bare"
export POST_RESTORE_PROC_VERSION_FILE
TAILSCALE_STATUS=0
TAILSCALE_LOGIN_NAME="ts.user@example.test"
run_secrets "1
y
q
" --menu
contains "the session-ending warning is printed" "ends every Tailscale connection" "$OUTPUT"
check "no tailscale command beyond the read-only status probes ran" "" \
	"$(log_of tailscale | grep -vE '^tailscale status( --json)?$' || true)"

echo
# ==============================================================================
# --menu: each ssh:<host> row acts on that key only, and the row numbers stay
# consecutive around the expanded ssh rows.
# ==============================================================================
echo "menu: choosing the bitbucket row when pending generates only that key"
reset_test_env
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/github-hlclarog
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
mkdir -p "$TEST_HOME/.ssh"
: >"$TEST_HOME/.ssh/github-hlclarog"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/github-hlclarog.pub"
SSH_GH_OK=1
GH_STATUS=1
run_secrets "3
y

q
" --menu
keygen_log=$(log_of ssh-keygen)
contains "ssh-keygen ran for the bitbucket key" "-f $TEST_HOME/.ssh/bit-hclaro" "$keygen_log"
not_contains "no keygen call touched the github key" "github-hlclarog" "$keygen_log"

echo "menu: choosing the github row when done + N does nothing"
reset_test_env
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/github-hlclarog
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
mkdir -p "$TEST_HOME/.ssh"
: >"$TEST_HOME/.ssh/github-hlclarog"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/github-hlclarog.pub"
: >"$TEST_HOME/.ssh/bit-hclaro"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/bit-hclaro.pub"
SSH_GH_OK=1
SSH_HI_NAME=testuser
GH_STATUS=0
run_secrets "2
n
q
" --menu
contains "menu shows the configured account before asking" "testuser" "$OUTPUT"
check "no ssh-keygen ran (declined)" "" "$(log_of ssh-keygen)"

echo "menu: choosing the github row when done + y replaces only the github key"
reset_test_env
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/github-hlclarog
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
mkdir -p "$TEST_HOME/.ssh"
echo "ORIGINAL-GH-PRIVATE-KEY-MARKER" >"$TEST_HOME/.ssh/github-hlclarog"
echo "ssh-ed25519 OLDKEYDATA $(id -un)@testhost" >"$TEST_HOME/.ssh/github-hlclarog.pub"
: >"$TEST_HOME/.ssh/bit-hclaro"
echo "ssh-ed25519 FAKE stub" >"$TEST_HOME/.ssh/bit-hclaro.pub"
SSH_GH_OK=1
SSH_HI_NAME=testuser
GH_STATUS=0
run_secrets "2
y

q
" --menu
retired_priv_gh=$(find "$TEST_HOME/.ssh/retired" -maxdepth 1 -type f -name 'github-hlclarog.[0-9]*' ! -name '*.pub.*' 2>/dev/null | head -1)
check "the old github key was retired with a timestamp" "yes" "$([ -n "$retired_priv_gh" ] && echo yes || echo no)"
contains "gh ssh-key add uploaded the regenerated github key" \
	"ssh-key add $TEST_HOME/.ssh/github-hlclarog.pub --title testhost" "$(log_of gh)"
not_contains "the bitbucket key was never regenerated" "bit-hclaro" "$(log_of ssh-keygen)"

echo "menu: row numbers stay consecutive around the expanded ssh rows"
reset_test_env
cat >"$FIXTURE_DOTFILES/ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/github-hlclarog
Host bitbucket.org
  IdentityFile ~/.ssh/bit-hclaro
CONF
run_secrets "q
" --menu --no-accounts
menu_lines=$(printf '%s\n' "$OUTPUT" | grep -E '^[0-9]+ ')
contains "row 1 is gh" "1   gh" "$(printf '%s\n' "$menu_lines" | sed -n '1p')"
contains "row 2 is ssh:github.com" "2   ssh:github.com" "$(printf '%s\n' "$menu_lines" | sed -n '2p')"
contains "row 3 is ssh:bitbucket.org" "3   ssh:bitbucket.org" "$(printf '%s\n' "$menu_lines" | sed -n '3p')"
contains "row 4 is pi (right after the two expanded ssh rows)" "4   pi" "$(printf '%s\n' "$menu_lines" | sed -n '4p')"

echo
# ==============================================================================
# table: columns stay aligned on screen. "✓" is 3 bytes in UTF-8, so padding
# by bytes put the ACCOUNT column 2 characters left on every done row.
# ==============================================================================
echo "table: alignment with multibyte status"
reset_test_env
GH_STATUS=0
run_secrets "" --check --no-accounts
# ACCOUNT starts after 51 characters: 17 (fits "ssh:bitbucket.org") + space +
# 32 + space. Counted in characters, not bytes, so the check itself needs a
# UTF-8 locale.
misaligned=$(printf '%s\n' "$OUTPUT" | LC_ALL=C.UTF-8 bash -c '
	while IFS= read -r line; do
		case "$line" in "STEP "* | [a-z]*" "*) ;; *) continue ;; esac
		[ "${line:50:1}" = " " ] && [ "${line:51:1}" != " " ] || printf "%s\n" "$line"
	done')
check "every row starts ACCOUNT at the same character column" "" "$misaligned"
contains "a done row is still rendered" "gh                ✓" "$OUTPUT"

# The --menu table has an extra N column (3 + space), so ACCOUNT starts after
# 55 characters.
reset_test_env
GH_STATUS=0
run_secrets "q
" --menu --no-accounts
menu_misaligned=$(printf '%s\n' "$OUTPUT" | LC_ALL=C.UTF-8 bash -c '
	while IFS= read -r line; do
		case "$line" in "N   STEP "* | [0-9]*" "*) ;; *) continue ;; esac
		[ "${line:54:1}" = " " ] && [ "${line:55:1}" != " " ] || printf "%s\n" "$line"
	done')
check "every menu row starts ACCOUNT at the same character column" "" "$menu_misaligned"

echo
echo "$tests_run tests, $tests_failed failed"
[ "$tests_failed" -eq 0 ]
