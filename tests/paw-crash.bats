#!/usr/bin/env bats
# Tests for crash traceability: crash_log.sh helpers and paw crash-log subcommand.
#
# A PATH-shimmed `claude` fake is used so tests never make real API calls.
# Crash-specific shims exit non-zero and write a message to stderr.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PAW="$SCRIPTS_DIR/paw"
LIB_DIR="$SCRIPTS_DIR/lib"

load 'helpers/exit_code'

# ── setup / teardown ─────────────────────────────────────────────────────────

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent"

  SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM_DIR"

  # Default shim: exits 0 with minimal JSON.
  cat > "$SHIM_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/claude.args"
cat <<JSON
{"result":"ok","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
JSON
SHIM
  chmod +x "$SHIM_DIR/claude"

  export PATH="$SHIM_DIR:$PATH"
  export PAW_HOME="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export PAW_BACKEND=claude
  cd "$REPO"
}

# ── helpers ───────────────────────────────────────────────────────────────────

make_failing_shim() {
  local exit_code="${1:-1}" stderr_msg="${2:-error: unknown failure}"
  cat > "$SHIM_DIR/claude" <<SHIM
#!/usr/bin/env bash
echo "${stderr_msg}" >&2
exit ${exit_code}
SHIM
  chmod +x "$SHIM_DIR/claude"
}

make_task() {
  local name="$1"
  mkdir -p "$REPO/.agent/$name"
  cp "$(dirname "$BATS_TEST_FILENAME")/fixtures/sample-task-valid/plan.md" \
     "$REPO/.agent/$name/plan.md"
}

# ── crash_classify unit tests (source lib directly) ──────────────────────────

@test "crash_classify: identifies context overflow from stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "context window exceeded, please reduce your prompt" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"context overflow"* ]]
}

@test "crash_classify: identifies rate limit from stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "rate limit exceeded, please wait and retry" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rate limit"* ]]
}

# ── integration tests via paw ────────────────────────────────────────────────

@test "paw implement: crash.log created when backend exits non-zero" {
  make_task crash-task
  make_failing_shim 1 "error: context window exceeded"

  run "$PAW" implement crash-task

  [ -f "$REPO/.agent/crash-task/crash.log" ]
}

@test "paw implement: crash.log contains exit_code, classification, and model" {
  make_task crash-task
  make_failing_shim 1 "error: context window exceeded"

  run "$PAW" implement crash-task

  grep -q "exit_code:" "$REPO/.agent/crash-task/crash.log"
  grep -q "classification:" "$REPO/.agent/crash-task/crash.log"
  grep -q "context overflow" "$REPO/.agent/crash-task/crash.log"
  grep -q "model:" "$REPO/.agent/crash-task/crash.log"
}

@test "paw crash-log: prints crash.log content when crashes exist" {
  make_task crash-log-task
  make_failing_shim 1 "error: rate limit exceeded"

  "$PAW" implement crash-log-task || true
  run "$PAW" crash-log crash-log-task

  [ "$status" -eq 0 ]
  [[ "$output" == *"==="* ]]
  [[ "$output" == *"classification:"* ]]
}

@test "paw crash-log: prints 'no crashes recorded' when crash.log absent" {
  make_task no-crash-task

  run "$PAW" crash-log no-crash-task

  [ "$status" -eq 0 ]
  [[ "$output" == *"no crashes recorded"* ]]
}

@test "paw crash-log: exits 2 when no task name given" {
  run "$PAW" crash-log

  assert_exits_2
}

@test "paw crash-log: exits 2 when task directory not found" {
  run "$PAW" crash-log nonexistent-task

  [ "$status" -eq 2 ]
}

@test "paw implement: prompt-size warning fires when prompt exceeds token threshold" {
  make_task warn-task
  # Set threshold to 1 token so any non-empty prompt triggers the warning.
  PAW_PROMPT_WARN_TOKENS=1 run "$PAW" implement warn-task

  [[ "$output" == *"context overflow risk"* ]]
  [[ "$output" == *"paw compact warn-task"* ]]
  [[ "$output" == *"split the task"* ]]
}

@test "paw implement: prompt-size telemetry reports rising context pressure before overflow" {
  make_task pressure-task
  # Use a threshold that places the standard implement prompt above 75% but below 100%.
  PAW_PROMPT_WARN_TOKENS=100 run "$PAW" implement pressure-task

  [[ "$output" == *"context pressure is building"* ]]
  [[ "$output" == *"paw compact pressure-task"* ]]
  [[ "$output" == *"archive stale detail"* ]]
}

# ── crash_classify: Phase 1b expanded classifications ────────────────────────

@test "crash_classify: identifies content_filter from 'content filter' in stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "error: output blocked by content filter policy" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"content_filter"* ]]
}

@test "crash_classify: identifies content_filter from 'flagged' in stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "request flagged by moderation system" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"content_filter"* ]]
}

@test "crash_classify: identifies too_many_requests from '429' in stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "HTTP 429: request limit exceeded" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"too_many_requests"* ]]
}

@test "crash_classify: identifies too_many_requests from 'too many requests' in stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "error: too many requests, please slow down" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"too_many_requests"* ]]
}

@test "crash_classify: identifies overloaded from 'overloaded' in stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "API overloaded, please retry later" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"overloaded"* ]]
}

@test "crash_classify: identifies overloaded from '503' in stderr" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err
  tmp_err=$(mktemp)
  echo "HTTP 503: service unavailable" > "$tmp_err"
  run crash_classify 1 "$tmp_err"
  rm -f "$tmp_err"
  [ "$status" -eq 0 ]
  [[ "$output" == *"overloaded"* ]]
}

@test "crash_classify: extracts API error type from JSON and prepends to result" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  local tmp_err tmp_json
  tmp_err=$(mktemp)
  tmp_json=$(mktemp)
  echo "error: request failed" > "$tmp_err"
  printf '{"error":{"type":"content_filter"}}\n' > "$tmp_json"
  run crash_classify 1 "$tmp_err" "$tmp_json"
  rm -f "$tmp_err" "$tmp_json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"content_filter"* ]]
}

# ── crash_color_status unit tests ─────────────────────────────────────────────

@test "crash_color_status: emits green line on exit 0" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  run crash_color_status 0 "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit 0"* ]]
}

@test "crash_color_status: emits red line with api_code on non-zero exit" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  run crash_color_status 1 "429" "too_many_requests"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit 1"* ]]
  [[ "$output" == *"429"* ]]
}

@test "crash_color_status: falls back to classification when api_code is empty" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  run crash_color_status 1 "" "context overflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit 1"* ]]
  [[ "$output" == *"context overflow"* ]]
}

@test "crash_color_status: omits ANSI codes when NO_COLOR is set" {
  # shellcheck disable=SC1090
  source "$LIB_DIR/crash_log.sh"
  NO_COLOR=1 run crash_color_status 1 "" "context overflow"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
  [[ "$output" == *"exit 1"* ]]
}

@test "paw implement: colored status line appears in output on non-zero exit" {
  make_task color-task
  make_failing_shim 1 "error: API overloaded"

  run "$PAW" implement color-task

  [[ "$output" == *"paw: exit"* ]]
}
