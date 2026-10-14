#!/usr/bin/env bash
# Mock all update commands in-process; never touch an installed package or Pi.
# Dynamic source paths and function calls are intentional in this isolated test.
# SC2016: '. "$1"' is the literal child-Bash script upall passes.
# shellcheck disable=SC1091,SC2329,SC2016
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/update-workstation"
PATCH="$ROOT/scripts/patch-pi-claude-bridge-1m"
INTEGRATIONS="$ROOT/restoration_scripts/12-agent-integrations.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$SCRIPT" ]] || fail 'updater must be executable'
# Verify the new alias without changing the existing shortcut.
(
    # shellcheck source=../../shell/aliases.sh
    source "$ROOT/shell/aliases.sh"
    [[ $(alias up) == "alias up='dot package update_all'" ]] || fail 'up changed'
    [[ $(alias upall) == "alias upall='\$DOTFILES_PATH/scripts/update-workstation'" ]] || fail 'upall alias missing'
)

# A path-named Bash function intercepts the patch invocation, even though the
# production script uses an absolute path. No fake executable or live HOME needed.
run_case() (
    local failure=$1 cwd=$2 herdr_case=${3:-absent} safe_patch safe_integrations
    cd "$cwd"
    command() {
        if [[ "$1" == -v && "$2" == herdr ]]; then
            [[ "$herdr_case" != absent ]] || return 1
            if [[ "$herdr_case" == unmanaged ]]; then
                printf '/other/bin/herdr\n'
            else
                printf '/mock/homebrew/bin/herdr\n'
            fi
        elif [[ "$1" == -v && "$2" == brew ]]; then
            printf '/mock/homebrew/bin/brew\n'
        else
            builtin command "$@"
        fi
    }
    brew() {
        case "$*" in
            --prefix) printf '/mock/homebrew\n' ;;
            'list --versions herdr') printf 'herdr 0.9.3\n' ;;
            *) fail "unexpected brew call: $*" ;;
        esac
    }
    herdr() {
        case "$*" in
            --version)
                [[ "$herdr_case" != failed_cli ]] || return 1
                printf 'herdr 0.9.3\n' ;;
            'status server')
                [[ "$herdr_case" != failed ]] || return 1
                # Mirror real Herdr 0.9.3 output: lowercase keys plus extra keys
                # the parser must ignore. mismatch_capitalized guards key casing.
                case "$herdr_case" in
                    match) printf 'status: running\nversion: 0.9.3\nendpoint_compatible: yes\n' ;;
                    stopped) printf 'status: stopped\nversion: 0.9.2\n' ;;
                    malformed) printf 'status: running\nversion: unknown version\n' ;;
                    mismatch_capitalized) printf 'Status: running\nVersion: 0.9.2\n' ;;
                    *) printf 'status: running\nversion: 0.9.2\nendpoint_compatible: yes\nprivate_protocol: 22\n' ;;
                esac ;;
            *) fail "unexpected Herdr command: $*" ;;
        esac
    }
    dot() {
        printf 'call:dot %s\n' "$*"
        [[ "$failure" != dot ]]
    }
    pi() {
        printf 'call:pi %s\n' "$*"
        case "$failure:$*" in
            'core:update'|'extensions:update --extensions'|'models:update --models') return 17 ;;
        esac
    }
    patch_mock() {
        printf 'call:patch %s\n' "$*"
        [[ "$failure" != patch ]]
    }
    # The integrations script returns early when Herdr is absent, so it must be
    # sourced in a child Bash; only that exact invocation is accepted.
    bash() {
        [[ $# == 4 && "$1" == -c && "$2" == '. "$1"' && "$3" == agent-integrations ]] ||
            fail "unexpected bash call: $*"
        printf 'call:agent-integrations %s\n' "$4"
        [[ "$failure" != integrations ]]
    }
    git() { fail 'updater must not run git'; }
    printf -v safe_patch '%q' "$PATCH"
    eval "function $safe_patch() { patch_mock \"\$@\"; }"
    # Executing the integrations script directly must never reach the real one.
    printf -v safe_integrations '%q' "$INTEGRATIONS"
    eval "function $safe_integrations() { fail 'integrations must be sourced in a child Bash'; }"
    # Source into this subshell so the path-named patch function can intercept
    # execution without creating files or invoking the real patch.
    # shellcheck source=../../scripts/update-workstation
    source "$SCRIPT"
)

expected=(
    'stage:dot packages' 'call:dot package update_all'
    'stage:Pi core' 'call:pi update'
    'stage:Pi extensions' 'call:pi update --extensions'
    'stage:Pi model catalog' 'call:pi update --models'
    'stage:Claude bridge 1M patch' 'call:patch '
    'stage:Agent integrations' "call:agent-integrations $INTEGRATIONS"
    'Workstation update complete.'
)

check_case() {
    local failure=$1 cwd=$2 output status=0 line count index
    output=$(run_case "$failure" "$cwd" 2>&1) || status=$?
    if [[ "$failure" == none ]]; then
        [[ "$status" == 0 ]] || fail "success case exited $status: $output"
        count=${#expected[@]}
    else
        case "$failure" in
            dot) count=2; [[ "$status" == 1 ]] || fail "dot exited $status" ;;
            core) count=4; [[ "$status" == 17 ]] || fail "core exited $status" ;;
            extensions) count=6; [[ "$status" == 17 ]] || fail "extensions exited $status" ;;
            models) count=8; [[ "$status" == 17 ]] || fail "models exited $status" ;;
            patch) count=10; [[ "$status" == 1 ]] || fail "patch exited $status" ;;
            integrations) count=12; [[ "$status" == 1 ]] || fail "integrations exited $status" ;;
        esac
        [[ "$output" == *"failed"* ]] || fail "$failure did not report failure: $output"
        [[ "$output" != *'Workstation update complete.'* ]] || fail "$failure claimed success"
    fi
    for ((index=0; index<count; index++)); do
        IFS= read -r line <<< "$output"
        [[ "$line" == "${expected[index]}" ]] || fail "$failure stage $index: expected '${expected[index]}', got '$line'"
        output=${output#"$line"}
        output=${output#$'\n'}
    done
    if [[ "$failure" == none ]]; then
        [[ -z "$output" ]] || fail "unexpected output after success: $output"
    else
        [[ "$output" == *"failed"* ]] || fail "unexpected output after $failure: $output"
        [[ "$output" != *'call:'* ]] || fail "$failure ran a later command: $output"
    fi
}

check_case none /  # resolved patch path must not depend on the current directory
for failure in dot core extensions models patch integrations; do
    check_case "$failure" /
done

check_herdr_case() {
    local kind=$1 output status=0
    output=$(run_case none / "$kind" 2>&1) || status=$?
    [[ "$status" == 0 ]] || fail "Herdr $kind exited $status: $output"
    [[ "$output" == *'Workstation update complete.'* ]] || fail "Herdr $kind interrupted updates"
    case "$kind" in
        mismatch|mismatch_capitalized)
            [[ "$output" == *'Herdr'*'0.9.3'*'0.9.2'* ]] || fail "$kind: missing version warning: $output"
            [[ "$output" == *'after stopping all agents'*'terminal outside Herdr'* ]] || fail "$kind: missing safe manual precondition: $output"
            [[ "$output" == *'stopping the server terminates pane processes, including the invoking shell inside Herdr'* ]] || fail "$kind: missing pane safety warning: $output"
            [[ "$output" == *$'\n  herdr server stop\n  herdr\n'* ]] || fail "$kind: missing separate, ordered manual commands: $output" ;;
        *)
            [[ "$output" != *'warning:'* ]] || fail "unexpected Herdr warning for $kind: $output"
            [[ "$output" != *'herdr server stop'* && "$output" != *$'\n  herdr\n'* ]] || fail "unexpected manual commands for $kind: $output" ;;
    esac
}
for herdr_case in mismatch mismatch_capitalized match absent failed failed_cli stopped malformed unmanaged; do
    check_herdr_case "$herdr_case"
done

# The real integrations script, sourced the way upall runs it, with Herdr absent:
# its top-level `return` must end it cleanly instead of falling through to the
# install loop. Isolated HOME and a PATH without Herdr, Codex or moshi-hook.
(
    [[ -x "$INTEGRATIONS" ]] || fail 'integrations script must exist'
    tmp_home=$(mktemp -d)
    trap 'rm -rf -- "$tmp_home"' EXIT
    status=0
    output=$(env -i HOME="$tmp_home" PATH=/usr/bin:/bin \
        bash -c '. "$1"' agent-integrations "$INTEGRATIONS" 2>&1) || status=$?
    [[ "$status" == 0 ]] || fail "integrations without Herdr exited $status: $output"
    [[ "$output" == ' > herdr is not installed; skipping agent integrations' ]] ||
        fail "integrations without Herdr: unexpected output: $output"
    [[ -z "$(ls -A "$tmp_home")" ]] || fail 'integrations without Herdr wrote into HOME'
)
printf 'update-workstation mock tests passed\n'
