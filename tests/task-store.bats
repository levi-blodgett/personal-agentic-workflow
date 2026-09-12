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

@test "task store: exact branch PR identities resist slash case Unicode and long-name collisions" {
  run bash -c '
    source "$1"
    prior=""
    for branch in feature/foo feature-foo Feature/foo café/foo cafe/foo "$(printf "x%.0s" {1..200})/a" "$(printf "x%.0s" {1..200})/b"; do
      file=$(paw_branch_pr_body_file "$2" "$branch") || exit
      digest=$(printf %s "$branch" | shasum -a 256 | cut -d " " -f1)
      [[ "$file" == *"-$digest-pr.md" && ${#file} -lt 250 ]] || exit 1
      [[ "$prior" != *"${file##*/}"* ]] || exit 1
      [[ "$file" == "$(paw_branch_pr_body_file "$2" "$branch")" ]] || exit 1
      prior="$prior ${file##*/}"
    done
  ' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 0 ]
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

@test "task store: archive moves central tasks out of active listings" {
  run bash -c 'source "$1"; central=$(paw_task_create_dir "$2" archive-me); mkdir -p "$central"; printf "# Plan\n" > "$central/plan.md"; paw_task_write_metadata "$central" "$2" archive-me created ""; archived=$(paw_task_archive "$2" archive-me); test -f "$archived/plan.md"; git config --file "$archived/metadata.gitconfig" --get paw.archived-at; paw_task_list "$2"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$PAW_TASK_HOME/"*"archive"*"/archive-me"* ]]
  [[ "$output" != *"archive-me"$'\t'*"central"* ]]
}

@test "task store: archive rejects missing and already archived central tasks clearly" {
  run bash -c 'source "$1"; paw_task_archive "$2" missing-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"task 'missing-task' not found"* ]]

  run bash -c 'source "$1"; central=$(paw_task_create_dir "$2" duplicate-task); archived=$(paw_task_archive_dir "$2" duplicate-task); mkdir -p "$central" "$archived"; paw_task_archive "$2" duplicate-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"archived task already exists"* ]]
}

@test "task store: detects pending answers active runs and finished plans" {
  mkdir -p "$REPO/.agent/state-task/runs"
  cat > "$REPO/.agent/state-task/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Done.
- Estimated completion: 100%
- Next work: Review.

## Open Questions / Follow-Ups

- Which path?
  - USER ANSWER (PROVIDED): later
MD
  git config --file "$REPO/.agent/state-task/runs/running.gitconfig" paw.status running

  run bash -c 'source "$1"; paw_task_has_pending_user_answers "$2/.agent/state-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; paw_task_has_active_run "$2/.agent/state-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; paw_task_is_finished "$2/.agent/state-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 0 ]
}

@test "task store: ignores stale pid-based running metadata" {
  mkdir -p "$REPO/.agent/stale-task/runs"
  git config --file "$REPO/.agent/stale-task/runs/20260911T000000Z-999999.gitconfig" paw.status running

  run bash -c 'source "$1"; ! paw_task_has_active_run "$2/.agent/stale-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
}

@test "task store: finds active cancellable pid-bearing running metadata" {
  mkdir -p "$REPO/.agent/cancellable-task/runs"
  sleep 60 &
  local sleeper="$!"
  git config --file "$REPO/.agent/cancellable-task/runs/20260911T000000Z-$sleeper.gitconfig" paw.status running

  run bash -c 'source "$1"; paw_task_active_run_info "$2/.agent/cancellable-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [[ "$output" == "$REPO/.agent/cancellable-task/runs/20260911T000000Z-$sleeper.gitconfig"$'\t'"$sleeper" ]]
}

@test "task store: active run info ignores stale pid metadata" {
  mkdir -p "$REPO/.agent/stale-cancel-task/runs"
  git config --file "$REPO/.agent/stale-cancel-task/runs/20260911T000000Z-999999.gitconfig" paw.status running

  run bash -c 'source "$1"; ! paw_task_active_run_info "$2/.agent/stale-cancel-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
}

@test "task store: pidless running metadata remains active but not cancellable" {
  mkdir -p "$REPO/.agent/pidless-task/runs"
  git config --file "$REPO/.agent/pidless-task/runs/running.gitconfig" paw.status running

  run bash -c 'source "$1"; paw_task_has_active_run "$2/.agent/pidless-task"; ! paw_task_active_run_info "$2/.agent/pidless-task"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"

  [ "$status" -eq 0 ]
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

@test "task store: batch completion requires 100 percent Review for replacement packages" {
  for task_dir in "$REPO/.agent/replacement" "$PAW_TASK_HOME/replacement"; do
    mkdir -p "$task_dir"
    git config --file "$task_dir/metadata.gitconfig" paw.prototype-status planned
    for percent in 95 100; do
      printf '## Current Status\n- Estimated completion: %s%%\n- Next work: Review.\n' "$percent" > "$task_dir/plan.md"
      run bash -c 'source "$1"; paw_task_is_finished "$2"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$task_dir"
      if [[ "$percent" = 100 ]]; then
        [ "$status" -eq 0 ]
      else
        [ "$status" -ne 0 ]
      fi
    done
  done
}

@test "task-store: review evidence and archive lineage boundaries" {
  PYTHONDONTWRITEBYTECODE=1 python3 "$REPO_ROOT/tests/review-record.py"
}

@test "task store: branch bodies share worktree identity and isolate repositories" {
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m base
  git -C "$REPO" worktree add -q -b linked "$BATS_TEST_TMPDIR/linked"
  mkdir "$BATS_TEST_TMPDIR/other"
  git -C "$BATS_TEST_TMPDIR/other" init -q
  run bash -c '
    source "$1"
    first=$(paw_branch_pr_body_file "$2" feature/foo)
    [[ "$first" == "$(paw_branch_pr_body_file "$3" feature/foo)" ]] || exit 1
    [[ "$first" != "$(paw_branch_pr_body_file "$4" feature/foo)" ]]
  ' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO" "$BATS_TEST_TMPDIR/linked" "$BATS_TEST_TMPDIR/other"
  [ "$status" -eq 0 ]
}

@test "task store: saved branch wins and malformed detached or foreign assignments refuse" {
  run bash -c '
    source "$1"
    task=$(paw_task_create_dir "$2" saved)
    paw_task_write_metadata "$task" "$2" saved created ""
    file="$task/metadata.gitconfig"
    git config --file "$file" paw.branch-name saved/branch
    [[ "$(paw_task_branch_pr_body_file "$2" "$task")" == "$(paw_branch_pr_body_file "$2" saved/branch)" ]] || exit 1
    for state in detached missing; do
      git config --file "$file" paw.head-state "$state"
      if paw_task_branch_pr_body_file "$2" "$task"; then exit 1; fi
    done
    git config --file "$file" paw.head-state branch
    git config --file "$file" paw.branch-name invalid:branch
    if paw_task_branch_pr_body_file "$2" "$task"; then exit 1; fi
    git config --file "$file" paw.branch-name saved/branch
    git config --file "$file" paw.git-common-dir /another/repo/.git
    if paw_task_branch_pr_body_file "$2" "$task"; then exit 1; fi
  ' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 0 ]
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m base
  git -C "$REPO" checkout -q --detach
  run bash -c 'source "$1"; paw_branch_pr_body_file "$2"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a named branch"* ]]
}

@test "task store: historical body in a linked worktree store blocks automatic seeding" {
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m base
  git -C "$REPO" worktree add -q -b linked "$BATS_TEST_TMPDIR/linked"
  run bash -c '
    source "$1"
    old="$(paw_task_repo_store "$2")/feature-foo-pr.md"
    mkdir -p "${old%/*}"
    printf historical > "$old"
    if paw_branch_pr_resolve_file "$2" feature/foo; then exit 1; fi
    [[ "$(cat "$old")" == historical ]]
  ' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$BATS_TEST_TMPDIR/linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ambiguous historical"* ]]
}
