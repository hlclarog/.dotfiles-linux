# Adopt Claude Opus 5.5 in Pi profiles

## Objective
Replace every live `claude-bridge/claude-opus-5` assignment in Pi's `current`, `claude-full`, and `claude-full.autogen` profiles with `claude-bridge/claude-opus-5-5`, preserving thinking levels, unrelated models, credentials, and active profile; keep a portable copy in dotfiles.

## Evidence and constraints
- Installed `pi-claude-bridge` 0.8.0 with Pi 0.87.1: `pi --offline --list-models opus-5-5` lists the exact bridge model; one minimal `pi --print --no-session --no-context-files --no-tools --provider claude-bridge --model claude-opus-5-5 --thinking off` invocation returned `OK`.
- Live registry: `current` and `claude-full` use Opus 5 in 22 roles each; `claude-full.autogen` uses it in 5 roles. `open-ai-full.autogen` uses none. Leave `.export` files and historical backups untouched.
- Save only sanitized `model`/`thinking` mappings in the public repo; never copy `auth.json` or raw registry. Existing `.codegraph/` is untracked and out of scope.
- Effective TDD: strict on from `~/.gentle-ai/state.json` (`strict_tdd: true`); exact runner: `bash restoration_scripts/tests/pi-claude-opus-upgrade.sh`. T1 delegated to `gentle-ai-worker` (two non-trivial files); T3 independent verification to `gentle-ai-verify`. User authorized push to `feat/pi-openai-profile-backup` only, no master integration.

## Tasks
- [x] T1: Implement/test an explicit safe Opus 5 -> 5.5 migration with backup, conflict/no-op handling, and no live edits in tests. Check: old refs replaced, 49 changes, unrelated fields and active unchanged, invalid/symlink registries refused.
- [x] T2: Apply once to the live Pi registry, verify exact mappings, then store a sanitized snapshot of the three updated Claude profiles in the repo with recovery instructions. Check: private original backup, 49 updated mappings, 0 old mappings in live profiles, no secrets in snapshot.
- [x] T3: Independently verify tests, artifact equality and diff scope; commit the work unit and push only the selected branch if native review policy permits. Record commit and publication evidence.

## Progress
T1 complete: `scripts/upgrade-pi-claude-opus` and isolated tests added. T2 complete: live migration replaced 49 exact refs, preserved the active OpenAI profile and unrelated fields, and created private exact-byte backup `~/.pi/gentle-ai/profiles.json.backup-h_ib1_tz`. `config/pi/claude-profiles.json` captures the three Claude profiles without credentials or active selection (two roles intentionally lack a thinking field). Docs explain that fresh-registry restoration from this snapshot is manual. Prior OpenAI backup was committed as b682165 and published with metadata commit 069cf39 to the selected feature branch.

## Verification evidence
T1: worker observed RED before implementation, then six behavior tests GREEN with executable-mode test RED, then 7/7 GREEN after chmod; shell syntax, in-memory Python compile, and diff check passed. T2: live old refs 49 -> 0 and new refs 0 -> 49; comparing the private backup after exactly these replacements to the live registry showed every other field and active unchanged. Snapshot has 3 x 26 roles, 49 new refs, 0 old refs, exact normalized equality to selected live profiles, no keys beyond model/thinking; focused 7-test suite passed. Independent verifier reran 7/7 tests, shell syntax, in-memory Python compile, `git diff --check`, and snapshot/live/backup comparison (49 exact replacements, unrelated fields unchanged, mode 0600). Git status was unchanged before and after. Untracked files are outside `git diff --check`; concurrent writes and fresh-registry recovery were not tested. A model listing alone would not establish runtime access; the minimal inference above succeeded. No `max` thinking inference was run.

## Commit and publication evidence
Work-unit commit: `5412d6ee72608c590da3db6f582ef5b7b9611b6c` (`feat(pi): migrate Claude profiles to Opus 5.5`). Independent post-commit verification reran 7/7 tests, confirmed five intended paths (no `.codegraph/`), exact 49 updated/0 old IDs in snapshot and live registry, 3 x 26 roles, HEAD bound to commit and unchanged git status. Native review inspect/assess could not run (`package-local-binary-missing`); no native approval claimed. Test runner's disposable sandbox also wrote `unrelated.json` beside its temporary HOME, then cleaned up; verifier flagged this as outside its narrowly stated temporary-HOME authorization, with no lasting writes.

## Next step
Published `feat/pi-openai-profile-backup` to origin after independent verification; `master` remains at `d2b3131` and `.codegraph/` remains untracked. User decides whether to integrate the branch. Restart Pi before using a Claude profile; a fresh Pi registry still needs manual Claude snapshot recovery.
