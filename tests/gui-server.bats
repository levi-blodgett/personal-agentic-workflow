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

@test "paw gui: serves local dashboard with legacy task details" {
  local port=18765
  "$PAW" gui --repo "$REPO" --port "$port" > "$BATS_TEST_TMPDIR/gui.out" 2> "$BATS_TEST_TMPDIR/gui.err" &
  local pid="$!"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 - "$port" > "$BATS_TEST_TMPDIR/page.html" <<'PY'
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

  grep -q "gui-task" "$BATS_TEST_TMPDIR/page.html"
  grep -q "GUI smoke" "$BATS_TEST_TMPDIR/page.html"
  grep -q "1/2" "$BATS_TEST_TMPDIR/page.html"
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
