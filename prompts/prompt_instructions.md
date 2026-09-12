# Agent Workflow Contract
## Per-Subcommand Routing
| Anchor | Primary subcommand | Load-bearing sections |
|---|---|---|
| `<!-- PAW:PLAN -->` | `paw plan` | Plan: plan-only run |
| `<!-- PAW:IMPLEMENT -->` | `paw implement` | Implement; Implementation Preflight |
| `<!-- PAW:REVIEW -->` | PR feedback planning/implementation | PR Review Feedback; Implementation Preflight |
| `<!-- PAW:EDIT -->` | `paw edit` | Edit work: plan-only refinement |
Shared document, approval, risk, validation, quality and handoff rules apply to every route.
## Standard Task Directory
Central or legacy `.agent/<task>/` packages contain `contract.md` and `plan.md`.
These are local AI working docs, not durable project documentation; never commit them.
With `.github/pull_request_template.md`, use the resolved branch PR body;
legacy task-level `pr.md` remains readable for compatibility.
## Document Contract
### `contract.md`
Capture task summary, repo context, exact user constraints, inputs/links/examples
and unresolved assumptions so a later run can resume accurately.
### `plan.md`
The approved plan is the single planning/progress contract. If materially wrong, stop
and ask; never silently rewrite approved scope during implementation.
Order objective, open questions / follow-ups, implementation phases / checklist,
acceptance criteria, then remaining sections. Use enough vertical slices for the scope.
Every follow-up expecting input needs an indented answer directly below it:
```markdown
- <question>
  - USER ANSWER (UNRESOLVED):
```
Replace a reply with `USER ANSWER (PROVIDED): <answer>` until `paw edit` reconciles it.
Either marker anywhere in plan.md blocks implementation/diagnosis, including examples.
Start every phase item with `- [ ]`. Finish it as `- [x]` and add an adjacent one-line
`Progress:` in the same edit before moving to the next checkbox. Do not batch updates.
```markdown
## Current Status
- Plan position: <short progress summary>
- Estimated completion: 25%
- Next work: <next step; when complete use Review.>
```
Use a bare integer percentage. At 100%, Next work must be `Review.` with only a
genuinely important follow-up if needed. PAW owns `.agent/cost-log.md`; do not hand-edit costs.
### Branch PR Body
Keep reviewer-facing scope, validation and risks concise and current, derived from plan.md.
Every PR creation/update needs relevant screenshot or Mermaid under `## Visual Evidence`,
with explanatory prose before it. Prefer screenshots for UI, Mermaid for nonvisual work.
One visual may cover several tasks; independent Review assesses relevance/rendering.
At wrap-up add task-scoped `## PR Contribution` with concrete `- Outcome:`,
`- Validation:`, `- Risks:` and `- Visual:` fields. Preserve other tasks’ attribution.
Publish only completed, current A-/higher reviewed contributions with no blockers through
an explicit preview/token invocation. Commits and pushes remain manual.
## Approval Model
<!-- PAW:PLAN -->
### Plan: plan-only run
Read needed repo/task files; inspect git status/diff; create/update contract and plan
and the branch PR body when present. Ask high-value task-specific questions when
answers improve scope; skip only well-specified/trivial work. Keep self-checks and
validation inside implementation, independent grading/sign-off and inherited thresholds
in post-implementation Review. Stop for plan review; leave implementation files untouched.
<!-- PAW:EDIT -->
### Edit work: plan-only refinement
Re-read task docs and git status/diff. Ask useful follow-ups, reconcile supplied answers,
and edit only the requested task package. Exit with error if it is missing.
Stop before security-sensitive, deployment or broad structural changes.
<!-- PAW:IMPLEMENT -->
### Implement: autonomous inside approved scope
Perform preflight, resume Current Status, and refuse either answer marker in plan.md.
Complete authorized implementation, docs, tests and validation autonomously; keep progress
current. Stop only at an approval boundary or when the approved plan lacks a safe answer.
### Post-Implementation Wrap-Up
After the last implementation checkbox completes, run the plan’s validation decision
ladder and named full local command after the final implementation change, including
batch, GUI and docs-only runs. Reuse a successful full run on final code; later changes
require another full run. Missing tools/failing checks block 100%/Review.
Check durable docs and behavior-test coverage; add unchecked items for missing tests.
After implementation, docs, tests and required final full validation pass, record 100%
and `Next work: Review.`. Finish routine authorized work without asking for permission.
Keep bounded self-checks inside implementation; independent grading and production
sign-off follow in Review. Preserve task-specific gates and inherited thresholds;
reconcile conflicting old approved plans rather than silently overriding them.
### Pre-authorized routine work
Approved-area edits, routine durable docs, planned/local checks, diff/status review
and small reviewable refactors need no repeated permission.
### Approval boundaries
Stop before unplanned release/Docker/Helm/deployment/infra/CI changes, dependencies,
external services, security/auth/credentials/permissions changes, large restructures,
destructive deletions, ambiguous high-impact options or scope expansion.
Explain the boundary, affected files, options and recommended next step.
## Implementation Preflight
Read task docs and git status/diff; inspect outward as needed and identify durable docs
and validation entrypoints. If an older plan omits the full command, discover and record
it from repo docs/build targets or report a specific blocker. Do not install dependencies
or cross external-service boundaries to clear missing tools.
## Risk Classification
Low (local docs/narrow config) and medium (subsystem/refactor/validation wiring): proceed.
High (release, deployment, permissions, cross-repo/user-facing): explicit plan scope required.
Any approval-boundary crossing requires approval.

<!-- PAW:REVIEW -->
## PR Review Feedback
Run the supplied `$SCRIPT_DIR/gh-pr-comments.sh <pr_number>`; track every INLINE,
REVIEW SUMMARY and PR COMMENT item in `## PR Review Comments`, initially unchecked.
Finish each as addressed, deferred (reason), or declined (reason). Stay within scope.
Re-fetch before handoff, reconcile new comments, and record planned validation results.
## Operating Rules
Keep changes small, readable, reviewable and within scope. Update durable project docs
for changed behavior, commands, workflows, reports, policy/config or validation.
Prefer reusable checks; resume from task docs after interruption.
### Context Pressure
Notify only at meaningful pressure changes (high, near-overflow, or reset after compaction).
Keep notices brief: name pressure, recommend `paw compact <task-name>`, archive stale
detail and split growing tasks. Keep updates lean; refer to docs instead of repeating history.
### Plan Length Budget
AI authors must keep every Markdown file within 150 physical lines, counting blanks,
comments, fences and history. Shorten first; split valuable topics into linked files.
Count and refine internally; do not pack huge lines or truncate evidence. Length is
an AI responsibility, never a CLI/GUI, lint, CI, approval or completion gate.
The operator requests work, then reviews it; retain non-length approval safeguards.
## Code Best Practices
Apply before completing checkboxes. Keep functions/classes readable on one screen or
justify size; use thin replaceable tool adapters, pure functions and composition.
Three cases earn abstraction; keep public exports small and errors specific to file/failure.
Use behavior tests that survive refactoring. Repeat red-green-refactor per vertical slice:
one failing behavior test, one implementation step, repeat; defer test cleanup until then.
## Validation Contract
Start with targeted changed-area checks. Escalate for shared/high-risk or workflow/CI
changes, security, failures, unclear blast radius, explicit request or PR-ready handoff.
The full local command remains mandatory after final implement/diagnose changes.
Record `Validation tier chosen: <targeted|broader|full>` and rationale in plan.md.
Record one named outcome per required check with indented Command/Tier/Log metadata
and code identities. Only an explicit successful same-name rerun supersedes failure;
preserve missing original checks when substitutes pass. Separate Context/Development
history from Implementation results; see [evidence semantics](../examples/docs/testing.md).
Run applicable file-type/unit/integration checks; record missing tools and final diff/status.
## Quality Contract
New plan/edit/prototype outputs use Quality policy version 1 and the
[canonical quality rubric](../examples/docs/quality.md). Include an Acceptance Evidence
table (Criterion, Observable behavior, Planned check, Evidence destination), with a row
for each user constraint and inherited blocker. Preserve explicit inherited thresholds
and sources; A- is the improvement target. Do not retroactively version old plans.
Before final full validation, select applicable risk families, one concrete counterexample
and behavioral check each, and specific exclusion reasons. At wrap-up map rows to actual
named checks and durable log/code identities. Explain waivers without blessing missing
required checks. Independent Review requires A- or higher with no production blockers,
outside implementation checkboxes; explicit older gates remain authoritative.
## Acceptance Criteria
Define concrete, verifiable criteria before implementation, tied to approved scope,
durable docs and required validation.
## Final Response Expectations
Report changes, durable/task docs, validation, risks/follow-ups, git status/diff summary,
and any approved-plan boundary stop. For plan-only runs, state the limited doc scope
and that implementation needs approval.
