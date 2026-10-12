# Fix upall Herdr warning and Zim stage

## Objective
`upall` never prints the stale Herdr server warning, and its dotly stage fails with `ZIM_HOME: unbound variable`. Make the warning fire on real Herdr output and skip the Zim update when Zim is not configured.

## Evidence and constraints
- Real `herdr status server` prints `Status: running` (capital S); `scripts/update-workstation:35` matches only lowercase `status:`, so `server_running` stays false and the warning never prints.
- `restoration_scripts/tests/update-workstation.sh:55-58` mocks lowercase output, so the suite never exercised the real format.
- `modules/dotly/scripts/package/update_all:33` runs `zsh "$ZIM_HOME/zimfw.zsh"` under `set -u`; this zsh config neither loads Zim nor sets `ZIM_HOME`.
- `modules/dotly` is a submodule of the fork `hlclarog/dotly`, branch `dotfiles`; fixes land there and the parent bumps the pointer.
- At diagnosis time CLI and server were both 0.9.3, so no warning was due in that run.

## Tasks
- [x] T1: Herdr status parsing accepts the real capitalized keys; test fixtures use the real format (RED, then GREEN).
- [x] T2: dotly `update_all` skips Zim when `ZIM_HOME` is unset or `zimfw.zsh` is missing; test in the fork; bump the submodule pointer.

## Progress and evidence
- T1 (`766fb3f`): `update-workstation.sh` RED with real-format fixtures (`missing version warning`), then GREEN; ShellCheck clean. The live function against the running 0.9.3 server exits 0 with no warning, as expected for matching versions.
- T2 (fork `d5ff020`, pointer bump in this commit): `tests/zim-update-all.sh` RED (missing `zim.sh`), then GREEN together with the cargo and npm tests; ShellCheck clean, `bash -n update_all` clean. In the live shell `ZIM_HOME` is unset and `zim::is_configured` skips under `set -u` without error. A full `dot package update_all` run was not executed because it updates real packages.
- Pending, user-owned: push the fork's `dotfiles` branch before pushing this branch, so the submodule pointer resolves remotely.
