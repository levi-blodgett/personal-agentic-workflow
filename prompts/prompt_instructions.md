# Agent Workflow Contract

## Per-Subcommand Routing

| Anchor | Primary subcommand | Load-bearing sections |
|---|---|---|
| `<!-- PAW:PLAN -->` | `paw plan` | Plan: plan-only run |
| `<!-- PAW:IMPLEMENT -->` | `paw implement` | Implement: autonomous inside approved scope; Implementation Preflight |
| `<!-- PAW:REVIEW -->` | `paw pr-address-comments` + `paw implement <pr-number>-review` | PR Review Feedback; Implementation Preflight |
| `<!-- PAW:EDIT -->` | `paw edit` | Edit work: plan-only refinement |

Shared sections apply universally: Document Contract, Approval Model, Risk Classification, Validation Contract, Acceptance Criteria, Final Response Expectations.

## Standard Task Directory

```text
.agent/<task-name>/
  contract.md
  plan.md
  pr.md           (only seeded when repo has .github/pull_request_template.md)
```

All `.agent/` files are local-only AI working docs — not project documentation. Do not commit `.agent/` files.

<!-- PAW:REVIEW -->
## PR Review Feedback

1. Run `$SCRIPT_DIR/gh-pr-comments.sh <pr_number>` (exact path given in the review-feedback prompt). The script emits three labelled groups: `INLINE path:line`, `REVIEW SUMMARY @author (state)`, `PR COMMENT @author`.
2. In `plan.md`, add a `## PR Review Comments` block listing every fetched item:
   ```
   - [ ] INLINE src/foo.ts:42 — @reviewer1: short summary — status: pending
   ```
   Every item must reach `- [x]` with status `addressed`, `deferred (reason)`, or `declined (reason)` before the run ends.
3. Address only in-scope comments; stop before scope expansion, high-risk changes, or plan conflicts.
4. Before declaring done: re-run `gh-pr-comments.sh` and diff against the tracked list to catch newly posted comments. Then run the plan's Validation Contract and record results in `plan.md → "Validation Performed"`.

## Document Contract

### `contract.md`

Capture: task summary, repo context, user constraints (exact, not paraphrased), inputs/links/examples, unresolved assumptions. Use as starting context for future resumes.

### `plan.md`

- `plan.md` is the single task surface for both planning and implementation progress.
- Plan-only runs update only `.agent/<task>/`; leave implementation files untouched.
- Treat the approved `plan.md` as the contract. If implementation reveals the plan is materially wrong, stop and ask instead of rewriting the plan mid-flight.
- Order sections as: objective, open questions / follow-ups, implementation phases / checklist, acceptance criteria, then the remaining sections.
- Make the implementation plan as thorough as the task warrants. Use multiple phases or slices when needed; do not compress substantial work into a single checkbox just to stay short.
- Every follow-up question that expects user input must include an indented hyphenated answer placeholder directly beneath it:
```markdown
- <question>
  - USER ANSWER (UNRESOLVED):
```
- When the user replies, replace the placeholder with `USER ANSWER (PROVIDED): <answer>` until a later `paw edit` run reconciles that answer into the plan. `paw implement` remains blocked while either placeholder form exists anywhere in `plan.md`.
- Every phase item must be `- [ ]`.
- Prefer vertical slices over horizontal workstreams. Do not plan "frontend first, backend second, tests last"; plan thin end-to-end slices that deliver behavior incrementally.
- Make TDD explicit as repeated vertical slices: follow red-green-refactor, write one behavior-focused failing test, make that single test pass with one implementation step, repeat, and defer test-cleanup refactors until the implementation loop is complete.
- When a checkbox is completed, flip it to `- [x]` and add a one-line `Progress:` note directly beneath that checkbox in the same edit before moving to the next checkbox. `paw lint` must be able to see that adjacent `Progress:` line.
- Keep the `## Current Status` section updated with:
```markdown
## Current Status

- Plan position:
- Estimated completion:
- Next work:
```
- **Cost log:** `paw` appends repo-level entries to `.agent/cost-log.md`; do not hand-edit task `plan.md` for cost tracking.

### `pr.md`

Only seeded when repo has `.github/pull_request_template.md`. Keep concise, derived from `plan.md`; update when reviewer-facing scope, validation, or risk notes change materially.

## Approval Model

<!-- PAW:PLAN -->
### Plan: plan-only run

1. Create or update `.agent/<task>/`.
2. Inspect `git status` and `git diff`.
3. Read only files needed for the plan.
4. Ask the user the highest-value task-specific clarifying questions whenever better answers would materially improve the plan; ask as many follow-ups as the task needs. Skip this only when the task is already well-specified or genuinely trivial.
5. Update `contract.md`, `plan.md`, and `pr.md`.
6. Stop; ask user to review. Do not modify project files outside `.agent/<task>/`.

<!-- PAW:EDIT -->
### Edit work: plan-only refinement

1. Re-read task docs; inspect `git status` and `git diff`.
2. Ask follow-up questions whenever they would materially improve the revised plan; ask as many as needed, not an arbitrary cap.
3. Apply requested changes confined to `.agent/<task-name>/`; do not modify project files.
4. Stop before security-sensitive, deployment, or broad structural changes.

Exit with error if task directory is missing.

<!-- PAW:IMPLEMENT -->
### Implement: autonomous inside approved scope

1. Read task docs; inspect `git status` and `git diff`; identify the validation entrypoint.
2. Continue from the `## Current Status` section.
3. Refuse to proceed when the task plan still contains follow-up placeholders. `paw implement` must not run while any `USER ANSWER (UNRESOLVED):` or `USER ANSWER (PROVIDED):` line remains in `plan.md`; those markers mean the user still needs to answer, or answered feedback still needs to be reconciled through `paw edit`.
4. Proceed autonomously for in-scope implementation, documentation, tests, and validation.
5. Keep `plan.md` current, including immediate checkbox flips and one-line `Progress:` notes directly beneath each completed item in the same edit; do not batch several completed items before updating the plan.

Stop only for approval-boundary crossings or when the approved plan no longer gives a safe answer. If the plan is materially wrong, bail out and ask rather than rewriting it in place.

When the last `- [ ]` flips to `- [x]`, run the **Post-Implementation Wrap-Up** gate:

1. Re-run full validation (plan's "Validation Contract"); record in `plan.md` → "Validation Performed". Failures block wrap-up.
2. Walk "Durable Documentation Requirements"; update stale docs.
3. Confirm tests exist (or waived) for every behavior change; missing tests → new `- [ ]` items.
4. Then update `## Current Status` to 100% and write final handoff summary.

### Pre-authorized routine work

No repeated permission needed for: edits inside approved files or areas, routine durable doc updates, the planned validation entrypoint, local validation plus diff/status review, and small reviewable refactors.

### Approval boundaries

Stop before: release/Docker/Helm/deployment/infra/CI changes beyond the plan; new dependencies or external services; security/auth/credential/permissions changes; large restructures; destructive deletions; ambiguous high-impact options not in the plan; scope expansion.

When stopping: summarize boundary, impacted files, options, recommended next step.

## Implementation Preflight

Before any implementation run: read task docs, inspect `git status` and diff, inspect outward as needed, identify the validation entrypoint, and confirm which durable project docs must change.

## Risk Classification

- **Low:** local docs, narrow config updates, in-scope changes with low blast radius — proceed autonomously.
- **Medium:** multi-file implementation in one subsystem, validation wiring, behavior-preserving refactors — proceed autonomously.
- **High:** release gates, deployment, permissions, cross-repo, user-facing — proceed only when plan explicitly covers the change; otherwise stop.
- **Approval required:** any approval-boundary crossing.

## Operating Rules

- Keep changes small, readable, and reviewable; stay within task scope; prefer existing repo conventions.
- Do not treat `.agent/` notes as durable repo docs.
- Update durable project docs whenever behavior, commands, workflows, reports, policies, config, validation steps, or user-facing behavior change.
- Prefer reusable validation over ad hoc commands.
- Resume from task docs if rate-limited or interrupted.

### Context Pressure

- When context pressure is materially rising, notify the user only at meaningful pressure changes: first high-pressure signal, near-overflow, or after a compaction/split resets the risk. Do not repeat the same warning every turn.
- That notification must stay brief and action-oriented: name the pressure level, recommend `paw compact <task-name>`, tell the user to archive stale detail, and split the task if growth continues.
- When pressure is high, the agent should keep its own progress updates lean: prefer file paths, diff summaries, and task-doc references over pasting large snippets or re-explaining settled context.
- Keep the working surface lean enough for those notifications to be useful: summarize resolved details once, compact completed phases instead of appending long status history, and avoid adding prompt/template prose that reduces available task headroom without adding operational value.

### Plan Length Budget

`plan.md` working surface ≤ 350 lines. Move overflow under `### Archived ...` appendix at the bottom (excluded from lint). Run `PAW_LINT_LENGTH=1 paw lint <task>` to check.

## Code Best Practices

Apply before flipping any `- [ ]` to `- [x]` in `<!-- PAW:IMPLEMENT -->`/`<!-- PAW:REVIEW -->`; plan commits to these in `<!-- PAW:PLAN -->`.

- **Small and readable.** Functions/classes fit on one screen; if not, justify it.
- **No hard tooling assumptions.** Any tool should be replaceable without rewrites — thin adapters at the boundary.
- **Composition over inheritance.** Prefer pure functions; prefer composition for extension.
- **No premature abstraction.** Three cases earn an abstraction; one or two do not.
- **Small public surface.** Every exported name is a future migration cost.
- **Useful error messages.** Name the file and failed expectation; never just "error".
- **Tests assert behaviour.** Survives clean refactor; fails only when behavior changes, not when implementation details are reorganized.
- **Vertical slices.** Ship narrow end-to-end increments; avoid subsystem-first horizontal phases.
- **Test first.** Follow red-green-refactor: write one behavior-focused failing test, make that single test pass with one implementation step, repeat, then refactor production code and tests after the loop if cleanup is still needed.
- **Plan length budget.** See "Plan Length Budget" above.

## Validation Contract

Prefer an existing Makefile target; add one when none exists. Run the relevant file-type checks (YAML, shell, JSON, workflow, unit, integration). Record commands run, results, unavailable tools, and the final `git status` plus diff review.

## Acceptance Criteria

Every plan must define concrete, verifiable criteria before implementation: mapped to approved scope, testable or reviewable, including required durable doc updates and the validation needed for handoff.

## Final Response Expectations

At handoff, report changes made, durable doc updates, `.agent/` doc updates, validation results, risks or follow-ups, git status plus diff summary, and whether implementation had to stop because the approved plan no longer gave a safe answer. For plan-only runs, note that only `.agent/<task>/` changed and implementation starts only after user approval.
