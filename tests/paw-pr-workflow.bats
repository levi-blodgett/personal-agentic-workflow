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

assignment_file() {
  local repo_path="$1"
  local task_name="$2"
  local common_dir
  common_dir=$(git -C "$repo_path" rev-parse --git-common-dir)
  printf '%s/%s.gitconfig\n' "$common_dir/paw-task-assignments" "$task_name"
}

seed_task_package() {
  local task_name="$1"
  local task_dir
  task_dir="$(task_dir_for "$task_name")"
  mkdir -p "$task_dir"
  cat > "$task_dir/contract.md" <<'EOF'
# Contract — `pr-workflow`

## Task Summary

Add two PR commands to paw, change paw review command.
EOF
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  cat > "$task_dir/pr.md" <<'EOF'
# `Feature: Add two PR commands to paw`

## Summary

PR body content.
EOF
}

branch_pr_file_for() {
  local branch="$1"
  # shellcheck source=../scripts/lib/task_store.sh
  source "$SCRIPTS_DIR/lib/task_store.sh"
  paw_branch_pr_body_file "$REPO" "$branch"
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

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  if [[ -n "${FIXTURE_PR_STATE:-}" && -f "$FIXTURE_PR_STATE" ]]; then cat "$FIXTURE_PR_STATE"; else echo '[]'; fi
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "create" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --body-file ]]; then cp "$2" "$BATS_TEST_TMPDIR/gh.body"; break; fi
    shift
  done
  if [[ -n "${FIXTURE_PR_STATE:-}" ]]; then
    python3 - "$BATS_TEST_TMPDIR/gh.body" "$FIXTURE_PR_STATE" "$(git branch --show-current)" <<'PYREMOTE'
import json,sys
from pathlib import Path
Path(sys.argv[2]).write_text(json.dumps([dict(number=123, url='https://github.com/example/repo/pull/123', body=Path(sys.argv[1]).read_text(), headRefName=sys.argv[3], headRepository=dict(name='repo'), headRepositoryOwner=dict(login='example'))]))
PYREMOTE
    echo create >> "$FIXTURE_PR_STATE.mutations"
  fi
  echo "https://github.com/example/repo/pull/${FIXTURE_PR_NUMBER:-123}"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "review" ]]; then
  echo "review submitted" > "$BATS_TEST_TMPDIR/gh.review"
  exit 0
fi

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo '{"nameWithOwner":"example/repo"}'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/gh"
  local real_git
  real_git="$(command -v git)"
  if [[ "$real_git" != "$SHIM_DIR/git" ]]; then
    printf '#!/usr/bin/env bash\nif [[ "$1" == ls-remote ]]; then printf "%%s\\t%%s\\n" "$(%q rev-parse HEAD)" "$4"; exit 0; fi\nexec %q "$@"\n' "$real_git" "$real_git" > "$SHIM_DIR/git"
    chmod +x "$SHIM_DIR/git"
  fi
}

qualify_publication() {
  local task_name="$1" task_dir branch common key
  task_dir="$(task_dir_for "$task_name")"
  branch="$(git branch --show-current)"
  common="$(git rev-parse --path-format=absolute --git-common-dir)"
  for key in "worktree-path=$REPO" "git-common-dir=$common" "branch-name=$branch" "head-state=branch"; do
    git config --file "$task_dir/metadata.gitconfig" "paw.${key%%=*}" "${key#*=}"
  done
  git config "branch.$branch.remote" origin
  git config "branch.$branch.merge" "refs/heads/$branch"
  git remote add origin https://github.com/example/repo.git 2>/dev/null || true
  PYTHONDONTWRITEBYTECODE=1 python3 - "$SCRIPTS_DIR" "$task_dir" "$REPO" <<'PYTEST'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
import review_record
p, repo = Path(sys.argv[2]), Path(sys.argv[3])
(p / 'plan.md').write_text('## Current Status\n- Estimated completion: 100%\n- Next work: Review.\n\n## PR Contribution\n- Outcome: Reviewed publication fixture works.\n- Validation: Isolated publication checks passed.\n- Risks: No fixture production risks.\n- Visual: Shared diagram explains publication.\n')
(p / 'review.md').write_text(f'## Review Metadata\n- Task: {p.name}\n- Grade: A-\n- Scope Reviewed: isolated test\n- Quality Threshold: A-\n- Threshold Result: met\n- Completion: complete\n- Attempt: test\n- Reviewed Code: {review_record.code_identity(repo)}\n## Blocking Production-Readiness Issues\n- None.\n')
(p / '.review-attempt').write_text('test\tcomplete\n')
PYTEST
  local body
  body="$(branch_pr_file_for "$branch")"
  [[ -f "$body" ]] || body="$task_dir/pr.md"
  if [[ -f "$body" ]] && ! grep -q '^## Visual Evidence' "$body"; then
    cat >> "$body" <<'VISUAL'

## Visual Evidence

This shows the reviewed publication transition.
```mermaid
flowchart TD
 A --> B
```
VISUAL
  fi
}

publish_fixture() {
  local task="$1" task_dir token
  "$PAW" pr-submit "$task" || return
  task_dir="$(task_dir_for "$task")"
  token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$task_dir/publication-preview.json")"
  "$PAW" pr-submit "$task" --publish "$token"
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

  local task_dir
  task_dir="$(task_dir_for pr-workflow)"
  mkdir -p "$task_dir"
  cat > "$task_dir/contract.md" <<'EOF'
# Contract — `pr-workflow`

## Task Summary

Add two PR commands to paw, change paw review command.
EOF
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  local pr_file
  pr_file="$(branch_pr_file_for feature/pr-workflow)"
  cat > "$pr_file" <<'EOF'
# `Feature: Add two PR commands to paw`

## Summary

PR body content.
EOF
  write_fake_gh

  qualify_publication pr-workflow
  run publish_fixture pr-workflow

  [ "$status" -eq 0 ]
  [[ "$(git -C "$REPO" branch --show-current)" == "feature/pr-workflow" ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"pr"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"create"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"--draft"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"--title"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh.args")" == *"Feature: pr workflow"* ]]
  grep -q "## PR Tracking" "$task_dir/plan.md"
  grep -q "PR Number: #123" "$task_dir/plan.md"
  grep -q "PR URL: https://github.com/example/repo/pull/123" "$task_dir/plan.md"
  grep -q "## Task: pr-workflow" "$pr_file"
  [ ! -f "$task_dir/pr.md" ]
}

@test "paw pr-submit: falls back to legacy task-level pr.md" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/legacy-pr-md
  seed_task_package legacy-pr
  write_fake_gh

  qualify_publication legacy-pr
  run publish_fixture legacy-pr

  [ "$status" -eq 0 ]
  grep -q "## Task: legacy-pr" "$REPO/.agent/legacy-pr/pr.md"
}

@test "paw pr-submit: errors clearly when branch PR body is missing" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/missing-pr-md
  run "$PAW" plan missing-pr "record assignment"
  [ "$status" -eq 0 ]

  local task_dir
  task_dir="$(task_dir_for missing-pr)"
  mkdir -p "$task_dir"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  cat > "$task_dir/contract.md" <<'EOF'
# Contract — `missing-pr`
EOF

  qualify_publication missing-pr
  run "$PAW" pr-submit missing-pr

  [ "$status" -eq 1 ]
  [[ "$output" == *"$(branch_pr_file_for feature/missing-pr-md)"* ]]
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

@test "paw branch PR: colliding branches seed and submit independent preserved bodies" {
  init_git_repo
  mkdir -p .github
  echo template > .github/pull_request_template.md
  write_fake_gh
  local branch task body first=""
  for branch in feature/foo feature-foo; do
    task="task-${branch//\//-}"
    [[ -z "$first" ]] || task=second
    git checkout -q -b "$branch"
    run "$PAW" plan "$task" "seed body"
    [ "$status" -eq 0 ]
    body="$(branch_pr_file_for "$branch")"
    [ -f "$body" ]
    printf 'Unique %s\n\n## Retained\n\nExact unrelated bytes.\n' "$branch" > "$body"
    cp "$body" "$BATS_TEST_TMPDIR/before"
    run "$PAW" plan "$task" "seed body"
    [ "$status" -eq 0 ]
    cmp "$body" "$BATS_TEST_TMPDIR/before"
    export FIXTURE_PR_NUMBER=123
    [[ -z "$first" ]] || export FIXTURE_PR_NUMBER=124
    qualify_publication "$task"
    run publish_fixture "$task"
    [ "$status" -eq 0 ]
    grep -q "## Task: $task" "$BATS_TEST_TMPDIR/gh.body"
    ! grep -q "Exact unrelated bytes" "$BATS_TEST_TMPDIR/gh.body"
    grep -Fxq "Unique $branch" "$body"
    grep -Fxq 'Exact unrelated bytes.' "$body"
    grep -q "PR Number: #$FIXTURE_PR_NUMBER" "$(task_dir_for "$task")/plan.md"
    if [[ -n "$first" ]]; then
      cmp "$first" "$BATS_TEST_TMPDIR/first"
    else
      first="$body"
      cp "$body" "$BATS_TEST_TMPDIR/first"
    fi
  done
}

@test "paw branch PR: ambiguous historical body refuses seed and submit until explicit canonical copy" {
  init_git_repo
  source "$SCRIPTS_DIR/lib/task_store.sh"
  mkdir -p .github "$(paw_task_repo_store "$REPO")"
  echo template > .github/pull_request_template.md
  local old="$(paw_task_repo_store "$REPO")/feature-foo-pr.md" branch body
  printf 'Historical body\n' > "$old"
  cp "$old" "$BATS_TEST_TMPDIR/old"
  write_fake_gh
  for branch in feature/foo feature-foo; do
    git checkout -q -b "$branch"
    body="$(branch_pr_file_for "$branch")"
    run "$PAW" plan migration "seed body"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$old"* && "$output" == *"$body"* ]]
    [ ! -f "$body" ]
    seed_task_package migration
    qualify_publication migration
    run "$PAW" pr-submit migration
    [ "$status" -ne 0 ]
    [[ "$output" == *"$old"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/gh.args" ]
    cmp "$old" "$BATS_TEST_TMPDIR/old"
  done
  cp "$old" "$body"
  qualify_publication migration
  run publish_fixture migration
  [ "$status" -eq 0 ]
  grep -q "## Task: migration" "$BATS_TEST_TMPDIR/gh.body"
  cmp "$old" "$BATS_TEST_TMPDIR/old"
  grep -q '## Task: migration' "$body"
  ! grep -q 'PR Number:' "$(task_dir_for migration)/pr.md"
}

seed_shared_pr() {
  local body
  body="$(branch_pr_file_for "$(git branch --show-current)")"
  mkdir -p "${body%/*}"
  printf '## PR Tracking\n\n- PR Number: #123\n' > "$body"
}

@test "paw pr-review: task-owned tracking wins over shared branch evidence in either order" {
  init_git_repo
  local owner other comments_cmd
  comments_cmd=$(write_fake_comments_cmd)
  for owner in a-owner z-owner; do
    other=middle-task
    seed_task_package "$owner"
    seed_task_package "$other"
    seed_shared_pr
    printf '\n## PR Tracking\n\n- PR Number: #123\n' >> "$REPO/.agent/$owner/plan.md"
    cp "$REPO/.agent/$other/plan.md" "$BATS_TEST_TMPDIR/other-plan"
    PAW_GH_COMMENTS_CMD="$comments_cmd" run "$PAW" pr-review 123
    [ "$status" -eq 0 ]
    [ -f "$REPO/.agent/$owner/review.md" ]
    [ ! -f "$REPO/.agent/$other/review.md" ]
    cmp "$REPO/.agent/$other/plan.md" "$BATS_TEST_TMPDIR/other-plan"
    write_fake_gh
    run "$PAW" pr-review 123
    [ "$status" -eq 0 ]
    grep -q 'Status: submitted' "$REPO/.agent/$owner/review.md"
    rm -r "$REPO/.agent/$owner" "$REPO/.agent/$other"
  done
}

@test "paw pr-review: conflicting and shared-only owners refuse without mutation or remote calls" {
  init_git_repo
  seed_task_package a-task
  seed_task_package z-task
  seed_shared_pr
  write_fake_gh
  export PAW_GH_COMMENTS_CMD="$SHIM_DIR/gh"
  local task
  for task in a-task z-task; do
    cp "$REPO/.agent/$task/plan.md" "$BATS_TEST_TMPDIR/$task-before"
  done
  run "$PAW" pr-review 123
  [ "$status" -ne 0 ]
  [[ "$output" == *a-task*z-task* ]]
  for task in a-task z-task; do
    cmp "$REPO/.agent/$task/plan.md" "$BATS_TEST_TMPDIR/$task-before"
    printf '\n## PR Tracking\n\n- PR Number: #123\n' >> "$REPO/.agent/$task/plan.md"
    cp "$REPO/.agent/$task/plan.md" "$BATS_TEST_TMPDIR/$task-before"
  done
  run "$PAW" pr-review 123
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicting task-owned tracking: a-task z-task"* ]]
  for task in a-task z-task; do
    cmp "$REPO/.agent/$task/plan.md" "$BATS_TEST_TMPDIR/$task-before"
    [ ! -f "$REPO/.agent/$task/review.md" ]
  done
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ]
}

@test "paw pr-review: only structural records own a PR and unique shared fallback remains supported" {
  init_git_repo
  seed_task_package examples
  cat >> "$REPO/.agent/examples/plan.md" <<'DOC'

PR Number: #123 is discussed in prose.
> ## PR Tracking
> - PR Number: #123

````markdown
## PR Tracking
- PR Number: #123
```
## PR Tracking
- PR Number: #123
````

   ~~~markdown
## PR Tracking
- PR Number: #123
   ~~~

## PR Tracking

    - PR Number: #123
- PR Number: #123 example

### Nested example
- PR Number: #123
DOC
  cat > "$REPO/.agent/examples/review.md" <<'DOC'
# Task Quality Review

## Review Metadata

- PR Number: #123
DOC
  write_fake_gh
  export PAW_GH_COMMENTS_CMD="$SHIM_DIR/gh"
  run "$PAW" pr-review 123
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ]
  # An explicit legacy task record owns the PR despite the unrelated examples.
  seed_task_package legacy-owner
  printf '\n## PR Tracking\n\n- PR Number: #123\n' >> "$REPO/.agent/legacy-owner/pr.md"
  local comments_cmd
  comments_cmd=$(write_fake_comments_cmd)
  PAW_GH_COMMENTS_CMD="$comments_cmd" run "$PAW" pr-review 123
  [ "$status" -eq 0 ]
  [ -f "$REPO/.agent/legacy-owner/review.md" ]
  rm -r "$REPO/.agent/legacy-owner"
  rm "$REPO/.agent/examples/review.md"
  seed_shared_pr
  PAW_GH_COMMENTS_CMD="$comments_cmd" run "$PAW" pr-review 123
  [ "$status" -eq 0 ]
  [ -f "$REPO/.agent/examples/review.md" ]
}

@test "paw PR publication: shared eligibility, body, remote retry and identity policy" {
  PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPTS_DIR/../tests/pr-publication.py"
}

@test "paw pr-update and pr-submit reject lower grades without gh mutation" {
  init_git_repo
  seed_task_package gate
  qualify_publication gate
  write_fake_gh
  sed -i.bak 's/Grade: A-/Grade: B+/' "$REPO/.agent/gate/review.md"
  local command
  for command in pr-submit pr-update; do
    run "$PAW" "$command" gate
    [ "$status" -ne 0 ]
    [[ "$output" == *"Review"* || "$output" == *"A-"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/gh.args" ]
  done
}

@test "paw pr-update resumes saved worktree without switching either branch" {
  init_git_repo
  git checkout -q -b feature/saved-publication
  run "$PAW" plan saved-publication "record assignment"
  [ "$status" -eq 0 ]
  local task_dir body other="$BATS_TEST_TMPDIR/other-worktree"
  task_dir="$(task_dir_for saved-publication)"
  body="$(branch_pr_file_for feature/saved-publication)"
  mkdir -p "${body%/*}"
  echo 'Local unrelated body.' > "$body"
  qualify_publication saved-publication
  git worktree add -q -b other-branch "$other"
  write_fake_gh
  cd "$other"
  run "$PAW" pr-update saved-publication
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature/saved-publication"* ]]
  [ "$(git -C "$other" branch --show-current)" = other-branch ]
  [ "$(git -C "$REPO" branch --show-current)" = feature/saved-publication ]
  [ -f "$task_dir/publication-preview.json" ]
  [ ! -f "$BATS_TEST_TMPDIR/gh.body" ]
}

@test "paw publication tokens cannot cross update and create-only commands" {
  init_git_repo
  seed_task_package modes
  qualify_publication modes
  write_fake_gh
  local origin other token before
  for origin in pr-update pr-submit; do
    other=pr-submit
    [[ "$origin" != pr-submit ]] || other=pr-update
    run "$PAW" "$origin" modes
    [ "$status" -eq 0 ]
    token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$REPO/.agent/modes/publication-preview.json")
    before=$(shasum "$REPO/.agent/modes/plan.md" "$REPO/.agent/modes/pr.md" "$REPO/.agent/modes/publication-preview.json")
    run "$PAW" "$other" modes --publish "$token"
    [ "$status" -ne 0 ]
    [[ "$output" == *mode* ]]
    [ ! -f "$BATS_TEST_TMPDIR/gh.body" ]
    [ "$before" = "$(shasum "$REPO/.agent/modes/plan.md" "$REPO/.agent/modes/pr.md" "$REPO/.agent/modes/publication-preview.json")" ]
  done
}

@test "paw both operation receipts refuse cross-command invocation and retry without remote edits" {
  init_git_repo
  local origin other task token before index_before refs_before
  for origin in pr-submit pr-update; do
    other=pr-submit
    [[ "$origin" != pr-submit ]] || other=pr-update
    seed_task_package "retry-$origin"
    qualify_publication "retry-$origin"
    write_fake_gh
    export FIXTURE_PR_STATE="$BATS_TEST_TMPDIR/remote-$origin.json"
    run "$PAW" "$origin" "retry-$origin"
    [ "$status" -eq 0 ]
    task="$REPO/.agent/retry-$origin"
    token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$task/publication-preview.json")
    index_before=$(shasum "$REPO/.git/index")
    refs_before=$(git show-ref)
    run "$PAW" "$origin" "retry-$origin" --publish "$token"
    [ "$status" -eq 0 ]
    before=$(shasum "$task/plan.md" "$task/pr.md" "$task/publication-result.json" "$REPO/.git/paw-publication/$token.json")
    run "$PAW" "$other" "retry-$origin" --publish "$token"
    [ "$status" -ne 0 ]
    [[ "$output" == *mode* ]]
    [ "$before" = "$(shasum "$task/plan.md" "$task/pr.md" "$task/publication-result.json" "$REPO/.git/paw-publication/$token.json")" ]
    run "$PAW" "$origin" "retry-$origin" --publish "$token"
    [ "$status" -eq 0 ]
    [ "$(cat "$FIXTURE_PR_STATE.mutations")" = create ]
    [ "$index_before" = "$(shasum "$REPO/.git/index")" ]
    [ "$refs_before" = "$(git show-ref)" ]
  done
}
