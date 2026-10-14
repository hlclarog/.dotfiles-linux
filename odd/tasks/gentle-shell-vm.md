# Gentle Shell on fresh and existing VMs
Branch: `feat/gentle-shell-vm`; base: `3e9611cbe60b128f1bd463b39974f89523c8f100`; delivery: ask-on-risk, no push/PR.
Checks: Bash mock suites with disposable HOME; test-first. Forecast: approximately 350 authored lines. Risk: item 5 (installation); implement inline, independent verify at feature end.

## Specs
S1. "que de estos comandos puedes ejecutar por mi. y dejar listo para ejecutar para mis otras vm recuerda que tengo que aplicar este cambio para mis nuevas vm y mis antiguas". Check: one migration command for existing machines; restoration integration for fresh machines; run against isolated fixtures.
S2. "Con gentle-shell, reutilizando Pi (recomendado)" — "Añadir el launcher y usar --link para conservar tus accesos, modelos y conversaciones actuales." Check: default linked home and existing managed Pi, forwarded arguments and status, no global duplicate installation.
S3. "Sí, conservando configuración y credenciales" — "Permitir comprobaciones y cambios necesarios sin borrar ni mostrar credenciales; conservar perfiles existentes." Check: synthetic configuration/auth/session/profile bytes remain unchanged; do not print live secrets.
S4. "Sí, dejar gentle-shell disponible en la terminal" — "Crear el enlace necesario y comprobarlo; conservar la instalación actual de Pi." Check: ~/.local/bin/gentle-shell links to dotfiles wrapper; collisions are rejected without overwriting.
S5. "Sí, commits locales por unidad de trabajo" — "Conservar implementación, pruebas y documentación en una rama recuperable; no publicar nada." Check: local work-unit commits on feature branch, no push/PR.

## Tasks
T1 | S1-S5 | inline (one cohesive launcher/migration unit) | done | implementation + tests + docs: commit `09276a1ca5bffb5a9d0862cdd30df0377184bb52`.
T2 | S2-S5 | inline | in_progress | applied successfully, version/readiness and preservation observed; rollout-evidence commit pending.
T3 | S1-S5 | independent gentle-ai-verify (risk item 5), parent native assessment | pending | evidence/closure commit pending.

## Log
L1. Original implementation request: "que de estos comandos puedes ejecutar por mi. y dejar listo para ejecutar para mis otras vm recuerda que tengo que aplicar este cambio para mis nuevas vm y mis antiguas".
L2. User chose S2/S3, then S4/S5. External changes authorized only in /home/hclaro/.pi/agent, /home/hclaro/.pi/gentle-ai and /home/hclaro/.local/bin/gentle-shell. No session restart or publication authorized.
L3. User: "reanudar". Interrupted mapping was cancelled; explicitly resumed once. Repository clean on master before new feature branch.
L4. Installed package metadata: gentle-pi 4.2.0 with bin/gentle-shell.mjs; managed Pi 1.2.0. Launcher --link skips auto-setup. Use installed package, explicitly prefer managed Pi, keep Pi update ownership. Do not downgrade to 4.1.0 from older README guidance.
L5. Plan: wrapper uses existing package and Node; explicit migration repairs missing launcher through Pi, safely installs local link, never copies credentials; new restoration step after 08-pi.sh. Existing upall stays unchanged. Native launcher handles special subcommands and explicit home selection without conflicting injected flags.
L6. T1 RED: isolated suite failed for missing wrapper (exit 1). GREEN: public wrapper/migration mock suite passed. Extra RED for missing explicit GENTLE_SHELL_PI (exit 1), corrected. Existing restore suite failed 2/330: new step lacked first-line exec </dev/null and expected ordering omitted 08-shell.sh; both corrected. Update-workstation suite exit 0. ShellCheck initially reported intentional child expansion SC2016; annotated and now exit 0. Final focused suite, bash -n and git diff --check exit 0; corrected full restore suite job-4 passed 330/330 (exit 0). No live installation applied yet.
L7. T1 committed as 09276a1 (354 insertions, including tracker). Authoritative local tracker is updated; mem_update failed on provider expected_project validation, so mirror is refreshed with mem_save and explicit project. T2 starts with package reuse, protected-file snapshot and version-only probes; no session is started or restarted.
L8. T2 live job-5 exit 0 (7s): migration and --check succeeded; gentle-shell 4.2.0, pi 1.2.0, home link /home/hclaro/.pi/agent. Link: ~/.local/bin/gentle-shell -> tools/gentle-shell/gentle-shell in this checkout. Eleven protected file entries unchanged; no new session files. No global install or configuration regeneration required.
L9. Native ASSESS over committed T1 (base 3e9611c, HEAD 09276a1) returned high/nativeRisk high, writerProfile large, independentVerifier true, RDD on and reviewDue true. No native START yet; independent verification runs before review.
