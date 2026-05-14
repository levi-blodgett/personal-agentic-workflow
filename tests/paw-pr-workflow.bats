#!/usr/bin/env bats
# Tests for the shell-driven PR workflow commands in scripts/paw.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PAW="$SCRIPTS_DIR/paw"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures" && pwd)"

load 'helpers/exit_code'

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent"

  SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM_DIR"

  export PATH="$SHIM_DIR:$PATH"
  export PAW_HOME="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export PAW_BACKEND=stub

  cd "$REPO"
}

init_git_repo() {
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "test@example.com"
  echo "base" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "init"
}

assignment_file() {
  local repo_path="$1"
  local task_name="$2"
  local common_dir
  common_dir=$(git -C "$repo_path" rev-parse --git-common-dir)
  printf '%s/%s.gitconfig\n' "$common_dir/paw-task-assignments" "$task_name"
}

seed_task_package() {
  local task_name="$1"
  mkdir -p "$REPO/.agent/$task_name"
  cat > "$REPO/.agent/$task_name/contract.md" <<'EOF'
# Contract — `pr-workflow`

## Task Summary

Add two PR commands to paw, change paw review command.
EOF
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$REPO/.agent/$task_name/plan.md"
  cat > "$REPO/.agent/$task_name/pr.md" <<'EOF'
# `Feature: Add two PR commands to paw`

## Summary

PR body content.
EOF
}

write_fake_gh() {
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/gh.args"

if [[ "$1" == "pr" && "$2" == "create" ]]; then
  echo "https://github.com/example/repo/pull/123"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "review" ]]; then
  echo "review submitted" > "$BATS_TEST_TMPDIR/gh.review"
  exit 0
fi

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo "example/repo"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/gh"
}

write_fake_comments_cmd() {
  local script="$BATS_TEST_TMPDIR/fake-gh-comments.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
INLINE src/foo.ts:42
  @reviewer1: Please fix this.

PR COMMENT @reviewer2
  Add more tests.
OUT
EOF
  chmod +x "$script"
  printf '%s\n' "$script"
}

@test "paw pr-submit: reuses saved branch assignment, creates draft PR, and records PR tracking metadata" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/pr-workflow
  run "$PAW" plan pr-workflow "record assignment"
  [ "$status" -eq 0 ]

  seed_task_package pr-workflow
  write_fake_gh

  run "$PAW" pr-submit pr-workflow

  [ "$status" -eq 0 ]
  [[ "$(git -C "$REPO" branch --show-current)" == "feature/pr-workflow" ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"pr"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"create"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"--draft"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"--title"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"Feature: Add two PR commands to paw, change paw review command"* ]]
  grep -q "## PR Tracking" "$REPO/.agent/pr-workflow/plan.md"
  grep -q "PR Number: #123" "$REPO/.agent/pr-workflow/plan.md"
  grep -q "PR URL: https://github.com/example/repo/pull/123" "$REPO/.agent/pr-workflow/plan.md"
  grep -q "PR Number: #123" "$REPO/.agent/pr-workflow/pr.md"
}

@test "paw pr-submit: errors clearly when pr.md is missing" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/missing-pr-md
  run "$PAW" plan missing-pr "record assignment"
  [ "$status" -eq 0 ]

  mkdir -p "$REPO/.agent/missing-pr"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$REPO/.agent/missing-pr/plan.md"
  cat > "$REPO/.agent/missing-pr/contract.md" <<'EOF'
# Contract — `missing-pr`
EOF

  run "$PAW" pr-submit missing-pr

  [ "$status" -eq 1 ]
  [[ "$output" == *".agent/missing-pr/pr.md"* ]]
}

@test "paw pr-review: first run collects comments into the task review.md draft" {
  init_git_repo
  seed_task_package pr-workflow
  cat >> "$REPO/.agent/pr-workflow/plan.md" <<'EOF'

## PR Tracking

- PR Number: #123
- PR URL: https://github.com/example/repo/pull/123
EOF
  local comments_cmd
  comments_cmd=$(write_fake_comments_cmd)

  PAW_GH_COMMENTS_CMD="$comments_cmd" run "$PAW" pr-review 123

  [ "$status" -eq 0 ]
  [ -f "$REPO/.agent/pr-workflow/review.md" ]
  grep -q "## Review Metadata" "$REPO/.agent/pr-workflow/review.md"
  grep -q "PR Number: #123" "$REPO/.agent/pr-workflow/review.md"
  grep -q "Status: collected" "$REPO/.agent/pr-workflow/review.md"
  grep -q "INLINE src/foo.ts:42" "$REPO/.agent/pr-workflow/review.md"
}

@test "paw pr-review: second run submits the saved review draft with gh pr review" {
  init_git_repo
  seed_task_package pr-workflow
  cat >> "$REPO/.agent/pr-workflow/plan.md" <<'EOF'

## PR Tracking

- PR Number: #123
- PR URL: https://github.com/example/repo/pull/123
EOF
  cat > "$REPO/.agent/pr-workflow/review.md" <<'EOF'
# PR Review Draft — `pr-workflow`

## Review Metadata

- PR Number: #123
- Status: collected

## Review Summary

Please address the inline items before merge.

## Review Comments

INLINE src/foo.ts:42
  @reviewer1: Please fix this.
EOF
  write_fake_gh

  run "$PAW" pr-review 123

  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"pr"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"review"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"--comment"* ]]
  grep -q "Status: submitted" "$REPO/.agent/pr-workflow/review.md"
}

@test "paw pr-review: second run still submits when review metadata omits task name" {
  init_git_repo
  seed_task_package pr-workflow
  cat >> "$REPO/.agent/pr-workflow/plan.md" <<'EOF'

## PR Tracking

- PR Number: #123
- PR URL: https://github.com/example/repo/pull/123
EOF
  cat > "$REPO/.agent/pr-workflow/review.md" <<'EOF'
# PR Review Draft

## Review Metadata

- PR Number: #123
- Status: collected

## Review Summary

Please address the inline items before merge.

## Review Comments

INLINE src/foo.ts:42
  @reviewer1: Please fix this.
EOF
  write_fake_gh

  run "$PAW" pr-review 123

  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"pr"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"review"* ]]
  grep -q "Status: submitted" "$REPO/.agent/pr-workflow/review.md"
  ! grep -q "Task:" "$REPO/.agent/pr-workflow/review.md"
}
