#!/usr/bin/env bats
# Tests for the local PAW GUI server.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PAW="$REPO_ROOT/scripts/paw"

setup() {
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
}

start_gui() {
  GUI_PORT="$1"
  "$PAW" gui --repo "$REPO" --port "$GUI_PORT" > "$BATS_TEST_TMPDIR/gui-$GUI_PORT.out" 2> "$BATS_TEST_TMPDIR/gui-$GUI_PORT.err" &
  GUI_PID="$!"
}

stop_gui() {
  if [[ -n "${GUI_PID:-}" ]]; then
    pkill -P "$GUI_PID" 2>/dev/null || true
    pkill -f "gui_server.py .*--port $GUI_PORT" 2>/dev/null || true
    kill "$GUI_PID" 2>/dev/null || true
    wait "$GUI_PID" 2>/dev/null || true
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

post_gui() {
  local port="$1" path="$2" data="$3" out="$4"
  python3 - "$port" "$path" "$data" > "$out" <<'PY'
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
}

@test "paw gui: serves local dashboard with legacy task details" {
  local port=18765
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/page.html"
  stop_gui

  grep -q "gui-task" "$BATS_TEST_TMPDIR/page.html"
  grep -q "GUI smoke" "$BATS_TEST_TMPDIR/page.html"
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
  grep -q "blocked-task" "$BATS_TEST_TMPDIR/filter-state.html"
  ! grep -q "gui-task" "$BATS_TEST_TMPDIR/filter-state.html"
  grep -q "done-task" "$BATS_TEST_TMPDIR/filter-completion.html"
  ! grep -q "blocked-task" "$BATS_TEST_TMPDIR/filter-completion.html"
  grep -q "gui-task" "$BATS_TEST_TMPDIR/filter-repo.html"
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

  "$PAW" gui --all --repo "$REPO" --port "$port" > "$BATS_TEST_TMPDIR/gui-all-sort.out" 2> "$BATS_TEST_TMPDIR/gui-all-sort.err" &
  GUI_PID="$!"
  GUI_PORT="$port"
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
  fetch_gui "$port" "/fragments/tasks" "$BATS_TEST_TMPDIR/tasks-fragment.html"
  stop_gui

  grep -q 'data-paw-refresh-url="/fragments/tasks' "$BATS_TEST_TMPDIR/refresh-index.html"
  grep -q 'data-paw-refresh-interval-ms=' "$BATS_TEST_TMPDIR/refresh-index.html"
  grep -q "fetch(refreshUrl" "$BATS_TEST_TMPDIR/refresh-index.html"
  grep -q "gui-task" "$BATS_TEST_TMPDIR/tasks-fragment.html"
  ! grep -q "<!doctype html>" "$BATS_TEST_TMPDIR/tasks-fragment.html"
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

@test "paw gui: unfinished eligible tasks can be selected for batch implement" {
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
  local port=18762 gui_path blocked_path done_path
  gui_path="$(real_path "$REPO/.agent/gui-task")"
  blocked_path="$(real_path "$REPO/.agent/blocked-task")"
  done_path="$(real_path "$REPO/.agent/done-task")"
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/batch-select.html"
  stop_gui

  grep -q "Start selected implementations" "$BATS_TEST_TMPDIR/batch-select.html"
  grep -q "name='task' value='$gui_path'" "$BATS_TEST_TMPDIR/batch-select.html"
  ! grep -q "name='task' value='$blocked_path'" "$BATS_TEST_TMPDIR/batch-select.html"
  ! grep -q "name='task' value='$done_path'" "$BATS_TEST_TMPDIR/batch-select.html"
}

@test "paw gui: repo column includes branch context and branch column is removed" {
  git config --file "$REPO/.agent/gui-task/metadata.gitconfig" paw.branch-name feature/gui-context
  local port=18763
  start_gui "$port"
  fetch_gui "$port" "/" "$BATS_TEST_TMPDIR/branch-context.html"
  stop_gui

  grep -q "feature/gui-context" "$BATS_TEST_TMPDIR/branch-context.html"
  grep -q "<th>Repo</th>" "$BATS_TEST_TMPDIR/branch-context.html"
  ! grep -q "<th>Branch</th>" "$BATS_TEST_TMPDIR/branch-context.html"
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
  grep -q "finish the approved slice" "$BATS_TEST_TMPDIR/backend.prompt"
}

@test "paw gui: batch implement starts every selected eligible task" {
  mkdir -p "$REPO/.agent/gui-task-two"
  cp "$REPO/.agent/gui-task/plan.md" "$REPO/.agent/gui-task-two/plan.md"
  local port=18781 path_one path_two
  path_one="$(real_path "$REPO/.agent/gui-task")"
  path_two="$(real_path "$REPO/.agent/gui-task-two")"
  start_gui "$port"

  post_gui "$port" "/actions/implement-batch" "$(form_encode "task=$path_one" "task=$path_two")" "$BATS_TEST_TMPDIR/batch-post.html"
  wait_for_run_metadata gui-task
  wait_for_run_metadata gui-task-two
  stop_gui

  grep -q "batch implement started 2 task" "$BATS_TEST_TMPDIR/batch-post.html"
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

@test "paw gui: deletes a central task only with exact confirmation and listed path" {
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
  post_gui "$port" "/task/delete-me/delete" "$(form_encode "path=/tmp/delete-me" "confirm=delete-me")" "$BATS_TEST_TMPDIR/delete-stale.html"
  [[ -d "$central" ]]
  post_gui "$port" "/task/delete-me/delete" "$(form_encode "path=$central" "confirm=delete-me")" "$BATS_TEST_TMPDIR/delete-ok.html"
  stop_gui

  grep -q "delete confirmation must match" "$BATS_TEST_TMPDIR/delete-reject.html"
  grep -q "delete rejected: stale task path" "$BATS_TEST_TMPDIR/delete-stale.html"
  [[ ! -d "$central" ]]
}

@test "paw gui: deletes a legacy task only with exact confirmation" {
  local path port=18773
  path="$(real_path "$REPO/.agent/gui-task")"
  start_gui "$port"

  post_gui "$port" "/task/gui-task/delete" "$(form_encode "path=$path" "confirm=gui-task")" "$BATS_TEST_TMPDIR/delete-legacy.html"
  stop_gui

  [[ ! -d "$path" ]]
  grep -q "deleted task gui-task" "$BATS_TEST_TMPDIR/delete-legacy.html"
}

@test "paw gui start: launches background dashboard and records metadata" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"

  run "$PAW" gui start --repo "$REPO" --port 0

  [ "$status" -eq 0 ]
  [[ "$output" == *"paw gui: http://127.0.0.1:"* ]]
  local meta="$XDG_STATE_HOME/paw/gui/active.gitconfig"
  [ -f "$meta" ]
  local url
  url="$(git config --file "$meta" --get paw.url)"
  [[ "$url" == http://127.0.0.1:* ]]
  git config --file "$meta" --get paw.pid > "$BATS_TEST_TMPDIR/gui.pid"

  python3 - "$url" > "$BATS_TEST_TMPDIR/page.html" <<'PY'
import sys
from urllib.request import urlopen
print(urlopen(sys.argv[1], timeout=2).read().decode())
PY

  grep -q "gui-task" "$BATS_TEST_TMPDIR/page.html"

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
  "$PAW" gui --all --repo "$REPO" --port "$port" > "$BATS_TEST_TMPDIR/gui-all.out" 2> "$BATS_TEST_TMPDIR/gui-all.err" &
  local pid="$!"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 - "$port" > "$BATS_TEST_TMPDIR/all.html" <<'PY'
import sys
from urllib.request import urlopen
print(urlopen(f"http://127.0.0.1:{sys.argv[1]}/", timeout=1).read().decode())
PY
    then
      break
    fi
    sleep 0.2
  done

  pkill -P "$pid" 2>/dev/null || true
  pkill -f "gui_server.py .*--port $port" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -q "Repo one task" "$BATS_TEST_TMPDIR/all.html"
  grep -q "Repo two task" "$BATS_TEST_TMPDIR/all.html"
  grep -q "shared-task" "$BATS_TEST_TMPDIR/all.html"
  grep -q "repo-two" "$BATS_TEST_TMPDIR/all.html"
}
