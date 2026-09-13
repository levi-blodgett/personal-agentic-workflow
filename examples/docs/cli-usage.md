# Command usage and authoring

[Back to cli-reference](cli-reference.md).

### Task Store And GUI

[Task layout and migration](workflow.md#architecture-of-workflow),
[GUI journeys](gui.md), [recorded validation](testing.md#recorded-validation-in-the-gui).

### Batch implementation

[Selection preflight and worktree limits](workflow.md#branch-and-worktree-assignment).

### `paw completion zsh`

```bash
autoload -U compinit && compinit
source <(paw completion zsh)     # current shell
paw completion zsh >> ~/.zshrc # future shells
```

Only top-level zsh subcommands are completed (for example `paw gh-` + Tab).
See [installation](install.md#optional-zsh-completion).

### Branch/worktree assignment

[Recorded assignment and safe resume](workflow.md#branch-and-worktree-assignment).

### Required follow-up answer workflow

[Answer placeholders and edit reconciliation](workflow.md#required-follow-up-answer-workflow).

### Implementation checklist discipline

[Adjacent Progress notes and status format](workflow.md#implementation-checklist-discipline).

### Extra prompt argument (`paw implement` / `paw diagnose` / `paw tighten` / `paw edit`)

```bash
paw implement my-task "Focus on the README diff; run the required validation."
paw diagnose flaky-test "Find the shortest deterministic reproduction."
paw tighten my-task "Pressure-test the acceptance criteria."
paw edit my-task "Tighten the non-goals."
```

Trailing positional arguments join into `Human extras:` without replacing the standard
prompt; omitted extras add no header. GUI implementation sends no extras after approval.

### `paw diagnose`

Use when reproduction/root cause is still unknown; approved fixes may finish in the
same run. The plan records the feedback loop, ranked hypotheses, instrumentation and
cleanup. [Validation](testing.md) applies to both implement and diagnose.

### `paw tighten`

Use for ambiguous scope/acceptance before implementation. Existing answer placeholders
are allowed; the checkpoint does not replace the approved plan. Optional durable docs
belong only where the repo/conversation establishes a lasting decision or glossary need.

### `paw teach`

```bash
paw teach "focus on command dispatch and branch/worktree assignment"
```

A discovered implementation need should become an explicit follow-up plan.

### `paw review` / `paw prototype`

Review loads `$PAW_HOME/templates/review.md` on demand; invalid resources fail before
backend launch and preserve prior review state. See the
[template lifecycle](workflow.md#review-completion-and-inherited-findings).

```bash
paw review my-task "Also grade the current review/prototype workflow and cleanup readiness."
paw prototype my-task "Preserve the CLI behavior and address every source blocker."
```

Review records task scope/grade, threshold/result, design choices, blockers and
recommendations; requested overall subsystem grading is additional.
Replacement plans retain a Prototype Source section with source/review/grade and cleanup
context. See [completion and inheritance](workflow.md#review-completion-and-inherited-findings)
and [cleanup proof and recovery](review-workflow.md#prototype-cleanup).

### `paw architecture`

```bash
paw architecture "focus on test/data seams"
paw architecture --pick 2 "Prefer the smallest reviewable seam."
```

### Shared command authoring contract

When adding a new top-level `paw` command, treat the shell surface as shared infrastructure:

- Add the public entry once in `_paw_command_table()` so `paw help`, completion, and dispatch do not drift.
- Add AI-backed entries to `_paw_model_command_table()` so `paw model` reflects the same command set that actually resolves models and launches prompts.
- Reuse the shared prompt/template helpers in `scripts/paw` instead of copying heredoc assembly, task-template seeding, or `Human extras:` formatting into each command body.
- Update `tests/paw-dispatcher.bats` and `tests/paw-prompt-body.bats` with the smallest coverage that proves dispatch, prompt anchor/body, and launcher behavior for the new command.
- In the resolved task package for that command, record which upstream skill files and repo touchpoints were actually inspected so later resumes have a verifiable trail.
