# Workflow

Plan in the branch/worktree you intend to use. Read and approve the task package,
implement inside that scope, validate, then request independent Review.
The [agent contract](../../prompts/prompt_instructions.md) is authoritative;
prompts guide the agent but do not guarantee compliance.

## Architecture of Workflow

See [Task storage and identity](task-storage.md).

## Overall Workflow

```bash
paw plan my-task "Add the requested behavior with a focused regression."
paw browse my-task
paw edit my-task "Clarify the acceptance criteria."
# Approve the reconciled plan:
paw implement my-task
paw review my-task
# If a complete review calls for replacement:
paw prototype my-task "Preserve the public behavior; address each review blocker."
# Review the replacement plan before approving its later implementation.
```

[README lifecycle diagram](../../README.md) shows the short path.
[CLI reference](cli-reference.md) owns syntax/options; [GUI](gui.md) owns dashboard journeys.

## What The Task Package Owns

### Required follow-up answer workflow

```markdown
- Which output format is required?
  - USER ANSWER (UNRESOLVED):
```

After the user replies, replace the answer line with
`  - USER ANSWER (PROVIDED): <answer>` and run `paw edit <task>` to reconcile it.
Implement/diagnose refuse either marker anywhere in `plan.md`. Tighten can work
with existing placeholders; `plan.md` remains the approved source of truth.

### Implementation checklist discipline

Use enough vertical slices for the scope. For behavior changes repeat red-green-refactor:
one behavior-focused failing test, one implementation to pass it, then the next slice.
Defer test cleanup until that loop is complete. When finishing a checkbox, add its
adjacent Progress note in the same edit before moving on:

```markdown
- [x] Deliver the version flag and its behavior test.
  Progress: --version prints the expected version; version-output test passes.
```

`paw lint` checks sections/status and adjacent progress. AI authors count all physical
lines and keep Markdown within 150 by shortening or linking valuable detail. Length
never blocks commands or changes a successful run to failure. `paw compact <task>` moves completed detail to linked bounded files.
PAW owns repo-level `.agent/cost-log.md`.

```markdown
## Current Status

- Plan position: Approved implementation and final validation complete.
- Estimated completion: 100%
- Next work: Review.
```

Use a bare integer percentage. At 100%, Next work is `Review.` with only a genuinely
important follow-up if needed. [Testing](testing.md) owns the targeted-to-full ladder,
named results and mandatory final full validation. [Quality](quality.md) owns bounded
self-checks and acceptance evidence. Missing required checks block handoff.

### Branch and worktree assignment

PAW records the existing branch/worktree during plan in local Git common-dir metadata;
it creates neither. Saved assignments are shared across sibling worktrees and reused
by task commands when safe. Re-execution in another registered same-repo worktree
requires the current worktree clean except local `.agent/` docs. Unsafe dirty-state
clobbering, auto-detachment, invented/unborn branches and cross-repo/common-dir hops
stop for manual correction.

`paw implement-batch task-a task-b` preflights the entire selection before launch:
missing, duplicate, completed, running or answer-blocked tasks reject the batch.
Each child uses normal implement. PAW supplies no scheduler/conflict resolver;
use separate branches/worktrees for overlapping work and inspect child outcomes.

### Local GUI

See [GUI start/stop, repo selection, queue and recovery](gui.md).

### A `paw implement` run in detail

CLI → task/assignment guards → launch banner → backend → updated task docs/results.
Backend completion alone does not prove validation or production readiness.
Successful runs may capture verified cleanup provenance; see below.

### Implementation handoff and review grades

Replacement planning creates a plan for a later `paw implement` run. Once approved
implementation, documentation, tests and final full validation pass, record 100%
and `Next work: Review.`. Independent grading and inherited production quality
thresholds belong in the subsequent Review stage; 100% describes implementation
completion, not production sign-off. Self-checks and genuine blockers remain part
of implementation. Reconcile explicit conflicting old approved gates per task;
existing task histories are not automatically rewritten.

Reviews should write plain metadata, for example `- Grade: B+` under
`## Review Metadata`, with explanations and threshold results in separate fields.
The GUI also reads case-insensitive A/B/C/D/F grades with optional plus/minus,
one balanced bold, italic or backtick wrapper, and an optional final period.
Supported grades share badge text, color and prototype eligibility (A- or higher
blocks prototype). Pending/empty grades have no badge; unsupported values remain
escaped neutral text without a guessed rank. Review files are preserved.

## Review completion and inherited findings

See [Review and prototype lifecycle](review-workflow.md).

## Troubleshooting Crashes

See [Handoff and publication](publication-workflow.md).
