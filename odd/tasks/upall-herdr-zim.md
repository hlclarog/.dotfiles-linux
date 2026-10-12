# Fix upall Herdr warning and Zim stage

## Objective
`upall` never prints the stale Herdr server warning, and its dotly stage fails with `ZIM_HOME: unbound variable`. Make the warning fire on real Herdr output and skip the Zim update when Zim is not configured.

## Evidence and constraints
- Correction (2026-10-12): an earlier reading showed `Status: running` (capital S) and blamed the lowercase match in `scripts/update-workstation` for the missing warning. A byte-level check (`od -c`, three runs) shows Herdr 0.9.3 prints `status: running` in lowercase, which the original parser already matched. The warning was absent only because CLI and server were both 0.9.3.
- `modules/dotly/scripts/package/update_all:33` runs `zsh "$ZIM_HOME/zimfw.zsh"` under `set -u`; this zsh config neither loads Zim nor sets `ZIM_HOME`.
- `modules/dotly` is a submodule of the fork `hlclarog/dotly`, branch `dotfiles`; fixes land there and the parent bumps the pointer.
- At diagnosis time CLI and server were both 0.9.3, so no warning was due in that run.

## Tasks
- [x] T1: Herdr status parsing accepts lowercase and capitalized keys; fixtures use the real lowercase format plus a capitalized case.
- [x] T2: dotly `update_all` skips Zim when `ZIM_HOME` is unset or `zimfw.zsh` is missing; test in the fork; bump the submodule pointer.

## Progress and evidence
- T1 (`766fb3f`): its RED came from capitalized fixtures, not from real output. Follow-up branch `fix/herdr-status-fixture` restores lowercase fixtures and adds `mismatch_capitalized`; ShellCheck clean. The live function against the running 0.9.3 server exits 0 with no warning, as expected for matching versions.
- T2 (fork `d5ff020`, pointer bump in this commit): `tests/zim-update-all.sh` RED (missing `zim.sh`), then GREEN together with the cargo and npm tests; ShellCheck clean, `bash -n update_all` clean. In the live shell `ZIM_HOME` is unset and `zim::is_configured` skips under `set -u` without error. A full `dot package update_all` run was not executed because it updates real packages.
- Delivered: #48 merged into master; hlclarog/dotly#1 merged with a merge commit (`9f04207`), so `d5ff020` is on the fork's `dotfiles` branch.
