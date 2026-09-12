# Plan — `<task-name>`

## Objective

<one-sentence statement of the outcome>

## Open Questions / Follow-Ups

- <question that requires user input, or "None.">
  - USER ANSWER (UNRESOLVED):
<!-- Replace the answer line with `USER ANSWER (PROVIDED): <answer>` after the
user replies, then run `paw edit <task>` before `paw implement`. -->

## Implementation Phases / Checklist

<!-- Use `- [ ]` per item. Prefer vertical slices, make TDD explicit, and add
     an adjacent `Progress:` line in the same edit whenever you flip an item to
     `- [x]`. Keep notes lean when context pressure is building. -->

- [ ] <step>
  Progress: <one-line note added only when the item is complete>

<!-- Independent grading and production sign-off belong in a post-implementation
     Review requirement, outside implementation checkboxes. After approved work
     and final full validation pass, record 100% and Next work: Review.
     Preserve explicit task-specific gates; reconcile conflicts before proceeding. -->

## Acceptance Criteria

- [ ] <testable / reviewable criterion>
- [ ] Post-Implementation Wrap-Up gate passed (see `prompts/prompt_instructions.md` → `<!-- PAW:IMPLEMENT -->`).

## Scope

- <file or area> — <what changes>

## Non-Goals

- <explicit out-of-scope items>

## Current Status

- Plan position: <short progress summary>
- Estimated completion: 0%
- Next work: <next concrete step; use "Review." when Estimated completion is 100%>

## Approval Boundaries

Stop and ask before:

- <approval-boundary trigger>

## Risk Classification

**Low | Medium | High** — <one-line justification>

## Durable Documentation Requirements

- <project docs that must change because of this work>

## Validation Contract

<!-- `paw afk` replays runnable backticked commands from this section. Prefer
     one runnable command per bullet. -->
- Targeted validation: `<changed-area command>` — <why this covers the changed behavior>
- Full local validation: `<repository full command>` — required after the final implementation change for every implement/diagnose completion, including batch, GUI and docs-only work; missing tools/failures block completion. Reuse a successful full run on final code.
- Escalate to broader/full validation when: <shared/high-risk files, workflow/CI/security changes, targeted failures, unclear blast radius, explicit user/reviewer request, or PR-ready handoff>
- Record the validation tier chosen and rationale in Validation Performed.
- `git status` review before handoff.
- `git diff` review before handoff.

## Decisions Made

- <decision> — <rationale>

## Changed Files / Areas

- <file path> — <what changed, scope of edit>

## Validation Performed

### Implementation results

- <check-name>: <outcome>
  Command: <command>
  Tier: <targeted|broader|full>
  Log: <result details or log path>
<!-- Keep Context/Development history separate. Preserve original required checks;
     only an explicit successful same-name rerun supersedes prior evidence. -->
- Code best-practices checklist applied — see `prompts/prompt_instructions.md` "Code Best Practices".

## Remaining Work

- <next concrete step, or "None">

## Risks / Follow-Ups

- <follow-up or risk worth noting, or "None">

## Quality Contract

Quality policy version: 1

## Acceptance Evidence

| Criterion | Observable behavior | Planned check | Evidence destination |
|---|---|---|---|
| <criterion / user constraint / inherited blocker> | <observable behavior> | <named behavioral check> | <log and code identity destination> |

## Post-Implementation Review Requirement

Independent Review: A- or higher with no production blockers. Preserve explicit
older/inherited thresholds; record their source and retain A- as the improvement
target when the authoritative threshold differs. Independent grading and
production sign-off follow implementation completion.
