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
