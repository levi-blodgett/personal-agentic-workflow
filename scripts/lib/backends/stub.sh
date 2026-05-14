#!/usr/bin/env bash
# backends/stub.sh — test-only stub backend for paw.
#
# Implements the paw backend contract (see _iface.md) without making any real
# AI API calls.  Used by tests/paw-prompt-body.bats.
#
# BATS_TEST_TMPDIR must be set (exported by bats automatically).
# Each invocation writes:
#   $BATS_TEST_TMPDIR/backend.args   — one argument per line (after out_path)
#   $BATS_TEST_TMPDIR/backend.prompt — the prompt string (last positional arg)
#   $BATS_TEST_TMPDIR/backend.mode   — "capture" or "stream"
#
# A minimal JSON response is emitted so the standard token parsers have fixture data.

_stub_record() {
  local out_path="$1"; shift
  printf '%s\n' "$@" > "${BATS_TEST_TMPDIR}/backend.args"

  # The prompt is always the last positional argument.
  local total=$# i=0
  local prompt=""
  for arg in "$@"; do
    (( i++ )) || true
    if [[ $i -eq $total ]]; then
      prompt="$arg"
    fi
  done
  printf '%s' "$prompt" > "${BATS_TEST_TMPDIR}/backend.prompt"

  cat > "$out_path" <<'JSON'
{"result":"stub-ok","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
JSON
}

backend_run_capture() {
  local out_path="$1"; shift
  echo "capture" > "${BATS_TEST_TMPDIR}/backend.mode"
  _stub_record "$out_path" "$@"
}

backend_run_stream() {
  local out_path="$1"; shift
  echo "stream" > "${BATS_TEST_TMPDIR}/backend.mode"
  _stub_record "$out_path" "$@"
  echo "[stub stream output]"
}

backend_parse_tokens() {
  local json_file="$1" field="${2:-total}"
  if [[ ! -f "$json_file" ]]; then echo "unknown"; return 0; fi
  jq -r --arg field "$field" '
    if $field == "input"            then (.usage.input_tokens // 0)
    elif $field == "output"         then (.usage.output_tokens // 0)
    elif $field == "cache_read"     then (.usage.cache_read_input_tokens // 0)
    elif $field == "cache_creation" then (.usage.cache_creation_input_tokens // 0)
    else ( (.usage.input_tokens                // 0)
         + (.usage.output_tokens               // 0)
         + (.usage.cache_creation_input_tokens // 0)
         + (.usage.cache_read_input_tokens     // 0)
         )
    end | tostring
  ' "$json_file" 2>/dev/null || echo "unknown"
}

backend_parse_stream_tokens() {
  backend_parse_tokens "$@"
}

# Legacy aliases
claude_run_capture()        { backend_run_capture "$@"; }
claude_run_stream()         { backend_run_stream "$@"; }
parse_usage_tokens()        { backend_parse_tokens "$@"; }
parse_stream_usage_tokens() { backend_parse_stream_tokens "$@"; }
