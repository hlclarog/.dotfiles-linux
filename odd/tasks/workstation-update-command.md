# Update workstation packages and Pi profiles

## Objective
Provide one shell alias to run the existing dotly package updater and Pi core, extension and model-catalog updates, including the required local Claude bridge 1M patch. Apply newly merged repository Pi profiles locally without changing the active choice. Follow-up: fix Dotly's empty-Cargo-list invocation and report stale Homebrew Herdr servers without stopping active panes.

## Evidence and constraints
- Existing `up` is `dot package update_all` in shared `shell/aliases.sh` (Bash/zsh). The new alias should not replace it. User requests one additional convenient command; call it `upall` and route nontrivial logic through a standalone script.
- Pi 0.87.1 supports `pi update`, `pi update --extensions`, and `pi update --models`. `doc/INSTALL.md` documents the pin caveat for `--extensions` on a fresh restore; do not claim that it updates every pinned package. Bridge package updates remove the local 1M Sonnet 5.5 patch; rerun `scripts/patch-pi-claude-bridge-1m` after Pi updates.
- `origin/master` merged #38 (`1f178d9`) with Sonnet 5.5 and GPT-6.1-sol profile mappings; local CLI lists both. On existing registries, run `scripts/upgrade-pi-models`, then `scripts/restore-pi-profiles --replace` for the four managed profile names, preserving active `codex-low`. A Pi restart and re-application of the active profile is documented to synchronize agent frontmatter and effective settings; do not present registry edits alone as complete running-session activation.
- Preserve existing untracked `.codegraph/` and `odd/tasks/pi-sonnet-5-5-profiles.md`; never stage either. No implicit `git pull` inside the updater: pull happened explicitly and a generic workstation update should not silently alter the user's Git checkout.
- Strict TDD enabled from `~/.gentle-ai/state.json`; new focused test command `bash restoration_scripts/tests/update-workstation.sh`, with mocked external commands and RED before GREEN. Include shellcheck and `git diff --check`. RDD switch on; assess the work-unit commit per native instructions.
- Delivery strategy `ask-on-risk`; forecast below 250 authored diff lines (alias, script, test, brief documentation). One cohesive PR-sized unit. User has not requested push/PR here.

## Tasks
- [x] T1: Add tested `upall` alias and fail-visible serial updater invoking dotly, Pi self, Pi extensions, Pi model catalog, then the bridge patch. Implemented and verified in work-unit commit `83e8649ac54fb9514a64cf55a4d9606fa331b0f8`.
- [ ] T2: Safely apply merged profile migrations and bridge patch to local installation, compare managed mappings, preserve active choice and private backup; verify status and document any restart/reapply step. Registry and patch applied; effective `models.json` and Pi default still need activation from `/gentle:profiles` after restart.
- [ ] T3: Verify Git diff and local outcome, report command behavior, downloaded changes and any incomplete checks. Independent checks passed except the known effective-model mismatch; native review remains open. Do not push unless separately requested.
- [ ] T4: Resolve the native review lineage `review-f16a633fb292457d` after a provider-bound capture can be admitted; do not claim approval while reviewing.
- [ ] T5: In the user-authorized external Dotly submodule, prevent Cargo installation when `cargo install --list` is empty, with isolated tests; implementation and checks passed, but submodule commit/gitlink await explicit authorization.
- [ ] T6: Update `upall` to detect and explain a stale Homebrew-managed Herdr server after a package upgrade, without stopping or restarting any server; implementation and checks passed, but main work-unit commit awaits explicit authorization.

## Progress
Created feature branch `feat/workstation-update-command` at master `1f178d9`. T1 committed as `83e8649ac54fb9514a64cf55a4d9606fa331b0f8` (`feat(shell): add unified workstation update shortcut`); unrelated untracked work left untouched. T2 patched the installed bridge for Sonnet 5.5 at 1M, migrated 78 model references with private registry backup `profiles.json.backup-nu8n64p8`, and found four managed profiles already up to date. Pi sessions were live, so reactivation remains pending.

## Verification evidence
T1 writer observed RED (missing updater), then GREEN after implementation, with failure-stage and non-repo-cwd cases. `bash restoration_scripts/tests/update-workstation.sh`, `shellcheck scripts/update-workstation restoration_scripts/tests/update-workstation.sh`, `git diff --check` passed; parent spot-check reran focused test and diff check successfully. No real updater invocation in tests.
Independent read-only verifier reran those checks plus `bash restoration_scripts/tests/pi-models-upgrade.sh` (8 tests), `bash restoration_scripts/tests/pi-profiles.sh` (19), and `bash restoration_scripts/tests/pi-claude-bridge-1m.sh` (7), all passing. Six managed profiles match repository sources exactly, active remains `codex-low`, Sonnet 5.5 lists with 1M context and GPT-6.1 Sol lists. The legacy `current` and `claude-full` names remain in the local registry. `models.json` is stale (18 old `gpt-6-sol` roles) and Pi settings still default to the old orchestrator ID until profile reapplication. The actual updater was not executed.

## Native review status
RDD is on. Assessment of commit `83e8649` against `1f178d9` was unassessable due unrelated untracked files, so independent verifier was run and native inspect excluded those paths. Native START created high-tier lineage `review-f16a633fb292457d` for the committed five-file candidate. A four-lens group was forecast with no mutation; grouped and individual capture bindings were rejected as unknown/expired, with `mutation_performed: false`. Subsequent bound STATUS still reports `reviewing` and requests four reviewer results; no verdict or approval is claimed.

## Follow-up findings
`cargo install --list` is empty on this machine. Dotly's `cargo::update_all` pipes that empty list into `xargs -n1 cargo install`, which invokes `cargo install` with no crate and emits `not a crate root`; Dotly still prints Done. User authorized editing the independent Dotly submodule. Homebrew installed Herdr 0.9.3 but `herdr status server` reports 0.9.2 from the old Cellar path. Herdr's 0.9.3 install/session-state documentation states Homebrew updates deliberately leave compatible servers running to preserve pane processes; `herdr update --handoff` does not apply to Homebrew installs. User selected a non-destructive warning in `upall`, not an automatic stop.

## Follow-up verification
Dotly submodule branch `fix/cargo-empty-install-list`: `cargo.sh` now iterates parsed crate names instead of calling `xargs` on empty input. Writer recorded RED then GREEN; independent `bash tests/cargo-update-all.sh`, ShellCheck, and `git diff --check` passed. The test covers empty/two-crate cases, not installation failures. An unexpected `.gitignore` addition for `.atl/` and `.codegraph/` are out of scope and must not be staged.
Main repo: `upall` now warns when the installed Homebrew Herdr CLI and the running default server differ, never stops or restarts them. Writer recorded RED/GREEN and independent mocked `bash restoration_scripts/tests/update-workstation.sh`, ShellCheck, and `git diff --check` passed. The real updater was not rerun. RDD `assess` over ambient diff was unassessable because of unrelated untracked paths; independent verifier was run as instructed. Prior native lineage `review-f16a633fb292457d` is still reviewing and does not approve these changes.

## Next step
Ask authorization to commit only the Dotly Cargo fix/test and the main updater/README/test/gitlink (excluding unexpected `.gitignore`, `.codegraph/` and the prior untracked task doc); do not push. Leave Herdr running. Earlier pending Pi profile reactivation and native review remain open.
