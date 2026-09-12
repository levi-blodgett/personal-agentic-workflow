# Task templates

| Template | Use |
|---|---|
| [contract.md](contract.md) | Request, exact constraints, repo context and assumptions |
| [plan.md](plan.md) | Approved scope, checklist, status and evidence |
| [pr.md](pr.md) | Branch PR body when a repo has `.github/pull_request_template.md` (either case) |

`paw plan` seeds central packages by default; legacy packages remain supported.
The [agent contract](../prompts/prompt_instructions.md) owns section order, answer
placeholders, adjacent Progress notes and status conventions. See the
[workflow examples](../examples/docs/workflow.md#what-the-task-package-owns).
PAW writes cost tracking separately in `.agent/cost-log.md`.

New plans seed [Quality policy version 1](../examples/docs/quality.md): planned
Acceptance Evidence and independent post-implementation A- / no-blockers Review,
while retaining explicit inherited thresholds. Fill planned checks before approval
and actual named log/code evidence at handoff.
