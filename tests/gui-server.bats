#!/usr/bin/env bats
# Tests for the local PAW GUI server.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PAW="$REPO_ROOT/scripts/paw"

setup() {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export PAW_HOME="$REPO_ROOT"
  export PAW_BACKEND=stub
  export PAW_TASK_HOME="$BATS_TEST_TMPDIR/paw-state/tasks"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent/gui-task"
  cat > "$REPO/.agent/gui-task/plan.md" <<'MD'
# Plan

## Implementation Phases / Checklist
- [x] Done.
  Progress: Finished.
- [ ] Next.

## Current Status

- Plan position: GUI smoke.
- Estimated completion: 50%
- Next work: Keep testing.

## Validation Performed
- OK.
MD
}

teardown() {
  stop_gui
  if [[ -n "${GUI_COMPANION_PID:-}" ]]; then
    GUI_PID="$GUI_COMPANION_PID"
    stop_gui
  fi
  if [[ -f "$XDG_STATE_HOME/paw/gui/active.gitconfig" ]]; then
    "$PAW" gui kill >/dev/null 2>&1 || true
  fi
  if [[ -n "${SLEEPER_PID:-}" ]]; then
    kill "$SLEEPER_PID" 2>/dev/null || true
    wait "$SLEEPER_PID" 2>/dev/null || true
  fi
}

start_gui() {
  shift # Callers receive the OS-assigned port through Bash's dynamically scoped port.
  "$PAW" gui --repo "$REPO" --port 0 "$@" > "$BATS_TEST_TMPDIR/gui.out" 2> "$BATS_TEST_TMPDIR/gui.err" &
  GUI_PID="$!"
  for _ in {1..100}; do
    port="$(sed -n 's|^paw gui: http://127.0.0.1:\([0-9]*\)/$|\1|p' "$BATS_TEST_TMPDIR/gui.out")"
    [[ -n "$port" ]] && return 0
    kill -0 "$GUI_PID" 2>/dev/null || break
    sleep 0.1
  done
  cat "$BATS_TEST_TMPDIR/gui.err" >&2
  return 1
}

stop_gui() {
  if [[ -n "${GUI_PID:-}" ]]; then
    pkill -P "$GUI_PID" 2>/dev/null || true
    kill "$GUI_PID" 2>/dev/null || true
    wait "$GUI_PID" 2>/dev/null || true
    GUI_PID=""
  fi
}

fetch_gui() {
  local port="$1" path="${2:-/}" out="$3"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 - "$port" "$path" > "$out" <<'PY'
import sys
from urllib.request import urlopen
print(urlopen(f"http://127.0.0.1:{sys.argv[1]}{sys.argv[2]}", timeout=1).read().decode())
PY
    then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

url_encode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

real_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).resolve())
PY
}

form_encode() {
  python3 - "$@" <<'PY'
import sys
from urllib.parse import urlencode
pairs = [tuple(arg.split("=", 1)) for arg in sys.argv[1:]]
print(urlencode(pairs))
PY
}

wait_for_file() {
  local file="$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$file" ]] && return 0
    sleep 0.2
  done
  return 1
}

wait_for_run_metadata() {
  local task_name="$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    find "$REPO/.agent/$task_name/runs" -name "*.gitconfig" -print -quit 2>/dev/null | grep -q . && return 0
    sleep 0.2
  done
  return 1
}

init_repo_with_commit() {
  git -C "$REPO" init -q
  git -C "$REPO" config user.email "test@example.test"
  git -C "$REPO" config user.name "PAW Test"
  touch "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm "initial"
}

start_paw_like_sleeper() {
  bash -c 'exec -a paw-test sleep 60' &
  SLEEPER_PID="$!"
}

post_gui() {
  local port="$1" path="$2" data="$3" out="$4"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 - "$port" "$path" "$data" > "$out" <<'PY'
import sys
from urllib.request import Request, urlopen
data = sys.argv[3].encode()
req = Request(
    f"http://127.0.0.1:{sys.argv[1]}{sys.argv[2]}",
    data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    method="POST",
)
response = urlopen(req, timeout=3)
print(response.geturl())
print(response.read().decode())
PY
    then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

@test "paw gui: serves local dashboard with legacy task details" {
  local port=18765
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/page.html"
  stop_gui

  grep -q "gui-task" "$BATS_TEST_TMPDIR/page.html"
  grep -q "Stage: Implement" "$BATS_TEST_TMPDIR/page.html"
  grep -q "1/2" "$BATS_TEST_TMPDIR/page.html"
}

@test "paw gui: main table filters by state repo and completion" {
  mkdir -p "$REPO/.agent/blocked-task" "$REPO/.agent/done-task"
  cat > "$REPO/.agent/blocked-task/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Blocked task.
- Estimated completion: 10%
- Next work: Resolve question.

## Open Questions / Follow-Ups

- What is needed?
  - USER ANSWER (UNRESOLVED):
MD
  cat > "$REPO/.agent/done-task/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Done task.
- Estimated completion: 100%
- Next work: Review.
MD
  local port=18774
  start_gui "$port"
  fetch_gui "$port" "/?state=blocked" "$BATS_TEST_TMPDIR/filter-state.html"
  fetch_gui "$port" "/?completion=100%25" "$BATS_TEST_TMPDIR/filter-completion.html"
  fetch_gui "$port" "/?repo=repo" "$BATS_TEST_TMPDIR/filter-repo.html"
  stop_gui

  grep -q 'name="state"' "$BATS_TEST_TMPDIR/filter-state.html"
  grep -q 'name="repo"' "$BATS_TEST_TMPDIR/filter-state.html"
  grep -q 'name="completion"' "$BATS_TEST_TMPDIR/filter-state.html"
  grep -q "<details class='filter-disclosure' open>" "$BATS_TEST_TMPDIR/filter-state.html"
  grep -q "blocked-task" "$BATS_TEST_TMPDIR/filter-state.html"
  ! grep -q "gui-task" "$BATS_TEST_TMPDIR/filter-state.html"
  grep -q "done-task" "$BATS_TEST_TMPDIR/filter-completion.html"
  ! grep -q "blocked-task" "$BATS_TEST_TMPDIR/filter-completion.html"
  grep -q "gui-task" "$BATS_TEST_TMPDIR/filter-repo.html"
}

@test "paw gui: hides filters by default while keeping repo selector visible" {
  local port=18758
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/filter-default.html"
  stop_gui

  grep -q "<details class='filter-disclosure'>" "$BATS_TEST_TMPDIR/filter-default.html"
  ! grep -q "<details class='filter-disclosure' open>" "$BATS_TEST_TMPDIR/filter-default.html"
  grep -q "Active repo" "$BATS_TEST_TMPDIR/filter-default.html"
  grep -q "Filter tasks" "$BATS_TEST_TMPDIR/filter-default.html"
}

@test "paw gui: home rows expose stage workflow and next actions" {
  mkdir -p "$REPO/.agent/blocked-task" "$REPO/.agent/running-task/runs" "$REPO/.agent/done-task" "$REPO/.agent/reviewed-task" "$REPO/.agent/pending-review-task" "$REPO/.agent/empty-review-task" "$REPO/.agent/missing-grade-task" "$REPO/.agent/prototype-task"
  cat > "$REPO/.agent/blocked-task/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Blocked task.
- Estimated completion: 10%
- Next work: Resolve question.

## Open Questions / Follow-Ups

- What is needed?
  - USER ANSWER (UNRESOLVED):
MD
  cp "$REPO/.agent/gui-task/plan.md" "$REPO/.agent/running-task/plan.md"
  start_paw_like_sleeper
  git config --file "$REPO/.agent/running-task/runs/running-$SLEEPER_PID.gitconfig" paw.status running
  cat > "$REPO/.agent/done-task/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Done task.
- Estimated completion: 100%
- Next work: Review.
MD
  cp "$REPO/.agent/done-task/plan.md" "$REPO/.agent/reviewed-task/plan.md"
  cat > "$REPO/.agent/reviewed-task/review.md" <<'MD'
# Review

## Review Metadata
- Grade: B-
- Task: reviewed-task
- Scope Reviewed: task delta
- Quality Threshold: B+ / no blockers
- Threshold Result: below threshold

## Blocking Production-Readiness Issues
- None.
MD
  cp "$REPO/.agent/done-task/plan.md" "$REPO/.agent/pending-review-task/plan.md"
  cat > "$REPO/.agent/pending-review-task/review.md" <<'MD'
# Review

## Review Metadata
- Grade: pending
MD
  cp "$REPO/.agent/done-task/plan.md" "$REPO/.agent/empty-review-task/plan.md"
  cat > "$REPO/.agent/empty-review-task/review.md" <<'MD'
# Review

## Review Metadata
- Grade:
MD
  cp "$REPO/.agent/done-task/plan.md" "$REPO/.agent/missing-grade-task/plan.md"
  printf '# Review\n' > "$REPO/.agent/missing-grade-task/review.md"
  cp "$REPO/.agent/done-task/plan.md" "$REPO/.agent/prototype-task/plan.md"
  printf '# Review\n' > "$REPO/.agent/prototype-task/review.md"
  git config --file "$REPO/.agent/prototype-task/metadata.gitconfig" paw.prototype-status prototyped
  local port=18764
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/stage-workflow.html"
  stop_gui
  kill "$SLEEPER_PID" 2>/dev/null || true
  wait "$SLEEPER_PID" 2>/dev/null || true

  grep -q "<th[^>]*>Stage</th>" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "<th[^>]*>Next</th>" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Stage: Implement" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Next: Approve Implementation" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "data-doc-preview-url='/fragments/task-doc/gui-task" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Stage: Needs edit" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Next: Answer Questions" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "USER ANSWER placeholders remain" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "What is needed?" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Answer Questions blocked-task" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Stage: Running" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Next: Cancel" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "/task/running-task/cancel" "$BATS_TEST_TMPDIR/stage-workflow.html"
  ! grep -q "Next: Wait for run" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Stage: Review" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Next: Review" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "/task/done-task/review" "$BATS_TEST_TMPDIR/stage-workflow.html"
  ! grep -q "Review\\.</div>" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Stage: Reviewed" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Next: Use as Prototype" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Review grade: B-" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "grade-b" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "/task/reviewed-task/prototype" "$BATS_TEST_TMPDIR/stage-workflow.html"
  ! grep -q "Review grade: pending" "$BATS_TEST_TMPDIR/stage-workflow.html"
  ! grep -q "grade-pending" "$BATS_TEST_TMPDIR/stage-workflow.html"
  ! grep -q "Review grade:</span>" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Stage: Prototype" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "Next: Archive" "$BATS_TEST_TMPDIR/stage-workflow.html"
  grep -q "/task/prototype-task/archive" "$BATS_TEST_TMPDIR/stage-workflow.html"
}

@test "paw gui: disables prototype for A- or higher reviewed tasks" {
  mkdir -p "$REPO/.agent/grade-a" "$REPO/.agent/grade-a-minus" "$REPO/.agent/grade-b-plus" "$REPO/.agent/grade-pending" "$REPO/.agent/grade-missing"
  for task in grade-a grade-a-minus grade-b-plus grade-pending grade-missing; do
    cat > "$REPO/.agent/$task/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Reviewed task.
- Estimated completion: 100%
- Next work: Review.
MD
  done
  cat > "$REPO/.agent/grade-a/review.md" <<'MD'
# Review

## Review Metadata
- Grade: A
- Task: grade-a
- Scope Reviewed: task delta
- Quality Threshold: B+ / no blockers
- Threshold Result: met

## Blocking Production-Readiness Issues
- None.
MD
  cat > "$REPO/.agent/grade-a-minus/review.md" <<'MD'
# Review

## Review Metadata
- Grade: A-
- Task: grade-a-minus
- Scope Reviewed: task delta
- Quality Threshold: B+ / no blockers
- Threshold Result: met

## Blocking Production-Readiness Issues
- None.
MD
  cat > "$REPO/.agent/grade-b-plus/review.md" <<'MD'
# Review

## Review Metadata
- Grade: B+
- Task: grade-b-plus
- Scope Reviewed: task delta
- Quality Threshold: B+ / no blockers
- Threshold Result: met

## Blocking Production-Readiness Issues
- None.
MD
  cat > "$REPO/.agent/grade-pending/review.md" <<'MD'
# Review

## Review Metadata
- Grade: pending
MD
  printf '# Review\n' > "$REPO/.agent/grade-missing/review.md"
  local port=18757 a_path b_path
  a_path="$(real_path "$REPO/.agent/grade-a")"
  b_path="$(real_path "$REPO/.agent/grade-b-plus")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/prototype-grades.html"
  post_gui "$port" "/task/grade-a/prototype" "$(form_encode "path=$a_path")" "$BATS_TEST_TMPDIR/prototype-a-post.html"
  post_gui "$port" "/task/grade-b-plus/prototype" "$(form_encode "path=$b_path")" "$BATS_TEST_TMPDIR/prototype-b-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "Legacy review lacks completed attempt evidence" "$BATS_TEST_TMPDIR/prototype-grades.html"
  grep -q "Update PR" "$BATS_TEST_TMPDIR/prototype-grades.html"
  ! grep -q "/task/grade-a/prototype" "$BATS_TEST_TMPDIR/prototype-grades.html"
  ! grep -q "/task/grade-a-minus/prototype" "$BATS_TEST_TMPDIR/prototype-grades.html"
  grep -q "/task/grade-b-plus/prototype" "$BATS_TEST_TMPDIR/prototype-grades.html"
  ! grep -q "/task/grade-pending/prototype" "$BATS_TEST_TMPDIR/prototype-grades.html"
  ! grep -q "/task/grade-missing/prototype" "$BATS_TEST_TMPDIR/prototype-grades.html"
  grep -q "prototype blocked: Prototype disabled for review grade A" "$BATS_TEST_TMPDIR/prototype-a-post.html"
  grep -q "grade-b-plus-prototype" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw gui: sorts task rows by most recent activity in scoped mode" {
  mkdir -p "$REPO/.agent/alpha-task/runs" "$REPO/.agent/beta-task/runs"
  cp "$REPO/.agent/gui-task/plan.md" "$REPO/.agent/alpha-task/plan.md"
  cp "$REPO/.agent/gui-task/plan.md" "$REPO/.agent/beta-task/plan.md"
  git config --file "$REPO/.agent/alpha-task/runs/old.gitconfig" paw.end-time "2026-01-01T00:00:00Z"
  git config --file "$REPO/.agent/beta-task/runs/new.gitconfig" paw.start-time "2026-02-01T00:00:00Z"
  local port=18782
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/sorted.html"
  stop_gui

  python3 - "$BATS_TEST_TMPDIR/sorted.html" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
assert html.index("beta-task") < html.index("alpha-task"), html
PY
}

@test "paw gui --all: sorts central task rows by most recent activity" {
  git -C "$REPO" init -q
  local repo_two="$BATS_TEST_TMPDIR/repo-two"
  mkdir -p "$repo_two"
  git -C "$repo_two" init -q
  local old_task new_task port=18783
  old_task="$(bash -c 'source "$1"; paw_task_create_dir "$2" old-central' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  new_task="$(bash -c 'source "$1"; paw_task_create_dir "$2" new-central' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$repo_two")"
  mkdir -p "$old_task/runs" "$new_task/runs"
  cp "$REPO/.agent/gui-task/plan.md" "$old_task/plan.md"
  cp "$REPO/.agent/gui-task/plan.md" "$new_task/plan.md"
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" old-central created ""; paw_task_write_metadata "$4" "$5" new-central created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$old_task" "$REPO" "$new_task" "$repo_two"
  git config --file "$old_task/runs/old.gitconfig" paw.end-time "2026-01-01T00:00:00Z"
  git config --file "$new_task/runs/new.gitconfig" paw.end-time "2026-03-01T00:00:00Z"

  start_gui "$port" --all
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/all-sorted.html"
  stop_gui

  python3 - "$BATS_TEST_TMPDIR/all-sorted.html" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
assert html.index("new-central") < html.index("old-central"), html
PY
}

@test "paw gui: index page exposes auto-refresh fragment for task rows" {
  local port=18784
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/refresh-index.html"
  python3 - "$REPO/.agent/gui-task/plan.md" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("50%", "51%"))
PYTHON
  fetch_gui "$port" "/fragments/tasks" "$BATS_TEST_TMPDIR/tasks-fragment.html"
  stop_gui

  grep -q 'data-paw-refresh-url="/fragments/tasks' "$BATS_TEST_TMPDIR/refresh-index.html"
  grep -q 'data-paw-refresh-interval-ms=' "$BATS_TEST_TMPDIR/refresh-index.html"
  grep -q "gui-task" "$BATS_TEST_TMPDIR/tasks-fragment.html"
  grep -q "Stage: Implement" "$BATS_TEST_TMPDIR/refresh-index.html"
  grep -q "51%" "$BATS_TEST_TMPDIR/tasks-fragment.html"
  ! grep -q "<!doctype html>" "$BATS_TEST_TMPDIR/tasks-fragment.html"
}

@test "paw gui: pages expose home navigation" {
  local port=18791 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/home-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/home-detail.html"
  fetch_gui "$port" "/no-such-page" "$BATS_TEST_TMPDIR/home-missing.html" || true
  stop_gui

  grep -q "<a class='home-link' href='/'>Home</a>" "$BATS_TEST_TMPDIR/home-index.html"
  grep -q "<a class='home-link' href='/archive" "$BATS_TEST_TMPDIR/home-index.html"
  grep -q "<a class='home-link' href='/'>Home</a>" "$BATS_TEST_TMPDIR/home-detail.html"
  grep -q "<a class='home-link' href='/archive" "$BATS_TEST_TMPDIR/home-detail.html"
}

@test "paw gui: uses compact headers without always-visible full paths" {
  local port=18794 path encoded_path repo_path
  path="$(real_path "$REPO/.agent/gui-task")"
  repo_path="$(real_path "$REPO")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/compact-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/compact-detail.html"
  stop_gui

  grep -q "<header class='site-header'><div class='shell header-row'>" "$BATS_TEST_TMPDIR/compact-index.html"
  grep -q "<a class='home-link' href='/'>Home</a><a class='home-link' href='/archive" "$BATS_TEST_TMPDIR/compact-index.html"
  grep -q "<h1>PAW Tasks</h1>" "$BATS_TEST_TMPDIR/compact-index.html"
  grep -q "repo</span>" "$BATS_TEST_TMPDIR/compact-index.html"
  ! grep -q "<div>$repo_path</div>" "$BATS_TEST_TMPDIR/compact-index.html"
  grep -q "<a class='home-link' href='/'>Home</a><a class='home-link' href='/archive" "$BATS_TEST_TMPDIR/compact-detail.html"
  grep -q "<h1>gui-task</h1>" "$BATS_TEST_TMPDIR/compact-detail.html"
  ! grep -q "<div>$path</div>" "$BATS_TEST_TMPDIR/compact-detail.html"
}

@test "paw gui: hides exact paths behind disclosure controls" {
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-context
  local port=18795 path encoded_path repo_path
  path="$(real_path "$REPO/.agent/gui-task")"
  repo_path="$(real_path "$REPO")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/path-disclosure-detail.html"
  stop_gui

  grep -q "<details class='path-disclosure'><summary>Task path</summary><code>$path</code></details>" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  grep -q "<details class='path-disclosure'><summary>Repo details</summary>" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  grep -q "Branch: feature/gui-context" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  grep -q "<dt>Repo path</dt><dd><code>$repo_path</code></dd>" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  grep -q "<dt>Task store</dt><dd><code>" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  ! grep -q "Central store <details" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
  grep -q "<details class='path-disclosure'><summary>Task path</summary><code>$path</code></details>" "$BATS_TEST_TMPDIR/path-disclosure-detail.html"
  grep -q "<details class='path-disclosure'><summary>Repo path</summary><code>$repo_path</code></details>" "$BATS_TEST_TMPDIR/path-disclosure-detail.html"
  ! grep -q "<br><span class='muted'>$path</span>" "$BATS_TEST_TMPDIR/path-disclosure-index.html"
}

@test "paw gui: uses a shared wide shell and scrollable table wrappers" {
  local port=18796 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/layout-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/layout-detail.html"
  stop_gui

  grep -q ".shell{width:min(100% - 32px,1600px);margin-inline:auto}" "$BATS_TEST_TMPDIR/layout-index.html"
  grep -q "<header class='site-header'><div class='shell header-row'>" "$BATS_TEST_TMPDIR/layout-index.html"
  grep -q "<main class='shell'>" "$BATS_TEST_TMPDIR/layout-index.html"
  grep -q "<div class='table-wrap'><table class='dashboard-table' role='table' aria-label='Tasks'>" "$BATS_TEST_TMPDIR/layout-index.html"
  grep -q "<div class='table-wrap'><table><tbody>" "$BATS_TEST_TMPDIR/layout-detail.html"
  grep -q "data-label='Task'" "$BATS_TEST_TMPDIR/layout-index.html"
}

@test "paw gui: exposes polished toolbar status and document styling hooks" {
  local port=18797 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/polish-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/polish-detail.html"
  stop_gui

  grep -q "<form class='toolbar' method='get'>" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q "<div class='toolbar-fields'>" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q "<div class='top-actions'>" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q "<span class='metric-chip'>1/2</span>" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q "<span class='validation-chip validation-passed'>Passed</span>" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q "button:focus-visible,.button:focus-visible,.home-link:focus-visible" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q ".flash,.flash-error" "$BATS_TEST_TMPDIR/polish-index.html"
  grep -q ".document table{border:1px solid var(--line)}" "$BATS_TEST_TMPDIR/polish-detail.html"
}

@test "paw gui: task detail fragment reflects updated plan and run metadata" {
  local port=18785 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/detail-refresh-page.html"

  cat > "$REPO/.agent/gui-task/plan.md" <<'MD'
# Updated Plan

## Implementation Phases / Checklist
- [x] Done.
  Progress: Finished.
- [x] Next.
  Progress: Also finished.

## Current Status

- Plan position: Refreshed from disk.
- Estimated completion: 100%
- Next work: Review.

## Validation Performed
- OK.
MD
  mkdir -p "$REPO/.agent/gui-task/runs"
  git config --file "$REPO/.agent/gui-task/runs/done.gitconfig" paw.subcommand implement
  git config --file "$REPO/.agent/gui-task/runs/done.gitconfig" paw.status complete
  git config --file "$REPO/.agent/gui-task/runs/done.gitconfig" paw.end-time "2026-04-01T00:00:00Z"
  fetch_gui "$port" "/fragments/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/detail-fragment.html"
  stop_gui

  grep -q 'data-paw-refresh-url="/fragments/task/gui-task' "$BATS_TEST_TMPDIR/detail-refresh-page.html"
  grep -q '<span class=.pill complete.>complete</span>' "$BATS_TEST_TMPDIR/detail-fragment.html"
  grep -q "2/2 checklist" "$BATS_TEST_TMPDIR/detail-fragment.html"
  grep -q "Refreshed from disk" "$BATS_TEST_TMPDIR/detail-fragment.html"
  grep -q "<h1>Updated Plan</h1>" "$BATS_TEST_TMPDIR/detail-fragment.html"
  grep -q "implement" "$BATS_TEST_TMPDIR/detail-fragment.html"
  ! grep -q "<!doctype html>" "$BATS_TEST_TMPDIR/detail-fragment.html"
}

@test "paw gui: dashboard retires selection on page fragment and empty state" {
  local port=18762
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/page.html"
  fetch_gui "$port" "/fragments/tasks" "$BATS_TEST_TMPDIR/fragment.html"
  fetch_gui "$port" "/?repo=does-not-exist" "$BATS_TEST_TMPDIR/empty.html"
  stop_gui
  python3 - "$BATS_TEST_TMPDIR" <<'PYTEST'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ('page', 'fragment', 'empty'):
    page = (root / (name + '.html')).read_text()
    assert '<th>Select</th>' not in page
    assert 'selected-action' not in page and "name='task'" not in page
    if name != 'empty':
        from html.parser import HTMLParser
        class Headers(HTMLParser):
            def __init__(self): super().__init__(); self.headers = []; self.inside = False
            def handle_starttag(self, tag, attrs): self.inside = tag == 'th'
            def handle_data(self, data):
                if self.inside: self.headers.append(data)
        parser = Headers(); parser.feed(page)
        assert parser.headers == ['Task','Repo','Stage','Next','Completion','Checklist','Validation','Actions']
assert 'No tasks match these filters.' in (root / 'empty.html').read_text()
assert 'New Plan' in (root / 'page.html').read_text()
assert 'Queued Plans' in (root / 'page.html').read_text()
PYTEST
}

@test "paw gui: repo column includes branch context and branch column is removed" {
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-context
  local port=18763
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/branch-context.html"
  stop_gui

  grep -q "feature/gui-context" "$BATS_TEST_TMPDIR/branch-context.html"
  grep -q "<th[^>]*>Repo</th>" "$BATS_TEST_TMPDIR/branch-context.html"
  ! grep -q "<th[^>]*>Branch</th>" "$BATS_TEST_TMPDIR/branch-context.html"
}

@test "paw gui: exposes View PR for PAW branch metadata with an existing local branch" {
  init_repo_with_commit
  git -C "$REPO" branch feature/gui-pr
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-pr
  mkdir -p "$REPO/.agent/no-branch-task" "$REPO/.agent/deleted-branch-task"
  cp "$REPO/.agent/gui-task/plan.md" "$REPO/.agent/no-branch-task/plan.md"
  cp "$REPO/.agent/gui-task/plan.md" "$REPO/.agent/deleted-branch-task/plan.md"
  git config --file "$REPO/.agent/deleted-branch-task/metadata.gitconfig" paw.branch-name feature/deleted
  local port=18757 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/view-pr-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/view-pr-detail.html"
  stop_gui

  grep -q "/task/gui-task/view-pr" "$BATS_TEST_TMPDIR/view-pr-index.html"
  grep -q "/task/gui-task/view-pr" "$BATS_TEST_TMPDIR/view-pr-detail.html"
  grep -q ">View PR<" "$BATS_TEST_TMPDIR/view-pr-index.html"
  ! grep -q "/task/no-branch-task/view-pr" "$BATS_TEST_TMPDIR/view-pr-index.html"
  ! grep -q "/task/deleted-branch-task/view-pr" "$BATS_TEST_TMPDIR/view-pr-index.html"
}

@test "paw gui: View PR uses saved branch and returns the current PR URL without launching PAW" {
  init_repo_with_commit
  git -C "$REPO" branch feature/gui-pr
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-pr
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/gh.args"
printf 'https://github.example.test/org/repo/pull/42\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  local old_path="$PATH"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  local port=18756 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  post_gui "$port" "/task/gui-task/view-pr" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/view-pr-post.html"
  stop_gui
  export PATH="$old_path"

  grep -q "Current PR for gui-task" "$BATS_TEST_TMPDIR/view-pr-post.html"
  grep -q "https://github.example.test/org/repo/pull/42" "$BATS_TEST_TMPDIR/view-pr-post.html"
  grep -Fx "pr view feature/gui-pr --json url --jq .url" "$BATS_TEST_TMPDIR/gh.args"
  [ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]
  [ ! -d "$REPO/.agent/gui-task/runs" ]
}

@test "paw gui: View PR rejects ineligible branches and missing PRs clearly" {
  init_repo_with_commit
  git -C "$REPO" branch feature/gui-pr
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/deleted
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'no pull requests found\n' >&2
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  local old_path="$PATH"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  local port=18755 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  post_gui "$port" "/task/gui-task/view-pr" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/view-pr-deleted.html"
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-pr
  post_gui "$port" "/task/gui-task/view-pr" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/view-pr-missing.html"
  stop_gui
  export PATH="$old_path"

  grep -q "View PR unavailable: saved branch is missing or no longer exists locally" "$BATS_TEST_TMPDIR/view-pr-deleted.html"
  grep -q "No current PR found for branch feature/gui-pr" "$BATS_TEST_TMPDIR/view-pr-missing.html"
  [ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]
}

@test "paw gui: View PR preserves authentication guidance" {
  init_repo_with_commit
  git -C "$REPO" branch feature/gui-pr
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-pr
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'To get started with GitHub CLI, please run: gh auth login\nAlternatively, populate the GH_TOKEN environment variable.\n' >&2
exit 4
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  local port=18751 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  post_gui "$port" "/task/gui-task/view-pr" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/view-pr-auth.html"
  stop_gui

  grep -q "View PR unavailable: gh authentication/configuration failed" "$BATS_TEST_TMPDIR/view-pr-auth.html"
  grep -q "gh auth login" "$BATS_TEST_TMPDIR/view-pr-auth.html"
  grep -q "GH_TOKEN" "$BATS_TEST_TMPDIR/view-pr-auth.html"
  ! grep -q "No current PR found" "$BATS_TEST_TMPDIR/view-pr-auth.html"
  [ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]
  [ ! -d "$REPO/.agent/gui-task/runs" ]
}

@test "paw gui: View PR preserves generic diagnostics safely and handles empty output" {
  init_repo_with_commit
  git -C "$REPO" branch feature/gui-pr
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-pr
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$(cat "$BATS_TEST_TMPDIR/gh-mode")" in
  stderr) printf 'API unavailable <script>alert(1)</script>\n' >&2; exit 1 ;;
  stdout) printf 'Network connection refused\n'; exit 1 ;;
  silent) exit 1 ;;
  empty) exit 0 ;;
  invalid) printf 'not-a-url\n'; exit 0 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  local port=18750 path mode
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  for mode in stderr stdout silent empty invalid; do
    printf '%s\n' "$mode" > "$BATS_TEST_TMPDIR/gh-mode"
    post_gui "$port" "/task/gui-task/view-pr" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/view-pr-$mode.html"
    ! grep -q "No current PR found" "$BATS_TEST_TMPDIR/view-pr-$mode.html"
  done
  stop_gui

  grep -q "gh lookup failed for branch feature/gui-pr" "$BATS_TEST_TMPDIR/view-pr-stderr.html"
  grep -q 'API unavailable &lt;script&gt;alert(1)&lt;/script&gt;' "$BATS_TEST_TMPDIR/view-pr-stderr.html"
  ! grep -q '<script>alert(1)</script>' "$BATS_TEST_TMPDIR/view-pr-stderr.html"
  grep -q 'Network connection refused' "$BATS_TEST_TMPDIR/view-pr-stdout.html"
  grep -q 'exit status 1; no diagnostic output' "$BATS_TEST_TMPDIR/view-pr-silent.html"
  grep -q 'gh returned an invalid PR URL' "$BATS_TEST_TMPDIR/view-pr-empty.html"
  grep -q 'gh returned an invalid PR URL' "$BATS_TEST_TMPDIR/view-pr-invalid.html"
  [ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]
  [ ! -d "$REPO/.agent/gui-task/runs" ]
}

@test "paw gui: View PR reports when gh is unavailable" {
  init_repo_with_commit
  git -C "$REPO" branch feature/gui-pr
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-pr
  local no_gh_path="$BATS_TEST_TMPDIR/no-gh-bin"
  mkdir -p "$no_gh_path"
  for tool in bash python3 git cksum dirname readlink pkill sleep mkdir date sed awk grep basename cat; do
    local tool_path
    tool_path="$(command -v "$tool")"
    ln -s "$tool_path" "$no_gh_path/$tool"
  done
  local old_path="$PATH"
  export PATH="$no_gh_path"
  local port=18752 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  post_gui "$port" "/task/gui-task/view-pr" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/view-pr-no-gh.html"
  stop_gui
  export PATH="$old_path"

  grep -q "View PR unavailable: gh is not installed or not on PATH" "$BATS_TEST_TMPDIR/view-pr-no-gh.html"
  [ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]
}

@test "paw gui: renders task markdown as safe semantic HTML" {
  cat > "$REPO/.agent/gui-task/plan.md" <<'MD'
# Markdown Plan

Paragraph with **bold**, *emphasis*, `code`, [docs](https://example.test/docs), and <script>alert(1)</script>.

> Quoted line

- [x] Done item
- [ ] Todo item

| Name | State |
| --- | --- |
| GUI | Ready |

```sh
echo "hello"
```
MD
  local port=18767
  start_gui "$port"
  fetch_gui "$port" "/task/gui-task?path=$(url_encode "$(real_path "$REPO/.agent/gui-task")")&doc=plan" "$BATS_TEST_TMPDIR/markdown.html"
  stop_gui

  grep -q "<h1>Markdown Plan</h1>" "$BATS_TEST_TMPDIR/markdown.html"
  grep -q "<strong>bold</strong>" "$BATS_TEST_TMPDIR/markdown.html"
  grep -q "<em>emphasis</em>" "$BATS_TEST_TMPDIR/markdown.html"
  grep -q '<a href="https://example.test/docs" rel="noreferrer">docs</a>' "$BATS_TEST_TMPDIR/markdown.html"
  grep -q '<input type="checkbox" checked disabled>' "$BATS_TEST_TMPDIR/markdown.html"
  grep -q "<table>" "$BATS_TEST_TMPDIR/markdown.html"
  grep -q "<blockquote>" "$BATS_TEST_TMPDIR/markdown.html"
  grep -q "<pre><code class=\"language-sh\">echo &quot;hello&quot;" "$BATS_TEST_TMPDIR/markdown.html"
  grep -q "&lt;script&gt;alert(1)&lt;/script&gt;" "$BATS_TEST_TMPDIR/markdown.html"
  ! grep -q "<pre># Markdown Plan" "$BATS_TEST_TMPDIR/markdown.html"
}

@test "paw gui: starts paw plan from index form" {
  git -C "$REPO" init -q
  local port=18768
  start_gui "$port"

  post_gui "$port" "/actions/plan" "$(form_encode "task_name=gui-created" "prompt=Build from the browser")" "$BATS_TEST_TMPDIR/plan-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/plan-index.html"
  stop_gui

  grep -q "PAW:PLAN" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "Build from the browser" "$BATS_TEST_TMPDIR/backend.prompt"
  find "$PAW_TASK_HOME" -path "*/gui-created/plan.md" -print -quit | grep -q "gui-created/plan.md"
  grep -q "gui-created" "$BATS_TEST_TMPDIR/plan-index.html"
}

@test "paw gui: queues a plan prompt without launching paw" {
  git -C "$REPO" init -q
  local port=18756
  start_gui "$port"

  post_gui "$port" "/actions/plan" "$(form_encode "plan_action=queue" "task_name=queued-plan" "prompt=Save this prompt for later")" "$BATS_TEST_TMPDIR/queue-post.html"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/queue-index.html"
  stop_gui

  grep -q "queued plan prompt queued-plan" "$BATS_TEST_TMPDIR/queue-post.html"
  grep -q "queued-plan" "$BATS_TEST_TMPDIR/queue-index.html"
  grep -q "Save this prompt for later" "$BATS_TEST_TMPDIR/queue-index.html"
  grep -q "title='Save this prompt locally so planning can be started later'" "$BATS_TEST_TMPDIR/queue-index.html"
  [[ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]]
  find "$PAW_TASK_HOME" -path "*/.queue/queued-plan/metadata.gitconfig" -print -quit | grep -q "queued-plan"
}

@test "paw gui: triggers and removes queued plan prompts" {
  git -C "$REPO" init -q
  local queue_dir port=18755
  queue_dir="$PAW_TASK_HOME/$(bash -c 'source "$1"; paw_repo_slug "$2"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")/.queue/queued-plan"
  mkdir -p "$queue_dir"
  printf 'Queued prompt body\n' > "$queue_dir/prompt.txt"
  git config --file "$queue_dir/metadata.gitconfig" paw.task-name queued-plan
  git config --file "$queue_dir/metadata.gitconfig" paw.repo-root "$(real_path "$REPO")"
  start_gui "$port"

  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/queue-trigger-index.html"
  post_gui "$port" "/actions/queue/trigger" "$(form_encode "active_repo=$(real_path "$REPO")" "task_name=queued-plan")" "$BATS_TEST_TMPDIR/queue-trigger-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "Queued Plans" "$BATS_TEST_TMPDIR/queue-trigger-index.html"
  grep -q "queued-plan" "$BATS_TEST_TMPDIR/queue-trigger-index.html"
  grep -q "Queued prompt body" "$BATS_TEST_TMPDIR/queue-trigger-index.html"
  grep -q "triggered queued plan queued-plan" "$BATS_TEST_TMPDIR/queue-trigger-post.html"
  grep -q "Queued prompt body" "$BATS_TEST_TMPDIR/backend.prompt"
  [[ ! -d "$queue_dir" ]]
}

@test "paw gui: adds a second local Git repo to the selector" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  git -C "$REPO" init -q
  local repo_two="$BATS_TEST_TMPDIR/repo-two"
  mkdir -p "$repo_two"
  git -C "$repo_two" init -q
  local port=18796 repo_two_path
  repo_two_path="$(real_path "$repo_two")"
  start_gui "$port"

  post_gui "$port" "/actions/repos/add" "$(form_encode "repo_path=$repo_two_path")" "$BATS_TEST_TMPDIR/add-repo-post.html"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/add-repo-index.html"
  stop_gui

  grep -q "added repo $repo_two_path" "$BATS_TEST_TMPDIR/add-repo-post.html"
  grep -q "name=\"active_repo\"" "$BATS_TEST_TMPDIR/add-repo-index.html"
  grep -q "<option value='$repo_two_path'>repo-two</option>" "$BATS_TEST_TMPDIR/add-repo-index.html"
  git config --file "$XDG_STATE_HOME/paw/gui/repos.gitconfig" --get-all paw.repo | grep -Fx "$repo_two_path"
}

@test "paw gui: selected repo scopes listing and Plan target" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  git -C "$REPO" init -q
  local repo_two="$BATS_TEST_TMPDIR/repo-two"
  mkdir -p "$repo_two"
  git -C "$repo_two" init -q
  local central_one central_two
  central_one="$(bash -c 'source "$1"; paw_task_create_dir "$2" repo-one-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  central_two="$(bash -c 'source "$1"; paw_task_create_dir "$2" repo-two-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$repo_two")"
  mkdir -p "$central_one" "$central_two"
  cat > "$central_one/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Repo one only.
- Estimated completion: 10%
- Next work: One.
MD
  cat > "$central_two/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Repo two only.
- Estimated completion: 20%
- Next work: Two.
MD
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" repo-one-task created ""; paw_task_write_metadata "$4" "$5" repo-two-task created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$central_one" "$REPO" "$central_two" "$repo_two"
  local port=18797 repo_two_path encoded_repo_two created
  repo_two_path="$(real_path "$repo_two")"
  encoded_repo_two="$(url_encode "$repo_two_path")"
  created="$(bash -c 'source "$1"; paw_task_create_dir "$2" selected-plan' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$repo_two")"
  start_gui "$port"

  post_gui "$port" "/actions/repos/add" "$(form_encode "repo_path=$repo_two_path")" "$BATS_TEST_TMPDIR/select-add-post.html"
  fetch_gui "$port" "/?active_repo=$encoded_repo_two" "$BATS_TEST_TMPDIR/select-repo-index.html"
  post_gui "$port" "/actions/plan" "$(form_encode "active_repo=$repo_two_path" "task_name=selected-plan" "prompt=Plan in repo two")" "$BATS_TEST_TMPDIR/select-plan-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "repo-two-task" "$BATS_TEST_TMPDIR/select-repo-index.html"
  ! grep -q "repo-one-task" "$BATS_TEST_TMPDIR/select-repo-index.html"
  grep -q "Plan in repo two" "$BATS_TEST_TMPDIR/backend.prompt"
  [ -f "$created/metadata.gitconfig" ]
  git config --file "$created/metadata.gitconfig" --get paw.repo-root | grep -Fx "$repo_two_path"
}

@test "paw gui: rejects invalid and unregistered repo selections visibly" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  git -C "$REPO" init -q
  local missing="$BATS_TEST_TMPDIR/missing-repo"
  local unregistered="$BATS_TEST_TMPDIR/unregistered-repo"
  mkdir -p "$unregistered"
  git -C "$unregistered" init -q
  local port=18799 encoded_unregistered
  encoded_unregistered="$(url_encode "$(real_path "$unregistered")")"
  start_gui "$port"

  post_gui "$port" "/actions/repos/add" "$(form_encode "repo_path=$missing")" "$BATS_TEST_TMPDIR/invalid-add-post.html"
  fetch_gui "$port" "/?active_repo=$encoded_unregistered" "$BATS_TEST_TMPDIR/unregistered-index.html"
  stop_gui

  grep -q "repo path does not exist:" "$BATS_TEST_TMPDIR/invalid-add-post.html"
  grep -q "selected repo is not registered and was reset" "$BATS_TEST_TMPDIR/unregistered-index.html"
  ! git config --file "$XDG_STATE_HOME/paw/gui/repos.gitconfig" --get-all paw.repo | grep -Fx "$(real_path "$unregistered")"
}

@test "paw gui: index uses concise labels modals row actions and doc preview controls" {
  local port=18792
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/index-actions.html"
  stop_gui

  grep -q "data-doc-preview" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "data-doc-preview-url='/fragments/task-doc/gui-task" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q ">contract.md<" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "Preview plan" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q "pr.md" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q ">Open<" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "/task/gui-task/archive" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "/task/gui-task/edit" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "approve=implementation" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q "/task/gui-task/implement" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "/task/gui-task/delete" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q ">Plan<" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q ">Archive<" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q ">Edit<" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q ">Approve Implementation<" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q ">Implement<" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q ">Delete<" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q "Start plan" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q "Start edit" "$BATS_TEST_TMPDIR/index-actions.html"
  ! grep -q "Start implement" "$BATS_TEST_TMPDIR/index-actions.html"
  grep -q "Extra instructions" "$BATS_TEST_TMPDIR/index-actions.html"
}

@test "paw gui: homepage task doc preview returns safe overlay fragment" {
  rm -f "$REPO/.agent/gui-task/pr.md"
  local port=18793 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/fragments/task-doc/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/plan-preview.html"
  stop_gui

  grep -q "modal-panel" "$BATS_TEST_TMPDIR/plan-preview.html"
  grep -q "gui-task / plan.md" "$BATS_TEST_TMPDIR/plan-preview.html"
  grep -q "<h1>Plan</h1>" "$BATS_TEST_TMPDIR/plan-preview.html"
  ! grep -q "<!doctype html>" "$BATS_TEST_TMPDIR/plan-preview.html"
}

@test "paw gui: approval preview shows plan and implementation approval controls" {
  rm -f "$REPO/.agent/gui-task/pr.md"
  local port=18762 path encoded_path plan_path
  path="$(real_path "$REPO/.agent/gui-task")"
  plan_path="$path/plan.md"
  encoded_path="$(url_encode "$path")"
  start_gui "$port"
  fetch_gui "$port" "/fragments/task-doc/gui-task?path=$encoded_path&doc=plan&approve=implementation" "$BATS_TEST_TMPDIR/approval-preview.html"
  stop_gui

  grep -q "modal-panel" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q "gui-task / plan.md" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q "<h1>Plan</h1>" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q "Approve implementation for gui-task" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q "/task/gui-task/edit" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q "/task/gui-task/implement" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q "$plan_path" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q ">Approve Implementation<" "$BATS_TEST_TMPDIR/approval-preview.html"
  grep -q ">Close<" "$BATS_TEST_TMPDIR/approval-preview.html"
  ! grep -q "<!doctype html>" "$BATS_TEST_TMPDIR/approval-preview.html"
}

@test "paw gui: starts paw edit for an existing task" {
  local port=18769 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"

  post_gui "$port" "/task/gui-task/edit" "$(form_encode "path=$path" "extras=tighten acceptance criteria")" "$BATS_TEST_TMPDIR/edit-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "PAW:EDIT" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "tighten acceptance criteria" "$BATS_TEST_TMPDIR/backend.prompt"
  find "$REPO/.agent/gui-task/runs" -name "*.stdout.log" -print -quit | grep -q stdout.log
}

@test "paw gui: blocked edit modal submits answer context through paw edit" {
  cat >> "$REPO/.agent/gui-task/plan.md" <<'MD'

## Open Questions / Follow-Ups

- Which threshold should the task use?
  - USER ANSWER (UNRESOLVED):
MD
  local port=18768 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/answer-modal.html"

  post_gui "$port" "/task/gui-task/edit" "$(form_encode "path=$path" "answers=Use 85% for now." "extras=Keep the scope narrow.")" "$BATS_TEST_TMPDIR/answer-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "name='answers'" "$BATS_TEST_TMPDIR/answer-modal.html"
  grep -q "Which threshold should the task use?" "$BATS_TEST_TMPDIR/answer-modal.html"
  grep -q "PAW:EDIT" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "Question answers submitted from the GUI for gui-task:" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "Use 85% for now." "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "Keep the scope narrow." "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "USER ANSWER (UNRESOLVED):" "$REPO/.agent/gui-task/plan.md"
}

@test "paw gui: blocked edit modal falls back when question text is not parseable" {
  cat >> "$REPO/.agent/gui-task/plan.md" <<'MD'

USER ANSWER (UNRESOLVED):
MD
  local port=18767 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  fetch_gui "$port" "/task/gui-task?path=$(url_encode "$path")&doc=plan" "$BATS_TEST_TMPDIR/answer-fallback.html"
  stop_gui

  grep -q ">Answer Questions<" "$BATS_TEST_TMPDIR/answer-fallback.html"
  grep -q "Answer Questions gui-task" "$BATS_TEST_TMPDIR/answer-fallback.html"
  grep -q "name='answers'" "$BATS_TEST_TMPDIR/answer-fallback.html"
  ! grep -q "class='question-list'" "$BATS_TEST_TMPDIR/answer-fallback.html"
}

@test "paw gui: starts paw implement and blocks duplicate active runs" {
  local port=18770 path
  path="$(real_path "$REPO/.agent/gui-task")"
  mkdir -p "$REPO/.agent/gui-task/runs"
  git config --file "$REPO/.agent/gui-task/runs/running.gitconfig" paw.status running
  start_gui "$port"

  post_gui "$port" "/task/gui-task/implement" "$(form_encode "path=$path" "extras=finish the approved slice")" "$BATS_TEST_TMPDIR/implement-blocked.html"
  rm "$REPO/.agent/gui-task/runs/running.gitconfig"
  post_gui "$port" "/task/gui-task/implement" "$(form_encode "path=$path" "extras=finish the approved slice")" "$BATS_TEST_TMPDIR/implement-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "already has a running PAW subprocess" "$BATS_TEST_TMPDIR/implement-blocked.html"
  grep -q "PAW:IMPLEMENT" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -qF "bounded self-check" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -qF "Acceptance Evidence" "$BATS_TEST_TMPDIR/backend.prompt"
  ! grep -q "finish the approved slice" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw gui: cancels a verified active PAW run" {
  local port=18761 path meta
  path="$(real_path "$REPO/.agent/gui-task")"
  mkdir -p "$REPO/.agent/gui-task/runs"
  start_paw_like_sleeper
  meta="$REPO/.agent/gui-task/runs/running-$SLEEPER_PID.gitconfig"
  git config --file "$meta" paw.status running
  git config --file "$meta" paw.subcommand implement
  start_gui "$port"

  post_gui "$port" "/task/gui-task/cancel" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/cancel-post.html"
  stop_gui
  wait "$SLEEPER_PID" 2>/dev/null || true

  grep -Eq "cancelled gui-task|SIGKILL fallback" "$BATS_TEST_TMPDIR/cancel-post.html"
  git config --file "$meta" --get paw.status | grep -Fx cancelled
}

@test "paw gui: does not expose cancel for pidless running metadata" {
  local port=18760
  mkdir -p "$REPO/.agent/gui-task/runs"
  git config --file "$REPO/.agent/gui-task/runs/running.gitconfig" paw.status running
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/pidless-running.html"
  fetch_gui "$port" "/task/gui-task?path=$(url_encode "$(real_path "$REPO/.agent/gui-task")")&doc=plan" "$BATS_TEST_TMPDIR/pidless-detail.html"
  stop_gui

  grep -q "Next: Wait for run" "$BATS_TEST_TMPDIR/pidless-running.html"
  grep -q "running metadata without a live cancellable PID" "$BATS_TEST_TMPDIR/pidless-running.html"
  ! grep -q "/task/gui-task/cancel" "$BATS_TEST_TMPDIR/pidless-running.html"
  ! grep -q "/task/gui-task/stream" "$BATS_TEST_TMPDIR/pidless-running.html"
  ! grep -q "Live Run Logs" "$BATS_TEST_TMPDIR/pidless-detail.html"
}

@test "paw gui: streams active run stdout and stderr from task-local logs" {
  local port=18754 path encoded_path meta
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  mkdir -p "$REPO/.agent/gui-task/runs"
  start_paw_like_sleeper
  meta="$REPO/.agent/gui-task/runs/20260911T010203Z-$SLEEPER_PID.gitconfig"
  git config --file "$meta" paw.status running
  git config --file "$meta" paw.subcommand implement
  git config --file "$meta" paw.start-time "2026-09-11T01:02:03Z"
  printf 'stdout <b>tag</b>\n' > "$REPO/.agent/gui-task/runs/20260911T010202Z-gui-999-implement-gui-task.stdout.log"
  printf 'stderr & detail\n' > "$REPO/.agent/gui-task/runs/20260911T010202Z-gui-999-implement-gui-task.stderr.log"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/stream-index.html"
  fetch_gui "$port" "/task/gui-task?path=$encoded_path&doc=plan" "$BATS_TEST_TMPDIR/stream-detail.html"
  fetch_gui "$port" "/task/gui-task/stream?path=$encoded_path" "$BATS_TEST_TMPDIR/stream-page.html"
  fetch_gui "$port" "/fragments/task-stream/gui-task?path=$encoded_path" "$BATS_TEST_TMPDIR/stream-fragment.html"
  stop_gui
  kill "$SLEEPER_PID" 2>/dev/null || true
  wait "$SLEEPER_PID" 2>/dev/null || true

  python3 - "$BATS_TEST_TMPDIR/stream-index.html" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
assert html.index(">Stream<") < html.index(">Cancel<"), html
PY
  grep -q "/task/gui-task/stream" "$BATS_TEST_TMPDIR/stream-index.html"
  grep -q "Live Run Logs" "$BATS_TEST_TMPDIR/stream-detail.html"
  grep -q 'data-paw-refresh-url="/fragments/task-stream/gui-task' "$BATS_TEST_TMPDIR/stream-detail.html"
  grep -q 'data-paw-refresh-url="/fragments/task-stream/gui-task' "$BATS_TEST_TMPDIR/stream-page.html"
  grep -q "stdout &lt;b&gt;tag&lt;/b&gt;" "$BATS_TEST_TMPDIR/stream-fragment.html"
  grep -q "stderr &amp; detail" "$BATS_TEST_TMPDIR/stream-fragment.html"
  ! grep -q "stdout <b>tag</b>" "$BATS_TEST_TMPDIR/stream-fragment.html"
}

@test "paw gui: stream route rejects stale pid metadata and missing task-local logs clearly" {
  local port=18753 path encoded_path
  path="$(real_path "$REPO/.agent/gui-task")"
  encoded_path="$(url_encode "$path")"
  mkdir -p "$REPO/.agent/gui-task/runs"
  git config --file "$REPO/.agent/gui-task/runs/20260911T010203Z-999999.gitconfig" paw.status running
  git config --file "$REPO/.agent/gui-task/runs/20260911T010203Z-999999.gitconfig" paw.subcommand implement
  printf 'not task local\n' > "$BATS_TEST_TMPDIR/outside.stdout.log"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/stale-index.html"
  fetch_gui "$port" "/task/gui-task/stream?path=$encoded_path" "$BATS_TEST_TMPDIR/stale-stream.html"
  stop_gui

  ! grep -q "/task/gui-task/stream" "$BATS_TEST_TMPDIR/stale-index.html"
  grep -q "No active PAW run is available for streaming." "$BATS_TEST_TMPDIR/stale-stream.html"
  ! grep -q "not task local" "$BATS_TEST_TMPDIR/stale-stream.html"
}

@test "paw gui: task detail exposes review prototype and archive actions" {
  local port=18786 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  fetch_gui "$port" "/task/gui-task?path=$(url_encode "$path")&doc=plan" "$BATS_TEST_TMPDIR/actions.html"
  stop_gui

  grep -q "/task/gui-task/review" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "/task/gui-task/prototype" "$BATS_TEST_TMPDIR/actions.html"
  grep -q "Run Review first: this task has no review.md" "$BATS_TEST_TMPDIR/actions.html"
  grep -q "/task/gui-task/archive" "$BATS_TEST_TMPDIR/actions.html"
  grep -q "approve=implementation" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "/task/gui-task/implement" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q ">Open<" "$BATS_TEST_TMPDIR/actions.html"
  grep -q ">Review<" "$BATS_TEST_TMPDIR/actions.html"
  grep -q ">Use as Prototype<" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "Use as Prototype gui-task" "$BATS_TEST_TMPDIR/actions.html"
  grep -q ">Archive<" "$BATS_TEST_TMPDIR/actions.html"
  grep -q ">Approve Implementation<" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q ">Implement<" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "Start review" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "Start prototype" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "Archive task" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "Start edit" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "Start implement" "$BATS_TEST_TMPDIR/actions.html"
  ! grep -q "<label>Type gui-task" "$BATS_TEST_TMPDIR/actions.html"
  grep -q "Are you sure?" "$BATS_TEST_TMPDIR/actions.html"
}

@test "paw gui: starts review and prototype through paw actions" {
  local port=18787 path
  path="$(real_path "$REPO/.agent/gui-task")"
  printf '# Review\n' > "$REPO/.agent/gui-task/review.md"
  start_gui "$port"

  post_gui "$port" "/task/gui-task/review" "$(form_encode "path=$path" "extras=Threshold is B+")" "$BATS_TEST_TMPDIR/review-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "PAW:IMPLEMENT" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "Threshold is B+" "$BATS_TEST_TMPDIR/backend.prompt"
  rm -f "$BATS_TEST_TMPDIR/backend.prompt"
  # The stub does not author reviews. Supply completed evidence for the next action.
  python3 - "$REPO/.agent/gui-task" "$REPO_ROOT/scripts" <<'PY_REVIEW'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[2]) / 'lib'))
import review_record
path = Path(sys.argv[1])
text = (path / 'review.md').read_text().replace('pending', 'assessed').replace('- Grade: assessed', '- Grade: B+').replace('- Quality Threshold: assessed', '- Quality Threshold: B+').replace('- Threshold Result: assessed', '- Threshold Result: met').replace('- Completion: assessed', '- Completion: complete').replace('- Pending.', '- None.')
(path / 'review.md').write_text(text)
review_record.finish(path, 'gui-task')
PY_REVIEW

  post_gui "$port" "/task/gui-task/prototype" "$(form_encode "path=$path" "extras=Use the review as source")" "$BATS_TEST_TMPDIR/prototype-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -q "PAW:PLAN" "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q "Use the review as source" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw gui: blocks review prototype archive delete while task is running" {
  local port=18788 path
  path="$(real_path "$REPO/.agent/gui-task")"
  mkdir -p "$REPO/.agent/gui-task/runs"
  git config --file "$REPO/.agent/gui-task/runs/running.gitconfig" paw.status running
  start_gui "$port"

  post_gui "$port" "/task/gui-task/review" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/review-running.html"
  post_gui "$port" "/task/gui-task/prototype" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/prototype-running.html"
  post_gui "$port" "/task/gui-task/archive" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/archive-running.html"
  post_gui "$port" "/task/gui-task/delete" "$(form_encode "path=$path" "confirm=yes")" "$BATS_TEST_TMPDIR/delete-running.html"
  stop_gui

  grep -q "already has a running PAW subprocess" "$BATS_TEST_TMPDIR/review-running.html"
  grep -q "already has a running PAW subprocess" "$BATS_TEST_TMPDIR/prototype-running.html"
  grep -q "already has a running PAW subprocess" "$BATS_TEST_TMPDIR/archive-running.html"
  grep -q "delete blocked while a PAW subprocess is running" "$BATS_TEST_TMPDIR/delete-running.html"
}

@test "paw gui: blocks implement when follow-up placeholders remain" {
  cat >> "$REPO/.agent/gui-task/plan.md" <<'MD'

## Open Questions / Follow-Ups

- What should happen?
  - USER ANSWER (UNRESOLVED):
MD
  local port=18771 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"

  post_gui "$port" "/task/gui-task/implement" "$(form_encode "path=$path")" "$BATS_TEST_TMPDIR/implement-placeholder.html"
  stop_gui

  grep -q "implement blocked: reconcile USER ANSWER placeholders first" "$BATS_TEST_TMPDIR/implement-placeholder.html"
  [[ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]]
}

@test "paw gui: deletes a central task only with confirmation and listed path" {
  git -C "$REPO" init -q
  local central
  central="$(bash -c 'source "$1"; paw_task_create_dir "$2" delete-me' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  mkdir -p "$central"
  cat > "$central/plan.md" <<'MD'
# Delete Me
MD
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" delete-me created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$central" "$REPO"
  central="$(real_path "$central")"
  local port=18772
  start_gui "$port"

  post_gui "$port" "/task/delete-me/delete" "$(form_encode "path=$central" "confirm=wrong")" "$BATS_TEST_TMPDIR/delete-reject.html"
  [[ -d "$central" ]]
  post_gui "$port" "/task/delete-me/delete" "$(form_encode "path=/tmp/delete-me" "confirm=yes")" "$BATS_TEST_TMPDIR/delete-stale.html"
  [[ -d "$central" ]]
  post_gui "$port" "/task/delete-me/delete" "$(form_encode "path=$central" "confirm=yes")" "$BATS_TEST_TMPDIR/delete-ok.html"
  stop_gui

  grep -q "delete confirmation is required" "$BATS_TEST_TMPDIR/delete-reject.html"
  grep -q "delete rejected: stale task path" "$BATS_TEST_TMPDIR/delete-stale.html"
  [[ ! -d "$central" ]]
}

@test "paw gui: archive action moves central task out of active dashboard" {
  git -C "$REPO" init -q
  local central
  central="$(bash -c 'source "$1"; paw_task_create_dir "$2" archive-me' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  mkdir -p "$central"
  cat > "$central/plan.md" <<'MD'
# Archive Me
MD
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" archive-me created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$central" "$REPO"
  central="$(real_path "$central")"
  local port=18789
  start_gui "$port"

  post_gui "$port" "/task/archive-me/archive" "$(form_encode "path=$central")" "$BATS_TEST_TMPDIR/archive-post.html"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ ! -d "$central" ]] && break
    sleep 0.2
  done
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/archive-index.html"
  stop_gui

  [[ ! -d "$central" ]]
  find "$PAW_TASK_HOME" -path "*/.archive/archive-me" -type d -print -quit | grep -q "archive-me"
  ! grep -q "archive-me" "$BATS_TEST_TMPDIR/archive-index.html"
}

@test "paw gui: archived dashboard lists central archives and unarchives safely" {
  git -C "$REPO" init -q
  local central archived port=18766
  central="$(bash -c 'source "$1"; paw_task_create_dir "$2" archived-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  archived="$(bash -c 'source "$1"; paw_task_archive_dir "$2" archived-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  mkdir -p "$archived"
  cat > "$archived/plan.md" <<'MD'
# Archived Task

## Current Status

- Plan position: Archived.
- Estimated completion: 25%
- Next work: Restore.
MD
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" archived-task created ""; git config --file "$2/metadata.gitconfig" paw.archived-at "2026-01-01T00:00:00Z"' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$archived" "$REPO"
  archived="$(real_path "$archived")"
  start_gui "$port"

  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/archive-active-index.html"
  fetch_gui "$port" "/archive" "$BATS_TEST_TMPDIR/archive-dashboard.html"
  post_gui "$port" "/archive/archived-task/unarchive" "$(form_encode "path=$archived")" "$BATS_TEST_TMPDIR/unarchive-post.html"
  stop_gui

  grep -q "Archived" "$BATS_TEST_TMPDIR/archive-active-index.html"
  ! grep -q "archived-task" "$BATS_TEST_TMPDIR/archive-active-index.html"
  grep -q "Archived Tasks" "$BATS_TEST_TMPDIR/archive-dashboard.html"
  grep -q "archived-task" "$BATS_TEST_TMPDIR/archive-dashboard.html"
  grep -q "/archive/archived-task/unarchive" "$BATS_TEST_TMPDIR/archive-dashboard.html"
  grep -q ">Unarchive<" "$BATS_TEST_TMPDIR/archive-dashboard.html"
  grep -q "unarchived task archived-task" "$BATS_TEST_TMPDIR/unarchive-post.html"
  [[ -d "$central" ]]
  [[ ! -d "$archived" ]]
}

@test "paw gui: archived dashboard empty state and unarchive conflict are clear" {
  git -C "$REPO" init -q
  local archived active port=18759
  archived="$(bash -c 'source "$1"; paw_task_archive_dir "$2" conflict-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  active="$(bash -c 'source "$1"; paw_task_create_dir "$2" conflict-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  mkdir -p "$archived" "$active"
  printf '# Archived\n' > "$archived/plan.md"
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" conflict-task created ""; paw_task_write_metadata "$4" "$3" conflict-task created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$archived" "$REPO" "$active"
  archived="$(real_path "$archived")"
  start_gui "$port"

  post_gui "$port" "/archive/conflict-task/unarchive" "$(form_encode "path=$archived")" "$BATS_TEST_TMPDIR/unarchive-conflict.html"
  rm -rf "$archived"
  fetch_gui "$port" "/archive" "$BATS_TEST_TMPDIR/archive-empty.html"
  stop_gui

  grep -q "unarchive blocked: active task already exists for conflict-task" "$BATS_TEST_TMPDIR/unarchive-conflict.html"
  grep -q "No archived task packages found." "$BATS_TEST_TMPDIR/archive-empty.html"
}

@test "paw gui: shows prototype lineage marker in index and detail" {
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.prototype-status planned-source-reverted
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.prototype-source source-task
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.prototype-cleanup-message "source cleanup completed"
  local port=18790 path
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/prototype-index.html"
  fetch_gui "$port" "/task/gui-task?path=$(url_encode "$path")&doc=plan" "$BATS_TEST_TMPDIR/prototype-detail.html"
  stop_gui

  grep -q "Details / lineage" "$BATS_TEST_TMPDIR/prototype-index.html"
  ! grep -q "source cleanup completed" "$BATS_TEST_TMPDIR/prototype-index.html"
  grep -q "<th>Prototype</th>" "$BATS_TEST_TMPDIR/prototype-detail.html"
  grep -q "planned-source-reverted from source-task" "$BATS_TEST_TMPDIR/prototype-detail.html"
  grep -q "<th>Prototype Cleanup</th>" "$BATS_TEST_TMPDIR/prototype-detail.html"
  grep -q "source cleanup completed" "$BATS_TEST_TMPDIR/prototype-detail.html"
}

@test "paw gui: deletes a legacy task only with confirmation" {
  local path port=18773
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"

  post_gui "$port" "/task/gui-task/delete" "$(form_encode "path=$path" "confirm=yes")" "$BATS_TEST_TMPDIR/delete-legacy.html"
  stop_gui

  [[ ! -d "$path" ]]
  grep -q "deleted task gui-task" "$BATS_TEST_TMPDIR/delete-legacy.html"
}

@test "paw gui start: launches background dashboard and records metadata" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"

  run "$PAW" gui start --repo "$REPO" --port 0

  [ "$status" -eq 0 ]
  [[ "$output" == "paw gui: http://127.0.0.1:"* ]]
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  [ -f "$meta" ]
  local url
  url="$(git config --file "$meta" --get paw.url)"
  [[ "$url" == "http://127.0.0.1:"* ]]
  [[ "$(git config --file "$meta" --get paw.port)" != "0" ]]
  git config --file "$meta" --get paw.pid > "$BATS_TEST_TMPDIR/gui.pid"

  python3 - "$url" > "$BATS_TEST_TMPDIR/page.html" <<'PY'
import sys
from urllib.request import urlopen
print(urlopen(sys.argv[1], timeout=2).read().decode())
PY

  grep -q "gui-task" "$BATS_TEST_TMPDIR/page.html"

  "$PAW" gui kill >/dev/null 2>&1 || true
}

@test "paw gui start: explicit port zero still requests an ephemeral port" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"

  run "$PAW" gui start --repo "$REPO" --port 0

  [ "$status" -eq 0 ]
  [[ "$output" == *"paw gui: http://127.0.0.1:"* ]]
  [[ "$output" != "paw gui: http://127.0.0.1:8765/" ]]
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  [ -f "$meta" ]
  [[ "$(git config --file "$meta" --get paw.port)" != "0" ]]

  "$PAW" gui kill >/dev/null 2>&1 || true
}

@test "paw gui start: refuses to overwrite an active recorded process" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"

  run "$PAW" gui start --repo "$REPO" --port 0
  [ "$status" -eq 0 ]

  run "$PAW" gui start --repo "$REPO" --port 0

  [ "$status" -eq 1 ]
  [[ "$output" == *"already running"* ]]

  "$PAW" gui kill >/dev/null 2>&1 || true
}

@test "paw gui restart: replaces active recorded dashboard and preserves mode metadata" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  git -C "$REPO" init -q

  "$PAW" gui start --repo "$REPO" --port 0 --all >/dev/null
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  local first_pid first_port
  first_pid="$(git config --file "$meta" --get paw.pid)"
  first_port="$(git config --file "$meta" --get paw.port)"

  run "$PAW" gui restart

  [ "$status" -eq 0 ]
  [[ "$output" == *"restarted"* ]]
  local second_pid
  second_pid="$(git config --file "$meta" --get paw.pid)"
  [[ "$second_pid" != "$first_pid" ]]
  [[ "$(git config --file "$meta" --get paw.port)" == "$first_port" ]]
  [[ "$(git config --file "$meta" --get paw.repo-path)" == "$(real_path "$REPO")" ]]
  [[ "$(git config --file "$meta" --get paw.all-repos)" == "1" ]]
  ! kill -0 "$first_pid" 2>/dev/null
  kill -0 "$second_pid"

  "$PAW" gui kill >/dev/null 2>&1 || true
}

@test "paw gui restart: without active metadata starts a managed dashboard" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"

  run "$PAW" gui restart --repo "$REPO" --port 0

  [ "$status" -eq 0 ]
  [[ "$output" == *"paw gui: http://127.0.0.1:"* ]]
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  [ -f "$meta" ]
  kill -0 "$(git config --file "$meta" --get paw.pid)"

  "$PAW" gui kill >/dev/null 2>&1 || true
}

@test "paw gui stop: gracefully stops recorded dashboard and is idempotent" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  "$PAW" gui start --repo "$REPO" --port 0 >/dev/null

  run "$PAW" gui stop

  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped"* ]]
  [ ! -f "$XDG_STATE_HOME/paw/gui/active.gitconfig" ]

  run "$PAW" gui stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"no recorded GUI process"* ]]
}

@test "paw gui kill: force-stops recorded dashboard" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  "$PAW" gui start --repo "$REPO" --port 0 >/dev/null

  run "$PAW" gui kill

  [ "$status" -eq 0 ]
  [[ "$output" == *"killed"* ]]
  [ ! -f "$XDG_STATE_HOME/paw/gui/active.gitconfig" ]
}

@test "paw gui stop: cleans stale pid metadata" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$XDG_STATE_HOME/paw/gui"
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  git config --file "$meta" paw.pid 999999
  git config --file "$meta" paw.url "http://127.0.0.1:9/"

  run "$PAW" gui stop

  [ "$status" -eq 0 ]
  [[ "$output" == *"no recorded GUI process"* ]]
  [ ! -f "$meta" ]
}

@test "paw gui stop: does not stop unrelated recorded pid" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$XDG_STATE_HOME/paw/gui"
  sleep 30 &
  local sleeper="$!"
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  git config --file "$meta" paw.pid "$sleeper"
  git config --file "$meta" paw.url "http://127.0.0.1:9/"

  run "$PAW" gui stop

  [ "$status" -eq 0 ]
  [[ "$output" == *"no recorded GUI process"* ]]
  kill -0 "$sleeper"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
}

@test "paw gui --all: shows central tasks from multiple repos without name collisions" {
  local repo_two="$BATS_TEST_TMPDIR/repo-two"
  mkdir -p "$repo_two"
  git -C "$REPO" init -q
  git -C "$repo_two" init -q

  local central_one central_two
  central_one="$(bash -c 'source "$1"; paw_task_create_dir "$2" shared-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  central_two="$(bash -c 'source "$1"; paw_task_create_dir "$2" shared-task' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$repo_two")"
  mkdir -p "$central_one" "$central_two"
  cat > "$central_one/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Repo one task.
- Estimated completion: 10%
- Next work: One.
MD
  cat > "$central_two/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: Repo two task.
- Estimated completion: 20%
- Next work: Two.
MD
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" shared-task created ""; paw_task_write_metadata "$4" "$5" shared-task created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$central_one" "$REPO" "$central_two" "$repo_two"

  local port=18766
  start_gui "$port" --all
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/all.html"
  stop_gui

  grep -Fq "data-paw-key='$(real_path "$central_one")'" "$BATS_TEST_TMPDIR/all.html"
  grep -Fq "data-paw-key='$(real_path "$central_two")'" "$BATS_TEST_TMPDIR/all.html"
  grep -q "shared-task" "$BATS_TEST_TMPDIR/all.html"
  grep -q "repo-two" "$BATS_TEST_TMPDIR/all.html"
}

@test "paw gui --all: active repo selector controls Plan target only" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  local repo_two="$BATS_TEST_TMPDIR/repo-two"
  mkdir -p "$repo_two"
  git -C "$REPO" init -q
  git -C "$repo_two" init -q
  local central_one central_two
  central_one="$(bash -c 'source "$1"; paw_task_create_dir "$2" all-one' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$REPO")"
  central_two="$(bash -c 'source "$1"; paw_task_create_dir "$2" all-two' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$repo_two")"
  mkdir -p "$central_one" "$central_two"
  cat > "$central_one/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: All repo one.
- Estimated completion: 10%
- Next work: One.
MD
  cat > "$central_two/plan.md" <<'MD'
# Plan

## Current Status

- Plan position: All repo two.
- Estimated completion: 20%
- Next work: Two.
MD
  bash -c 'source "$1"; paw_task_write_metadata "$2" "$3" all-one created ""; paw_task_write_metadata "$4" "$5" all-two created ""' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$central_one" "$REPO" "$central_two" "$repo_two"
  local port=18798 repo_two_path encoded_repo_two created
  repo_two_path="$(real_path "$repo_two")"
  encoded_repo_two="$(url_encode "$repo_two_path")"
  created="$(bash -c 'source "$1"; paw_task_create_dir "$2" all-selected-plan' _ "$REPO_ROOT/scripts/lib/task_store.sh" "$repo_two")"
  start_gui "$port" --all

  post_gui "$port" "/actions/repos/add" "$(form_encode "repo_path=$repo_two_path")" "$BATS_TEST_TMPDIR/all-add-post.html"
  fetch_gui "$port" "/?active_repo=$encoded_repo_two" "$BATS_TEST_TMPDIR/all-active-index.html"
  post_gui "$port" "/actions/plan" "$(form_encode "active_repo=$repo_two_path" "task_name=all-selected-plan" "prompt=Plan from all mode")" "$BATS_TEST_TMPDIR/all-plan-post.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  stop_gui

  grep -Fq "data-paw-key='$(real_path "$central_one")'" "$BATS_TEST_TMPDIR/all-active-index.html"
  grep -Fq "data-paw-key='$(real_path "$central_two")'" "$BATS_TEST_TMPDIR/all-active-index.html"
  grep -q "Repo filter" "$BATS_TEST_TMPDIR/all-active-index.html"
  grep -q "name=\"active_repo\"" "$BATS_TEST_TMPDIR/all-active-index.html"
  grep -q "Plan from all mode" "$BATS_TEST_TMPDIR/backend.prompt"
  [ -f "$created/metadata.gitconfig" ]
  git config --file "$created/metadata.gitconfig" --get paw.repo-root | grep -Fx "$repo_two_path"
}

@test "paw gui: edits queued prompt and task name before triggering" {
  git -C "$REPO" init -q
  local port=18810
  start_gui "$port"
  post_gui "$port" /actions/plan "$(form_encode plan_action=queue task_name=before prompt=Original)" "$BATS_TEST_TMPDIR/post.html"
  post_gui "$port" /actions/queue/edit "$(form_encode original_task_name=before task_name=after 'prompt=Edited prompt')" "$BATS_TEST_TMPDIR/edit.html"
  grep -q 'updated queued plan after' "$BATS_TEST_TMPDIR/edit.html"
  [[ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]]
  fetch_gui "$port" / "$BATS_TEST_TMPDIR/index.html"
  grep -q "action='/actions/queue/edit'" "$BATS_TEST_TMPDIR/index.html"
  grep -q 'Edited prompt' "$BATS_TEST_TMPDIR/index.html"
  post_gui "$port" /actions/queue/trigger "$(form_encode task_name=after)" "$BATS_TEST_TMPDIR/trigger.html"
  wait_for_file "$BATS_TEST_TMPDIR/backend.prompt"
  grep -q 'Edited prompt' "$BATS_TEST_TMPDIR/backend.prompt"
  find "$PAW_TASK_HOME" -path '*/after/plan.md' -print -quit | grep -q after
  [[ -z "$(find "$PAW_TASK_HOME" -path '*/.queue/*/prompt.txt' -print)" ]]
}

@test "paw gui: displays complete escaped multiline queued prompts" {
  git -C "$REPO" init -q
  local port=18811 prompt
  prompt="$(python3 -c 'print("Long prompt " * 30 + "\n  <script>tail & text</script>")')"
  start_gui "$port"
  post_gui "$port" /actions/plan "$(form_encode plan_action=queue task_name=long "prompt=$prompt")" "$BATS_TEST_TMPDIR/post.html"
  fetch_gui "$port" / "$BATS_TEST_TMPDIR/index.html"
  python3 - "$BATS_TEST_TMPDIR/index.html" "$prompt" <<'PY'
import html, pathlib, sys
page = pathlib.Path(sys.argv[1]).read_text()
assert "<pre class='queued-prompt'>" + html.escape(sys.argv[2]) + "\n</pre>" in page
assert '<script>tail' not in page
assert 'white-space:pre-wrap' in page
PY
}

@test "paw gui: rejects invalid queued edits without changing saved prompts" {
  git -C "$REPO" init -q
  local port=18812 name prompt original expected
  start_gui "$port"
  post_gui "$port" /actions/plan "$(form_encode plan_action=queue task_name=original prompt=Original)" "$BATS_TEST_TMPDIR/post.html"
  post_gui "$port" /actions/plan "$(form_encode plan_action=queue task_name=occupied prompt=Occupied)" "$BATS_TEST_TMPDIR/post.html"
  while IFS='|' read -r original name prompt expected; do
    post_gui "$port" /actions/queue/edit "$(form_encode "original_task_name=$original" "task_name=$name" "prompt=$prompt")" "$BATS_TEST_TMPDIR/error.html"
    grep -q "$expected" "$BATS_TEST_TMPDIR/error.html"
  done <<'CASES'
original|../invalid|Changed|invalid task name
../invalid|valid|Changed|invalid task name
original|original|   |prompt is required
missing|valid|Changed|queued plan prompt not found
original|occupied|Changed|already exists for occupied
CASES
  local queue_root
  queue_root="$(find "$PAW_TASK_HOME" -type d -name .queue -print -quit)"
  [[ "$(cat "$queue_root/original/prompt.txt")" == Original ]]
  [[ "$(cat "$queue_root/occupied/prompt.txt")" == Occupied ]]
  post_gui "$port" /actions/queue/edit "$(form_encode original_task_name=original task_name=original 'prompt=Same name edited')" "$BATS_TEST_TMPDIR/edit.html"
  [[ "$(cat "$queue_root/original/prompt.txt")" == 'Same name edited' ]]
  post_gui "$port" /actions/queue/delete "$(form_encode task_name=original)" "$BATS_TEST_TMPDIR/delete.html"
  grep -q 'removed queued plan original' "$BATS_TEST_TMPDIR/delete.html"
  [[ ! -d "$queue_root/original" ]]
  [[ ! -f "$BATS_TEST_TMPDIR/backend.prompt" ]]
}

@test "paw gui: failed queued saves and launches retain the original prompt" {
  python3 - "$REPO_ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('gui_server', Path(sys.argv[1]) / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gui
spec.loader.exec_module(gui)
root = Path(sys.argv[2])
home, repo = root / 'tasks', root / 'repo'
gui.write_queued_plan(home, repo, 'original', 'Original')
item = gui.queue_item_dir(home, repo, 'original')
with patch.object(gui.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'git')):
    try:
        gui.update_queued_plan(home, repo, 'original', 'renamed', 'Changed')
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError('expected metadata write failure')
assert (item / 'prompt.txt').read_text() == 'Original\n'
assert not gui.queue_item_dir(home, repo, 'renamed').exists()
with patch.object(Path, 'replace', side_effect=OSError('disk write failure')):
    try:
        gui.update_queued_plan(home, repo, 'original', 'original', 'Changed')
    except OSError:
        pass
    else:
        raise AssertionError('expected prompt replacement failure')
assert (item / 'prompt.txt').read_text() == 'Original\n'
gui.update_queued_plan(home, repo, 'original', 'renamed', 'Edited')
handler = gui.Handler.__new__(gui.Handler)
handler.task_home = home
handler.repo = repo
handler.form_data = lambda: {'task_name': 'renamed'}
handler.selected_repo = lambda _: (repo, '')
redirects = []
handler.redirect = redirects.append
with patch.object(gui, 'launch_paw', return_value=(False, 'start failed')):
    handler.post_queue_trigger()
assert gui.queue_item_dir(home, repo, 'renamed').joinpath('prompt.txt').read_text() == 'Edited'
from urllib.parse import parse_qs, urlparse
assert parse_qs(urlparse(redirects[0]).query)['message'] == ['start failed']
PY
}

@test "paw gui: prototype journey behavior regressions" {
  python3 "$REPO_ROOT/tests/gui-prototype.py"
}

@test "paw gui: recorded validation behavior regressions" {
  python3 "$REPO_ROOT/tests/gui-validation.py"
}

@test "paw gui: asynchronous actions return structured acceptance and errors without redirects" {
  local port=18890
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/page.html"
  python3 - "$port" "$REPO" <<'PY'
import json
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
port, repo = sys.argv[1:]

def post(path, data):
    request = Request(f'http://127.0.0.1:{port}{path}', urlencode(data).encode(),
                      {'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        response = urlopen(request)
    except HTTPError as error:
        response = error
    assert response.headers.get_content_type() == 'application/json', response.headers
    return response.status, json.load(response)

status, result = post('/actions/plan', {'task_name': 'queued-inline', 'prompt': 'Full prompt', 'plan_action': 'queue'})
assert status == 200 and result['ok'] is True and 'queued plan prompt' in result['message'], result
status, result = post('/actions/plan', {'task_name': '../bad', 'prompt': 'Bad'})
assert status == 200 and result['ok'] is False and 'invalid task name' in result['message'], result
status, result = post('/task/missing/edit', {'path': repo + '/.agent/missing'})
assert status == 404 and result['ok'] is False and 'Task not found' in result['message'], result
PY
}

@test "paw gui: dashboard fallback preserves only validated local filter context" {
  local port=18891
  start_gui "$port"
  fetch_gui "$port" "/?repo=needle&state=ready&completion=50%25" "$BATS_TEST_TMPDIR/page.html"
  python3 - "$port" <<'PY'
import sys
from urllib.parse import urlencode, urlparse, parse_qs
from urllib.request import Request, urlopen
base = f'http://127.0.0.1:{sys.argv[1]}'
for target in ('/?repo=needle&state=ready&completion=50%25', 'https://example.com/?repo=foreign', '//example.com/'):
    data = urlencode({'task_name': '../invalid', 'prompt': 'draft', 'dashboard_return': target}).encode()
    response = urlopen(Request(base + '/actions/plan', data))
    url = urlparse(response.url)
    query = parse_qs(url.query)
    assert url.netloc == f'127.0.0.1:{sys.argv[1]}' and url.path == '/'
    if target.startswith('/?'):
        assert query['repo'] == ['needle'] and query['state'] == ['ready'] and query['completion'] == ['50%'], query
    else:
        assert 'repo' not in query, query
    assert 'invalid task name' in query['message'][0]
response = urlopen(Request(base + '/task/missing/edit', urlencode({'dashboard_return': '/?repo=needle'}).encode()))
query = parse_qs(urlparse(response.url).query)
assert query['repo'] == ['needle'] and 'Task not found' in query['message'][0], query
PY
}

@test "paw gui: inline action protocol retains guards and task identity in scoped and all-repo modes" {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import importlib.util
import json
import os
import subprocess
import sys
import threading
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

root, temporary = (Path(value).resolve() for value in sys.argv[1:])
spec = importlib.util.spec_from_file_location('gui', root / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec)
sys.modules['gui'] = gui
spec.loader.exec_module(gui)
plan = '# Plan\n## Current Status\n- Estimated completion: 0%\n- Next work: Implement.\n'

for all_repos in (False, True):
    base = temporary / str(all_repos)
    repo, other, task_home = base / 'repo', base / 'other', base / 'tasks'
    for directory in (repo, other):
        directory.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(directory)], check=True)
    class Handler(gui.Handler):
        def log_message(self, *args):
            pass
    Handler.repo = repo.resolve()
    Handler.task_home = task_home.resolve()
    Handler.all_repos = all_repos
    Handler.repo_registry = base / 'registry.gitconfig'
    gui.add_repo_to_registry(Handler.repo_registry, repo, other)
    def task(name, owner=repo):
        path = task_home / gui.repo_slug(owner) / name
        path.mkdir(parents=True, exist_ok=True)
        (path / 'plan.md').write_text(plan)
        (path / 'metadata.gitconfig').write_text(f'[paw]\nrepo-root = {owner}\n')
        return path.resolve()
    first, second = task('same'), task('same', other)
    server = gui.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    def post(action, data):
        request = Request(f'http://127.0.0.1:{server.server_port}{action}', urlencode(data, doseq=True).encode(),
                          {'Accept': 'application/json'})
        try:
            response = urlopen(request)
        except HTTPError as error:
            response = error
        assert response.headers.get_content_type() == 'application/json'
        return response.status, json.load(response)
    def action(name, verb, path, **data):
        return post(f'/task/{name}/{verb}', {'path': str(path), **data})[1]
    try:
        with patch.object(gui, 'launch_paw', return_value=(True, 'started paw (accepted)')) as launch:
            for verb in ('edit', 'review', 'implement', 'archive'):
                result = action('same', verb, first, extras='user instructions')
                assert result['ok'], (verb, result)
                assert launch.call_args.args[0] == repo
                assert launch.call_args.args[2] == first
                expected = [verb, 'same'] + (['user instructions'] if verb in ('edit', 'review') else [])
                assert launch.call_args.args[3] == expected, launch.call_args
            result = action('same', 'edit', second, extras='other repo')
            assert result['ok'] and launch.call_args.args[0] == other and launch.call_args.args[2] == second
            assert not action('same', 'prototype', first)['ok']  # missing review
            (first / 'review.md').write_text('## Review Metadata\n- Task: same\n- Grade: F\n- Scope Reviewed: task delta\n- Quality Threshold: B+\n- Threshold Result: below threshold\n\n## Blocking Production-Readiness Issues\n- None.\n')
            assert action('same', 'prototype', first, extras='prototype instructions')['ok']
            assert launch.call_args.args[3] == ['prototype', 'same', 'prototype instructions']
            (first / 'review.md').write_text('## Review Metadata\n- Task: same\n- Grade: A\n- Scope Reviewed: task delta\n- Quality Threshold: B+\n- Threshold Result: met\n\n## Blocking Production-Readiness Issues\n- None.\n')
            assert not action('same', 'prototype', first)['ok']
            (first / 'plan.md').write_text(plan + '\n- USER ANSWER (UNRESOLVED):\n')
            assert not action('same', 'implement', first)['ok']
            assert action('same', 'edit', first, answers='answer text')['ok']
            assert 'answer text' in launch.call_args.args[3][-1]
            (first / 'plan.md').write_text(plan)
            runs = first / 'runs'
            runs.mkdir()
            metadata = runs / f'20260911-run-{os.getpid()}.gitconfig'
            metadata.write_text('[paw]\nstatus = running\nsubcommand = implement\n')
            assert not action('same', 'edit', first)['ok']
            assert not action('same', 'delete', first, confirm='yes')['ok']
            with patch.object(gui, 'process_looks_like_paw', return_value=False):
                assert 'verified PAW' in action('same', 'cancel', first)['message']
            metadata.unlink()
            assert not action('same', 'delete', first)['ok']
            assert 'stale task path' in action('same', 'delete', first / 'stale')['message']
            assert post('/task/missing/edit', {'path': str(first / 'missing')})[0] == 404
            before = {str(p): p.read_bytes() for owner in (first, second) for p in owner.rglob('*') if p.is_file()}
            for verb in ('archive', 'delete'):
                for accept in ('text/html', 'application/json'):
                    request = Request(f'http://127.0.0.1:{server.server_port}/actions/selected',
                                      urlencode({'selected_action': verb, 'task': [str(first), str(second)], 'confirm': 'yes'}, doseq=True).encode(),
                                      {'Accept': accept})
                    try:
                        urlopen(request)
                        raise AssertionError('retired endpoint accepted')
                    except HTTPError as error:
                        assert error.code == 404
                    assert before == {str(p): p.read_bytes() for owner in (first, second) for p in owner.rglob('*') if p.is_file()}
            assert not list(task_home.rglob('.archive'))
            assert action('same', 'delete', first, confirm='yes')['ok']
            assert not first.exists() and second.exists()
            for verb, data, fragment in (
                ('/actions/plan', {'task_name': 'queue-me', 'prompt': 'full\ntext', 'plan_action': 'queue'}, 'queued'),
                ('/actions/queue/edit', {'original_task_name': 'queue-me', 'task_name': 'renamed', 'prompt': 'edited\ntext'}, 'updated'),
                ('/actions/queue/trigger', {'task_name': 'renamed'}, 'triggered'),
            ):
                result = post(verb, data)[1]
                assert result['ok'] and fragment in result['message'], result
            assert launch.call_args.args[3] == ['plan', 'renamed', 'edited\ntext']
            assert not post('/actions/queue/trigger', {'task_name': 'renamed'})[1]['ok']
            assert post('/actions/plan', {'task_name': 'remove-me', 'prompt': 'remove', 'plan_action': 'queue'})[1]['ok']
            assert post('/actions/queue/delete', {'task_name': 'remove-me'})[1]['ok']
            assert not post('/actions/queue/edit', {'original_task_name': 'missing', 'task_name': 'x', 'prompt': 'y'})[1]['ok']
            result = post('/actions/repos/add', {'repo_path': str(other)})[1]
            assert result['ok'] and result['active_repo'] == str(other)
            assert not post('/actions/repos/add', {'repo_path': str(base / 'missing')})[1]['ok']
            pr_task = task('pr')
            real_run = subprocess.run
            gh_result = subprocess.CompletedProcess([], 0, 'https://example.test/pr/1', '')
            def run_command(args, **kwargs):
                return gh_result if args[0] == 'gh' else real_run(args, **kwargs)
            with patch.object(gui, 'view_pr_branch', return_value='branch'), patch.object(gui.subprocess, 'run', side_effect=run_command):
                result = action('pr', 'view-pr', pr_task)
                assert result['ok'] and result['link'] == 'https://example.test/pr/1'
                response = urlopen(Request(f'http://127.0.0.1:{server.server_port}/task/pr/view-pr',
                                           urlencode({'path': str(pr_task), 'dashboard_return': '/?repo=needle'}).encode()))
                assert '/?repo=needle' in response.url, response.url
                assert "href='https://example.test/pr/1'" in response.read().decode()
                gh_result = subprocess.CompletedProcess([], 0, 'javascript:alert(1)', '')
                assert not action('pr', 'view-pr', pr_task)['ok']
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
PY
}

@test "paw gui: request work bounds and freshness regressions" {
  python3 "$REPO_ROOT/tests/gui-performance.py"
}

@test "paw gui: default port is passed to foreground and background launchers" {
  run bash -c '
    source "$1"
    _cmd_gui_foreground() { printf "foreground:%s\n" "$2"; }
    _cmd_gui_start() { printf "background:%s\n" "$2"; }
    cmd_gui --repo "$2"
    cmd_gui start --repo "$2"
  ' _ "$PAW" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == $'foreground:8765\nbackground:8765' ]]
}

@test "paw gui: fixture cleanup preserves an independent ephemeral server" {
  local port=0 companion_pid companion_port
  start_gui "$port"
  companion_pid="$GUI_PID"
  GUI_COMPANION_PID="$companion_pid"
  companion_port="$port"
  start_gui "$port"
  stop_gui
  GUI_PID="$companion_pid"
  fetch_gui "$companion_port" "/" "$BATS_TEST_TMPDIR/companion.html"
  grep -q "gui-task" "$BATS_TEST_TMPDIR/companion.html"
}

@test "paw gui: compact context keeps one approval and adjacent lifecycle actions" {
  local port=0
  start_gui "$port"
  fetch_gui "$port" "/?state=ready&completion=50%25" "$BATS_TEST_TMPDIR/compact.html"
  python3 - "$BATS_TEST_TMPDIR/compact.html" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
body = Path(sys.argv[1]).read_text()
assert "data-repo-switch" in body and "data-new-plan" in body
assert "Queued Plans (0)" in body and "Destination:" in body
assert "<details class='repo-management'>" in body
assert "name='state' value='ready'" in body
assert "name='completion' value='50%'" in body
row = body.split("<tr data-paw-key=", 1)[1].split('</tr>', 1)[0]
assert row.count('approve=implementation') == 1
utilities, lifecycle = row.split("<div class='lifecycle-actions action-row'>")
assert 'approve=implementation' not in utilities.split("<div class='task-utilities action-row'>")[1]
assert lifecycle.index('/archive') < lifecycle.index('/delete')
assert "class='archive'" in lifecycle
PY
}

@test "paw gui: shared theme shell initializes before content without server preference forms" {
  local port=0
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/theme.html"
  python3 - "$BATS_TEST_TMPDIR/theme.html" <<'PYTHON'
from pathlib import Path
import sys
page = Path(sys.argv[1]).read_text()
assert page.index("localStorage.getItem('paw.gui.theme')") < page.index('<body>')
assert 'name="viewport"' in page
assert "<label class='theme-control'>Theme <select data-theme-select aria-label='Theme'>" in page
for preference in ('system', 'light', 'dark'):
    assert f"<option value='{preference}'>" in page
assert '@media(prefers-color-scheme:dark)' in page
assert '.theme-control{display:none' in page
assert "name='theme'" not in page
PYTHON
}

@test "paw gui: transient navigation messages are escaped and marked on every route" {
  local port=0
  start_gui "$port"
  for route in / /archive /task/gui-task; do
    for level in notice error; do
      fetch_gui "$port" "$route?message=%3Cscript%3Ealert(1)%3C%2Fscript%3E&level=$level" "$BATS_TEST_TMPDIR/message.html"
      python3 - "$BATS_TEST_TMPDIR/message.html" "$level" <<'PYTHON'
import sys
from pathlib import Path
page = Path(sys.argv[1]).read_text()
kind = 'flash-error' if sys.argv[2] == 'error' else 'flash'
assert f"<p class='{kind}' data-transient-message role='status'>&lt;script&gt;alert(1)&lt;/script&gt;" in page
assert "<button type='button' data-message-dismiss aria-label='Dismiss message'></button>" in page
assert '<script>alert(1)</script>' not in page
PYTHON
    done
  done
}

@test "paw gui: history selects exact completed run through native and fragment routes" {
  local port=0
  local runs="$REPO/.agent/gui-task/runs"
  mkdir -p "$runs"
  for id in old new; do
    printf '[paw]\nstatus = completed\nsubcommand = implement\nstdout-log = %s.stdout.log\nstderr-log = %s.stderr.log\n' "$id" "$id" > "$runs/20260912-gui-$id.gitconfig"
    printf '%s <saved> output\n' "$id" > "$runs/$id.stdout.log"
  done
  start_gui "$port"
  fetch_gui "$port" '/task/gui-task?doc=contract&run=20260912-gui-old.gitconfig' "$BATS_TEST_TMPDIR/history.html"
  grep -q 'old &lt;saved&gt; output' "$BATS_TEST_TMPDIR/history.html"
  ! grep -q 'new &lt;saved&gt; output' "$BATS_TEST_TMPDIR/history.html"
  grep -q 'Close logs' "$BATS_TEST_TMPDIR/history.html"
  grep -q 'doc=contract.*run=20260912-gui-old.gitconfig' "$BATS_TEST_TMPDIR/history.html"
  fetch_gui "$port" '/fragments/task/gui-task?doc=contract&run=20260912-gui-old.gitconfig' "$BATS_TEST_TMPDIR/history-fragment.html"
  grep -q 'old &lt;saved&gt; output' "$BATS_TEST_TMPDIR/history-fragment.html"
  rm "$runs/20260912-gui-old.gitconfig"
  fetch_gui "$port" '/fragments/task/gui-task?run=20260912-gui-old.gitconfig' "$BATS_TEST_TMPDIR/deleted.html"
  grep -q 'Selected run unavailable' "$BATS_TEST_TMPDIR/deleted.html"
  ! grep -q 'new &lt;saved&gt; output' "$BATS_TEST_TMPDIR/deleted.html"
}

@test "paw gui: history launch references survive terminal updates and launch failure" {
  python3 - "$REPO_ROOT" "$REPO" <<'PY'
import importlib.util, sys
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('gui', Path(sys.argv[1]) / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec); sys.modules[spec.name] = gui; spec.loader.exec_module(gui)
repo = Path(sys.argv[2]); task = repo / '.agent/gui-task'
class Process:
    pid = 99999999
    def wait(self): return 0
class Thread:
    def __init__(self, **kwargs): pass
    def start(self): pass
for failure in (False, True):
    with patch.object(gui.subprocess, 'Popen', side_effect=OSError('fixture') if failure else None, return_value=Process()), patch.object(gui.threading, 'Thread', Thread), patch.object(gui.subprocess, 'run', wraps=__import__('subprocess').run):
        # Popen is also used by subprocess.run; persist metadata with a simple fixture writer.
        def config(args, **kwargs):
            path = Path(args[3]); key, value = args[4][4:], args[5]
            with path.open('a') as f: f.write(('[paw]\n' if path.stat().st_size == 0 else '') + key + ' = "' + value + '"\n')
        with patch.object(gui.subprocess, 'run', side_effect=config):
            ok, _ = gui.launch_paw(repo, repo / 'tasks', task, ['implement', task.name])
            assert ok != failure
    meta = max((task / 'runs').glob('*.gitconfig'), key=lambda p: p.stat().st_mtime_ns)
    refs = [gui.metadata_value(meta, stream + '-log') for stream in ('stdout', 'stderr')]
    assert all(refs), refs
    assert all((meta.parent / ref).is_file() and Path(ref).name == ref for ref in refs)
    if not failure:
        for code, state in ((0, 'completed'), (1, 'failed')):
            process = Process(); process.wait = lambda: code
            gui.finish_gui_run(process, meta)
            assert gui.metadata_value(meta, 'status') == state
            assert refs == [gui.metadata_value(meta, s + '-log') for s in ('stdout', 'stderr')]
        __import__('subprocess').run(['git','config','--file',str(meta),'paw.status','cancelled'], check=True)
        gui.finish_gui_run(Process(), meta)
        assert gui.metadata_value(meta,'status') == 'cancelled'
        assert refs == [gui.metadata_value(meta, s + '-log') for s in ('stdout', 'stderr')]
PY
}

@test "paw gui: history legacy matching rejects ambiguous or insufficient evidence" {
  python3 - "$REPO_ROOT" "$REPO" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('gui', Path(sys.argv[1]) / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec); sys.modules[spec.name] = gui; spec.loader.exec_module(gui)
task = (Path(sys.argv[2]) / '.agent/gui-task').resolve(); runs = task / 'runs'; runs.mkdir()
meta = runs / '20260912T120000Z-gui-1-99999999.gitconfig'
body = '[paw]\nstatus = completed\nsubcommand = implement\nstart-time = 2026-09-12T12:00:00Z\n'
meta.write_text(body)
out = runs / '20260912T120000Z-gui-1-1-implement-gui-task.stdout.log'; out.write_text('legacy unique')
assert gui.history_logs(task, meta.name)[0].stdout == out
other = runs / '20260912T120000Z-gui-2-99999999.gitconfig'; other.write_text(body)
assert not gui.history_logs(task, meta.name)[0].available
other.write_text(body.replace('2026-09-12T12:00:00Z','2026-09-12T11:59:59Z'))
assert not gui.history_logs(task, meta.name)[0].available, 'overlap without end is ambiguous'
other.unlink()
second = out.with_name(out.name.replace('-1-1-', '-2-2-')); second.write_text('competing')
assert not gui.history_logs(task, meta.name)[0].available
second.unlink()
for start in ('', 'invalid', '2026-09-12T12:00:01Z'):
    meta.write_text(body.replace('2026-09-12T12:00:00Z', start))
    assert not gui.history_logs(task, meta.name)[0].available
meta.write_text(body + 'stdout-log = ../invalid\n')
assert not gui.history_logs(task, meta.name)[0].available, 'invalid explicit reference must not fall back'
meta.write_text(body + 'end-time = 2026-09-12T11:59:00Z\n')
assert not gui.history_logs(task, meta.name)[0].available, 'reversed time interval'
meta.write_text(body); other.write_text('[paw]\nstatus=completed\n')
assert not gui.history_logs(task, meta.name)[0].available, 'unknown competing GUI operation'
other.unlink()
meta.write_text(body); out.unlink(); err = out.with_name(out.name.replace('stdout','stderr')); err.write_text('only stderr')
assert gui.history_logs(task, meta.name)[0].stderr == err
assert meta.read_text() == body, 'read-only legacy resolution'
PY
}

@test "paw gui: history HTTP missing partial empty and unreadable captures stay per stream" {
  local port=0
  mkdir -p "$REPO/.agent/gui-task/runs"
  printf '[paw]\nstatus=failed\nstdout-log=out.log\nstderr-log=err.log\n' > "$REPO/.agent/gui-task/runs/one-gui-failed.gitconfig"
  touch "$REPO/.agent/gui-task/runs/out.log"
  printf '[paw]\nstatus=completed\n' > "$REPO/.agent/gui-task/runs/backend.gitconfig"
  start_gui "$port"
  fetch_gui "$port" '/task/gui-task?run=one-gui-failed.gitconfig' "$BATS_TEST_TMPDIR/partial.html"
  grep -q 'stdout (empty)' "$BATS_TEST_TMPDIR/partial.html"
  grep -q 'stderr (unavailable)' "$BATS_TEST_TMPDIR/partial.html"
  printf 'surviving stderr' > "$REPO/.agent/gui-task/runs/err.log"
  chmod 000 "$REPO/.agent/gui-task/runs/out.log"
  fetch_gui "$port" '/fragments/task/gui-task?run=one-gui-failed.gitconfig' "$BATS_TEST_TMPDIR/unreadable.html"
  chmod 600 "$REPO/.agent/gui-task/runs/out.log"
  grep -q 'stdout (unavailable)' "$BATS_TEST_TMPDIR/unreadable.html"
  grep -q 'surviving stderr' "$BATS_TEST_TMPDIR/unreadable.html"
  fetch_gui "$port" '/task/gui-task?run=backend.gitconfig' "$BATS_TEST_TMPDIR/backend.html"
  grep -q 'Unavailable: backend capture not saved' "$BATS_TEST_TMPDIR/backend.html"
  ! grep -q 'surviving stderr' "$BATS_TEST_TMPDIR/backend.html"
}

@test "paw gui: history HTTP rejects foreign selectors references symlinks and nonregular files" {
  local port=0
  mkdir -p "$REPO/.agent/gui-task/runs"
  start_gui "$port"
  python3 - "$port" "$REPO" <<'PY'
import os, sys
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen
repo = Path(sys.argv[2]); task = repo / '.agent/gui-task'; runs = task / 'runs'
foreign = repo / 'foreign'; foreign.mkdir(); (foreign / 'secret.log').write_text('FOREIGN-SECRET')
meta = runs / 'one-gui-test.gitconfig'; body = '[paw]\nstatus=completed\nstdout-log = "{}"\n'
meta.write_text(body.format('owned.log')); (runs / 'owned.log').write_text('OWNED-ONLY')
def get(selector):
    with urlopen('http://127.0.0.1:' + sys.argv[1] + '/fragments/task/gui-task?' + urlencode({'run':selector})) as r: return r.read().decode()
for selector in ('../one-gui-test.gitconfig', str(meta), 'a/../one-gui-test.gitconfig', 'bad\x00.gitconfig'):
    page = get(selector); assert 'OWNED-ONLY' not in page and 'Selected run unavailable' in page
for reference in ('../../foreign/secret.log', str(foreign / 'secret.log'), 'a/../owned.log', ''):
    meta.write_text(body.format(reference)); page = get(meta.name)
    assert 'FOREIGN-SECRET' not in page and 'OWNED-ONLY' not in page and 'stdout (unavailable)' in page
(runs / 'escape.log').symlink_to(foreign / 'secret.log')
(runs / 'folder').mkdir(); os.mkfifo(runs / 'fifo')
for reference in ('escape.log', 'folder', 'fifo'):
    meta.write_text(body.format(reference)); assert 'stdout (unavailable)' in get(meta.name)
foreign_meta = foreign / meta.name; foreign_meta.write_text(body.format('secret.log'))
meta.unlink(); meta.symlink_to(foreign_meta)
assert 'Selected run unavailable' in get(meta.name)
meta.unlink(); runs.rename(task / 'saved-runs'); runs.symlink_to(foreign, target_is_directory=True)
assert 'FOREIGN-SECRET' not in get(meta.name) and 'Selected run unavailable' in get(meta.name)
runs.unlink(); (task / 'saved-runs').rename(runs)
# A path to a same-named task outside the discovered repo cannot select its record.
other = repo / 'other/.agent/gui-task'; other.mkdir(parents=True)
(other / 'plan.md').write_text('# foreign')
try:
    urlopen('http://127.0.0.1:' + sys.argv[1] + '/task/gui-task?' + urlencode({'path': str(other), 'run': foreign_meta.name}))
    raise AssertionError('foreign task accepted')
except __import__('urllib.error', fromlist=['HTTPError']).HTTPError as exc:
    assert exc.code == 404
PY
}

@test "paw gui: history bounded tail escapes hostile output and reads only selected bodies" {
  python3 - "$REPO_ROOT" "$REPO" <<'PY'
import importlib.util, sys
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('gui', Path(sys.argv[1]) / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec); sys.modules[spec.name] = gui; spec.loader.exec_module(gui)
task = (Path(sys.argv[2]) / '.agent/gui-task').resolve(); runs = task / 'runs'; runs.mkdir()
for name in ('old', 'new'):
    (runs / (name + '-gui-test.gitconfig')).write_text('[paw]\nstdout-log = ' + name + '.log\n')
    (runs / (name + '.log')).write_bytes(b'START-OMITTED' + b'x' * 70000 + b'\xff<script>tail</script>')
h = object.__new__(gui.Handler)
with patch.object(Path, 'open', side_effect=AssertionError('history list opened log body')):
    assert 'Logs' in gui.run_rows(task, '/task/gui-task?doc=plan')
opened = []
original = Path.open
def record(path, *args, **kwargs):
    opened.append(path.name); return original(path, *args, **kwargs)
with patch.object(Path, 'open', record):
    logs, _ = gui.history_logs(task, 'old-gui-test.gitconfig')
    rendered = h.log_panel('stdout', logs.stdout)
assert opened == ['old.log'], opened
assert 'START-OMITTED' not in rendered and 'showing last 64 KiB' in rendered
assert '&lt;script&gt;tail&lt;/script&gt;' in rendered and '\ufffd' in rendered
# A file growing between stat and read still cannot exceed the byte budget.
class Growing:
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, size=-1):
        assert size == gui.LOG_TAIL_BYTES, 'tail read must have an explicit bound'
        return b'bounded'
    def seek(self, offset): pass
with patch.object(Path, 'open', return_value=Growing()):
    assert gui.tail_text(runs / 'old.log')[1].endswith('bounded')
PY
}

@test "paw gui: dashboard tools distinguish next action from secondary editing" {
  local port=0
  printf '\n- USER ANSWER (UNRESOLVED):\n' >> "$REPO/.agent/gui-task/plan.md"
  start_gui "$port"
  fetch_gui "$port" / "$BATS_TEST_TMPDIR/tools.html"
  python3 - "$BATS_TEST_TMPDIR/tools.html" <<'PY'
import sys
from html.parser import HTMLParser
class Controls(HTMLParser):
    def __init__(self):
        super().__init__(); self.edits = 0; self.tools = []; self.preview = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'form' and a.get('action', '').endswith('/edit'): self.edits += 1
        if tag == 'details' and a.get('class') == 'row-tools': self.tools.append(a)
        if 'data-doc-preview-url' in a: self.preview = 'Preview plan for gui-task' == a.get('aria-label')
p = Controls(); p.feed(open(sys.argv[1]).read())
assert p.edits == 1, 'Answer Questions must appear once, as next action'
assert len(p.tools) == 1 and p.tools[0].get('data-paw-key'), 'stable native Tools disclosure'
assert p.preview, 'descriptive task-specific preview label'
PY
}

@test "paw gui: filter recovery retains selected repo and all-repo counts" {
  local port=0
  local second="$BATS_TEST_TMPDIR/second"
  mkdir -p "$second" "$PAW_TASK_HOME/fixture/gui-task"
  git init -q "$second"
  cp "$REPO/.agent/gui-task/plan.md" "$PAW_TASK_HOME/fixture/gui-task/plan.md"
  git config --file "$PAW_TASK_HOME/fixture/gui-task/metadata.gitconfig" paw.repo-root "$(real_path "$REPO")"
  start_gui "$port" --all
  python3 - "$port" "$second" "$REPO" <<'PY'
import sys
from urllib.request import urlopen
from urllib.parse import urlencode, urlparse, parse_qs
from html.parser import HTMLParser
base = 'http://127.0.0.1:' + sys.argv[1]
# Register destination using the same local GUI boundary as normal navigation.
urlopen(base + '/actions/repos/add', urlencode({'repo_path': sys.argv[2]}).encode()).read()
query = urlencode({'active_repo':sys.argv[2], 'repo':'no-such-repo', 'state':'ready', 'completion':'50%'})
page = urlopen(base + '/?' + query).read().decode()
assert 'No tasks match these filters.' in page
assert '0 of 1 tasks' in page and 'Filters active' in page
class Links(HTMLParser):
    def __init__(self): super().__init__(); self.clear = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'a' and 'data-clear-filters' in a: self.clear.append(a['href'])
p = Links(); p.feed(page)
assert p.clear
for href in p.clear:
    assert parse_qs(urlparse(href).query) == {'active_repo':[__import__('os').path.realpath(sys.argv[2])]}
cleared = urlopen(base + p.clear[0]).read().decode()
assert '1 of 1 tasks' in cleared and 'gui-task' in cleared
assert 'All task stores' in cleared
PY
}

@test "paw gui: empty repository offers selected destination New Plan" {
  rm -r "$REPO/.agent/gui-task"
  local port=0
  start_gui "$port"
  fetch_gui "$port" / "$BATS_TEST_TMPDIR/empty.html"
  python3 - "$BATS_TEST_TMPDIR/empty.html" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert 'No task packages in this repository yet.' in s
assert 'href=\'#dashboard-controls\'' in s and 'Create a New Plan' in s
assert '0 of 0 tasks' in s
PY
}
