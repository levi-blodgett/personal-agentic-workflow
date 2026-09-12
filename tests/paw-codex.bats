#!/usr/bin/env bats
# Tests for the codex backend (PAW_BACKEND=codex).
#
# A stub `codex` binary is placed on PATH so no real Codex CLI is required.
# The stub records its argv (one arg per line) to:
#   $BATS_TEST_TMPDIR/codex.args
# For capture mode (when a -o <file> flag is present) the stub also writes
# "codex-stub-ok" to that file so backend_run_capture can read it.
# For stream mode the stub emits minimal JSONL. Use the current Codex CLI schema
# (`item.completed` / `turn.completed`) so the tests catch future drift in the
# jq stream filter.
#
# Assertions verify argv translation, prompt forwarding, PAW_MODEL
# forwarding, ephemeral flag, sandbox flags, centralized cost log behavior,
# PAW_CODEX_DANGEROUS opt-in, require_backend guard, and paw model output.

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
  export PAW_BACKEND=codex
  export PAW_MAX_TURNS=100

  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  # Stub codex binary: records argv, writes fixture to -o file, emits stub JSONL.
  # Handles "codex login status" separately (returns auth stub line).
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
# Handle login status without touching codex.args or emitting JSONL.
if [[ "$1" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using ChatGPT (stub)"
  exit 0
fi
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
# Write fixture text to the -o output file when present.
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  if [[ "$arg" == "-o" ]]; then
    j=$(( i + 1 ))
    echo "codex-stub-ok" > "${!j}"
  fi
  i=$(( i + 1 ))
done
# Emit minimal JSONL in the current Codex CLI shape.
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"codex-stub-ok"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3}}'
EOF
  chmod +x "$STUB_BIN/codex"

  export PATH="$STUB_BIN:$PATH"

  cd "$REPO"
}

# ── helpers ───────────────────────────────────────────────────────────────────

make_task() {
  local name="$1"
  mkdir -p "$REPO/.agent/$name"
  cp "$FIXTURES_DIR/sample-task-valid/plan.md" "$REPO/.agent/$name/plan.md"
}

codex_args() {
  cat "$BATS_TEST_TMPDIR/codex.args" 2>/dev/null || true
}

args_contain() {
  grep -qF -- "$1" "$BATS_TEST_TMPDIR/codex.args"
}

args_not_contain() {
  ! grep -qF -- "$1" "$BATS_TEST_TMPDIR/codex.args"
}

# ── argv translation ──────────────────────────────────────────────────────────

@test "codex: argv begins with exec --json -C <repo>" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  local args
  args=$(codex_args)
  [[ "$(echo "$args" | sed -n '1p')" == "exec"   ]]
  [[ "$(echo "$args" | sed -n '2p')" == "--json" ]]
  [[ "$(echo "$args" | sed -n '3p')" == "-C"     ]]
  [[ "$(echo "$args" | sed -n '4p')" == "$REPO"  ]]
}

@test "codex: --model/-m flag present with the default codex model" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "-m"
  args_contain "gpt-6-astra"
}

@test "codex: --add-dir <paw_home> is forwarded" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "--add-dir"
  args_contain "$PAW_HOME"
}

@test "codex: --permission-mode is not forwarded to codex" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_not_contain "--permission-mode"
  args_not_contain "bypassPermissions"
}

@test "codex: --max-turns is not forwarded to codex" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_not_contain "--max-turns"
  ! grep -qxF "100" "$BATS_TEST_TMPDIR/codex.args"
}

@test "codex: --ephemeral flag present in every invocation" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "--ephemeral"
}

# ── prompt forwarding ─────────────────────────────────────────────────────────

@test "codex: prompt (last positional arg) contains PAW:IMPLEMENT anchor" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  grep -qF "PAW:IMPLEMENT" "$BATS_TEST_TMPDIR/codex.args"
}

@test "codex: paw plan passes PAW:PLAN anchor to codex" {
  run "$PAW" plan my-plan-task "add observability"
  [ "$status" -eq 0 ]
  args_contain "-m"
  args_contain "gpt-6-astra"
  [[ "$output" == *"model=gpt-6-astra"* ]]
  grep -qF "PAW:PLAN" "$BATS_TEST_TMPDIR/codex.args"
}

@test "codex: paw edit passes PAW:EDIT anchor to codex" {
  make_task edit-task
  run "$PAW" edit edit-task
  [ "$status" -eq 0 ]
  grep -qF "PAW:EDIT" "$BATS_TEST_TMPDIR/codex.args"
}

# ── model forwarding (codex honors PAW_MODEL) ─────────────────────────────────

@test "codex: PAW_MODEL=gpt-5.4 forwarded as -m gpt-5.4" {
  make_task my-task
  PAW_MODEL=gpt-5.4 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "gpt-5.4"
}

@test "codex: PAW_MODEL=gpt-5.5 forwarded as -m gpt-5.5" {
  make_task my-task
  PAW_MODEL=gpt-5.5 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "gpt-5.5"
}

@test "codex: PAW_MODEL=gpt-5.5 forwarded as -m gpt-5.5 for paw plan" {
  PAW_MODEL=gpt-5.5 run "$PAW" plan my-plan-task "add observability"
  [ "$status" -eq 0 ]
  args_contain "gpt-5.5"
}

@test "codex: legacy PAW_MODEL_* vars no longer affect model selection" {
  make_task my-task
  PAW_MODEL_PLAN=gpt-5.5 PAW_MODEL_CONTEXT=gpt-5.5 PAW_MODEL_EDIT=gpt-5.5 PAW_MODEL_RUN=gpt-5.5 PAW_MODEL_NEW=gpt-5.5 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "gpt-6-astra"
  args_not_contain "gpt-5.5"
}

# ── sandbox flags ─────────────────────────────────────────────────────────────

@test "codex: -s danger-full-access present by default" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "-s"
  args_contain "danger-full-access"
}

@test "codex: --dangerously-bypass-approvals-and-sandbox absent by default" {
  make_task my-task
  run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_not_contain "--dangerously-bypass-approvals-and-sandbox"
}

@test "codex: PAW_CODEX_DANGEROUS=1 uses --dangerously-bypass-approvals-and-sandbox" {
  make_task my-task
  PAW_CODEX_DANGEROUS=1 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_contain "--dangerously-bypass-approvals-and-sandbox"
}

@test "codex: PAW_CODEX_DANGEROUS=1 omits -s danger-full-access" {
  make_task my-task
  PAW_CODEX_DANGEROUS=1 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_not_contain "danger-full-access"
}

@test "codex: PAW_CODEX_DANGEROUS=0 does not append dangerous flag" {
  make_task my-task
  PAW_CODEX_DANGEROUS=0 run "$PAW" implement my-task
  [ "$status" -eq 0 ]
  args_not_contain "--dangerously-bypass-approvals-and-sandbox"
}

# ── paw model -v ──────────────────────────────────────────────────────────────

@test "paw model -v: reports backend: codex" {
  run "$PAW" model -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:   codex"* ]]
}

@test "paw model -v: reports per-subcommand models without error" {
  run "$PAW" model -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan:"*      ]]
  [[ "$output" == *"edit:"*      ]]
  [[ "$output" == *"implement:"* ]]
}

@test "paw model: implement subcommand reports PAW_MODEL value" {
  PAW_MODEL=gpt-5.4 run "$PAW" model
  [ "$status" -eq 0 ]
  [[ "$output" == *"implement: gpt-5.4"* ]]
}

@test "paw model: plan subcommand reports PAW_MODEL value" {
  PAW_MODEL=gpt-5.5 run "$PAW" model
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan:      gpt-5.5"* ]]
}

# ── launch banner ─────────────────────────────────────────────────────────────

@test "codex: launch banner reports model=gpt-5.4 for paw implement" {
  make_task banner-task
  PAW_MODEL=gpt-5.4 run "$PAW" implement banner-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=gpt-5.4"* ]]
}

@test "codex: launch banner reports model=gpt-5.5 for paw plan" {
  PAW_MODEL=gpt-5.5 run "$PAW" plan banner-plan-task "add observability"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=gpt-5.5"* ]]
}

# ── guard: codex binary required ──────────────────────────────────────────────

@test "guard: paw exits nonzero when codex not on PATH" {
  make_task my-task
  local clean_bin="$BATS_TEST_TMPDIR/clean-bin"
  mkdir -p "$clean_bin"
  local clean_path="$clean_bin:${PATH#${STUB_BIN}:}"
  PATH="$clean_path" run "$PAW" implement my-task
  [ "$status" -ne 0 ]
  [[ "$output" == *"codex"* ]]
}

# ── PAW_STREAM=1 ──────────────────────────────────────────────────────────────

@test "codex: PAW_STREAM=1 paw implement streams output" {
  make_task stream-task
  PAW_STREAM=1 run "$PAW" implement stream-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex-stub-ok"* ]]
}

# ── no "claude exited" warning text ──────────────────────────────────────────

@test "codex: 'claude exited' never appears in output on success" {
  make_task warn-task
  run "$PAW" implement warn-task
  [ "$status" -eq 0 ]
  [[ "$output" != *"claude exited"* ]]
}

@test "codex: 'claude exited' never appears in output on failure" {
  make_task fail-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  if [[ "$arg" == "-o" ]]; then
    j=$(( i + 1 ))
    echo "" > "${!j}"
  fi
  i=$(( i + 1 ))
done
echo '{"type":"agent_message_content_delta","delta":"codex-stub-fail"}'
exit 1
EOF
  chmod +x "$STUB_BIN/codex"
  run "$PAW" implement fail-task
  [[ "$output" != *"claude exited"* ]]
}

# ── token-unavailable warning suppressed ─────────────────────────────────────

@test "codex: token-unavailable warning suppressed when backend exits non-zero" {
  make_task suppress-warn-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  if [[ "$arg" == "-o" ]]; then
    j=$(( i + 1 ))
    echo "" > "${!j}"
  fi
  i=$(( i + 1 ))
done
echo '{"type":"agent_message_content_delta","delta":"codex-stub-fail"}'
exit 1
EOF
  chmod +x "$STUB_BIN/codex"
  run "$PAW" implement suppress-warn-task
  [[ "$output" != *"token count unavailable"* ]]
}

# ── usage banner (backend_usage_banner) ───────────────────────────────────────

@test "codex: launch output includes codex auth status line" {
  make_task banner-auth-task
  run "$PAW" implement banner-auth-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: Logged in using ChatGPT (stub)"* ]]
}

@test "codex: auth status line appears for paw plan" {
  run "$PAW" plan banner-plan-auth "add observability"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: Logged in using ChatGPT (stub)"* ]]
}

# ── Anthropic model name warning ──────────────────────────────────────────────

@test "codex: PAW_MODEL=sonnet emits Anthropic model warning" {
  make_task model-warn-task
  PAW_MODEL=sonnet run "$PAW" implement model-warn-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn: model 'sonnet' looks like an Anthropic model name"* ]]
  [[ "$output" == *"for example gpt-6-astra"* ]]
}

@test "codex: PAW_MODEL=o4-mini does not emit Anthropic model warning" {
  make_task model-ok-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using ChatGPT (stub)"; exit 0
fi
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then echo "codex-stub-ok" > "$2"; fi
  shift
done
echo '{"type":"agent_message_content_delta","delta":"codex-stub-ok"}'
echo '{"type":"task_complete"}'
EOF
  chmod +x "$STUB_BIN/codex"
  PAW_MODEL=o4-mini run "$PAW" implement model-ok-task
  [ "$status" -eq 0 ]
  [[ "$output" != *"looks like an Anthropic model name"* ]]
}

@test "codex: token-unavailable warning suppressed for unsupported model on failure" {
  make_task suppress-model-warn-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using ChatGPT (stub)"; exit 0
fi
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then echo "" > "$2"; fi
  shift
done
echo '{"type":"agent_message_content_delta","delta":"codex-stub-fail"}'
exit 1
EOF
  chmod +x "$STUB_BIN/codex"
  PAW_MODEL=sonnet run "$PAW" implement suppress-model-warn-task
  [[ "$output" != *"token count unavailable"* ]]
}

# ── error event surfacing (PAW_STREAM=1) ──────────────────────────────────────

@test "codex: PAW_STREAM=1 error events produce visible output" {
  make_task error-surface-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using ChatGPT (stub)"; exit 0
fi
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
echo '{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"model not supported\"}}"}'
echo '{"type":"turn.failed","error":{"message":"model not supported"}}'
exit 1
EOF
  chmod +x "$STUB_BIN/codex"
  PAW_STREAM=1 run "$PAW" implement error-surface-task
  [[ "$output" == *"paw/codex error"* ]]
}

@test "codex: PAW_STREAM=1 exit code propagated when codex exits non-zero" {
  make_task stream-exit-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using ChatGPT (stub)"; exit 0
fi
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"failing"}}'
exit 1
EOF
  chmod +x "$STUB_BIN/codex"
  PAW_STREAM=1 run "$PAW" implement stream-exit-task
  [ "$status" -ne 0 ]
}

@test "codex: PAW_STREAM=1 item.completed events produce visible output" {
  make_task item-complete-task
  cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "login" && "${2:-}" == "status" ]]; then
  echo "Logged in using ChatGPT (stub)"; exit 0
fi
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/codex.args"
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"item-complete-ok"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3}}'
EOF
  chmod +x "$STUB_BIN/codex"
  PAW_STREAM=1 run "$PAW" implement item-complete-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"item-complete-ok"* ]]
}

# ── ChatGPT auth + API-key-only model warning ─────────────────────────────────

@test "codex: PAW_MODEL=o4-mini with ChatGPT auth recommends the current default" {
  make_task chatgpt-model-warn-task
  PAW_MODEL=o4-mini run "$PAW" implement chatgpt-model-warn-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"prefer gpt-6-astra by default"* ]]
}

@test "paw model: every subcommand defaults to gpt-6-astra" {
  run "$PAW" model
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" == *": "* ]]
    [[ "${line##* }" == "gpt-6-astra" ]]
  done
}

@test "codex: default gpt-6-astra launch supports ChatGPT auth without model warnings" {
  make_task astra-task
  run "$PAW" implement astra-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=gpt-6-astra"* ]]
  [[ "$output" == *"codex: Logged in using ChatGPT (stub)"* ]]
  [[ "$output" != *"warn: model"* ]]
}
