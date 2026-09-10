#!/usr/bin/env bats
# Tests for central task-store resolution helpers.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export PAW_TASK_HOME="$BATS_TEST_TMPDIR/paw-state/tasks"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
}

@test "task store: create path uses PAW_TASK_HOME and records metadata" {
  run bash -c 'source "$1"; dir=$(paw_task_create_dir "$2" demo-task); paw_task_write_metadata "$dir" "$2" demo-task created ""; printf "%s\n" "$dir"; git config --file "$dir/metadata.gitconfig" --get paw.task-name' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$PAW_TASK_HOME/"* ]]
  [[ "$output" == *"demo-task"* ]]
}

@test "task store: resolve prefers central task and falls back to legacy .agent task" {
  mkdir -p "$REPO/.agent/legacy-task"

  run bash -c 'source "$1"; central=$(paw_task_create_dir "$2" central-task); mkdir -p "$central"; paw_task_resolve "$2" central-task; paw_task_resolve "$2" legacy-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$PAW_TASK_HOME/"* ]]
  [[ "$output" == *"$REPO/.agent/legacy-task"* ]]
}

@test "task store: resolve error names task and expected paths" {
  run bash -c 'source "$1"; paw_task_resolve "$2" missing-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing-task"* ]]
  [[ "$output" == *"$PAW_TASK_HOME/"* ]]
  [[ "$output" == *"$REPO/.agent/missing-task"* ]]
}

@test "task store: list repo tasks includes central and legacy packages" {
  mkdir -p "$REPO/.agent/legacy-task"
  run bash -c 'source "$1"; central=$(paw_task_create_dir "$2" central-task); mkdir -p "$central"; paw_task_write_metadata "$central" "$2" central-task created ""; paw_task_list "$2"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"central-task"$'\t'*"central"* ]]
  [[ "$output" == *"legacy-task"$'\t'*"legacy"* ]]
}

@test "task store: migrate copies legacy task and records source path" {
  mkdir -p "$REPO/.agent/migrate-me"
  printf '# Plan\n' > "$REPO/.agent/migrate-me/plan.md"

  run bash -c 'source "$1"; paw_task_migrate_repo "$2"; central=$(paw_task_create_dir "$2" migrate-me); test -f "$central/plan.md"; git config --file "$central/metadata.gitconfig" --get paw.source-path' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$REPO/.agent/migrate-me"* ]]
}

@test "task store: migrate imports multiple explicit repos and preserves repo metadata" {
  local repo_two="$BATS_TEST_TMPDIR/repo-two"
  mkdir -p "$REPO/.agent/shared-name" "$repo_two/.agent/shared-name"
  git -C "$repo_two" init -q
  printf '# Plan one\n' > "$REPO/.agent/shared-name/plan.md"
  printf '# Plan two\n' > "$repo_two/.agent/shared-name/plan.md"

  run bash -c 'source "$1"; paw_task_migrate_repo "$2"; paw_task_migrate_repo "$3"; one=$(paw_task_create_dir "$2" shared-name); two=$(paw_task_create_dir "$3" shared-name); git config --file "$one/metadata.gitconfig" --get paw.repo-root; git config --file "$two/metadata.gitconfig" --get paw.repo-root' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO" "$repo_two"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$REPO"* ]]
  [[ "$output" == *"$repo_two"* ]]
}
