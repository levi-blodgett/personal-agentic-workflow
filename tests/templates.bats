#!/usr/bin/env bats
# Tests for template files and prompt_instructions.md structural guarantees.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

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
  grep -qF "Prefer vertical slices over horizontal workstreams" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "Use multiple phases or slices when needed" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "follow red-green-refactor" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "behavior-focused failing test" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "fails only when behavior changes" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "defer test-cleanup refactors until the implementation loop is complete" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md requires adjacent Progress notes for completed items" {
  grep -qF "paw lint" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF 'one-line `Progress:` note directly beneath that checkbox in the same edit before moving to the next checkbox' "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "do not batch several completed items before updating the plan" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md defines context-pressure guidance and lean updates" {
  grep -qF "context pressure" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "meaningful pressure changes" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "paw compact" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "archive stale detail" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "split the task" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "keep its own progress updates lean" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md documents user-answer placeholders and implement blocking" {
  grep -qF "USER ANSWER (UNRESOLVED):" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "USER ANSWER (PROVIDED):" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "ask as many follow-ups as the task needs" "$REPO_ROOT/prompts/prompt_instructions.md"
  grep -qF "must not run while any \`USER ANSWER (UNRESOLVED):\` or \`USER ANSWER (PROVIDED):\` line remains in \`plan.md\`" "$REPO_ROOT/prompts/prompt_instructions.md"
}

@test "templates: prompt_instructions.md working surface <= 300 lines" {
  local count
  count=$(awk '
    /^###[[:space:]]+Archived/ { in_archive=1 }
    in_archive && /^#{1,2}[[:space:]]/ && !/^###[[:space:]]+Archived/ { in_archive=0 }
    in_archive { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*<!--.*-->[[:space:]]*$/ { next }
    { lines++ }
    END { print lines+0 }
  ' "$REPO_ROOT/prompts/prompt_instructions.md")
  [ "$count" -le 300 ]
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
