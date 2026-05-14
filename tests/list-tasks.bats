#!/usr/bin/env bats
# Tests for scripts/list-tasks.sh

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"

make_valid_plan() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Phase 2 complete.
- Estimated completion: 80%
- Next work: Phase 3.
MD
}

@test "list-tasks: empty .agent/ prints no-task message" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/.agent"

  run "$SCRIPTS_DIR/list-tasks.sh" "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no task directories"* ]]
}

@test "list-tasks: no .agent/ prints no-.agent message" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"

  run "$SCRIPTS_DIR/list-tasks.sh" "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no .agent/"* ]]
}

@test "list-tasks: valid task shows status fields" {
  local repo="$BATS_TEST_TMPDIR/repo"
  make_valid_plan "$repo/.agent/my-task"

  run "$SCRIPTS_DIR/list-tasks.sh" "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"my-task"* ]]
  [[ "$output" == *"Phase 2 complete"* ]]
  [[ "$output" == *"80%"* ]]
  [[ "$output" == *"Phase 3"* ]]
}

@test "list-tasks: task missing plan.md prints fallback message" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/.agent/no-plan"

  run "$SCRIPTS_DIR/list-tasks.sh" "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no plan.md"* ]]
}

@test "list-tasks: multiple tasks all appear in output" {
  local repo="$BATS_TEST_TMPDIR/repo"
  make_valid_plan "$repo/.agent/task-alpha"
  make_valid_plan "$repo/.agent/task-beta"

  run "$SCRIPTS_DIR/list-tasks.sh" "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"task-alpha"* ]]
  [[ "$output" == *"task-beta"* ]]
}

@test "list-tasks: ignores stray legacy agent log files" {
  local repo="$BATS_TEST_TMPDIR/repo"
  make_valid_plan "$repo/.agent/plain-task"
  mkdir -p "$repo/.agent"
  cat > "$repo/.agent/legacy-log.md" <<'MD'
# Historical file left behind by older PAW versions.
MD

  run "$SCRIPTS_DIR/list-tasks.sh" "$repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"plain-task"* ]]
  [[ "$output" != *"Cost so far:"* ]]
  [[ "$output" != *"Repo total:"* ]]
}
