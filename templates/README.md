# `templates/`

Empty skeleton files for the task package. `paw plan` copies these into `.agent/<task-name>/` when creating a new task.

## Files

| Template | Purpose |
|----------|---------|
| [`contract.md`](contract.md) | Raw task request, constraints, repo context, and unresolved assumptions. |
| [`plan.md`](plan.md) | Single task surface for planning and implementation progress: objective, questions, implementation checklist, acceptance criteria, scope, status, validation, decisions, and handoff notes. |
| [`pr.md`](pr.md) | Concise PR-ready description derived from `plan.md`. **Opt-in:** only seeded by `paw plan` when the repo has `.github/pull_request_template.md` (either case). Omit from prompt context and lint checks when absent. |

## Conventions to note

- `prompts/prompt_instructions.md` is the canonical rulebook. Keep templates, examples, fixtures, and docs aligned with it instead of restating rules loosely.
- `plan.md` section order is fixed: `Objective`, `Open Questions / Follow-Ups`, `Implementation Phases / Checklist`, `Acceptance Criteria`, then the remaining sections.
- Follow-up questions use the indented `USER ANSWER (UNRESOLVED):` / `USER ANSWER (PROVIDED):` placeholder pattern. `paw implement` stays blocked until `paw edit` reconciles any provided answer back into the plan.
- Implementation checklist items stay `- [ ]` until complete. When you flip one to `- [x]`, add an adjacent one-line `Progress:` note in the same edit.
- Keep the `## Current Status` fields (`Plan position`, `Estimated completion`, `Next work`) current and keep the working surface lean. Use `paw compact <task>` if the task grows noisy.
- Task plans do not own cost tracking. `paw` appends repo-level entries to `.agent/cost-log.md`.

See `prompts/prompt_instructions.md` for the full workflow contract these templates implement.
