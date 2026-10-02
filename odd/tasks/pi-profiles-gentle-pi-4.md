# Prune Pi profiles for gentle-pi 4.0.0 and order them by provider and tier

## Objective
gentle-pi 4.0.0 retired the SDD agents: 13 of the 26 roles in every saved profile now route to agents that no longer exist, and `/gentle:install-sdd`, which script 08 runs twice, is gone. Drop the retired roles, order the profiles by provider and then low/medium/high, apply it to the live registry, and open a PR to master.

## Evidence and constraints
- `lib/agent-assets.ts` `RETIRED_MANAGED_ASSETS` lists `agents/sdd-*.md` (13 roles) and the review-refuter/validator agent files; `~/.pi/agent/agents/` now holds 10 agents.
- `review-refuter` and `review-validator` stay: `lib/review-host-relay.ts` resolves them as routing keys and fails with "no model is configured" without them.
- Registered commands no longer include `gentle:install-sdd`; `gentle:install-delegation` and `gentle:install-review` exist. `session_start` installs both asset owners and then applies the saved models, so one session suffices.
- Writing a role to `subagents.json` merges per name and never drops stale keys, so retired `sdd-*` entries must be removed explicitly.
- Effective TDD: `strict_tdd: true`; runners `restoration_scripts/tests/pi-profiles.sh` and `restoration_scripts/tests/fresh-machine-restore.sh`.

## Tasks
- [x] T1: Profiles with 13 roles in canonical order, ordered claude-low/medium/high then codex-low/medium/high, in the snapshots, the subagents seed, `restore-pi-profiles` validation and its tests.
- [x] T2: Script 08 runs one asset install session (`/gentle:install-delegation`) instead of the retired `/gentle:install-sdd` twice; tests and docs.
- [x] T3: Apply to the live registry, `models.json` and `subagents.json` with private backups; verify equality with the snapshots.
- [x] T4: Full test run, commit, push, PR to master.

## Progress and evidence
- T1 (`c8e38dc`): `pi-profiles.sh` RED on 5 cases (26 roles, old order), then 21/21 GREEN. Snapshots keep 13 roles in canonical order; the subagents seed drops 13 `sdd-*` entries.
- T2 (`8dd9136`): `fresh-machine-restore.sh` RED on 6 cases, then 329/329 GREEN; ShellCheck clean. T1 alone passes 328/328 with `DOTFILES_PATH` set to its own worktree. Without that variable the suite tests the caller's checkout, not the worktree.
- T3: the live registry minus `sdd-*` roles equalled the snapshots before writing. Private backups `profiles.json.backup-d1i76w5n`, `models.json.backup-hwyrwabe`, `subagents.json.backup-vr7sogqp`. One real `pi -p "/gentle:install-delegation"` session exited 0 and left `models.json`, `subagents.json` (10 roles), all 10 agent frontmatters and the orchestrator equal to `claude-medium`, now on Sonnet 5.5.
- T4: `pi-profiles`, `pi-models-upgrade`, `pi-claude-bridge-1m`, `update-workstation` and `fresh-machine-restore` (329) pass; JSON valid. 721 changed lines, 526 of them JSON.
