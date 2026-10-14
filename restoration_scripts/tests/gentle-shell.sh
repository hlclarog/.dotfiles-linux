#!/usr/bin/env bash
# Public entrypoints with disposable HOME and fake Pi; never install software.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WRAPPER="$ROOT/tools/gentle-shell/gentle-shell"
RESTORE="$ROOT/scripts/restore-gentle-shell"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
NODE=$(command -v node)
export HOME="$SANDBOX/home with spaces" GENTLE_SHELL_TEST_LOG="$SANDBOX/calls"
export GENTLE_SHELL_TEST_VERSION="$SANDBOX/pi-version"
unset PI_CODING_AGENT_DIR GENTLE_SHELL_USER_PI_HOME GENTLE_SHELL_PI
mkdir -p "$HOME/.pi/agent/bin" "$HOME/.pi/gentle-ai" "$SANDBOX/bin"
export PATH="$SANDBOX/bin:$PATH"
ln -s "$NODE" "$SANDBOX/bin/node"
PI_HOME="$HOME/.pi/agent"
LAUNCHER="$PI_HOME/npm/node_modules/gentle-pi/bin/gentle-shell.mjs"
export GENTLE_SHELL_TEST_TEMPLATE="$SANDBOX/launcher.mjs"
printf '1.2.0\n' >"$GENTLE_SHELL_TEST_VERSION"
: >"$GENTLE_SHELL_TEST_LOG"
for file in agent/auth.json agent/settings.json agent/sessions/saved.jsonl gentle-ai/profiles.json gentle-ai/models.json; do
    mkdir -p "$(dirname "$HOME/.pi/$file")"
    printf '{"sentinel":"%s"}\n' "$file" >"$HOME/.pi/$file"
done
printf '{"packages":["npm:gentle-pi@latest"]}\n' >"$PI_HOME/settings.json"
before=$(find "$HOME/.pi" -type f -exec sha256sum {} + | sort)
cat >"$GENTLE_SHELL_TEST_TEMPLATE" <<'JS'
console.log(JSON.stringify({args: process.argv.slice(2), pi: process.env.GENTLE_SHELL_PI}));
process.exit(Number(process.env.GENTLE_SHELL_TEST_EXIT || 0));
JS
cat >"$PI_HOME/bin/pi" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
    --version) printf 'pi %s\n' "$(<"$GENTLE_SHELL_TEST_VERSION")" ;;
    update) printf 'update\n' >>"$GENTLE_SHELL_TEST_LOG"; printf '1.2.0\n' >"$GENTLE_SHELL_TEST_VERSION" ;;
    install)
        printf 'install %s\n' "$2" >>"$GENTLE_SHELL_TEST_LOG"
        [[ ${GENTLE_SHELL_TEST_INSTALL_FAIL:-0} == 0 ]] || exit 17
        mkdir -p "$HOME/.pi/agent/npm/node_modules/gentle-pi/bin"
        cp "$GENTLE_SHELL_TEST_TEMPLATE" "$HOME/.pi/agent/npm/node_modules/gentle-pi/bin/gentle-shell.mjs" ;;
    *) printf 'Unexpected Pi invocation\n' >&2; exit 99 ;;
esac
SH
chmod +x "$PI_HOME/bin/pi"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() {
    status=0
    "$@" >"$SANDBOX/out" 2>"$SANDBOX/err" || status=$?
    out=$(<"$SANDBOX/out"); err=$(<"$SANDBOX/err")
}
assert() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }
check_preserved() {
    after=$(find "$HOME/.pi" -type f ! -path '*/npm/*' ! -path '*/bin/*' -exec sha256sum {} + | sort)
    expected=$(printf '%s\n' "$before" | grep -v '/bin/')
    assert "$expected" "$after"
}
# S2: missing package is actionable, no implicit installation during launch.
run bash "$WRAPPER" --version
assert 127 "$status"; assert '' "$out"
assert "gentle-shell: launcher missing: $LAUNCHER; run scripts/restore-gentle-shell" "$err"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
# S1/S4: existing VM with old package directory repairs it; rerun is a no-op.
mkdir -p "$(dirname "$LAUNCHER")"
run bash "$RESTORE"
assert 0 "$status"; assert '' "$err"
assert "Gentle Shell ready: $HOME/.local/bin/gentle-shell (linked Pi home)." "$out"
assert 'install npm:gentle-pi@latest' "$(<"$GENTLE_SHELL_TEST_LOG")"
assert "$WRAPPER" "$(readlink "$HOME/.local/bin/gentle-shell")"
check_preserved
: >"$GENTLE_SHELL_TEST_LOG"
run bash "$RESTORE"; assert 0 "$status"; assert '' "$err"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
# S2/S3: default --link, exact argv including spaces/delimiter, existing Pi.
run "$HOME/.local/bin/gentle-shell" --mode rpc -p 'hello world' -- --isolated
assert 0 "$status"; assert '' "$err"
assert "{\"args\":[\"--link\",\"--mode\",\"rpc\",\"-p\",\"hello world\",\"--\",\"--isolated\"],\"pi\":\"$PI_HOME/bin/pi\"}" "$out"
for selector in --link --isolated --home=/somewhere; do
    run bash "$WRAPPER" "$selector" --version
    assert 0 "$status"; assert '' "$err"
    assert "{\"args\":[\"$selector\",\"--version\"],\"pi\":\"$PI_HOME/bin/pi\"}" "$out"
done
for command in home upgrade self-uninstall; do
    run bash "$WRAPPER" "$command" --dry-run
    assert 0 "$status"; assert '' "$err"
    assert "{\"args\":[\"$command\",\"--dry-run\"],\"pi\":\"$PI_HOME/bin/pi\"}" "$out"
done
GENTLE_SHELL_PI=/explicit/pi run bash "$WRAPPER" --home '/path with spaces' --version
assert 0 "$status"; assert '' "$err"
assert '{"args":["--home","/path with spaces","--version"],"pi":"/explicit/pi"}' "$out"
GENTLE_SHELL_TEST_EXIT=23 run bash "$WRAPPER" --version
assert 23 "$status"; assert '' "$err"
check_preserved
GENTLE_SHELL_PI=/missing/pi run bash "$RESTORE"
assert 1 "$status"; assert '' "$out"
assert 'gentle-shell: explicit Pi executable missing: /missing/pi' "$err"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
# S1: check never changes data; old core updates only on explicit migration.
printf '1.1.0\n' >"$GENTLE_SHELL_TEST_VERSION"
run bash "$RESTORE" --check
assert 1 "$status"; assert '' "$out"
assert 'gentle-shell: Pi >=1.2.0 required; run pi update, then scripts/restore-gentle-shell' "$err"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
run bash "$RESTORE"; assert 0 "$status"; assert '' "$err"
assert 'update' "$(<"$GENTLE_SHELL_TEST_LOG")"
: >"$GENTLE_SHELL_TEST_LOG"
run bash "$RESTORE" --check; assert 0 "$status"; assert '' "$err"
check_preserved
# S3/S4: reject an occupied name before package updates, preserving counters.
rm "$HOME/.local/bin/gentle-shell" "$LAUNCHER"
printf 'foreign command\n' >"$HOME/.local/bin/gentle-shell"
run bash "$RESTORE"
assert 1 "$status"; assert '' "$out"
assert "gentle-shell: refusing to replace $HOME/.local/bin/gentle-shell" "$err"
assert 'foreign command' "$(<"$HOME/.local/bin/gentle-shell")"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
check_preserved
# Intentional package pins and malformed settings reject before any updates.
rm "$HOME/.local/bin/gentle-shell"
settings=$(<"$PI_HOME/settings.json")
for declaration in '"npm:gentle-pi@3.0.0"' '{"source":"npm:gentle-pi@3.0.0"}'; do
    printf '{"packages":[%s]}\n' "$declaration" >"$PI_HOME/settings.json"
    pinned_before=$(sha256sum "$PI_HOME/settings.json")
    run bash "$RESTORE"
    assert 1 "$status"; assert '' "$out"
    assert 'gentle-shell: pinned gentle-pi lacks launcher; review its pin before upgrading' "$err"
    assert "$pinned_before" "$(sha256sum "$PI_HOME/settings.json")"
    assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
done
printf 'private malformed value\n' >"$PI_HOME/settings.json"
run bash "$RESTORE"
assert 1 "$status"; assert '' "$out"
assert 'gentle-shell: invalid Pi package settings; inspect settings.json before migrating' "$err"
assert 'private malformed value' "$(<"$PI_HOME/settings.json")"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
printf '%s\n' "$settings" >"$PI_HOME/settings.json"
# Node prerequisite failure does not create links or install packages.
rm "$SANDBOX/bin/node" # Unlink the fixture before writing a stub.
cat >"$SANDBOX/bin/node" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$SANDBOX/bin/node"
run bash "$RESTORE"
assert 1 "$status"; assert '' "$out"
assert 'gentle-shell: Node >=22.19.0 required; restore Node first' "$err"
assert '' "$(<"$GENTLE_SHELL_TEST_LOG")"
# The stable fnm default takes precedence over a stale project Node.
mkdir -p "$HOME/.local/share/fnm/aliases/default/bin"
ln -s "$NODE" "$HOME/.local/share/fnm/aliases/default/bin/node"
# Failed installs propagate, never create a launcher link or claim success.
GENTLE_SHELL_TEST_INSTALL_FAIL=1 run bash "$RESTORE"
assert 17 "$status"; assert '' "$out"; assert '' "$err"
[[ ! -e "$HOME/.local/bin/gentle-shell" ]] || fail 'failed install created link'
check_preserved
# S1: fresh restore integration runs the same migration without consuming stdin.
cat >"$SANDBOX/bin/fnm" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == 'exec --using=default' ]] || exit 99
shift 2
exec "$@"
SH
chmod +x "$SANDBOX/bin/fnm"
: >"$GENTLE_SHELL_TEST_LOG"
# Expanded intentionally by the child shell, not this test process.
# shellcheck disable=SC2016
run env DOTFILES_PATH="$ROOT" PATH="$PI_HOME/bin:$PATH" bash -c 'source "$DOTFILES_PATH/restoration_scripts/08-shell.sh"'
assert 0 "$status"; assert '' "$err"
assert "Gentle Shell ready: $HOME/.local/bin/gentle-shell (linked Pi home)." "$out"
assert 'install npm:gentle-pi@latest' "$(<"$GENTLE_SHELL_TEST_LOG")"
check_preserved
printf 'gentle-shell isolated tests passed\n'
