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
  [ "$status" -eq 1 ] # Stub leaves the review pending; routing still captured.
  prompt_contains "PAW:IMPLEMENT"
  prompt_contains 'This is a `paw review` run'
  prompt_contains "Assign a clear grade"
  prompt_contains "overall workflow or subsystem state"
  prompt_contains "quality threshold"
  prompt_contains "architectural and design choices"
  prompt_contains "prototype cleanup is production-ready"
  prompt_contains "- Grade: B+"
  prompt_contains "no Markdown wrappers or terminal punctuation"
  prompt_contains "concrete recommendations"
}

@test "paw review: seeds review.md for durable grade and recommendations" {
  make_task review-task
  run "$PAW" review review-task
  [ "$status" -eq 1 ] # Stub leaves the review pending; routing still captured.
  [ -f "$REPO/.agent/review-task/review.md" ]
  grep -q "Scope Reviewed" "$REPO/.agent/review-task/review.md"
  grep -q "Overall Workflow / Subsystem Grade" "$REPO/.agent/review-task/review.md"
  grep -q "Prototype Cleanup Production-Ready" "$REPO/.agent/review-task/review.md"
  grep -q "## Architectural / Design Choices" "$REPO/.agent/review-task/review.md"
  grep -q "## Blocking Production-Readiness Issues" "$REPO/.agent/review-task/review.md"
  grep -q "## Recommendations" "$REPO/.agent/review-task/review.md"
}

@test "paw review: supports overall workflow grading when requested" {
  make_task review-task
  run "$PAW" review review-task "Rate the overall state of paw review and paw prototype, not just this task delta."
  [ "$status" -eq 1 ] # Stub leaves the review pending; routing still captured.
  prompt_contains "grade the current overall workflow or subsystem state"
  prompt_contains 'overall current state of `paw review` and `paw prototype`'
  prompt_contains "Human extras:"
  prompt_contains "Rate the overall state of paw review and paw prototype"
}

@test "paw review: appends Human extras when extra arg given" {
  make_task review-task
  run "$PAW" review review-task "Threshold is B+."
  [ "$status" -eq 1 ] # Stub leaves the review pending; routing still captured.
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
  complete_review "$REPO/.agent/proto-task/review.md" proto-task
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  prompt_contains "PAW:PLAN"
  prompt_contains "proto-task/review.md"
  prompt_contains "source task being treated as the prototype"
  prompt_contains "post-implementation Review requirement"
  prompt_contains "replacement plan-only task package"
}

@test "paw prototype: seeds replacement plan package and records prototype metadata" {
  init_git_repo
  mkdir -p "$REPO/.github"
  touch "$REPO/.github/pull_request_template.md"
  make_task proto-task
  complete_review "$REPO/.agent/proto-task/review.md" proto-task
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  local matches=("$PAW_TASK_HOME"/*/proto-task-prototype/plan.md)
  [ -f "${matches[0]}" ]
  local metadata="${matches[0]%/plan.md}/metadata.gitconfig"
  [ "$(git config --file "$metadata" --get paw.prototype-source)" = "proto-task" ]
  [[ "$(git config --file "$metadata" --get paw.prototype-status)" == planned* ]]
  local bodies=("$PAW_TASK_HOME"/*/v2-*-pr.md)
  [ -f "${bodies[0]}" ]
  prompt_contains "${bodies[0]}"
  [ ! -f "${matches[0]%/plan.md}/pr.md" ]
}

# Exercise production capture with a known clean pre-run snapshot for edge fixtures.
capture_fixture_provenance() {
  : > "$BATS_TEST_TMPDIR/before-paths"
  bash -c 'source "$1"; _implement_record_prototype_provenance proto-task "$2" "$3"' \
    _ "$PAW" "$source_dir" "$BATS_TEST_TMPDIR/before-paths"
}

# Capture real implementation provenance before introducing unrelated work.
capture_prototype_source() {
  init_git_repo
  run "$PAW" plan proto-task "Plan source work."
  [ "$status" -eq 0 ]
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$source_dir/plan.md"
  run env PAW_STUB_MUTATE_FILE="$REPO/README.md" "$PAW" implement proto-task
  [ "$status" -eq 0 ]
  complete_review "$source_dir/review.md" proto-task
}

@test "paw prototype: preserves later same-path edits after provenance capture" {
  capture_prototype_source
  printf 'later unrelated edit\n' >> "$REPO/README.md"
  cp "$REPO/README.md" "$BATS_TEST_TMPDIR/expected"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  cmp "$REPO/README.md" "$BATS_TEST_TMPDIR/expected"
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = "revert-blocked" ]
  [ -f "${source_dir}-prototype/plan.md" ]
}

@test "paw prototype: preserves staged divergence hidden by baseline worktree bytes" {
  capture_prototype_source
  git -C "$REPO" add README.md
  git -C "$REPO" show HEAD:README.md > "$REPO/README.md"
  git -C "$REPO" diff --cached --binary > "$BATS_TEST_TMPDIR/index-before"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = "revert-blocked" ]
  git -C "$REPO" diff --cached --binary > "$BATS_TEST_TMPDIR/index-after"
  cmp "$BATS_TEST_TMPDIR/index-before" "$BATS_TEST_TMPDIR/index-after"
  [ "$(cat "$REPO/README.md")" = base ]
  [ -f "${source_dir}-prototype/plan.md" ]
}

@test "paw prototype: blocks cleanup when tracked changes include unowned paths" {
  init_git_repo
  printf 'notes base\n' > "$REPO/NOTES.md"
  git -C "$REPO" add NOTES.md
  git -C "$REPO" commit -q -m "add notes"

  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  git config --file "$source_dir/metadata.gitconfig" --add paw.prototype-owned-path README.md
  printf 'changed\n' > "$REPO/README.md"
  capture_fixture_provenance
  printf 'unrelated change\n' > "$REPO/NOTES.md"

  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = "changed" ]
  [ "$(cat "$REPO/NOTES.md")" = "unrelated change" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ -d "$replacement_dir" ]
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-revert-blocked" ]
  [[ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-cleanup-message)" == *"unowned tracked changes"* ]]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = "revert-blocked" ]
}

@test "paw prototype: reverts only proven task-owned tracked source work after planning" {
  init_git_repo
  printf 'notes base\n' > "$REPO/NOTES.md"
  git -C "$REPO" add NOTES.md
  git -C "$REPO" commit -q -m "add notes"

  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  git config --file "$source_dir/metadata.gitconfig" --add paw.prototype-owned-path README.md
  printf 'changed\n' > "$REPO/README.md"

  capture_fixture_provenance
  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = "base" ]
  [ "$(cat "$REPO/NOTES.md")" = "notes base" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-source-reverted" ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = "source-reverted" ]
}

@test "paw prototype: keeps replacement plan when cleanup provenance is missing" {
  init_git_repo

  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  printf 'changed\n' > "$REPO/README.md"

  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = "changed" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ -f "$replacement_dir/plan.md" ]
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-revert-blocked" ]
  [[ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-cleanup-message)" == *"missing immutable provenance"* ]]
  [[ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-cleanup-message)" == *"missing immutable provenance"* ]]
}

@test "paw prototype: blocks cleanup for invalid provenance paths" {
  init_git_repo

  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  git config --file "$source_dir/metadata.gitconfig" --add paw.prototype-owned-path ../README.md
  printf 'changed\n' > "$REPO/README.md"

  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = "changed" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-revert-blocked" ]
  [[ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-cleanup-message)" == *"missing immutable provenance"* ]]
}

@test "paw prototype: blocks cleanup when untracked non-agent files are present" {
  init_git_repo

  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  git config --file "$source_dir/metadata.gitconfig" --add paw.prototype-owned-path README.md
  printf 'changed\n' > "$REPO/README.md"
  capture_fixture_provenance
  printf 'scratch\n' > "$REPO/SCRATCH.md"

  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = "changed" ]
  [ -f "$REPO/SCRATCH.md" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-revert-blocked" ]
  [[ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-cleanup-message)" == *"untracked non-.agent"* ]]
}

@test "paw prototype: reverts owned paths with spaces and deletions exactly" {
  init_git_repo
  printf 'space base\n' > "$REPO/file with spaces.md"
  printf 'remove me\n' > "$REPO/delete-me.md"
  printf 'keep me\n' > "$REPO/keep.md"
  git -C "$REPO" add "file with spaces.md" delete-me.md keep.md
  git -C "$REPO" commit -q -m "add edge files"

  run "$PAW" plan proto-task "Plan the source work."
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task" -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  git config --file "$source_dir/metadata.gitconfig" --add paw.prototype-owned-path "file with spaces.md"
  git config --file "$source_dir/metadata.gitconfig" --add paw.prototype-owned-path delete-me.md
  printf 'space changed\n' > "$REPO/file with spaces.md"
  rm "$REPO/delete-me.md"
  capture_fixture_provenance

  run "$PAW" prototype proto-task

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/file with spaces.md")" = "space base" ]
  [ "$(cat "$REPO/delete-me.md")" = "remove me" ]
  [ "$(cat "$REPO/keep.md")" = "keep me" ]
  local replacement_dir
  replacement_dir=$(find "$PAW_TASK_HOME" -path "*/proto-task-prototype" -type d -print -quit)
  [ "$(git config --file "$replacement_dir/metadata.gitconfig" --get paw.prototype-status)" = "planned-source-reverted" ]
}

@test "paw prototype: round trips literal unusual paths binary bytes and executable modes" {
  init_git_repo
  local paths=('é.md' ':(glob)*.md' $'tab\tname' 'quote"name' 'back\slash') path
  for path in "${paths[@]}"; do printf 'base\0bytes\n' > "$REPO/$path"; done
  git --literal-pathspecs -C "$REPO" add -- "${paths[@]}"
  git -C "$REPO" commit -qm 'edge files'
  run "$PAW" plan proto-task source
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path '*/proto-task' -type d -print -quit)
  complete_review "$source_dir/review.md" proto-task
  for path in "${paths[@]}"; do printf 'task\0bytes\n' > "$REPO/$path"; done
  chmod +x "$REPO/é.md"
  capture_fixture_provenance
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = source-reverted ]
  git -C "$REPO" diff --exit-code HEAD
  [ ! -x "$REPO/é.md" ]
}

@test "paw prototype: legacy path-only provenance cannot authorize cleanup" {
  capture_prototype_source
  git config --file "$source_dir/metadata.gitconfig" --unset paw.prototype-provenance-status
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = implemented ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = revert-blocked ]
}

@test "paw prototype: tampered immutable patch blocks cleanup" {
  capture_prototype_source
  printf 'tampered\n' >> "$source_dir/prototype.patch"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = implemented ]
  [[ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-cleanup-message)" == *checksum* ]]
}

@test "paw prototype: unavailable saved commit preserves replacement and source" {
  capture_prototype_source
  git config --file "$source_dir/metadata.gitconfig" paw.head-sha 0000000000000000000000000000000000000000
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = implemented ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = revert-unavailable ]
  [ -f "${source_dir}-prototype/plan.md" ]
}

@test "paw prototype: later mode drift blocks even when core.filemode is false" {
  capture_prototype_source
  git -C "$REPO" config core.filemode false
  chmod +x "$REPO/README.md"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = implemented ]
  [ -x "$REPO/README.md" ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-status)" = revert-blocked ]
}

@test "paw implement: does not reuse old evidence on resume" {
  capture_prototype_source
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$source_dir/plan.md"
  run "$PAW" implement proto-task
  [ "$status" -eq 0 ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = no-owned-paths ]
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/README.md")" = implemented ]
}

@test "paw implement: blocks provenance on unsafe newline path encoding" {
  init_git_repo
  local path=$'line\nbreak'
  printf 'base\n' > "$REPO/$path"
  git -C "$REPO" add -- "$path"
  git -C "$REPO" commit -qm newline
  run "$PAW" plan proto-task source
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path '*/proto-task' -type d -print -quit)
  printf 'changed\n' > "$REPO/$path"
  capture_fixture_provenance
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = blocked ]
}

@test "paw implement: Git enumeration failures invalidate provenance" {
  capture_prototype_source
  : > "$BATS_TEST_TMPDIR/before-paths"
  run bash -c '
    source "$1"
    git() { if [[ " $* " == *" ls-files "* ]]; then return 1; fi; command git "$@"; }
    _implement_record_prototype_provenance proto-task "$2" "$3"
  ' _ "$PAW" "$source_dir" "$BATS_TEST_TMPDIR/before-paths"
  [ "$status" -eq 0 ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = unavailable ]
  [[ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-message)" == *enumeration* ]]
}

@test "paw prototype: metadata write failure prevents source mutation" {
  capture_prototype_source
  run bash -c '
    source "$1"
    git() { if [[ " $* " == *" paw.prototype-status "* ]]; then return 1; fi; command git "$@"; }
    _prototype_revert_source_work proto-task "$2" "$2"
  ' _ "$PAW" "$source_dir"
  [ "$(cat "$REPO/README.md")" = implemented ]
  [[ "$output" == *"cannot write"* ]]
}

@test "paw implement: blocks deleted paths when checkout normalization is enabled" {
  capture_prototype_source
  git -C "$REPO" config core.autocrlf true
  rm "$REPO/README.md"
  capture_fixture_provenance
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = blocked ]
}

@test "paw implement: pre-existing staged rename excludes both source and destination" {
  init_git_repo
  run "$PAW" plan proto-task source
  [ "$status" -eq 0 ]
  local source_dir
  source_dir=$(find "$PAW_TASK_HOME" -path '*/proto-task' -type d -print -quit)
  git -C "$REPO" mv README.md renamed.md
  run bash -c '
    source "$1"
    _implement_tracked_paths_from_saved_head "$2" "$3"
    git -C "$4" reset -q HEAD -- README.md renamed.md
    rm "$4/renamed.md"
    printf "task result\n" > "$4/README.md"
    _implement_record_prototype_provenance proto-task "$2" "$3"
  ' _ "$PAW" "$source_dir" "$BATS_TEST_TMPDIR/before-paths" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = no-owned-paths ]
}

@test "paw implement: final provenance message write failure leaves no cleanup authority" {
  capture_prototype_source
  : > "$BATS_TEST_TMPDIR/before-paths"
  run bash -c '
    source "$1"
    git() {
      if [[ " $* " == *" paw.prototype-provenance-message "* && " $* " != *" --unset-all "* ]]; then return 1; fi
      command git "$@"
    }
    _implement_record_prototype_provenance proto-task "$2" "$3"
  ' _ "$PAW" "$source_dir" "$BATS_TEST_TMPDIR/before-paths"
  [ "$status" -eq 0 ]
  [ "$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = unavailable ]
  [ ! -f "$source_dir/prototype.patch" ]
  [[ "$output" == *"cannot record"* ]]
}

@test "paw prototype: uses plan-class model defaults when PAW_MODEL is unset" {
  make_task proto-task
  complete_review "$REPO/.agent/proto-task/review.md" proto-task
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  args_contain "sonnet"
}

@test "paw prototype: appends Human extras when extra arg given" {
  make_task proto-task
  complete_review "$REPO/.agent/proto-task/review.md" proto-task
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
  prompt_contains "Run the named full local validation command after the final implementation change"
  prompt_contains "record 100% and"
}

@test "paw implement: records prototype ownership for tracked paths changed during implementation" {
  init_git_repo
  printf 'notes base\n' > "$REPO/NOTES.md"
  git -C "$REPO" add NOTES.md
  git -C "$REPO" commit -q -m "add notes"

  run "$PAW" plan owned-task "Plan the implementation."
  [ "$status" -eq 0 ]
  local task_dir
  task_dir=$(find "$PAW_TASK_HOME" -path "*/owned-task" -type d -print -quit)
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"

  printf 'pre-existing unrelated\n' > "$REPO/NOTES.md"
  mkdir -p "$REPO/.agent/local-task"
  printf '# Local task note\n' > "$REPO/.agent/local-task/plan.md"

  run env PAW_STUB_MUTATE_FILE="$REPO/README.md" "$PAW" implement owned-task

  [ "$status" -eq 0 ]
  [ "$(git config --file "$task_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = "recorded" ]
  [ -s "$task_dir/prototype.patch" ]
  [ "$(git hash-object "$task_dir/prototype.patch")" = "$(git config --file "$task_dir/metadata.gitconfig" --get paw.prototype-patch-hash)" ]
  [ "$(git config --file "$task_dir/metadata.gitconfig" --get-all paw.prototype-owned-path)" = "README.md" ]
  ! git config --file "$task_dir/metadata.gitconfig" --get-all paw.prototype-owned-path | grep -Fx "NOTES.md"
  ! git config --file "$task_dir/metadata.gitconfig" --get-all paw.prototype-owned-path | grep -Fx ".agent/local-task/plan.md"
}

@test "paw implement: excludes pre-existing staged work hidden by the worktree diff" {
  init_git_repo
  run "$PAW" plan owned-task "Plan the implementation."
  [ "$status" -eq 0 ]
  local task_dir
  task_dir=$(find "$PAW_TASK_HOME" -path "*/owned-task" -type d -print -quit)
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  printf 'unrelated staged work\n' > "$REPO/README.md"
  git -C "$REPO" add README.md
  printf 'base\n' > "$REPO/README.md"

  run env PAW_STUB_MUTATE_FILE="$REPO/README.md" "$PAW" implement owned-task

  [ "$status" -eq 0 ]
  [ "$(git config --file "$task_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = "no-owned-paths" ]
  ! git config --file "$task_dir/metadata.gitconfig" --get-all paw.prototype-owned-path
  [ "$(git -C "$REPO" show :README.md)" = "unrelated staged work" ]
}

@test "paw implement: records unavailable provenance without a saved baseline" {
  make_task legacy-task

  run "$PAW" implement legacy-task

  [ "$status" -eq 0 ]
  local metadata="$REPO/.agent/legacy-task/metadata.gitconfig"
  [ "$(git config --file "$metadata" --get paw.prototype-provenance-status)" = "unavailable" ]
  [[ "$(git config --file "$metadata" --get paw.prototype-provenance-message)" == *"no saved worktree-path"* ]]
  ! git config --file "$metadata" --get-all paw.prototype-owned-path
}

@test "paw implement: blocks provenance when untracked work makes ownership ambiguous" {
  init_git_repo
  run "$PAW" plan owned-task "Plan the implementation."
  [ "$status" -eq 0 ]
  local task_dir
  task_dir=$(find "$PAW_TASK_HOME" -path "*/owned-task" -type d -print -quit)
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  printf 'scratch\n' > "$REPO/scratch.md"

  run env PAW_STUB_MUTATE_FILE="$REPO/README.md" "$PAW" implement owned-task

  [ "$status" -eq 0 ]
  [ "$(git config --file "$task_dir/metadata.gitconfig" --get paw.prototype-provenance-status)" = "blocked" ]
  [[ "$(git config --file "$task_dir/metadata.gitconfig" --get paw.prototype-provenance-message)" == *"scratch.md"* ]]
  ! git config --file "$task_dir/metadata.gitconfig" --get-all paw.prototype-owned-path
  [ "$(cat "$REPO/scratch.md")" = "scratch" ]
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
  prompt_contains "Run the named full local validation command after the final implementation change"
  prompt_contains "record 100% and"
  prompt_contains "including batch, GUI, and docs-only runs"
  prompt_contains "missing tools or failed checks block completion"
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
  local matches=("$PAW_TASK_HOME"/*/v2-feature-seeded-pr-*-pr.md)
  [ -f "${matches[0]}" ]
  local task_matches=("$PAW_TASK_HOME"/*/seeded-task-with-pr/pr.md)
  [ ! -e "${task_matches[0]}" ]
  prompt_contains "${matches[0]}"
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

@test "paw prototype: failed planning preserves source and links reusable replacement" {
  capture_prototype_source
  run bash -c '
    source "$1"
    _run_model_subcommand() { return 7; }
    cmd_prototype proto-task
  ' _ "$PAW"
  [ "$status" -eq 7 ]
  [ "$(cat "$REPO/README.md")" = implemented ]
  local replacement
  replacement="$(git config --file "$source_dir/metadata.gitconfig" --get paw.prototype-replacement)"
  [ -f "$replacement/plan.md" ]
  [ "$(git config --file "$replacement/metadata.gitconfig" --get paw.prototype-status)" = planning-failed ]
  printf '\nKeep these notes.\n' >> "$replacement/contract.md"
  run "$PAW" prototype proto-task
  [ "$status" -eq 0 ]
  grep -q 'Keep these notes.' "$replacement/contract.md"
  [ "$(git config --file "$replacement/metadata.gitconfig" --get paw.prototype-status)" = planned-source-reverted ]
  run "$PAW" archive proto-task
  [ "$status" -eq 0 ]
  [ -f "$replacement/plan.md" ]
  [ ! -d "$source_dir" ]
}

@test "quality policy: new plan seeds measurable independent Review contract (routing evidence)" {
  init_git_repo
  run "$PAW" plan quality-task "Quality fixture"
  [ "$status" -eq 0 ]
  local plan
  plan=$(find "$PAW_TASK_HOME" -path '*/quality-task/plan.md' -print -quit)
  grep -qF 'Quality policy version: 1' "$plan"
  grep -qF '## Acceptance Evidence' "$plan"
  grep -qF '## Post-Implementation Review Requirement' "$plan"
  grep -qF 'A- or higher' "$plan"
}

@test "quality policy: implement and diagnose route bounded risk self-checks" {
  make_task quality
  for command in implement diagnose; do
    run "$PAW" "$command" quality
    [ "$status" -eq 0 ]
    prompt_contains 'bounded self-check'
    prompt_contains 'counterexample'
    prompt_contains 'Acceptance Evidence'
  done
}

@test "review completeness: heading-only prototype refuses before seeding" {
  make_task pending-review
  printf '# Review\n' > "$REPO/.agent/pending-review/review.md"
  run "$PAW" prototype pending-review
  [ "$status" -ne 0 ]
  [[ "$output" == *'Run Review'* ]]
  [ ! -e "$REPO/.agent/pending-review-prototype" ]
  [ ! -e "$BATS_TEST_TMPDIR/backend.prompt" ]
}

complete_review() {
  cat > "$1" <<EOF_REVIEW
## Review Metadata
- Task: $2
- Scope Reviewed: task delta
- Grade: B+
- Quality Threshold: B+ / no blockers
- Threshold Result: met

## Blocking Production-Readiness Issues
- None.

## Recommendations
- Preserve the tested behavior.
EOF_REVIEW
}

@test "quality lifecycle: plan handoff pending refusal archived ancestry and preserved rereview" {
  init_git_repo
  run "$PAW" plan lifecycle "Preserve immutable bytes and structural parser invariants."
  [ "$status" -eq 0 ]
  local task_dir replacement archive_dir
  task_dir=$(find "$PAW_TASK_HOME" -path '*/lifecycle/plan.md' -print -quit)
  task_dir="${task_dir%/plan.md}"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$task_dir/plan.md"
  run "$PAW" implement lifecycle
  [ "$status" -eq 0 ]
  run "$PAW" review lifecycle
  [ "$status" -eq 1 ]
  run "$PAW" prototype lifecycle
  [ "$status" -eq 1 ]
  [ ! -d "${task_dir}-prototype" ]

  # A hermetic reviewer resolves the seed, preserving attempt identity.
  export FIXTURE_REVIEW_DIR="$task_dir"
  cat > "$EMPTY_BIN/paw-backend-review-fixture" <<'PLUGIN'
#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1] in ('run-capture', 'run-stream'):
    path = Path(os.environ['FIXTURE_REVIEW_DIR']) / 'review.md'
    text = path.read_text().replace('- Scope Reviewed: pending', '- Scope Reviewed: fixture delta').replace('- Grade: pending', '- Grade: C').replace('- Quality Threshold: pending', '- Quality Threshold: A- / no blockers').replace('- Threshold Result: pending', '- Threshold Result: below threshold').replace('- Completion: pending', '- Completion: complete').replace('- Pending.', '- Preserve immutable bytes and structural parser invariants.')
    path.write_text(text)
    Path(sys.argv[2]).write_text('{"result":"fixture"}')
elif sys.argv[1] in ('parse-tokens', 'parse-stream-tokens'):
    print('0')
PLUGIN
  chmod +x "$EMPTY_BIN/paw-backend-review-fixture"
  PAW_BACKEND=review-fixture run "$PAW" review lifecycle
  [ "$status" -eq 0 ]
  cp "$task_dir/review.md" "$BATS_TEST_TMPDIR/completed-review"
  run "$PAW" prototype lifecycle
  [ "$status" -eq 0 ]
  replacement="${task_dir}-prototype"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$replacement/plan.md"
  complete_review "$replacement/review.md" lifecycle-prototype
  run "$PAW" archive lifecycle
  [ "$status" -eq 0 ]
  archive_dir="${task_dir%/*}/.archive/lifecycle"
  run "$PAW" prototype lifecycle-prototype
  [ "$status" -eq 0 ]
  prompt_contains "$archive_dir/review.md"
  prompt_contains 'immutable bytes and structural parser invariants'
  prompt_contains 'finding → invariant → acceptance/test'
  prompt_contains 'already-resolved-with-evidence'
  # Legacy source history remains byte-identical through archive and planning.
  cmp "$BATS_TEST_TMPDIR/completed-review" "$archive_dir/review.md"
  export FIXTURE_REVIEW_DIR="$replacement"
  PAW_BACKEND=review-fixture run "$PAW" review lifecycle-prototype
  [ "$status" -eq 0 ]
  [ -d "$replacement/review-history" ]
}
