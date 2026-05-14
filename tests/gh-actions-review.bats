#!/usr/bin/env bats
# Tests for scripts/gh-actions-review.sh using a PATH-shimmed fake `gh`.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SCRIPT="$SCRIPTS_DIR/gh-actions-review.sh"

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$FAKE_BIN"

  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not on PATH"
  fi

  export PATH="$FAKE_BIN:$PATH"
}

assert_output_has_line() {
  local expected="$1"
  printf '%s\n' "$output" | grep -Fqx "$expected"
}

write_fake_gh() {
  local body="$1"
  cat > "$FAKE_BIN/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$FAKE_BIN/gh"
}

@test "gh-actions-review: exits 2 on unknown argument" {
  write_fake_gh 'exit 0'

  run "$SCRIPT" --wat

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "gh-actions-review: reports no-failures when no same-day runs failed" {
  local runs_json="$BATS_TEST_TMPDIR/runs.json"
  cat > "$runs_json" <<'JSON'
[
  {
    "databaseId": 1001,
    "workflowName": "test",
    "status": "completed",
    "conclusion": "success",
    "createdAt": "2026-05-16T08:00:00Z",
    "url": "https://github.com/example/repo/actions/runs/1001"
  }
]
JSON

  write_fake_gh "
if [[ \"\$1\" == \"repo\" && \"\$2\" == \"view\" ]]; then
  echo example/repo
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"list\" ]]; then
  printf '%s\n' \"\$*\" > \"$BATS_TEST_TMPDIR/run-list.args\"
  cat \"$runs_json\"
  exit 0
fi
echo \"unexpected gh invocation: \$*\" >&2
exit 1
"

  run "$SCRIPT" --date 2026-05-16

  [ "$status" -eq 0 ]
  [[ "$output" == *"state: no-failures"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/run-list.args")" == *"--created 2026-05-16"* ]]
}

@test "gh-actions-review: marks a failure documented when an open issue contains the normalized signature" {
  local runs_json="$BATS_TEST_TMPDIR/runs.json"
  local run_view_json="$BATS_TEST_TMPDIR/run-view.json"
  local issues_json="$BATS_TEST_TMPDIR/issues.json"
  local log_file="$BATS_TEST_TMPDIR/job.log"

  cat > "$runs_json" <<'JSON'
[
  {
    "databaseId": 2001,
    "workflowName": "test",
    "status": "completed",
    "conclusion": "failure",
    "createdAt": "2026-05-16T08:00:00Z",
    "url": "https://github.com/example/repo/actions/runs/2001"
  }
]
JSON

  cat > "$run_view_json" <<'JSON'
{
  "databaseId": 2001,
  "workflowName": "test",
  "url": "https://github.com/example/repo/actions/runs/2001",
  "jobs": [
    {
      "databaseId": 9001,
      "name": "unit",
      "conclusion": "failure"
    }
  ]
}
JSON

  cat > "$issues_json" <<'JSON'
[
  {
    "number": 77,
    "title": "CI bug in test workflow",
    "body": "npm test failed with exit code 1 on the unit job",
    "url": "https://github.com/example/repo/issues/77"
  }
]
JSON

  cat > "$log_file" <<'LOG'
2026-05-16T08:11:00Z ERROR npm test failed with exit code 1
LOG

  write_fake_gh "
if [[ \"\$1\" == \"repo\" && \"\$2\" == \"view\" ]]; then
  echo example/repo
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"list\" ]]; then
  cat \"$runs_json\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$6\" == \"--json\" ]]; then
  cat \"$run_view_json\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$6\" == \"--job\" ]]; then
  cat \"$log_file\"
  exit 0
fi
if [[ \"\$1\" == \"issue\" && \"\$2\" == \"list\" ]]; then
  printf '%s\n' \"\$*\" > \"$BATS_TEST_TMPDIR/issue-list.args\"
  cat \"$issues_json\"
  exit 0
fi
echo \"unexpected gh invocation: \$*\" >&2
exit 1
"

  run "$SCRIPT" --date 2026-05-16

  [ "$status" -eq 0 ]
  assert_output_has_line "state: documented"
  [[ "$output" == *"issue_number: 77"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/issue-list.args")" == *"test"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/issue-list.args")" == *"unit"* ]]
}

@test "gh-actions-review: reports an undocumented failure without creating an issue by default" {
  local runs_json="$BATS_TEST_TMPDIR/runs.json"
  local run_view_json="$BATS_TEST_TMPDIR/run-view.json"
  local issues_json="$BATS_TEST_TMPDIR/issues.json"
  local log_file="$BATS_TEST_TMPDIR/job.log"

  cat > "$runs_json" <<'JSON'
[
  {
    "databaseId": 3001,
    "workflowName": "lint",
    "status": "completed",
    "conclusion": "failure",
    "createdAt": "2026-05-16T08:00:00Z",
    "url": "https://github.com/example/repo/actions/runs/3001"
  }
]
JSON

  cat > "$run_view_json" <<'JSON'
{
  "databaseId": 3001,
  "workflowName": "lint",
  "url": "https://github.com/example/repo/actions/runs/3001",
  "jobs": [
    {
      "databaseId": 9002,
      "name": "shellcheck",
      "conclusion": "failure"
    }
  ]
}
JSON

  cat > "$issues_json" <<'JSON'
[]
JSON

  cat > "$log_file" <<'LOG'
shellcheck: scripts/paw: line 12: error: unexpected fi
LOG

  write_fake_gh "
if [[ \"\$1\" == \"repo\" && \"\$2\" == \"view\" ]]; then
  echo example/repo
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"list\" ]]; then
  cat \"$runs_json\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$6\" == \"--json\" ]]; then
  cat \"$run_view_json\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$6\" == \"--job\" ]]; then
  cat \"$log_file\"
  exit 0
fi
if [[ \"\$1\" == \"issue\" && \"\$2\" == \"list\" ]]; then
  cat \"$issues_json\"
  exit 0
fi
if [[ \"\$1\" == \"issue\" && \"\$2\" == \"create\" ]]; then
  echo \"issue create should not be called without --create-issue\" >&2
  exit 1
fi
echo \"unexpected gh invocation: \$*\" >&2
exit 1
"

  run "$SCRIPT" --date 2026-05-16

  [ "$status" -eq 0 ]
  assert_output_has_line "state: undocumented"
  [[ "$output" == *"job_url: https://github.com/example/repo/actions/runs/3001/job/9002"* ]]
}

@test "gh-actions-review: skips documented failures and creates one issue for the first undocumented pipeline when flagged" {
  local runs_json="$BATS_TEST_TMPDIR/runs.json"
  local run_view_1="$BATS_TEST_TMPDIR/run-view-1.json"
  local run_view_2="$BATS_TEST_TMPDIR/run-view-2.json"
  local issues_doc="$BATS_TEST_TMPDIR/issues-doc.json"
  local issues_empty="$BATS_TEST_TMPDIR/issues-empty.json"
  local log_1="$BATS_TEST_TMPDIR/job-1.log"
  local log_2="$BATS_TEST_TMPDIR/job-2.log"

  cat > "$runs_json" <<'JSON'
[
  {
    "databaseId": 4001,
    "workflowName": "test",
    "status": "completed",
    "conclusion": "failure",
    "createdAt": "2026-05-16T08:00:00Z",
    "url": "https://github.com/example/repo/actions/runs/4001"
  },
  {
    "databaseId": 4002,
    "workflowName": "release",
    "status": "completed",
    "conclusion": "failure",
    "createdAt": "2026-05-16T09:00:00Z",
    "url": "https://github.com/example/repo/actions/runs/4002"
  }
]
JSON

  cat > "$run_view_1" <<'JSON'
{
  "databaseId": 4001,
  "workflowName": "test",
  "url": "https://github.com/example/repo/actions/runs/4001",
  "jobs": [
    {
      "databaseId": 9101,
      "name": "unit",
      "conclusion": "failure"
    }
  ]
}
JSON

  cat > "$run_view_2" <<'JSON'
{
  "databaseId": 4002,
  "workflowName": "release",
  "url": "https://github.com/example/repo/actions/runs/4002",
  "jobs": [
    {
      "databaseId": 9102,
      "name": "publish",
      "conclusion": "failure"
    }
  ]
}
JSON

  cat > "$issues_doc" <<'JSON'
[
  {
    "number": 88,
    "title": "Existing CI issue",
    "body": "npm test failed with exit code 1 on unit",
    "url": "https://github.com/example/repo/issues/88"
  }
]
JSON

  cat > "$issues_empty" <<'JSON'
[]
JSON

  cat > "$log_1" <<'LOG'
ERROR npm test failed with exit code 1
LOG

  cat > "$log_2" <<'LOG'
fatal: release publish timed out after 15m
LOG

  write_fake_gh "
if [[ \"\$1\" == \"repo\" && \"\$2\" == \"view\" ]]; then
  echo example/repo
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"list\" ]]; then
  cat \"$runs_json\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$3\" == \"4001\" && \"\$6\" == \"--json\" ]]; then
  cat \"$run_view_1\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$3\" == \"4002\" && \"\$6\" == \"--json\" ]]; then
  cat \"$run_view_2\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$3\" == \"4001\" && \"\$6\" == \"--job\" ]]; then
  cat \"$log_1\"
  exit 0
fi
if [[ \"\$1\" == \"run\" && \"\$2\" == \"view\" && \"\$3\" == \"4002\" && \"\$6\" == \"--job\" ]]; then
  cat \"$log_2\"
  exit 0
fi
if [[ \"\$1\" == \"issue\" && \"\$2\" == \"list\" ]]; then
  if [[ \"\$*\" == *release* ]]; then
    cat \"$issues_empty\"
  else
    cat \"$issues_doc\"
  fi
  exit 0
fi
if [[ \"\$1\" == \"issue\" && \"\$2\" == \"create\" ]]; then
  printf '%s\n' \"\$*\" > \"$BATS_TEST_TMPDIR/issue-create.args\"
  body_file=\"\"
  prev=\"\"
  for arg in \"\$@\"; do
    if [[ \"\$prev\" == \"--body-file\" ]]; then
      body_file=\"\$arg\"
      break
    fi
    prev=\"\$arg\"
  done
  cp \"\$body_file\" \"$BATS_TEST_TMPDIR/created-issue-body.md\"
  echo \"https://github.com/example/repo/issues/99\"
  exit 0
fi
echo \"unexpected gh invocation: \$*\" >&2
exit 1
"

  run "$SCRIPT" --date 2026-05-16 --create-issue

  [ "$status" -eq 0 ]
  [[ "$output" == *"state: created"* ]]
  [[ "$output" == *"issue_number: 99"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/issue-create.args")" == *"GitHub Actions failure: release / publish"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/created-issue-body.md")" == *"https://github.com/example/repo/actions/runs/4002"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/created-issue-body.md")" == *"https://github.com/example/repo/actions/runs/4002/job/9102"* ]]
}
