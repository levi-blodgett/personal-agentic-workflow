#!/usr/bin/env bats
# Tests for the scripts/paw subcommand dispatcher.
#
# A PATH-shimmed `claude` fake is used so tests never make real API calls.
# The fake writes its full argv to $BATS_TEST_TMPDIR/claude.args and exits 0.
# It also writes a minimal JSON response so the shared token parsers have fixture data.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PAW="$SCRIPTS_DIR/paw"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures" && pwd)"

load 'helpers/exit_code'

# ── setup / teardown ──────────────────────────────────────────────────────────

setup() {
  # Create a temporary repo with a .agent/ dir.
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent"

  # Build the claude shim directory.
  SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
# Record all args for the test to inspect.
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/claude.args"
pwd -P > "$BATS_TEST_TMPDIR/claude.cwd"
# Emit a minimal --output-format json response.
cat <<JSON
{"result":"ok","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
JSON
SHIM
  chmod +x "$SHIM_DIR/claude"

  # Prepend shim dir to PATH so paw finds our fake claude first.
  export PATH="$SHIM_DIR:$PATH"

  # Point PAW_HOME at this repo so prompts/prompt_instructions.md is found.
  export PAW_HOME="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export PAW_BACKEND=claude
  export PAW_TASK_HOME="$BATS_TEST_TMPDIR/paw-state/tasks"

  # Run from inside the temp repo so .agent/ relative paths resolve.
  cd "$REPO"
}

# ── helper ────────────────────────────────────────────────────────────────────

args_contain() {
  grep -qF -- "$1" "$BATS_TEST_TMPDIR/claude.args"
}

init_git_repo() {
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "test@example.com"
  echo "base" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "init"
}

make_task() {
  local name="$1"
  mkdir -p "$REPO/.agent/$name"
  cp "$(dirname "$BATS_TEST_FILENAME")/fixtures/sample-task-valid/plan.md" \
     "$REPO/.agent/$name/plan.md"
  local matches=("$PAW_TASK_HOME"/*/"$name")
  if [[ -d "${matches[0]}" ]]; then
    cp "$(dirname "$BATS_TEST_FILENAME")/fixtures/sample-task-valid/plan.md" \
       "${matches[0]}/plan.md"
  fi
}

physical_path() {
  cd "$1" && pwd -P
}

assignment_file() {
  local repo_path="$1"
  local task_name="$2"
  local common_dir
  common_dir=$(git -C "$repo_path" rev-parse --git-common-dir)
  printf '%s/%s.gitconfig\n' "$common_dir/paw-task-assignments" "$task_name"
}

# ── tests ─────────────────────────────────────────────────────────────────────

@test "paw help: exits 0 and prints subcommand list" {
  run "$PAW" help

  [ "$status" -eq 0 ]
  [[ "$output" == *'paw prototype <task-name> [--question "<question>"] [--logic|--ui] [extras...]'* ]]
  [[ "$output" == *'paw lint [task-dir|--repo p]'* ]]
  [[ "$output" == *'paw model [-v|--verbose]'* ]]
  [[ "$output" == *"paw architecture"* ]]
  [[ "$output" == *"paw teach"* ]]
  [[ "$output" == *"paw prototype"* ]]
  [[ "$output" == *"paw completion zsh"* ]]
  [[ "$output" == *"paw plan"* ]]
  [[ "$output" == *"paw implement"* ]]
  [[ "$output" == *"paw diagnose"* ]]
  [[ "$output" == *"paw tighten"* ]]
  [[ "$output" == *"paw to-issues"* ]]
  [[ "$output" == *"paw task-migrate"* ]]
  [[ "$output" == *"paw gui [start|stop|kill]"* ]]
  [[ "$output" == *"paw pr-submit"* ]]
  [[ "$output" == *"paw pr-review"* ]]
  [[ "$output" == *"paw pr-address-comments"* ]]
  [[ "$output" == *"paw issue-submit"* ]]
  [[ "$output" == *"paw issue-review"* ]]
  [[ "$output" == *"paw gh-actions-review"* ]]
  [[ "$output" == *"PAW_STREAM"* ]]
}

@test "paw gui: rejects unknown lifecycle subcommands clearly" {
  run "$PAW" gui restart

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown paw gui subcommand: restart"* ]]
  [[ "$output" == *"supported subcommands: start, stop, kill"* ]]
}

@test "paw gui --help: prints lifecycle usage without starting server" {
  run "$PAW" gui --help

  [ "$status" -eq 0 ]
  [[ "$output" == "usage: paw gui [start|stop|kill]"* ]]
  [[ "$output" == *"[--all]"* ]]
}

@test "paw gui start: rejects non-local hosts" {
  run "$PAW" gui start --host 0.0.0.0

  [ "$status" -eq 2 ]
  [[ "$output" == *"local-only"* ]]
}

@test "paw completion zsh: prints a zsh completion script with live subcommands" {
  run "$PAW" completion zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"#compdef paw"* ]]
  [[ "$output" == *"_describe -t commands 'paw subcommand' commands"* ]]
  [[ "$output" == *"'gh-actions-review:inspect same-day GitHub Actions failures'"* ]]
  [[ "$output" == *"'architecture:explore repo architecture candidates, then continue grilling the selected path'"* ]]
  [[ "$output" == *"'teach:map the relevant modules and callers for an unfamiliar area'"* ]]
  [[ "$output" == *"'prototype:run a bounded throwaway prototype workflow for one concrete question'"* ]]
  [[ "$output" == *"'diagnose:run the feedback-loop-first debugging workflow for an approved task'"* ]]
  [[ "$output" == *"'tighten:sharpen an existing task plan one question at a time'"* ]]
  [[ "$output" == *"'to-issues:draft tracer-bullet issue slices or publish reviewed drafts'"* ]]
  [[ "$output" == *"'task-migrate:copy legacy .agent tasks into the central task store'"* ]]
  [[ "$output" == *"'gui:start, stop, or foreground the local PAW task dashboard'"* ]]
  [[ "$output" == *"'pr-address-comments:create a plan for addressing PR review comments'"* ]]
  [[ "$output" == *"'implement:resume or complete an approved task'"* ]]
}

@test "paw completion: rejects unsupported shells" {
  run "$PAW" completion bash

  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported shell for completion: bash"* ]]
  [[ "$output" == *"supported shells: zsh"* ]]
}

@test "sourcing scripts/paw does not run main" {
  run bash -lc 'source "$1"; printf "main=%s\n" "$(type -t main)"' _ "$PAW"

  [ "$status" -eq 0 ]
  [ "$output" = "main=function" ]
}

@test "paw: unknown subcommand exits 2" {
  run "$PAW" notacommand

  [ "$status" -eq 2 ]
}

@test "paw list: delegates to list-tasks.sh" {
  run "$PAW" list "$REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no task directories"* ]]
}

@test "paw lint: delegates to lint-task.sh on a valid fixture" {
  local fixtures_dir
  fixtures_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures" && pwd)"
  run "$PAW" lint "$fixtures_dir/sample-task-valid"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "paw setup: delegates to setup-repo.sh" {
  local repo="$BATS_TEST_TMPDIR/setup-target"
  mkdir -p "$repo"
  git -C "$repo" init -q

  run "$PAW" setup "$repo"

  [ "$status" -eq 0 ]
  grep -qxF '.agent/' "$repo/.git/info/exclude"
}

@test "paw plan: records task branch/worktree assignment in git-common-dir metadata" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/task-context

  run "$PAW" plan branch-task "record the current git context"

  [ "$status" -eq 0 ]
  local task_assignment
  task_assignment="$(assignment_file "$REPO" "branch-task")"
  [ -f "$task_assignment" ]
  [[ "$(git config --file "$task_assignment" --get paw.branch-name)" == "feature/task-context" ]]
  [[ "$(git config --file "$task_assignment" --get paw.head-state)" == "branch" ]]
  [[ "$(git config --file "$task_assignment" --get paw.worktree-path)" == "$(physical_path "$REPO")" ]]
}

@test "paw plan: rejects --multi-plan before writing assignment metadata" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/multi-plan

  run "$PAW" plan --multi-plan parent-task "break the work into child plans"

  [ "$status" -eq 2 ]
  [[ "$output" == *"--multi-plan has been removed"* ]]
  [ ! -e "$(assignment_file "$REPO" "parent-task")" ]
}

@test "paw implement: switches back to the assigned branch in the current worktree when clean" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/resume-task
  run "$PAW" plan branch-task "record assignment"
  [ "$status" -eq 0 ]

  make_task branch-task
  git -C "$REPO" checkout -q -b scratch

  run "$PAW" implement branch-task

  [ "$status" -eq 0 ]
  [[ "$(git -C "$REPO" branch --show-current)" == "feature/resume-task" ]]
}

@test "paw implement: refuses branch switching when the current worktree has unstashed changes" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/safe-task
  run "$PAW" plan guarded-task "record assignment"
  [ "$status" -eq 0 ]

  make_task guarded-task
  git -C "$REPO" checkout -q -b scratch
  echo "dirty" >> "$REPO/README.md"

  run "$PAW" implement guarded-task

  [ "$status" -eq 1 ]
  [[ "$output" == *"unstashed changes"* ]]
  [[ "$(git -C "$REPO" branch --show-current)" == "scratch" ]]
}

@test "paw implement: re-execs from the assigned registered worktree in the same repo" {
  init_git_repo
  git -C "$REPO" branch feature/worktree-task
  local assigned_worktree="$BATS_TEST_TMPDIR/repo-feature-worktree"
  git -C "$REPO" worktree add -q "$assigned_worktree" feature/worktree-task

  cd "$assigned_worktree"
  run "$PAW" plan worktree-task "record worktree assignment"
  [ "$status" -eq 0 ]
  mkdir -p "$assigned_worktree/.agent/worktree-task"
  cp "$(dirname "$BATS_TEST_FILENAME")/fixtures/sample-task-valid/plan.md" \
     "$assigned_worktree/.agent/worktree-task/plan.md"
  local matches=("$PAW_TASK_HOME"/*/worktree-task)
  if [[ -d "${matches[0]}" ]]; then
    cp "$(dirname "$BATS_TEST_FILENAME")/fixtures/sample-task-valid/plan.md" \
       "${matches[0]}/plan.md"
  fi

  cd "$REPO"
  run "$PAW" implement worktree-task

  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/claude.cwd")" == "$(physical_path "$assigned_worktree")" ]]
}

@test "paw implement: resolves an external backend plugin executable when no built-in module exists" {
  make_task plugin-task
  cp "$FIXTURES_DIR/backend-plugins/paw-backend-fixture-plugin" \
     "$SHIM_DIR/paw-backend-fixture-plugin"
  chmod +x "$SHIM_DIR/paw-backend-fixture-plugin"

  PAW_BACKEND=fixture-plugin run "$PAW" implement plugin-task

  [ "$status" -eq 0 ]
  [[ "$output" == *"fixture-plugin-ok"* ]]
  grep -qF "PAW:IMPLEMENT" "$BATS_TEST_TMPDIR/fixture-plugin.prompt"
  grep -qF -- "--model" "$BATS_TEST_TMPDIR/fixture-plugin.args"
}

@test "paw implement: reports a missing external backend plugin clearly" {
  make_task missing-plugin-task

  PAW_BACKEND=missing-plugin run "$PAW" implement missing-plugin-task

  [ "$status" -eq 1 ]
  [[ "$output" == *"paw-backend-missing-plugin"* ]]
  [[ "$output" == *"not found"* ]]
}

@test "paw implement: refuses to auto-detach when the saved task assignment came from detached HEAD" {
  init_git_repo
  git -C "$REPO" checkout --detach -q HEAD

  run "$PAW" plan detached-task "record detached assignment"

  [ "$status" -eq 0 ]
  make_task detached-task
  git -C "$REPO" checkout -q -b scratch

  run "$PAW" implement detached-task

  [ "$status" -eq 1 ]
  [[ "$output" == *"will not auto-detach"* ]]
}

@test "paw implement: refuses assignments that point at another repo/common-dir" {
  init_git_repo
  git -C "$REPO" checkout -q -b feature/foreign-check
  run "$PAW" plan foreign-task "record assignment"
  [ "$status" -eq 0 ]
  make_task foreign-task

  local other_repo="$BATS_TEST_TMPDIR/other-repo"
  mkdir -p "$other_repo"
  git -C "$other_repo" init -q
  local task_assignment
  task_assignment="$(assignment_file "$REPO" "foreign-task")"
  git config --file "$task_assignment" paw.git-common-dir "$(git -C "$other_repo" rev-parse --git-common-dir)"

  run "$PAW" implement foreign-task

  [ "$status" -eq 1 ]
  [[ "$output" == *"another repo/common-dir"* ]]
}

@test "paw implement: invokes claude with --model and PAW:IMPLEMENT anchor" {
  mkdir -p "$REPO/.agent/my-task"
  cp "$(dirname "$BATS_TEST_FILENAME")/fixtures/sample-task-valid/plan.md" \
     "$REPO/.agent/my-task/plan.md"

  run "$PAW" implement my-task

  [ "$status" -eq 0 ]
  args_contain "--model"
  args_contain "PAW:IMPLEMENT"
  args_contain "my-task"
}

@test "paw teach: invokes claude with the repo-mapping prompt" {
  run "$PAW" teach "Focus on command dispatch."

  [ "$status" -eq 0 ]
  args_contain "--model"
  args_contain "paw teach"
  args_contain "Focus on command dispatch."
}

@test "removed command: paw new exits 2 with unknown-subcommand guidance" {
  run "$PAW" new my-new-task "add logging"

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand: new"* ]]
}

@test "removed command: paw complete exits 2 with unknown-subcommand guidance" {
  run "$PAW" complete my-task

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand: complete"* ]]
}

@test "removed command: paw continue exits 2 with unknown-subcommand guidance" {
  run "$PAW" continue my-task

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand: continue"* ]]
}

@test "removed command: paw context exits 2 with unknown-subcommand guidance" {
  run "$PAW" context

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand: context"* ]]
}

@test "paw pr-address-comments: creates task dir, seeds templates, writes comments.md, uses PAW:PLAN anchor" {
  PAW_GH_COMMENTS_CMD=echo run "$PAW" pr-address-comments 42

  [ "$status" -eq 0 ]
  local matches=("$PAW_TASK_HOME"/*/42-review/comments.md)
  [ -f "${matches[0]}" ]
  args_contain "PAW:PLAN"
}

@test "paw task-migrate: migrates legacy task package to central store" {
  make_task migrate-me

  run "$PAW" task-migrate "$REPO"

  [ "$status" -eq 0 ]
  local matches=("$PAW_TASK_HOME"/*/migrate-me/plan.md)
  [ -f "${matches[0]}" ]
  [[ "$output" == *"migrated:"* ]]
}

@test "paw gui: rejects non-local hosts" {
  run "$PAW" gui --host 0.0.0.0

  [ "$status" -eq 2 ]
  [[ "$output" == *"local-only"* ]]
}

@test "paw implement: exits 2 when no task name given" {
  run "$PAW" implement

  assert_exits_2
}

@test "paw pr-address-comments: exits 2 when pr number missing" {
  run "$PAW" pr-address-comments

  assert_exits_2
}

@test "paw pr-address-comments: two-arg form exits 2 with signature error" {
  run "$PAW" pr-address-comments some-task 42

  [ "$status" -eq 2 ]
  [[ "$output" == *"paw pr-address-comments signature changed"* ]]
}

@test "paw issue-submit: exits 2 when task name missing" {
  run "$PAW" issue-submit

  assert_exits_2
}

@test "paw issue-submit: errors on extra arguments" {
  run "$PAW" issue-submit some-task extra

  [ "$status" -eq 2 ]
  [[ "$output" == *"paw issue-submit accepts only <task-name>"* ]]
}

@test "paw issue-review: exits 2 when issue number missing" {
  run "$PAW" issue-review

  assert_exits_2
}

@test "paw issue-review: errors on extra arguments" {
  run "$PAW" issue-review 42 extra

  [ "$status" -eq 2 ]
  [[ "$output" == *"paw issue-review accepts only <issue-number>"* ]]
}

@test "paw review: exits 2 and points callers to pr-address-comments" {
  run "$PAW" review 42

  [ "$status" -eq 2 ]
  [ "$output" = "error: paw review has been replaced by paw pr-address-comments 42." ]
}

@test "paw model: exits 0 and prints eleven subcommand lines" {
  run "$PAW" model

  [ "$status" -eq 0 ]
  [[ "$output" == *"plan:"* ]]
  [[ "$output" == *"architecture:"* ]]
  [[ "$output" == *"teach:"* ]]
  [[ "$output" == *"prototype:"* ]]
  [[ "$output" == *"edit:"* ]]
  [[ "$output" == *"implement:"* ]]
  [[ "$output" == *"diagnose:"* ]]
  [[ "$output" == *"tighten:"* ]]
  [[ "$output" == *"to-issues:"* ]]
  [[ "$output" == *"issue-review:"* ]]
  [[ "$output" == *"pr-address-comments:"* ]]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 11 ]
}

@test "paw model: respects PAW_MODEL override for every subcommand" {
  PAW_MODEL=opus run "$PAW" model

  [ "$status" -eq 0 ]
  [[ "$output" == *"plan:      opus"* ]]
  [[ "$output" == *"architecture: opus"* ]]
  [[ "$output" == *"teach:     opus"* ]]
  [[ "$output" == *"prototype: opus"* ]]
  [[ "$output" == *"edit:      opus"* ]]
  [[ "$output" == *"implement: opus"* ]]
  [[ "$output" == *"diagnose:  opus"* ]]
  [[ "$output" == *"tighten:   opus"* ]]
  [[ "$output" == *"to-issues: opus"* ]]
  [[ "$output" == *"issue-review: opus"* ]]
  [[ "$output" == *"pr-address-comments: opus"* ]]
}

@test "paw model --verbose: prints fourteen lines including backend, stream, max-turns" {
  PAW_BACKEND=stub PAW_STREAM=0 PAW_MAX_TURNS=50 run "$PAW" model --verbose

  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 14 ]
  [[ "$output" == *"backend:"* ]]
  [[ "$output" == *"stream:"* ]]
  [[ "$output" == *"max-turns:"* ]]
  [[ "$output" == *"stub"* ]]
  [[ "$output" == *"50"* ]]
}

@test "paw model -v: short flag also triggers verbose output" {
  run "$PAW" model -v

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:"* ]]
}

@test "paw model: legacy PAW_MODEL_* vars no longer affect resolution" {
  PAW_MODEL_PLAN=opus PAW_MODEL_CONTEXT=opus PAW_MODEL_EDIT=opus PAW_MODEL_RUN=opus PAW_MODEL_NEW=opus run "$PAW" model

  [ "$status" -eq 0 ]
  [[ "$output" == *"plan:      sonnet"* ]]
  [[ "$output" == *"architecture: sonnet"* ]]
  [[ "$output" == *"teach:     sonnet"* ]]
  [[ "$output" == *"prototype: sonnet"* ]]
  [[ "$output" == *"edit:      sonnet"* ]]
  [[ "$output" == *"implement: sonnet"* ]]
  [[ "$output" == *"diagnose:  sonnet"* ]]
  [[ "$output" == *"tighten:   sonnet"* ]]
  [[ "$output" == *"to-issues: sonnet"* ]]
  [[ "$output" == *"issue-review: sonnet"* ]]
  [[ "$output" == *"pr-address-comments: sonnet"* ]]
}
