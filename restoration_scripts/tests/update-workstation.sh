#!/usr/bin/env bash
# Mock all update commands in-process; never touch an installed package or Pi.
# Dynamic source paths and function calls are intentional in this isolated test.
# shellcheck disable=SC1091,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/update-workstation"
PATCH="$ROOT/scripts/patch-pi-claude-bridge-1m"

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
    local failure=$1 cwd=$2 safe_patch
    cd "$cwd"
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
    git() { fail 'updater must not run git'; }
    printf -v safe_patch '%q' "$PATCH"
    eval "function $safe_patch() { patch_mock \"\$@\"; }"
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
for failure in dot core extensions models patch; do
    check_case "$failure" /
done
printf 'update-workstation mock tests passed\n'
