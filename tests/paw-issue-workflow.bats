#!/usr/bin/env bats
# Tests for the shell-driven GitHub issue workflow commands in scripts/paw.

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
  export PAW_TASK_HOME="$BATS_TEST_TMPDIR/paw-state/tasks"

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

seed_task_package() {
  local task_name="$1"
  local task_dir
  task_dir="$(task_dir_for "$task_name")"
  mkdir -p "$task_dir"
  cat > "$task_dir/contract.md" <<'EOF'
# Contract — `issue-workflow`

## Task Summary

Add GitHub issue workflow support to paw.
EOF
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  cat > "$task_dir/issue.md" <<'EOF'
# `Feature: Add GitHub issue workflow support to paw`

## Summary

Issue body content.
EOF
}

task_dir_for() {
  local task_name="$1"
  local matches=("$PAW_TASK_HOME"/*/"$task_name")
  if [[ -d "${matches[0]}" ]]; then
    printf '%s\n' "${matches[0]}"
  else
    printf '%s\n' "$REPO/.agent/$task_name"
  fi
}

write_fake_gh() {
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/gh.args"

if [[ "$1" == "issue" && "$2" == "create" ]]; then
  echo "https://github.com/example/repo/issues/456"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/gh"
}

write_fake_gh_multi_issue() {
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$BATS_TEST_TMPDIR/gh.args"
echo "---" >> "$BATS_TEST_TMPDIR/gh.args"

if [[ "$1" == "issue" && "$2" == "create" ]]; then
  count_file="$BATS_TEST_TMPDIR/gh.issue-count"
  count=0
  if [[ -f "$count_file" ]]; then
    count=$(cat "$count_file")
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ "$count" -eq 1 ]]; then
    echo "https://github.com/example/repo/issues/101"
  else
    echo "https://github.com/example/repo/issues/102"
  fi
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/gh"
}

write_fake_issue_view_cmd() {
  local script="$BATS_TEST_TMPDIR/fake-gh-issue-view.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Title: Support GitHub issue review workflow
URL: https://github.com/example/repo/issues/456

Issue body from GitHub.
OUT
EOF
  chmod +x "$script"
  printf '%s\n' "$script"
}

write_fake_issue_view_cmd_updated() {
  local script="$BATS_TEST_TMPDIR/fake-gh-issue-view-updated.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Title: Support GitHub issue review workflow
URL: https://github.com/example/repo/issues/456

Updated issue body from GitHub.
OUT
EOF
  chmod +x "$script"
  printf '%s\n' "$script"
}

@test "paw issue-submit: reuses saved branch assignment, creates issue, and records issue tracking metadata" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/issue-workflow
  run "$PAW" plan issue-workflow "record assignment"
  [ "$status" -eq 0 ]

  seed_task_package issue-workflow
  local task_dir
  task_dir="$(task_dir_for issue-workflow)"
  write_fake_gh

  run "$PAW" issue-submit issue-workflow

  [ "$status" -eq 0 ]
  [[ "$(git -C "$REPO" branch --show-current)" == "feature/issue-workflow" ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"issue"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"create"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"--title"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"Feature: Add GitHub issue workflow support to paw"* ]]
  grep -q "## Issue Tracking" "$task_dir/plan.md"
  grep -q "Issue Number: #456" "$task_dir/plan.md"
  grep -q "Issue URL: https://github.com/example/repo/issues/456" "$task_dir/plan.md"
  grep -q "Issue Number: #456" "$task_dir/issue.md"
}

@test "paw issue-submit: errors clearly when issue.md is missing" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/missing-issue-md
  run "$PAW" plan missing-issue "record assignment"
  [ "$status" -eq 0 ]

  local task_dir
  task_dir="$(task_dir_for missing-issue)"
  mkdir -p "$task_dir"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  cat > "$task_dir/contract.md" <<'EOF'
# Contract — `missing-issue`
EOF

  run "$PAW" issue-submit missing-issue

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing-issue/issue.md"* ]]
}

@test "paw issue-review: first run collects the issue body into a planning task package" {
  init_git_repo
  local issue_view_cmd
  issue_view_cmd=$(write_fake_issue_view_cmd)

  PAW_GH_ISSUE_VIEW_CMD="$issue_view_cmd" run "$PAW" issue-review 456

  [ "$status" -eq 0 ]
  local task_dir
  task_dir="$(task_dir_for 456-issue-review)"
  [ -f "$task_dir/issue.md" ]
  grep -q "## Issue Metadata" "$task_dir/issue.md"
  grep -q "Issue Number: #456" "$task_dir/issue.md"
  grep -q "Issue URL: https://github.com/example/repo/issues/456" "$task_dir/issue.md"
  grep -q "Issue body from GitHub." "$task_dir/issue.md"
}

@test "paw issue-review: rerun refreshes the saved issue body and reuses the task package" {
  init_git_repo
  local issue_view_cmd updated_issue_view_cmd
  issue_view_cmd=$(write_fake_issue_view_cmd)
  updated_issue_view_cmd=$(write_fake_issue_view_cmd_updated)

  PAW_GH_ISSUE_VIEW_CMD="$issue_view_cmd" run "$PAW" issue-review 456
  [ "$status" -eq 0 ]

  PAW_GH_ISSUE_VIEW_CMD="$updated_issue_view_cmd" run "$PAW" issue-review 456

  [ "$status" -eq 0 ]
  local task_dir
  task_dir="$(task_dir_for 456-issue-review)"
  [ -d "$task_dir" ]
  grep -q "Updated issue body from GitHub." "$task_dir/issue.md"
}

@test "paw to-issues --publish: publishes pending drafts in dependency order and records tracking metadata" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/issue-slices
  run "$PAW" plan issue-slices "record assignment"
  [ "$status" -eq 0 ]

  local task_dir
  task_dir="$(task_dir_for issue-slices)"
  mkdir -p "$task_dir/issues"
  cat > "$task_dir/contract.md" <<'EOF'
# Contract — `issue-slices`

## Task Summary

Break the approved work into issue slices.
EOF
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  cat > "$task_dir/issues/01-foundation.md" <<'EOF'
# Foundation slice

## Draft Metadata
- Slug: foundation
- Type: AFK
- Blocked by: None - can start immediately
- Status: draft
- Issue Number:
- Issue URL:

## Parent

Parent issue context.

## What to build

Create the narrow first slice.

## Acceptance criteria

- [ ] Foundation behavior exists.

## Blocked by

Placeholder blocker text.
EOF
  cat > "$task_dir/issues/02-follow-up.md" <<'EOF'
# Follow-up slice

## Draft Metadata
- Slug: follow-up
- Type: AFK
- Blocked by: foundation
- Status: draft
- Issue Number:
- Issue URL:

## Parent

Parent issue context.

## What to build

Extend the first slice.

## Acceptance criteria

- [ ] Follow-up behavior exists.

## Blocked by

Placeholder blocker text.
EOF
  write_fake_gh_multi_issue

  run "$PAW" to-issues issue-slices --publish

  [ "$status" -eq 0 ]
  [[ "$(git -C "$REPO" branch --show-current)" == "feature/issue-slices" ]]
  grep -q "Issue Number: #101" "$task_dir/issues/01-foundation.md"
  grep -q "Issue URL: https://github.com/example/repo/issues/101" "$task_dir/issues/01-foundation.md"
  grep -q "Issue Number: #102" "$task_dir/issues/02-follow-up.md"
  grep -q "Issue URL: https://github.com/example/repo/issues/102" "$task_dir/issues/02-follow-up.md"
  grep -q "foundation: #101" "$task_dir/plan.md"
  grep -q "follow-up: #102" "$task_dir/plan.md"
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"Foundation slice"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"Follow-up slice"* ]]
}
