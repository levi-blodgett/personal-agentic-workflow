#!/usr/bin/env bash
# crash_log.sh — helpers for recording and displaying crash entries.
#
# Source this file; then call crash_log_record, crash_classify, crash_log_show,
# crash_extract_api_code, and crash_color_status.
#
# crash_log_record <task_dir> <exit_code> <model> <subcommand> <stderr_file> <json_file>
#   Appends a crash record to <task_dir>/crash.log.
#   Each record is delimited by === ... --- blocks and contains: timestamp,
#   exit code, api_code, model, subcommand, classification, estimated input
#   tokens (parsed from json_file when jq is available), and the last 20 lines
#   of stderr.
#
# crash_classify <exit_code> <stderr_file> [json_file]
#   Prints a human-readable cause string.  When json_file is provided, the
#   .error.type field (if present) is extracted and prepended to the cause.
#   Priority order: content_filter → too_many_requests → rate_limit →
#   overloaded → context_overflow → timeout → OOM/killed → API error → unknown.
#
# crash_extract_api_code <stderr_file>
#   Prints the first 4xx/5xx HTTP status code found in stderr, or nothing.
#
# crash_log_show <task_dir>
#   Prints crash.log when present; otherwise prints "no crashes recorded".
#
# crash_color_status <exit_code> <api_code> <classification>
#   Prints a colored status line to stderr after every backend call.
#   Green on exit 0; red with [api_code or classification] on non-zero.
#   Suppressed by NO_COLOR or PAW_NO_COLOR (any non-empty value).

crash_extract_api_code() {
  local stderr_file="$1"
  if [[ ! -f "$stderr_file" ]]; then return 0; fi
  # Return the first 4xx/5xx HTTP status code found in stderr.
  grep -oE '[45][0-9][0-9]' "$stderr_file" | head -1 || true
}

crash_classify() {
  local exit_code="$1" stderr_file="$2" json_file="${3:-}"
  local stderr_text=""
  if [[ -f "$stderr_file" ]]; then
    stderr_text=$(cat "$stderr_file")
  fi

  # Try to extract error type from JSON output (e.g. "content_filter", "overloaded").
  local json_type=""
  if [[ -n "$json_file" && -f "$json_file" ]] && command -v jq >/dev/null 2>&1; then
    json_type=$(jq -r '.error.type // empty' "$json_file" 2>/dev/null || true)
    if [[ -z "$json_type" ]]; then
      # Fall back to .error when it is a plain string (not an object).
      json_type=$(jq -r 'if .error | type == "string" then .error else empty end' \
        "$json_file" 2>/dev/null || true)
    fi
  fi

  # Combine stderr and JSON type for pattern matching; dot in patterns acts as
  # a wildcard so "content.filter" matches both "content_filter" and "content filter".
  local _check="${stderr_text} ${json_type}"

  # Classification priority order — match most-specific first.
  local cause
  if echo "$_check" | grep -qi \
      "content.filter\|content.polic\|harmful content\|moderation\|flagged\|output blocked"; then
    cause="content_filter"
  elif echo "$_check" | grep -qi "429\|too many requests\|too_many_requests\|request.*limit"; then
    cause="too_many_requests"
  elif echo "$stderr_text" | grep -qi "rate limit"; then
    cause="rate limit"
  elif echo "$_check" | grep -qi "overloaded\|service.*unavailable\|503"; then
    cause="overloaded"
  elif echo "$stderr_text" | grep -qi \
      "context window\|context length\|too long\|maximum context\|context overflow"; then
    cause="context overflow"
  elif echo "$stderr_text" | grep -qi "timeout\|timed out\|deadline exceeded"; then
    cause="timeout"
  elif echo "$stderr_text" | grep -qi "out of memory\|oom\|killed\|signal 9"; then
    cause="OOM/killed"
  elif echo "$stderr_text" | grep -qi "api error\|internal server error\| 500\| 502"; then
    cause="API error"
  elif [[ "$exit_code" -eq 130 ]]; then
    cause="interrupted (SIGINT)"
  elif [[ "$exit_code" -eq 143 ]]; then
    cause="terminated (SIGTERM)"
  else
    cause="unknown (exit ${exit_code})"
  fi

  # Prepend JSON error type when it provides additional context.
  if [[ -n "$json_type" ]]; then
    echo "${json_type}: ${cause}"
  else
    echo "$cause"
  fi
}

crash_log_record() {
  local task_dir="$1" exit_code="$2" model="$3" subcommand="$4"
  local stderr_file="$5" json_file="$6"
  local crash_log="${task_dir}/crash.log"

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M %Z')

  local api_code
  api_code=$(crash_extract_api_code "$stderr_file")

  local classification
  classification=$(crash_classify "$exit_code" "$stderr_file" "$json_file")

  # Estimate input tokens from json_file when jq is available.
  local est_tokens="unknown"
  if [[ -f "$json_file" ]] && command -v jq >/dev/null 2>&1; then
    local _t
    _t=$(jq -r '.usage.input_tokens // empty' "$json_file" 2>/dev/null || true)
    if [[ -n "$_t" && "$_t" =~ ^[0-9]+$ ]]; then
      est_tokens="$_t"
    fi
  fi

  # Capture last 20 lines of stderr.
  local stderr_tail="(none)"
  if [[ -f "$stderr_file" && -s "$stderr_file" ]]; then
    stderr_tail=$(tail -20 "$stderr_file")
  fi

  {
    echo "==="
    echo "timestamp:      ${timestamp}"
    echo "exit_code:      ${exit_code}"
    echo "api_code:       ${api_code:-none}"
    echo "model:          ${model}"
    echo "subcommand:     ${subcommand}"
    echo "classification: ${classification}"
    echo "input_tokens:   ${est_tokens}"
    echo "stderr:"
    echo "${stderr_tail}"
    echo "---"
  } >> "$crash_log"
}

crash_log_show() {
  local task_dir="$1"
  local crash_log="${task_dir}/crash.log"
  if [[ -f "$crash_log" ]]; then
    cat "$crash_log"
  else
    echo "no crashes recorded"
  fi
}

crash_color_status() {
  local exit_code="$1" api_code="${2:-}" classification="${3:-}"
  local _use_color=1
  if [[ -n "${NO_COLOR:-}" || -n "${PAW_NO_COLOR:-}" ]]; then
    _use_color=0
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    if [[ "$_use_color" -eq 1 ]]; then
      printf '\033[0;32mpaw: exit 0\033[0m\n' >&2
    else
      printf 'paw: exit 0\n' >&2
    fi
    return 0
  fi

  # Show api_code if available; fall back to classification string.
  local _label="${api_code:-${classification:-}}"
  if [[ "$_use_color" -eq 1 ]]; then
    printf '\033[0;31mpaw: exit %s%s\033[0m\n' \
      "$exit_code" "${_label:+ [${_label}]}" >&2
  else
    printf 'paw: exit %s%s\n' \
      "$exit_code" "${_label:+ [${_label}]}" >&2
  fi
}
