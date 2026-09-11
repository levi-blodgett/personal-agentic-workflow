#!/usr/bin/env bats
# Tests for scripts/lint-task.sh

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures" && pwd)"

@test "lint-task: valid fixture passes (exit 0)" {
  run "$SCRIPTS_DIR/lint-task.sh" "$FIXTURES_DIR/sample-task-valid"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "lint-task: missing-sections fixture fails (exit non-zero)" {
  run "$SCRIPTS_DIR/lint-task.sh" "$FIXTURES_DIR/sample-task-missing-sections"

  [ "$status" -ne 0 ]
  [[ "$output" == *"WARN"* ]]
}

@test "lint-task: --repo mode iterates all tasks" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/.agent"
  cp -r "$FIXTURES_DIR/sample-task-valid" "$repo/.agent/task-a"

  run "$SCRIPTS_DIR/lint-task.sh" --repo "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"task-a"* ]]
}

@test "lint-task: missing plan.md produces ERROR" {
  local task="$BATS_TEST_TMPDIR/no-plan"
  mkdir -p "$task"

  run "$SCRIPTS_DIR/lint-task.sh" "$task"

  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: plan.md missing"* ]]
}

@test "lint-task: missing Current Status fields warns" {
  local task="$BATS_TEST_TMPDIR/no-status"
  mkdir -p "$task"
  cat > "$task/plan.md" <<'MD'
# Plan

## Objective
- x

## Open Questions / Follow-Ups
- None

## Implementation Phases / Checklist
- [x] Done.
  Progress: Completed fixture work.

## Acceptance Criteria
- [x] x

## Scope
- x

## Non-Goals
- None

## Current Status
- Plan position: done

## Approval Boundaries
- None

## Risk Classification
**Low** — fixture.

## Durable Documentation Requirements
- None

## Validation Contract
- manual

## Decisions Made
- x

## Changed Files / Areas
- x

## Validation Performed
- x

## Remaining Work
- None

## Risks / Follow-Ups
- None
MD

  run "$SCRIPTS_DIR/lint-task.sh" "$task"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Current Status missing field: Estimated completion"* ]]
  [[ "$output" == *"Current Status missing field: Next work"* ]]
}

@test "lint-task: warns when 100 percent complete but plan has unticked items" {
  local task="$BATS_TEST_TMPDIR/unticked-100pct"
  mkdir -p "$task"
  cat > "$task/plan.md" <<'MD'
# Plan

## Objective
Test.

## Open Questions / Follow-Ups
- None

## Implementation Phases / Checklist
- [x] Done step.
  Progress: Completed the first step.
- [ ] Unticked step.

## Acceptance Criteria
- [x] x

## Scope
- x

## Non-Goals
- None

## Current Status
- Plan position: done
- Estimated completion: 100%
- Next work: None

## Approval Boundaries
- None

## Risk Classification
**Low** — fixture.

## Durable Documentation Requirements
- None

## Validation Contract
- manual

## Decisions Made
- x

## Changed Files / Areas
- x

## Validation Performed
- x

## Remaining Work
- None

## Risks / Follow-Ups
- None
MD

  run "$SCRIPTS_DIR/lint-task.sh" "$task"

  [ "$status" -ne 0 ]
  [[ "$output" == *"still has unticked items"* ]]
}

@test "lint-task: completed implementation items require an inline progress note" {
  local task="$BATS_TEST_TMPDIR/missing-progress"
  mkdir -p "$task"
  cat > "$task/plan.md" <<'MD'
# Plan

## Objective
Test.

## Open Questions / Follow-Ups
- None

## Implementation Phases / Checklist
- [x] Completed step without a progress note.
- [x] Completed step with a progress note.
  Progress: Captured the completed work.

## Acceptance Criteria
- [x] x

## Scope
- x

## Non-Goals
- None

## Current Status
- Plan position: done
- Estimated completion: 100%
- Next work: None

## Approval Boundaries
- None

## Risk Classification
**Low** — fixture.

## Durable Documentation Requirements
- None.

## Validation Contract
- manual

## Decisions Made
- x

## Changed Files / Areas
- x

## Validation Performed
- x

## Remaining Work
- None

## Risks / Follow-Ups
- None
MD

  run "$SCRIPTS_DIR/lint-task.sh" "$task"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing Progress: note"* ]]
}

@test "lint-task: wrapped completed items may include continuation lines before Progress" {
  local task="$BATS_TEST_TMPDIR/wrapped-progress"
  mkdir -p "$task"
  cat > "$task/plan.md" <<'MD'
# Plan

## Objective
Test.

## Open Questions / Follow-Ups
- None

## Implementation Phases / Checklist
- [x] Completed step with wrapped detail:
  Additional wrapped detail that still belongs to the checkbox body.
  Progress: Captured the completed work after the wrapped detail.

## Acceptance Criteria
- [x] x

## Scope
- x

## Non-Goals
- None

## Current Status
- Plan position: done
- Estimated completion: 100%
- Next work: None

## Approval Boundaries
- None

## Risk Classification
**Low** — fixture.

## Durable Documentation Requirements
- None.

## Validation Contract
- manual

## Decisions Made
- x

## Changed Files / Areas
- x

## Validation Performed
- x

## Remaining Work
- None

## Risks / Follow-Ups
- None
MD

  run "$SCRIPTS_DIR/lint-task.sh" "$task"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "lint-task: length-budget warning fires for bloated fixture" {
  run env PAW_LINT_LENGTH=1 "$SCRIPTS_DIR/lint-task.sh" "$FIXTURES_DIR/sample-task-bloated"

  [ "$status" -ne 0 ]
  [[ "$output" == *"working surface"* ]]
}

@test "lint-task: repo mode suppresses pr.md info when repo has no template" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/.agent/task-no-pr"
  cp "$FIXTURES_DIR/sample-task-valid/contract.md" "$repo/.agent/task-no-pr/"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$repo/.agent/task-no-pr/"
  git -C "$repo" init -q

  run "$SCRIPTS_DIR/lint-task.sh" "$repo/.agent/task-no-pr"

  [ "$status" -eq 0 ]
  [[ "$output" != *"pr.md missing"* ]]
}

@test "lint-task: does not report missing task-level pr.md when repo has a PR template" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/.agent/task-with-pr" "$repo/.github"
  cp "$FIXTURES_DIR/sample-task-valid/contract.md" "$repo/.agent/task-with-pr/"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$repo/.agent/task-with-pr/"
  touch "$repo/.github/pull_request_template.md"
  git -C "$repo" init -q

  run "$SCRIPTS_DIR/lint-task.sh" "$repo/.agent/task-with-pr"

  [ "$status" -eq 0 ]
  [[ "$output" != *"pr.md missing"* ]]
}
