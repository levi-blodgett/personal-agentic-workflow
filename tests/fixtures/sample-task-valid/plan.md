# Plan — `sample-task-valid`

## Objective

Demonstrate a valid task package for the PAW lint tests.

## Open Questions / Follow-Ups

- None.

## Implementation Phases / Checklist

- [x] Create the valid fixture files.
  Progress: Added a complete `contract.md`, `plan.md`, and optional `pr.md` fixture set.

## Acceptance Criteria

- [x] `scripts/lint-task.sh tests/fixtures/sample-task-valid/` exits 0.
- [x] The fixture shows the canonical single-file `plan.md` workflow.

## Scope

- Only the fixture files themselves.

## Non-Goals

- No real implementation.

## Current Status

- Plan position: Complete.
- Estimated completion: 100%
- Next work: None.

## Approval Boundaries

- None.

## Risk Classification

**Low** — fixture data only.

## Durable Documentation Requirements

- None.

## Validation Contract

- `scripts/lint-task.sh tests/fixtures/sample-task-valid/` must exit 0.

## Decisions Made

- Use minimal content to keep the fixture readable.

## Changed Files / Areas

- `tests/fixtures/sample-task-valid/` — fixture package for lint and prompt tests.

## Validation Performed

- `scripts/lint-task.sh tests/fixtures/sample-task-valid/` — passes.
- Code best-practices checklist applied — see `prompts/prompt_instructions.md` "Code Best Practices".

## Remaining Work

- None.

## Risks / Follow-Ups

- None.
