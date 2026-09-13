#!/usr/bin/env bats
# Tests for template files and prompt_instructions.md structural guarantees.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"
# shellcheck source=helpers/documentation.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/documentation.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"

@test "templates: example-task passes lint-task.sh" {
  run "$SCRIPTS_DIR/lint-task.sh" "$REPO_ROOT/examples/example-task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "templates: example-task does not keep placeholder answer markers after plan reconciliation" {
  ! grep -qF "USER ANSWER (UNRESOLVED):" "$REPO_ROOT/examples/example-task/plan.md"
  ! grep -qF "USER ANSWER (PROVIDED):" "$REPO_ROOT/examples/example-task/plan.md"
}

@test "templates: prompt_instructions.md contains PAW anchors" {
  grep -qF "<!-- PAW:PLAN -->" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "<!-- PAW:IMPLEMENT -->" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "<!-- PAW:EDIT -->" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "<!-- PAW:REVIEW -->" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md does not contain deprecated anchors" {
  ! grep -qF "<!-- PAW:CONTEXT -->" "$REPO_ROOT/prompts/prompt_instructions.md"
  ! grep -qF "<!-- PAW:CONTINUE -->" "$REPO_ROOT/prompts/prompt_instructions.md"
  ! grep -qF "<!-- PAW:NEW -->" "$REPO_ROOT/prompts/prompt_instructions.md"
  ! grep -qF "<!-- PAW:COMPLETE -->" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md mentions vertical slices and canonical TDD guidance" {
  local topic
  for topic in 'vertical slices' 'red-green-refactor per vertical slice' \
    'one failing behavior test' 'behavior tests that survive refactoring' \
    'defer test cleanup until then'; do
    doc_contains "$topic" "$REPO_ROOT/prompts/prompt_instructions.md" || return 1
  done
}

@test "templates: prompt_instructions.md requires adjacent Progress notes for completed items" {
  grep -qF "Progress:" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF 'Progress:` in the same edit before moving to the next checkbox' "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Do not batch updates." "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: status contract standardizes completion and completed next work" {
  grep -qF "Estimated completion" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "bare integer percentage" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "25%" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF 'At 100%, Next work' "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF 'Next work must be `Review.`' "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md defines context-pressure guidance and lean updates" {
  grep -qF "Context Pressure" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "meaningful pressure changes" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "paw compact" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "archive stale" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "split growing tasks" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Keep updates lean" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md documents user-answer placeholders and implement blocking" {
  grep -qF "USER ANSWER (UNRESOLVED):" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "USER ANSWER (PROVIDED):" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Ask high-value task-specific questions" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Either marker anywhere in plan.md blocks implementation/diagnosis" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md documents targeted-first validation and escalation" {
  grep -qF "validation decision" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "targeted changed-area checks" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Validation tier chosen" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Escalate for shared/high-risk" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "explicit request" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: Markdown length belongs to AI authoring" {
  grep -qF "AI authors must keep every Markdown file within 150 physical lines" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "never a CLI/GUI, lint, CI, approval or completion gate" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: each template file has an H1 line" {
  local failed=0
  for f in "$TEMPLATES_DIR"/*.md; do
    if ! grep -qE "^# " "$f"; then
      echo "missing H1 in $f" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "templates: plan template includes the user-answer placeholder convention" {
  grep -qF "USER ANSWER (UNRESOLVED):" "$TEMPLATES_DIR/plan.md"
  grep -qF "USER ANSWER (PROVIDED):" "$TEMPLATES_DIR/plan.md"
}

@test "templates: plan template seeds percent-only completion and review next work convention" {
  grep -qF -- "- Estimated completion: 0%" "$TEMPLATES_DIR/plan.md"
  grep -qF -- "- Next work: <next concrete step; use \"Review.\" when Estimated completion is 100%>" "$TEMPLATES_DIR/plan.md"
}

@test "templates: completion requires final full validation and old-plan discovery" {
  grep -qF "full local command remains mandatory after final implement/diagnose changes" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "discover and record" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Full local validation:" "$TEMPLATES_DIR/plan.md"
  grep -qF "after the final implementation change" "$TEMPLATES_DIR/plan.md"
}

@test "templates: plan template seeds targeted validation contract shape" {
  grep -qF "Targeted validation:" "$TEMPLATES_DIR/plan.md"
  grep -qF "Escalate to broader/full validation when:" "$TEMPLATES_DIR/plan.md"
  grep -qF "Record the validation tier chosen and rationale in Validation Performed." "$TEMPLATES_DIR/plan.md"
}

@test "templates: legacy extra sections still pass lint when plan.md has required sections" {
  local task="$BATS_TEST_TMPDIR/legacy-compat-task"
  mkdir -p "$task"
  cat > "$task/plan.md" <<'MD'
# Plan — `legacy-compat-task`

## Objective
Legacy compatibility fixture.

## Open Questions / Follow-Ups
- None

## Implementation Phases / Checklist
- [x] Done.
  Progress: Completed the only fixture step.

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

## Affected Files / Areas
- x

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
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "templates: separate independent review from implementation handoff" {
  grep -qF "outside implementation checkboxes" "$TEMPLATES_DIR/plan.md"
  grep -qF "record 100% and" "$TEMPLATES_DIR/plan.md"
  grep -qF "Preserve task-specific gates" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: illustrative review is complete with synthetic evidence identities" {
  run python3 -B "$SCRIPTS_DIR/lib/review_record.py" check "$REPO_ROOT/examples/example-task" add-version-flag
  [ "$status" -eq 0 ]
  grep -qF 'EXAMPLE — illustrative only' "$REPO_ROOT/examples/example-task/review.md"
  grep -qF 'synthetic-example-attempt' "$REPO_ROOT/examples/example-task/review.md"
  grep -qF 'synthetic-example-code' "$REPO_ROOT/examples/example-task/review.md"
  grep -qF 'not executed in PAW' "$REPO_ROOT/examples/example-task/review.md"
}
