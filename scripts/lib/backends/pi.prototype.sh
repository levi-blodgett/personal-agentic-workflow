#!/usr/bin/env bash
# backends/pi.prototype.sh — THROWAWAY prototype for a future Pi backend.
#
# This file is intentionally unwired from scripts/paw. It exists only to answer
# one prototype question: whether Pi can fit the current PAW backend seam
# without broad changes.
#
# Prototype stance:
# - use Pi's non-interactive JSON event mode (`-p --mode json`)
# - disable Pi's ambient context/session/package discovery by default
# - synthesize PAW-style capture JSON from Pi's final assistant message
# - treat assistant error stop reasons as backend failures, even if Pi exits 0

PI_PROTO_DEFAULT_MODEL="${PI_PROTO_DEFAULT_MODEL:-gpt-5.4}"
PI_PROTO_PROVIDER="${PI_PROTO_PROVIDER:-}"
PI_PROTO_MODEL_REF="${PI_PROTO_MODEL_REF:-}"
PI_PROTO_JSONL_FIXTURE="${PI_PROTO_JSONL_FIXTURE:-}"

backend_display_model() {
  local requested="${PI_PROTO_MODEL_REF:-$PI_PROTO_DEFAULT_MODEL}"
  if [[ -n "${PI_PROTO_PROVIDER:-}" && "$requested" != */* ]]; then
    printf '%s/%s\n' "$PI_PROTO_PROVIDER" "$requested"
  else
    printf '%s\n' "$requested"
  fi
}

backend_usage_banner() {
  local cli auth_file model
  cli=$(_pi_proto_cli_name)
  auth_file=$(_pi_proto_auth_file)
  model=$(backend_display_model)

  printf 'pi prototype: cli=%s model=%s\n' "$cli" "$model" >&2
  printf 'pi prototype: ambient features disabled (--no-session --no-context-files --no-extensions --no-skills --no-prompt-templates --no-themes)\n' >&2
  if [[ -n "${PI_PROTO_JSONL_FIXTURE:-}" ]]; then
    printf 'pi prototype: using fixture=%s\n' "$PI_PROTO_JSONL_FIXTURE" >&2
  fi
  if [[ -f "$auth_file" ]]; then
    printf 'pi prototype: auth file present at %s\n' "$auth_file" >&2
  else
    printf 'pi prototype: auth file missing at %s; ChatGPT subscription path requires pi /login first\n' "$auth_file" >&2
  fi
}

_pi_proto_cli_name() {
  if [[ -n "${PI_PROTO_BIN:-}" ]]; then
    printf '%s\n' "$PI_PROTO_BIN"
  elif command -v pi >/dev/null 2>&1; then
    printf 'pi\n'
  else
    printf 'npx:@earendil-works/pi-coding-agent\n'
  fi
}

_pi_proto_auth_file() {
  local agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  printf '%s/auth.json\n' "$agent_dir"
}

_pi_proto_extract_prompt() {
  local last=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model|--add-dir|--permission-mode|--max-turns)
        shift
        [[ $# -gt 0 ]] && shift
        continue
        ;;
      *)
        last="$1"
        shift
        ;;
    esac
  done
  printf '%s' "$last"
}

_pi_proto_extract_model() {
  local model="$PI_PROTO_DEFAULT_MODEL"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        shift
        [[ $# -gt 0 ]] && model="$1"
        ;;
    esac
    [[ $# -gt 0 ]] && shift
  done
  printf '%s' "$model"
}

_pi_proto_resolve_model_ref() {
  local model="$1"
  if [[ -n "${PI_PROTO_MODEL_REF:-}" ]]; then
    printf '%s\n' "$PI_PROTO_MODEL_REF"
  elif [[ "$model" == */* ]]; then
    printf '%s\n' "$model"
  elif [[ -n "${PI_PROTO_PROVIDER:-}" ]]; then
    printf '%s/%s\n' "$PI_PROTO_PROVIDER" "$model"
  else
    printf '%s\n' "$model"
  fi
}

_pi_proto_build_cmd() {
  local prompt="$1"
  local model_ref="$2"

  if [[ -n "${PI_PROTO_BIN:-}" ]]; then
    _PI_PROTO_CMD=("$PI_PROTO_BIN")
  elif command -v pi >/dev/null 2>&1; then
    _PI_PROTO_CMD=(pi)
  else
    _PI_PROTO_CMD=(npx -y @earendil-works/pi-coding-agent)
  fi

  _PI_PROTO_CMD+=(
    -p
    --mode json
    --no-session
    --no-context-files
    --no-extensions
    --no-skills
    --no-prompt-templates
    --no-themes
    --tools "read,bash,edit,write,grep,find,ls"
  )
  [[ -n "$model_ref" ]] && _PI_PROTO_CMD+=(--model "$model_ref")
  _PI_PROTO_CMD+=("$prompt")
}

_pi_proto_capture_from_jsonl() {
  local jsonl_path="$1"
  local out_path="$2"
  jq -rsc '
    def final_assistant:
      ([ .[] | select(.type == "message_end" and .message.role == "assistant") | .message ] | last)
      // ([ .[] | select(.type == "agent_end") | .messages[]? | select(.role == "assistant") ] | last)
      // {};
    def text_of(msg):
      [ msg.content[]? | select(.type == "text") | .text ] | join("");
    final_assistant as $m |
    {
      result: text_of($m),
      provider: ($m.provider // null),
      model: ($m.model // null),
      stop_reason: ($m.stopReason // null),
      error: ($m.errorMessage // null),
      usage: {
        input: ($m.usage.input // null),
        output: ($m.usage.output // null),
        cache_read: ($m.usage.cacheRead // null),
        cache_write: ($m.usage.cacheWrite // null),
        total: ($m.usage.totalTokens // null)
      }
    }
  ' "$jsonl_path" > "$out_path"
}

_pi_proto_capture_failed() {
  local json_file="$1"
  jq -e '.stop_reason == "error" or (.error // "") != ""' "$json_file" >/dev/null 2>&1
}

_pi_proto_require_runtime() {
  command -v jq >/dev/null 2>&1 || {
    echo "pi prototype error: jq is required" >&2
    return 1
  }
  if [[ -n "${PI_PROTO_JSONL_FIXTURE:-}" ]]; then
    [[ -f "$PI_PROTO_JSONL_FIXTURE" ]] || {
      echo "pi prototype error: fixture not found: $PI_PROTO_JSONL_FIXTURE" >&2
      return 1
    }
    return 0
  fi

  if [[ -n "${PI_PROTO_BIN:-}" ]]; then
    command -v "$PI_PROTO_BIN" >/dev/null 2>&1 || {
      echo "pi prototype error: PI_PROTO_BIN not found on PATH: $PI_PROTO_BIN" >&2
      return 1
    }
  elif ! command -v pi >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
    echo "pi prototype error: neither pi nor npx is available" >&2
    return 1
  fi
}

backend_run_capture() {
  local out_path="$1"
  shift

  _pi_proto_require_runtime || return 1

  local prompt model model_ref raw_path exit_code=0
  prompt=$(_pi_proto_extract_prompt "$@")
  model=$(_pi_proto_extract_model "$@")
  model_ref=$(_pi_proto_resolve_model_ref "$model")

  if [[ -n "${PI_PROTO_JSONL_FIXTURE:-}" ]]; then
    _pi_proto_capture_from_jsonl "$PI_PROTO_JSONL_FIXTURE" "$out_path"
    _pi_proto_capture_failed "$out_path" && return 1 || return 0
  fi

  raw_path=$(mktemp)
  _pi_proto_build_cmd "$prompt" "$model_ref"
  "${_PI_PROTO_CMD[@]}" > "$raw_path" || exit_code=$?
  _pi_proto_capture_from_jsonl "$raw_path" "$out_path"
  rm -f "$raw_path"

  if _pi_proto_capture_failed "$out_path"; then
    return 1
  fi
  return "$exit_code"
}

backend_run_stream() {
  local out_path="$1"
  shift

  _pi_proto_require_runtime || return 1

  local prompt model model_ref pipe_status rc=0
  prompt=$(_pi_proto_extract_prompt "$@")
  model=$(_pi_proto_extract_model "$@")
  model_ref=$(_pi_proto_resolve_model_ref "$model")
  : > "$out_path"

  if [[ -n "${PI_PROTO_JSONL_FIXTURE:-}" ]]; then
    tee "$out_path" < "$PI_PROTO_JSONL_FIXTURE" | while IFS= read -r line; do
      event_type=$(printf '%s\n' "$line" | jq -r '.type // empty' 2>/dev/null)
      if [[ "$event_type" == "message_update" ]]; then
        delta=$(printf '%s\n' "$line" | jq -r '
          if (.assistantMessageEvent.type // "") == "text_delta" then
            (.assistantMessageEvent.delta // .assistantMessageEvent.text // "")
          else
            empty
          end
        ' 2>/dev/null)
        if [[ -n "$delta" ]]; then
          printf '%s' "$delta"
        fi
      fi
    done
    pipe_status=("${PIPESTATUS[@]}")
    rc="${pipe_status[0]}"
  else
    _pi_proto_build_cmd "$prompt" "$model_ref"
    "${_PI_PROTO_CMD[@]}" | tee "$out_path" | while IFS= read -r line; do
      event_type=$(printf '%s\n' "$line" | jq -r '.type // empty' 2>/dev/null)
      if [[ "$event_type" == "message_update" ]]; then
        delta=$(printf '%s\n' "$line" | jq -r '
          if (.assistantMessageEvent.type // "") == "text_delta" then
            (.assistantMessageEvent.delta // .assistantMessageEvent.text // "")
          else
            empty
          end
        ' 2>/dev/null)
        if [[ -n "$delta" ]]; then
          printf '%s' "$delta"
        fi
      fi
    done
    pipe_status=("${PIPESTATUS[@]}")
    rc="${pipe_status[0]}"
  fi

  local capture_tmp had_deltas result_text error_text
  capture_tmp=$(mktemp)
  _pi_proto_capture_from_jsonl "$out_path" "$capture_tmp"
  had_deltas=$(jq -rsc 'any(.[]; .type == "message_update" and (.assistantMessageEvent.type // "") == "text_delta")' "$out_path" 2>/dev/null || printf 'false\n')
  result_text=$(jq -r '.result // ""' "$capture_tmp" 2>/dev/null || true)
  error_text=$(jq -r '.error // ""' "$capture_tmp" 2>/dev/null || true)
  if [[ "$had_deltas" != "true" && -n "$result_text" ]]; then
    printf '%s\n\n' "$result_text"
  fi
  if [[ -n "$error_text" ]]; then
    printf 'paw/pi error: %s\n\n' "$error_text"
  fi
  if _pi_proto_capture_failed "$capture_tmp"; then
    rc=1
  fi
  rm -f "$capture_tmp"
  return "$rc"
}

backend_parse_tokens() {
  local json_file="$1"
  local field="${2:-total}"
  [[ -f "$json_file" ]] || {
    printf 'unknown\n'
    return 0
  }
  jq -r --arg field "$field" '
    .usage as $u |
    if $field == "input" then
      ($u.input // "unknown")
    elif $field == "output" then
      ($u.output // "unknown")
    elif $field == "cache_read" then
      ($u.cache_read // 0)
    elif $field == "cache_creation" then
      ($u.cache_write // 0)
    elif $field == "total" then
      ($u.total // (
        ($u.input // 0) +
        ($u.output // 0) +
        ($u.cache_read // 0) +
        ($u.cache_write // 0)
      ))
    else
      "unknown"
    end
  ' "$json_file" 2>/dev/null || printf 'unknown\n'
}

backend_parse_stream_tokens() {
  local stream_file="$1"
  local field="${2:-total}"
  [[ -f "$stream_file" ]] || {
    printf 'unknown\n'
    return 0
  }

  local capture_tmp
  capture_tmp=$(mktemp)
  _pi_proto_capture_from_jsonl "$stream_file" "$capture_tmp"
  backend_parse_tokens "$capture_tmp" "$field"
  rm -f "$capture_tmp"
}
