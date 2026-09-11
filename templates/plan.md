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
- Escalate to broader/full validation when: <shared/high-risk files, workflow/CI/security changes, targeted failures, unclear blast radius, explicit user/reviewer request, or PR-ready handoff>
- Record the validation tier chosen and rationale in Validation Performed.
- `git status` review before handoff.
- `git diff` review before handoff.

## Decisions Made

- <decision> — <rationale>

## Changed Files / Areas

- <file path> — <what changed, scope of edit>

## Validation Performed

- <command> — <result, including counts/output highlights>
- Code best-practices checklist applied — see `prompts/prompt_instructions.md` "Code Best Practices".

## Remaining Work

- <next concrete step, or "None">

## Risks / Follow-Ups

- <follow-up or risk worth noting, or "None">
