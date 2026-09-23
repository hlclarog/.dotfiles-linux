# Preserve Pi OpenAI profile

## Objective
Keep the recovered 26-role `open-ai-full.autogen` agent-model mappings in dotfiles and make them recoverable without storing credentials or overwriting unrelated live Pi profiles.

## Scope and constraints
- Source: `~/.pi/gentle-ai/profiles.json`, recovered OpenAI profile only.
- Store an allowlisted profile with `model` and `thinking` values; no auth, sessions, cache, other profiles, or `active` selection.
- Provide an explicit, manual restore path that validates input and preserves an existing registry. Do not automatically overwrite a live profile or change `active`.
- Do not touch pre-existing untracked `.codegraph/`. User authorized commit and push to feature branch on 2026-09-23; no master integration.
- Effective TDD: strict on, from `~/.gentle-ai/state.json` (`strict_tdd: true`); exact focused runner: `bash restoration_scripts/tests/pi-openai-profile.sh`.
- Routing: T1/T2 delegated to `gentle-ai-worker` (multi-file write and preparation trigger); T3 independent verification routed to `gentle-ai-verify`.

## Tasks
- [x] T1: Save the validated recovered OpenAI profile in a portable repository artifact. Check: 26 roles match the live source, all models are `openai-codex/*`, no credential-like keys.
- [x] T2: Add a safe manual restore script and usage documentation. Check: tests cover absent registry, existing unrelated profiles, identical target, conflicting target, explicit `--replace` recovery, malformed input; no loss or secret exposure.
- [x] T3: Independently verify repository artifact, restore tests, shell syntax, diff/secret scan, and report limitations. Check: actual command results recorded.

## Progress
T1 complete: `config/pi/open-ai-full.autogen.json` stores exactly the recovered 26 `model`/`thinking` mappings; `.codegraph/` was untracked before this work. T2 complete: manual CLI defaults to no overwrite, supports explicit backup-then-`--replace`, and now rejects nonfinite JSON overflow (`1e400`/`-1e400`) before writing. Effective TDD mode was forwarded from live `~/.gentle-ai/state.json`.

## Verification evidence
T1: `jq` schema and normalized equality checks against the recovered live profile passed. T2: worker observed two replacement tests RED, then 11 tests GREEN, followed by four overflow failure cases RED and 12 tests GREEN after the parser correction. T3: independent verifier reran `bash restoration_scripts/tests/pi-openai-profile.sh` (12/12 passed), shell syntax, in-memory Python compile, `git diff --check`, and artifact/live equality (true, 26 mappings). Secret-field scan found only `model`/`thinking`; test writes remained in disposable temp homes. `git diff --check` does not cover untracked files. Live restore, concurrent writes/crash recovery, and provider availability were not tested.

## Next step
Local backup and manual recovery path are ready. User authorized publication to `feat/pi-openai-profile-backup`; commit identity pending, no master integration. Existing `.codegraph/` remains untouched.
