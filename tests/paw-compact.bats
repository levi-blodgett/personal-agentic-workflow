#!/usr/bin/env bats
# Tests for paw compact subcommand.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PAW="$SCRIPTS_DIR/paw"

setup() {
  export PAW_HOME="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export PAW_BACKEND=stub
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent"
  cd "$REPO"
}

make_task() {
  local name="$1"
  local task_dir="$REPO/.agent/$name"
  mkdir -p "$task_dir"

  cat > "$task_dir/plan.md" <<'MD'
# Plan — `test-task`

## Implementation Phases / Checklist

- [x] Phase 1: done step one.
  Progress: Finished the first vertical slice.
- [x] Phase 2: done step two.
  Progress: Finished the second vertical slice.
- [ ] Phase 3: pending step.

## Current Status

- Plan position: Phase 2 complete.
- Estimated completion: 50%
- Next work: Phase 3.
MD
}

@test "paw compact: archives ticked phases and their progress notes" {
  make_task compact-tick
  run "$PAW" compact compact-tick
  [ "$status" -eq 0 ]

  local plan="$REPO/.agent/compact-tick/plan.md"
  grep -q "^### Archived Phases" "$plan"
  grep -q "Phase 1: done step one" "$plan"
  grep -q "Finished the first vertical slice" "$plan"
  grep -q "Phase 2: done step two" "$plan"
}

@test "paw compact: removes ticked items from active Implementation Phases section" {
  make_task compact-remove
  run "$PAW" compact compact-remove
  [ "$status" -eq 0 ]

  local plan="$REPO/.agent/compact-remove/plan.md"
  local phases_content
  phases_content=$(awk '
    /^## Implementation Phases/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec { print }
  ' "$plan")
  ! echo "$phases_content" | grep -q "Phase 1"
  ! echo "$phases_content" | grep -q "Phase 2"
  echo "$phases_content" | grep -q "Phase 3"
}

@test "paw compact: idempotent second run is a no-op" {
  make_task compact-idem
  run "$PAW" compact compact-idem
  [ "$status" -eq 0 ]

  local plan_before
  plan_before=$(cat "$REPO/.agent/compact-idem/plan.md")

  run "$PAW" compact compact-idem
  [ "$status" -eq 0 ]

  local plan_after
  plan_after=$(cat "$REPO/.agent/compact-idem/plan.md")
  [ "$plan_before" = "$plan_after" ]
}

@test "paw compact: no-op when nothing is archived" {
  local task_dir="$REPO/.agent/compact-noop"
  mkdir -p "$task_dir"

  cat > "$task_dir/plan.md" <<'MD'
# Plan — `compact-noop`

## Implementation Phases / Checklist

- [ ] Phase 1: pending.

## Current Status

- Plan position: Not started.
- Estimated completion: 0%
- Next work: Phase 1.
MD

  run "$PAW" compact compact-noop
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to archive"* ]]
}
