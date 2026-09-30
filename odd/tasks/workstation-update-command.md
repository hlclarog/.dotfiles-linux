# Update workstation packages and Pi profiles

## Objective
Provide one shell alias to run the existing dotly package updater and Pi core, extension and model-catalog updates, including the required local Claude bridge 1M patch. Apply newly merged repository Pi profiles locally without changing the active choice.

## Evidence and constraints
- Existing `up` is `dot package update_all` in shared `shell/aliases.sh` (Bash/zsh). The new alias should not replace it. User requests one additional convenient command; call it `upall` and route nontrivial logic through a standalone script.
- Pi 0.87.1 supports `pi update`, `pi update --extensions`, and `pi update --models`. `doc/INSTALL.md` documents the pin caveat for `--extensions` on a fresh restore; do not claim that it updates every pinned package. Bridge package updates remove the local 1M Sonnet 5.5 patch; rerun `scripts/patch-pi-claude-bridge-1m` after Pi updates.
- `origin/master` merged #38 (`1f178d9`) with Sonnet 5.5 and GPT-6.1-sol profile mappings; local CLI lists both. On existing registries, run `scripts/upgrade-pi-models`, then `scripts/restore-pi-profiles --replace` for the four managed profile names, preserving active `codex-low`. A Pi restart and re-application of the active profile is documented to synchronize agent frontmatter and effective settings; do not present registry edits alone as complete running-session activation.
- Preserve existing untracked `.codegraph/` and `odd/tasks/pi-sonnet-5-5-profiles.md`; never stage either. No implicit `git pull` inside the updater: pull happened explicitly and a generic workstation update should not silently alter the user's Git checkout.
- Strict TDD enabled from `~/.gentle-ai/state.json`; new focused test command `bash restoration_scripts/tests/update-workstation.sh`, with mocked external commands and RED before GREEN. Include shellcheck and `git diff --check`. RDD switch on; assess the work-unit commit per native instructions.
- Delivery strategy `ask-on-risk`; forecast below 250 authored diff lines (alias, script, test, brief documentation). One cohesive PR-sized unit. User has not requested push/PR here.

## Tasks
- [ ] T1: Add tested `upall` alias and fail-visible serial updater invoking dotly, Pi self, Pi extensions, Pi model catalog, then the bridge patch. Implementation and checks complete; work-unit commit awaits explicit user authorization.
- [ ] T2: Safely apply merged profile migrations and bridge patch to local installation, compare managed mappings, preserve active choice and private backup; verify status and document any restart/reapply step. Registry and patch applied; effective `models.json` and Pi default still need activation from `/gentle:profiles` after restart.
- [ ] T3: Verify Git diff and local outcome, report command behavior, downloaded changes and any incomplete checks. Independent checks passed except the known effective-model mismatch; work-unit commit pending explicit user authorization. Do not push unless separately requested.

## Progress
Created feature branch `feat/workstation-update-command` at master `1f178d9`. T1 implemented in `shell/aliases.sh`, `scripts/update-workstation`, `restoration_scripts/tests/update-workstation.sh` and `README.md`; unrelated untracked work left untouched. Work-unit commit pending. T2 patched the installed bridge for Sonnet 5.5 at 1M, migrated 78 model references with private registry backup `profiles.json.backup-nu8n64p8`, and found four managed profiles already up to date. Pi sessions were live, so reactivation remains pending.

## Verification evidence
T1 writer observed RED (missing updater), then GREEN after implementation, with failure-stage and non-repo-cwd cases. `bash restoration_scripts/tests/update-workstation.sh`, `shellcheck scripts/update-workstation restoration_scripts/tests/update-workstation.sh`, `git diff --check` passed; parent spot-check reran focused test and diff check successfully. No real updater invocation in tests.
Independent read-only verifier reran those checks plus `bash restoration_scripts/tests/pi-models-upgrade.sh` (8 tests), `bash restoration_scripts/tests/pi-profiles.sh` (19), and `bash restoration_scripts/tests/pi-claude-bridge-1m.sh` (7), all passing. Six managed profiles match repository sources exactly, active remains `codex-low`, Sonnet 5.5 lists with 1M context and GPT-6.1 Sol lists. The legacy `current` and `claude-full` names remain in the local registry. `models.json` is stale (18 old `gpt-6-sol` roles) and Pi settings still default to the old orchestrator ID until profile reapplication. The actual updater was not executed.

## Next step
Restart Pi and reapply `codex-low` with `/gentle:profiles` to synchronize effective models/settings/agents; then verify. Ask before committing the tested updater. Do not stage unrelated untracked paths or push without explicit request.
