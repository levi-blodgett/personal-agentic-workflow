#!/usr/bin/env bash
# backends/claude.sh — claude CLI backend for paw.
#
# Implements the paw backend contract (see _iface.md).
# Source this file via: source "$LIB_DIR/backends/claude.sh"
#
# Required exports (backend contract):
#   backend_run_capture <out-json-path> [claude args...]
#   backend_run_stream  <out-json-path> [claude args...]
#   backend_parse_tokens <json-file> [field]
#   backend_parse_stream_tokens <json-file> [field]
#
# Legacy aliases (kept for backwards compatibility):
#   claude_run_capture, claude_run_stream,
#   parse_usage_tokens, parse_stream_usage_tokens

# backend_run_capture <out-json-path> [claude args...]
#   Runs: claude -p --output-format json [claude args...]
#   Writes the full JSON response to <out-json-path>.
#   Returns the claude exit code.
backend_run_capture() {
  local out_path="$1"; shift
  claude -p --output-format json "$@" > "$out_path"
}

# backend_run_stream <out-json-path> [claude args...]
#   Runs: claude -p --output-format stream-json --include-partial-messages
#         --verbose [claude args...]
#   Tees the raw stream-json to <out-json-path> while printing assistant text
#   live to stdout via jq with block-boundary newlines.  Requires jq on PATH.
#   Returns the claude exit code.
backend_run_stream() {
  local out_path="$1"; shift
  local pipe_status

  claude -p \
    --output-format stream-json \
    --include-partial-messages \
    --verbose \
    "$@" \
    | tee "$out_path" \
    | jq -rj --unbuffered '
        if .event.type == "content_block_delta" and .event.delta.type == "text_delta" then
          .event.delta.text
        elif .event.type == "content_block_stop" then
          "\n"
        elif .event.type == "message_stop" then
          "\n\n"
        else
          empty
        end
      ' 2>/dev/null \
    || true

  pipe_status=("${PIPESTATUS[@]}")
  return "${pipe_status[0]}"
}

# backend_parse_tokens <json-file> [field]
#   Reads a --output-format json result file and prints a token count summed
#   across all iterations (usage.iterations[]) when present, falling back to
#   the top-level .usage object for single-turn results.
#   field: input | output | cache_read | cache_creation | (omit for total)
#   Prints "unknown" on failure.
backend_parse_tokens() {
  local json_file="$1" field="${2:-total}"
  if [[ ! -f "$json_file" ]]; then
    echo "unknown"
    return 0
  fi
  local tokens
  tokens=$(jq -r --arg field "$field" '
    def pick_tok:
      if $field == "input"            then (.input_tokens // 0)
      elif $field == "output"         then (.output_tokens // 0)
      elif $field == "cache_read"     then (.cache_read_input_tokens // 0)
      elif $field == "cache_creation" then (.cache_creation_input_tokens // 0)
      else (.input_tokens // 0) + (.output_tokens // 0)
           + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
      end;
    if (.usage.iterations | length) > 0 then
      ([.usage.iterations[] | pick_tok] | add // 0)
    else
      (.usage | pick_tok)
    end | tostring
  ' "$json_file" 2>/dev/null) || tokens=""
  if [[ -z "$tokens" || "$tokens" == "null" || "$tokens" == "0" ]]; then
    echo "unknown"
  else
    echo "$tokens"
  fi
}

# backend_parse_stream_tokens <stream-json-file> [field]
#   Reads an accumulated stream-json file and sums token counts across all
#   message.usage events in the stream (not just the last one).
#   Prints "unknown" on failure.
#   field: input | output | cache_read | cache_creation | (omit for total)
backend_parse_stream_tokens() {
  local json_file="$1" field="${2:-total}"
  if [[ ! -f "$json_file" ]]; then
    echo "unknown"
    return 0
  fi
  local tokens
  tokens=$(jq -rs --arg field "$field" '
    [ .[] | select(.message?.usage? != null) | .message.usage ]
    | if length == 0 then "unknown"
      elif $field == "input"          then ([ .[].input_tokens // 0 ] | add | tostring)
      elif $field == "output"         then ([ .[].output_tokens // 0 ] | add | tostring)
      elif $field == "cache_read"     then ([ .[].cache_read_input_tokens // 0 ] | add | tostring)
      elif $field == "cache_creation" then ([ .[].cache_creation_input_tokens // 0 ] | add | tostring)
      else ([ .[] | (.input_tokens // 0) + (.output_tokens // 0)
                  + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) ]
           | add | tostring)
      end
  ' "$json_file" 2>/dev/null) || tokens="unknown"
  echo "${tokens:-unknown}"
}

# ── Legacy aliases (backwards compatibility) ──────────────────────────────────
claude_run_capture()        { backend_run_capture "$@"; }
claude_run_stream()         { backend_run_stream "$@"; }
parse_usage_tokens()        { backend_parse_tokens "$@"; }
parse_stream_usage_tokens() { backend_parse_stream_tokens "$@"; }
