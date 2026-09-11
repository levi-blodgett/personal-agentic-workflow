#!/usr/bin/env bats
# Tests for the paw prompt body produced by each subcommand.
#
# All invocations use PAW_BACKEND=stub so no real AI API calls are made.
# The stub backend writes:
#   $BATS_TEST_TMPDIR/backend.args   — one argument per line
#   $BATS_TEST_TMPDIR/backend.prompt — the full prompt string
#   $BATS_TEST_TMPDIR/backend.mode   — "capture" or "stream"
#
# The real `claude` binary is never required — PAW_BACKEND=stub bypasses it.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PAW="$SCRIPTS_DIR/paw"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures" && pwd)"

load 'helpers/exit_code'

# ── setup / teardown ──────────────────────────────────────────────────────────

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent"

  export PAW_HOME="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export PAW_BACKEND=stub
  export PAW_MAX_TURNS=100
  export PAW_TASK_HOME="$BATS_TEST_TMPDIR/paw-state/tasks"

  # Ensure claude binary is NOT on PATH — stub backend must not need it.
  EMPTY_BIN="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$EMPTY_BIN"
  export PATH="$EMPTY_BIN:$PATH"

  cd "$REPO"
}

# ── helpers ───────────────────────────────────────────────────────────────────

make_task() {
  local name="$1"
  mkdir -p "$REPO/.agent/$name"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$REPO/.agent/$name/plan.md"
}

prompt_contains() {
  grep -qF -- "$1" "$BATS_TEST_TMPDIR/backend.prompt"
}

args_contain() {
  grep -qF -- "$1" "$BATS_TEST_TMPDIR/backend.args"
}

mode_is() {
  [[ "$(cat "$BATS_TEST_TMPDIR/backend.mode" 2>/dev/null)" == "$1" ]]
}

write_fake_gh_actions_review_cmd() {
  local script="$BATS_TEST_TMPDIR/fake-gh-actions-review.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/gh-actions-review.args"
echo "state: undocumented"
EOF
  chmod +x "$script"
  printf '%s\n' "$script"
}

init_git_repo() {
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "test@example.com"
  echo "base" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "init"
}

# ── paw architecture ──────────────────────────────────────────────────────────

@test "paw architecture: prompt contains architecture workflow guidance" {
  run "$PAW" architecture
  [ "$status" -eq 0 ]
  prompt_contains "paw architecture"
  prompt_contains "Explore the repository before recommending anything."
  prompt_contains ".agent/architecture/candidates.md"
}

@test "paw architecture: prompt references the --pick follow-up flow" {
  run "$PAW" architecture "focus on test seams"
  [ "$status" -eq 0 ]
  prompt_contains "paw architecture --pick <number> [answer/context...]"
  prompt_contains "focus on test seams"
}

@test "paw architecture: --pick prompt resumes the saved candidate" {
  mkdir -p "$REPO/.agent/architecture"
  cat > "$REPO/.agent/architecture/candidates.md" <<'MD'
1. Candidate one
2. Candidate two
MD

  run "$PAW" architecture --pick 2 "Prefer narrower changes."
  [ "$status" -eq 0 ]
  prompt_contains "Candidate #2 is the selected path for this run."
  prompt_contains ".agent/architecture/grill.md"
  prompt_contains "Prefer narrower changes."
}

@test "paw architecture: --pick requires the saved candidate list" {
  run "$PAW" architecture --pick 2
  [ "$status" -eq 1 ]
  [[ "$output" == *".agent/architecture/candidates.md not found"* ]]
  [[ "$output" == *"Run 'paw architecture' first"* ]]
}

@test "paw architecture: --pick rejects non-numeric candidates" {
  run "$PAW" architecture --pick two
  [ "$status" -eq 2 ]
  [[ "$output" == *"--pick expects a numeric candidate number"* ]]
}

# ── paw teach ─────────────────────────────────────────────────────────────────

@test "paw teach: prompt positions the command as lightweight repo orientation" {
  run "$PAW" teach
  [ "$status" -eq 0 ]
  prompt_contains "paw teach"
  prompt_contains "not a plan/edit/implement task"
  prompt_contains 'Stay lighter-weight than `paw plan` or `paw architecture`'
}

@test "paw teach: prompt preserves the module-and-callers mapping behavior" {
  run "$PAW" teach "Focus on command dispatch."
  [ "$status" -eq 0 ]
  prompt_contains "relevant modules and callers"
  prompt_contains "Use repo/domain vocabulary"
  prompt_contains "Focus on command dispatch."
}

@test "paw teach: prompt avoids automatic durable-doc writing and suggests explicit follow-up work instead" {
  run "$PAW" teach
  [ "$status" -eq 0 ]
  prompt_contains "Do not silently write durable docs"
  prompt_contains 'recommend an explicit next step such as `paw plan <task-name> "..."`'
}

@test "paw teach: uses architecture-class model defaults when PAW_MODEL is unset" {
  run "$PAW" teach
  [ "$status" -eq 0 ]
  args_contain "sonnet"
}

@test "paw teach: appends Human extras when extra arg given" {
  run "$PAW" teach "Focus on the CLI state machine."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Focus on the CLI state machine."
}

# ── paw review / prototype ───────────────────────────────────────────────────

@test "paw review: prompt contains PAW:IMPLEMENT anchor and task-quality guidance" {
  make_task review-task
  run "$PAW" review review-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:IMPLEMENT"
  prompt_contains 'This is a `paw review` run'
  prompt_contains "Assign a clear grade"
  prompt_contains "quality threshold"
  prompt_contains "architectural and design choices"
  prompt_contains "concrete recommendations"
}

@test "paw review: seeds review.md for durable grade and recommendations" {
  make_task review-task
  run "$PAW" review review-task
  [ "$status" -eq 0 ]
  [ -f "$REPO/.agent/review-task/review.md" ]
  grep -q "## Architectural / Design Choices" "$REPO/.agent/review-task/review.md"
  grep -q "## Recommendations" "$REPO/.agent/review-task/review.md"
}

@test "paw review: appends Human extras when extra arg given" {
  make_task review-task
  run "$PAW" review review-task "Threshold is B+."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Threshold is B+."
}

@test "paw prototype: requires a reviewed source task" {
  make_task proto-task
  run "$PAW" prototype proto-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no review.md"* ]]
  [[ "$output" == *"paw review proto-task"* ]]
}

@test "paw prototype: rejects old throwaway prototype flags with compatibility guidance" {
  make_task proto-task
  run "$PAW" prototype proto-task --question "Does this flow hold up?"
  [ "$status" -eq 2 ]
  [[ "$output" == *"now creates a replacement plan from a reviewed task"* ]]
}

@test "paw prototype: prompt contains PAW:PLAN anchor and reviewed source references" {
  make_task proto-task
  printf '# Review\n\n## Recommendations\n- Replace the flow.\n' > "$REPO/.agent/proto-task/review.md"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:PLAN"
  prompt_contains "proto-task/review.md"
  prompt_contains "source task being treated as the prototype"
  prompt_contains "replacement plan-only task package"
}

@test "paw prototype: seeds replacement plan package and records prototype metadata" {
  make_task proto-task
  printf '# Review\n' > "$REPO/.agent/proto-task/review.md"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  local matches=("$PAW_TASK_HOME"/*/proto-task-prototype/plan.md)
  [ -f "${matches[0]}" ]
  local metadata="${matches[0]%/plan.md}/metadata.gitconfig"
  [ "$(git config --file "$metadata" --get paw.prototype-source)" = "proto-task" ]
  [[ "$(git config --file "$metadata" --get paw.prototype-status)" == planned* ]]
}

@test "paw prototype: reverts tracked source work from saved task metadata after planning" {
  init_git_repo
  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  printf '# Review\n' > "$source_dir/review.md"
  printf 'changed\n' > "$REPO/README.md"

  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = "base" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-source-reverted" ]
}

@test "paw prototype: uses plan-class model defaults when PAW_MODEL is unset" {
  make_task proto-task
  printf '# Review\n' > "$REPO/.agent/proto-task/review.md"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  args_contain "sonnet"
}

@test "paw prototype: appends Human extras when extra arg given" {
  make_task proto-task
  printf '# Review\n' > "$REPO/.agent/proto-task/review.md"
  run "$PAW" prototype proto-task "Prefer the smallest replacement slice."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Prefer the smallest replacement slice."
}

# ── paw implement ─────────────────────────────────────────────────────────────

@test "paw implement: prompt contains PAW:IMPLEMENT anchor" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:IMPLEMENT"
}

@test "paw implement: prompt contains task name" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  prompt_contains "my-task"
}

@test "paw implement: prompt surfaces targeted-first validation policy" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  prompt_contains "Run the validation decision ladder"
  prompt_contains "targeted changed-area validation"
  prompt_contains "Validation tier chosen"
}

@test "paw implement: defaults to sonnet when PAW_MODEL is unset" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "sonnet"
}

@test "paw implement: haiku is rejected by quality guardrail on claude backend" {
  make_task my-task
  PAW_BACKEND=claude PAW_MODEL=haiku run "$PAW" implement my-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"quality floor"* ]]
}

@test "paw implement: haiku guardrail does not fire on non-claude backend" {
  make_task my-task
  PAW_MODEL=haiku run "$PAW" implement my-task
  [ "$status" -eq 0 ]
}

@test "paw implement: uses --max-turns from PAW_MAX_TURNS" {
  make_task my-task
  PAW_MAX_TURNS=77 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "77"
}

@test "paw implement: no Human extras header when no extras given" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  ! grep -qF "Human extras" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw implement: blocks when plan has unresolved user-answer placeholder" {
  mkdir -p "$REPO/.agent/block-task"
  cat > "$REPO/.agent/block-task/plan.md" <<'MD'
# Plan

## Open Questions / Follow-Ups
- Need the API base URL.
  - USER ANSWER (UNRESOLVED):
MD

  run "$PAW" implement block-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"pending user-answer placeholders"* ]]
  [[ "$output" == *"paw edit block-task"* ]]
}

@test "paw implement: blocks when plan has provided-but-unreconciled user-answer placeholder" {
  mkdir -p "$REPO/.agent/block-provided-task"
  cat > "$REPO/.agent/block-provided-task/plan.md" <<'MD'
# Plan

## Open Questions / Follow-Ups
- Need the API base URL.
  - USER ANSWER (PROVIDED): https://example.test
MD

  run "$PAW" implement block-provided-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"pending user-answer placeholders"* ]]
}

@test "paw implement: appends Human extras when extra arg given" {
  make_task my-task
  run "$PAW" implement my-task "Focus on README only."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Focus on README only."
}

@test "paw implement: multi-word extras joined and appended verbatim" {
  make_task my-task
  run "$PAW" implement my-task "skip the tests" "and focus on docs"
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "skip the tests and focus on docs"
}

@test "paw implement: exits 2 when no task name given" {
  run "$PAW" implement
  assert_exits_2
}

# ── paw diagnose ──────────────────────────────────────────────────────────────

@test "paw diagnose: prompt contains PAW:IMPLEMENT anchor" {
  make_task diagnose-task
  run "$PAW" diagnose diagnose-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:IMPLEMENT"
}

@test "paw diagnose: prompt contains task name and diagnose workflow guidance" {
  make_task diagnose-task
  run "$PAW" diagnose diagnose-task
  [ "$status" -eq 0 ]
  prompt_contains "diagnose-task"
  prompt_contains 'This is a `paw diagnose` run'
  prompt_contains "Lock or confirm a deterministic feedback loop first."
  prompt_contains "## Diagnose Loop"
  prompt_contains "### Ranked Hypotheses"
}

@test "paw diagnose: prompt surfaces targeted-first validation policy" {
  make_task diagnose-task
  run "$PAW" diagnose diagnose-task
  [ "$status" -eq 0 ]
  prompt_contains "Run the validation decision ladder"
  prompt_contains "targeted changed-area validation"
  prompt_contains "Validation tier chosen"
}

@test "paw diagnose: haiku is rejected by quality guardrail on claude backend" {
  make_task diagnose-task
  PAW_BACKEND=claude PAW_MODEL=haiku run "$PAW" diagnose diagnose-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"quality floor"* ]]
  [[ "$output" == *"'paw diagnose' requires at least sonnet."* ]]
}

@test "paw diagnose: blocks when plan has unresolved user-answer placeholder" {
  mkdir -p "$REPO/.agent/diagnose-block-task"
  cat > "$REPO/.agent/diagnose-block-task/plan.md" <<'MD'
# Plan

## Open Questions / Follow-Ups
- Need the failing commit SHA.
  - USER ANSWER (UNRESOLVED):
MD

  run "$PAW" diagnose diagnose-block-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"pending user-answer placeholders"* ]]
  [[ "$output" == *"paw edit diagnose-block-task"* ]]
}

@test "paw diagnose: appends Human extras when extra arg given" {
  make_task diagnose-task
  run "$PAW" diagnose diagnose-task "Focus on the flaky integration loop."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Focus on the flaky integration loop."
}

@test "paw diagnose: exits 2 when no task name given" {
  run "$PAW" diagnose
  assert_exits_2
}

# ── paw edit ─────────────────────────────────────────────────────────────────

@test "paw edit: prompt contains PAW:EDIT anchor" {
  make_task edit-task
  run "$PAW" edit edit-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:EDIT"
}

@test "paw edit: prompt contains task name" {
  make_task edit-task
  run "$PAW" edit edit-task
  [ "$status" -eq 0 ]
  prompt_contains "edit-task"
}

@test "paw edit: uses PAW_MODEL override when set" {
  make_task edit-task
  PAW_MODEL=opus run "$PAW" edit edit-task
  [ "$status" -eq 0 ]
  args_contain "opus"
}

@test "paw edit: exits 2 when task dir does not exist" {
  run "$PAW" edit nonexistent-task
  assert_exits_2
}

@test "paw edit: exits 2 when no task name given" {
  run "$PAW" edit
  assert_exits_2
}

@test "paw edit: appends Human extras when extra arg given" {
  make_task edit-task
  run "$PAW" edit edit-task "tighten the non-goals"
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "tighten the non-goals"
}

@test "paw edit: no Human extras header when no extras given" {
  make_task edit-task
  run "$PAW" edit edit-task
  [ "$status" -eq 0 ]
  ! grep -qF "Human extras" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw edit: still runs when plan has provided user-answer placeholder" {
  mkdir -p "$REPO/.agent/edit-placeholder-task"
  cat > "$REPO/.agent/edit-placeholder-task/plan.md" <<'MD'
# Plan

## Open Questions / Follow-Ups
- Need the API base URL.
  - USER ANSWER (PROVIDED): https://example.test
MD

  run "$PAW" edit edit-placeholder-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:EDIT"
}

# ── paw tighten ──────────────────────────────────────────────────────────────

@test "paw tighten: prompt contains PAW:EDIT anchor" {
  make_task tighten-task
  run "$PAW" tighten tighten-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:EDIT"
}

@test "paw tighten: seeds tighten.md as the interactive checkpoint" {
  make_task tighten-task
  run "$PAW" tighten tighten-task
  [ "$status" -eq 0 ]
  [ -f "$REPO/.agent/tighten-task/tighten.md" ]
  grep -q "## Current Question" "$REPO/.agent/tighten-task/tighten.md"
}

@test "paw tighten: prompt contains task name and tighten workflow guidance" {
  make_task tighten-task
  run "$PAW" tighten tighten-task
  [ "$status" -eq 0 ]
  prompt_contains "tighten-task"
  prompt_contains 'This is a `paw tighten` run'
  prompt_contains "Ask at most one highest-value next question in this run"
  prompt_contains ".agent/<task>/tighten.md"
  prompt_contains "include your recommended answer and brief reasoning"
}

@test "paw tighten: appends Human extras when extra arg given" {
  make_task tighten-task
  run "$PAW" tighten tighten-task "Focus on ambiguous acceptance criteria."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Focus on ambiguous acceptance criteria."
}

@test "paw tighten: still runs when plan has provided user-answer placeholder" {
  mkdir -p "$REPO/.agent/tighten-placeholder-task"
  cat > "$REPO/.agent/tighten-placeholder-task/plan.md" <<'MD'
# Plan

## Open Questions / Follow-Ups
- Need the API base URL.
  - USER ANSWER (PROVIDED): https://example.test
MD

  run "$PAW" tighten tighten-placeholder-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:EDIT"
}

@test "paw tighten: exits 2 when no task name given" {
  run "$PAW" tighten
  assert_exits_2
}

# ── paw to-issues ─────────────────────────────────────────────────────────────

@test "paw to-issues: prompt contains PAW:IMPLEMENT anchor" {
  make_task issue-slices
  run "$PAW" to-issues issue-slices
  [ "$status" -eq 0 ]
  prompt_contains "PAW:IMPLEMENT"
}

@test "paw to-issues: seeds issues README and references the draft workflow" {
  make_task issue-slices
  run "$PAW" to-issues issue-slices
  [ "$status" -eq 0 ]
  [ -f "$REPO/.agent/issue-slices/issues/README.md" ]
  prompt_contains ".agent/issue-slices/issues/index.md"
  prompt_contains "## Draft Metadata"
  prompt_contains 'paw to-issues issue-slices --publish'
}

@test "paw to-issues: appends Human extras when extra arg given" {
  make_task issue-slices
  run "$PAW" to-issues issue-slices "Prefer three thin AFK slices."
  [ "$status" -eq 0 ]
  prompt_contains "Human extras:"
  prompt_contains "Prefer three thin AFK slices."
}

# ── paw gh-actions-review ─────────────────────────────────────────────────────

@test "paw completion zsh: does not invoke the AI backend" {
  run "$PAW" completion zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"#compdef paw"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/backend.args" ]
}

@test "paw gh-actions-review: does not invoke the AI backend" {
  local review_cmd
  review_cmd=$(write_fake_gh_actions_review_cmd)

  PAW_GH_ACTIONS_REVIEW_CMD="$review_cmd" run "$PAW" gh-actions-review --create-issue

  [ "$status" -eq 0 ]
  [[ "$output" == *"state: undocumented"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/backend.args" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh-actions-review.args")" == *"--create-issue"* ]]
}

# ── paw pr-address-comments ───────────────────────────────────────────────────

@test "paw pr-address-comments: prompt contains PAW:PLAN anchor" {
  PAW_GH_COMMENTS_CMD=echo run "$PAW" pr-address-comments 42
  [ "$status" -eq 0 ]
  prompt_contains "PAW:PLAN"
}

@test "paw pr-address-comments: prompt contains task name" {
  PAW_GH_COMMENTS_CMD=echo run "$PAW" pr-address-comments 42
  [ "$status" -eq 0 ]
  prompt_contains "42-review"
}

@test "paw pr-address-comments: prompt contains PR number" {
  PAW_GH_COMMENTS_CMD=echo run "$PAW" pr-address-comments 42
  [ "$status" -eq 0 ]
  prompt_contains "42"
}

@test "paw pr-address-comments: uses PAW_MODEL when overridden" {
  PAW_GH_COMMENTS_CMD=echo PAW_MODEL=opus run "$PAW" pr-address-comments 42
  [ "$status" -eq 0 ]
  args_contain "opus"
}

@test "paw pr-address-comments: prompt references comments.md path" {
  PAW_GH_COMMENTS_CMD=echo run "$PAW" pr-address-comments 42
  [ "$status" -eq 0 ]
  prompt_contains "42-review/comments.md"
}

@test "paw pr-address-comments: prompt contains current branch" {
  PAW_GH_COMMENTS_CMD=echo run "$PAW" pr-address-comments 42
  [ "$status" -eq 0 ]
  prompt_contains "branch"
}

# ── paw issue-review ──────────────────────────────────────────────────────────

@test "paw issue-review: prompt contains PAW:PLAN anchor" {
  PAW_GH_ISSUE_VIEW_CMD=echo run "$PAW" issue-review 42
  [ "$status" -eq 0 ]
  prompt_contains "PAW:PLAN"
}

@test "paw issue-review: prompt contains task name" {
  PAW_GH_ISSUE_VIEW_CMD=echo run "$PAW" issue-review 42
  [ "$status" -eq 0 ]
  prompt_contains "42-issue-review"
}

@test "paw issue-review: prompt contains issue number" {
  PAW_GH_ISSUE_VIEW_CMD=echo run "$PAW" issue-review 42
  [ "$status" -eq 0 ]
  prompt_contains "Issue number: 42"
}

@test "paw issue-review: uses PAW_MODEL when overridden" {
  PAW_GH_ISSUE_VIEW_CMD=echo PAW_MODEL=opus run "$PAW" issue-review 42
  [ "$status" -eq 0 ]
  args_contain "opus"
}

@test "paw issue-review: prompt references issue.md path" {
  PAW_GH_ISSUE_VIEW_CMD=echo run "$PAW" issue-review 42
  [ "$status" -eq 0 ]
  prompt_contains "42-issue-review/issue.md"
}

# ── paw plan ──────────────────────────────────────────────────────────────────

@test "paw plan: prompt contains PAW:PLAN anchor" {
  run "$PAW" plan my-new-task "add logging to the auth module"
  [ "$status" -eq 0 ]
  prompt_contains "PAW:PLAN"
}

@test "paw plan: prompt contains task name" {
  run "$PAW" plan my-new-task "add logging to the auth module"
  [ "$status" -eq 0 ]
  prompt_contains "my-new-task"
}

@test "paw plan: prompt contains user prompt verbatim" {
  run "$PAW" plan my-new-task "add real-time search to the dashboard"
  [ "$status" -eq 0 ]
  prompt_contains "add real-time search to the dashboard"
}

@test "paw plan: uses PAW_MODEL when set to opus" {
  PAW_MODEL=opus run "$PAW" plan my-new-task "some task description"
  [ "$status" -eq 0 ]
  args_contain "opus"
}

@test "paw plan: default model is sonnet when PAW_MODEL is unset" {
  unset PAW_MODEL
  run "$PAW" plan my-new-task "some task description"
  [ "$status" -eq 0 ]
  args_contain "sonnet"
}

@test "paw plan: seeds template files before invoking backend" {
  run "$PAW" plan seeded-task "some task description"
  [ "$status" -eq 0 ]
  local matches=("$PAW_TASK_HOME"/*/seeded-task/contract.md)
  [ -f "${matches[0]}" ]
  matches=("$PAW_TASK_HOME"/*/seeded-task/plan.md)
  [ -f "${matches[0]}" ]
}

@test "paw plan: seeds branch PR body when the repo has a PR template" {
  mkdir -p "$REPO/.github"
  touch "$REPO/.github/pull_request_template.md"
  init_git_repo
  git -C "$REPO" checkout -q -b feature/seeded-pr

  run "$PAW" plan seeded-task-with-pr "some task description"

  [ "$status" -eq 0 ]
  local matches=("$PAW_TASK_HOME"/*/feature-seeded-pr-pr.md)
  [ -f "${matches[0]}" ]
  local task_matches=("$PAW_TASK_HOME"/*/seeded-task-with-pr/pr.md)
  [ ! -e "${task_matches[0]}" ]
  prompt_contains "feature-seeded-pr-pr.md"
  ! grep -qF "Branch PR body is not used for this task" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw plan: does not overwrite existing files during seeding" {
  mkdir -p "$REPO/.agent/existing-task"
  echo "# My existing contract" > "$REPO/.agent/existing-task/contract.md"
  run "$PAW" plan existing-task "some task description"
  [ "$status" -eq 0 ]
  grep -qF "My existing contract" "$REPO/.agent/existing-task/contract.md"
}

@test "paw plan: prompt mentions seeded files" {
  run "$PAW" plan seeded-prompt-task "some task description"
  [ "$status" -eq 0 ]
  prompt_contains "already been seeded"
}

@test "paw plan: exits 2 when no task name given" {
  run "$PAW" plan
  assert_exits_2
}

@test "paw plan: exits 2 when prompt argument is missing" {
  run "$PAW" plan my-task
  assert_exits_2
}

@test "paw plan: exits 2 when --brief flag used (removed)" {
  run "$PAW" plan my-task --brief "some text"
  assert_exits_2
}

@test "paw plan: exits 2 when --from-file flag used (removed)" {
  run "$PAW" plan my-task --from-file /dev/null
  assert_exits_2
}

@test "paw plan: ignores context.md contents even when file present" {
  printf '<!-- paw-context-commit: abc123 2026-01-01 -->\nThis is cached repo context.\n' \
    > "$REPO/.agent/context.md"
  run "$PAW" plan ctx-task "do something"
  [ "$status" -eq 0 ]
  ! grep -qF "Repo context (from .agent/context.md):" "$BATS_TEST_TMPDIR/backend.prompt"
  ! grep -qF "This is cached repo context." "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw plan: no context block label when context.md absent" {
  run "$PAW" plan no-ctx-task "do something"
  [ "$status" -eq 0 ]
  ! grep -qF "Repo context (from .agent/context.md):" "$BATS_TEST_TMPDIR/backend.prompt"
  prompt_contains "No .agent/context.md input is used during planning"
}

@test "paw plan: rejects --multi-plan" {
  run "$PAW" plan --multi-plan parent-plan "split this feature into child tasks"
  assert_exits_2
  [[ "$output" == *"--multi-plan has been removed"* ]]
  [ ! -d "$REPO/.agent/parent-plan" ]
}

@test "paw plan: rejects --child without multi-plan support" {
  run "$PAW" plan parent-plan "split this feature into child tasks" --child child-one
  assert_exits_2
  [[ "$output" == *"--child is only valid with the removed --multi-plan flow"* ]]
  [ ! -d "$REPO/.agent/parent-plan" ]
}

@test "paw plan: prompt references a single seeded task package" {
  run "$PAW" plan single-plan "some task description"
  [ "$status" -eq 0 ]
  prompt_contains "create a new plan-only task package in"
  prompt_contains "single-plan/contract.md"
  prompt_contains "single-plan/plan.md"
  ! grep -qF "Child task package:" "$BATS_TEST_TMPDIR/backend.prompt"
}

# ── paw plan --dry-run ────────────────────────────────────────────────────────

@test "paw plan --dry-run: prints prompt body to stdout and exits 0" {
  run "$PAW" plan dry-task "test dry-run output" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"test dry-run output"* ]]
  [[ "$output" == *"PAW:PLAN"* ]]
}

@test "paw plan --dry-run: does not invoke backend" {
  run "$PAW" plan dry-no-backend-task "some description" --dry-run
  [ "$status" -eq 0 ]
  # stub backend writes backend.args only when invoked; file absent means no backend call
  [ ! -f "$BATS_TEST_TMPDIR/backend.args" ]
}

@test "paw plan --dry-run: still rejects removed --multi-plan mode" {
  run "$PAW" plan --multi-plan dry-parent "split this feature into child tasks" --dry-run
  assert_exits_2
  [[ "$output" == *"--multi-plan has been removed"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/backend.args" ]
}

# ── PAW_STREAM=1 ─────────────────────────────────────────────────────────────

@test "PAW_STREAM=1 paw implement: backend_run_stream is invoked" {
  make_task stream-task
  PAW_STREAM=1 run "$PAW" implement stream-task
  [ "$status" -eq 0 ]
  mode_is "stream"
}

@test "PAW_STREAM=0 paw implement: backend_run_capture is invoked" {
  make_task stream-task
  PAW_STREAM=0 run "$PAW" implement stream-task
  [ "$status" -eq 0 ]
  mode_is "capture"
}

@test "PAW_STREAM=1 paw diagnose: backend_run_stream is invoked" {
  make_task stream-diagnose-task
  PAW_STREAM=1 run "$PAW" diagnose stream-diagnose-task
  [ "$status" -eq 0 ]
  mode_is "stream"
}

@test "PAW_STREAM=1 paw edit: backend_run_stream is invoked" {
  make_task stream-edit-task
  PAW_STREAM=1 run "$PAW" edit stream-edit-task
  [ "$status" -eq 0 ]
  mode_is "stream"
}

@test "PAW_STREAM=1 paw teach: backend_run_stream is invoked" {
  PAW_STREAM=1 run "$PAW" teach
  [ "$status" -eq 0 ]
  mode_is "stream"
}

# ── Guard: real claude never invoked ─────────────────────────────────────────

@test "guard: claude binary not required when PAW_BACKEND=stub" {
  make_task guard-task
  # PATH contains only $EMPTY_BIN (no claude). PAW_BACKEND=stub is set by setup.
  run "$PAW" implement guard-task
  [ "$status" -eq 0 ]
}

@test "guard: paw edit works without claude on PATH when PAW_BACKEND=stub" {
  make_task guard-task
  run "$PAW" edit guard-task
  [ "$status" -eq 0 ]
}

@test "guard: paw diagnose works without claude on PATH when PAW_BACKEND=stub" {
  make_task guard-diagnose-task
  run "$PAW" diagnose guard-diagnose-task
  [ "$status" -eq 0 ]
}

@test "guard: paw tighten works without claude on PATH when PAW_BACKEND=stub" {
  make_task guard-tighten-task
  run "$PAW" tighten guard-tighten-task
  [ "$status" -eq 0 ]
}

# ── Launch banner assertions ─────────────────────────────────────────────────

@test "paw implement: stderr contains launch banner with backend and model" {
  make_task banner-implement
  run "$PAW" implement banner-implement
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw implement"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=sonnet"* ]]
}

@test "paw diagnose: stderr contains launch banner with backend and model" {
  make_task banner-diagnose
  run "$PAW" diagnose banner-diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw diagnose"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=sonnet"* ]]
}

@test "paw edit: stderr contains launch banner with backend and model" {
  make_task banner-edit
  run "$PAW" edit banner-edit
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw edit"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=sonnet"* ]]
}

@test "paw tighten: stderr contains launch banner with backend and model" {
  make_task banner-tighten
  run "$PAW" tighten banner-tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw tighten"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=sonnet"* ]]
}

@test "paw pr-address-comments: stderr contains launch banner with backend and model" {
  PAW_GH_COMMENTS_CMD=echo PAW_MODEL=opus run "$PAW" pr-address-comments 99
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw pr-address-comments"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=opus"* ]]
}

@test "paw plan: stderr contains launch banner with backend and model" {
  PAW_MODEL=opus run "$PAW" plan banner-plan-task "some task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw plan"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=opus"* ]]
}

@test "paw teach: stderr contains launch banner with backend and model" {
  PAW_MODEL=opus run "$PAW" teach
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching: paw teach"* ]]
  [[ "$output" == *"PAW_BACKEND=stub"* ]]
  [[ "$output" == *"model=opus"* ]]
}
