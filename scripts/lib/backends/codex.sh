#!/usr/bin/env bash
# backends/codex.sh — OpenAI Codex CLI backend for paw.
#
# Implements the paw backend contract (see _iface.md).
# Source this file via: source "$LIB_DIR/backends/codex.sh"
#
# Required exports (backend contract):
#   backend_run_capture <out-json-path> [paw args...]
#   backend_run_stream  <out-json-path> [paw args...]
#   backend_parse_tokens <json-file> [field]
#   backend_parse_stream_tokens <json-file> [field]
#
# Optional capability exports:
#   backend_default_model       — returns gpt-6-astra when PAW_MODEL is unset
#   backend_usage_banner        — prints codex auth status to stderr at launch
#   backend_auth_mode           — prints api-key | chatgpt | unknown
#
# Arg translation: --model <val> → -m <val>; --add-dir passed through;
#   --permission-mode and --max-turns discarded; last positional arg is prompt.
# Sandbox: -s danger-full-access by default; set PAW_CODEX_DANGEROUS=1 to use
#   --dangerously-bypass-approvals-and-sandbox instead (for externally sandboxed CI).
# Always adds --ephemeral to avoid session-state bleed between paw runs.
# Token telemetry: parses current Codex JSONL usage (`turn.completed.usage`) and
#   older `token_count` events. `cached_input_tokens` is mapped to PAW's
#   cache_read/cache_creation fields because Codex does not expose a split.

_codex_warn_anthropic_model() {
  local model="$1"
  case "$model" in
    sonnet|haiku|opus|claude-*)
      echo "warn: model '$model' looks like an Anthropic model name; set PAW_MODEL to an OpenAI model (for example gpt-6-astra) for the codex backend." >&2 ;;
  esac
}

_codex_login_status() {
  codex login status 2>&1 || true
}

_codex_auth_mode_from_status() {
  local status_text="$1"
  case "$status_text" in
    *"ChatGPT"*) printf 'chatgpt\n' ;;
    *"OpenAI API key"*|*"API key"*) printf 'api-key\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

_codex_supported_chatgpt_model() {
  case "$1" in
    gpt-6-astra|gpt-5.4|gpt-5.5|gpt-5.4-mini|gpt-5.3-codex|gpt-5|gpt-5-mini|gpt-5-nano) return 0 ;;
    *) return 1 ;;
  esac
}

_codex_build_cmd() {
  local model=""
  local add_dirs=()
  _CODEX_PROMPT=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) shift; model="$1" ;;
      --add-dir) shift; add_dirs+=(--add-dir "$1") ;;
      --permission-mode|--max-turns) shift ;;
      *) _CODEX_PROMPT="$1" ;;
    esac
    shift
  done

  _CODEX_CMD=(codex exec --json -C "$PWD")
  [[ -n "$model" ]] && _CODEX_CMD+=(-m "$model")
  _CODEX_CMD+=("${add_dirs[@]}")
  _CODEX_CMD+=(--ephemeral)
  if [[ "${PAW_CODEX_DANGEROUS:-0}" == "1" ]]; then
    _CODEX_CMD+=(--dangerously-bypass-approvals-and-sandbox)
  else
    _CODEX_CMD+=(-s danger-full-access)
  fi
}

_codex_parse_usage_field() {
  local jsonl_file="$1" field="$2"
  [[ -f "$jsonl_file" ]] || { echo "unknown"; return 0; }
  local val
  val=$(jq -rs --arg f "$field" '
    def token_count_sum(name):
      [ .[] | select(type == "object" and .type? == "token_count") | .[name] // 0 ] | add;
    def turn_usage_sum(name):
      [ .[] | select(type == "object" and .type? == "turn.completed") | .usage[name] // 0 ] | add;
    if $f == "input" then
      (token_count_sum("input_tokens")) as $tc
      | if $tc > 0 then $tc else turn_usage_sum("input_tokens") end
    elif $f == "output" then
      (token_count_sum("output_tokens")) as $tc
      | if $tc > 0 then $tc else turn_usage_sum("output_tokens") end
    elif $f == "cached_input" then
      turn_usage_sum("cached_input_tokens")
    else
      -1
    end
    | if . < 0 then "unknown" else tostring end
  ' "$jsonl_file" 2>/dev/null) || val="unknown"
  if [[ -z "$val" || "$val" == "0" ]]; then
    echo "0"
  else
    echo "$val"
  fi
}

backend_run_capture() {
  local out_path="$1"; shift

  local msg_tmp jsonl_tmp
  msg_tmp=$(mktemp)
  jsonl_tmp=$(mktemp)
  trap 'trap - RETURN; rm -f "${msg_tmp:-}" "${jsonl_tmp:-}"' RETURN

  _codex_build_cmd "$@"
  _CODEX_CMD+=(-o "$msg_tmp")
  _CODEX_CMD+=("$_CODEX_PROMPT")

  local exit_code=0
  "${_CODEX_CMD[@]}" > "$jsonl_tmp" || exit_code=$?

  local final_text=""
  [[ -s "$msg_tmp" ]] && final_text=$(cat "$msg_tmp")

  local input_tok output_tok cached_input_tok
  input_tok=$(_codex_parse_usage_field "$jsonl_tmp" input)
  output_tok=$(_codex_parse_usage_field "$jsonl_tmp" output)
  cached_input_tok=$(_codex_parse_usage_field "$jsonl_tmp" cached_input)

  local input_tok_json output_tok_json cached_input_tok_json
  [[ "$input_tok" =~ ^[0-9]+$ ]] && input_tok_json="$input_tok" || input_tok_json="null"
  [[ "$output_tok" =~ ^[0-9]+$ ]] && output_tok_json="$output_tok" || output_tok_json="null"
  [[ "$cached_input_tok" =~ ^[0-9]+$ ]] && cached_input_tok_json="$cached_input_tok" || cached_input_tok_json="null"

  printf '{"result":%s,"input_tokens":%s,"output_tokens":%s,"cached_input_tokens":%s}\n' \
    "$(printf '%s' "$final_text" | jq -Rs .)" \
    "$input_tok_json" \
    "$output_tok_json" \
    "$cached_input_tok_json" \
    > "$out_path"

  return "$exit_code"
}

backend_run_stream() {
  local out_path="$1"; shift

  _codex_build_cmd "$@"
  _CODEX_CMD+=("$_CODEX_PROMPT")

  "${_CODEX_CMD[@]}" \
    | tee "$out_path" \
    | jq -rj --unbuffered '
        if .type == "agent_message_content_delta" then
          .delta // ""
        elif .type == "item.completed" and .item.type == "agent_message" then
          (.item.text // "") + "\n\n"
        elif .type == "task_complete" or .type == "turn.completed" then
          "\n\n"
        elif .type == "error" or .type == "turn.failed" then
          "paw/codex error: " + (
            (.message // .error.message // "unknown")
            | try (fromjson | .error.message // .) catch .
          ) + "\n\n"
        else
          empty
        end
      ' 2>/dev/null

  local _ps=("${PIPESTATUS[@]}")
  local _codex_rc="${_ps[0]}"
  [[ "$_codex_rc" -ne 0 ]] || [[ "${_ps[2]}" -eq 0 ]] || _codex_rc="${_ps[2]}"
  return "$_codex_rc"
}

backend_parse_tokens() {
  local json_file="$1" field="${2:-total}"
  if [[ ! -f "$json_file" ]]; then
    echo "unknown"
    return 0
  fi
  local tokens
  tokens=$(jq -r --arg f "$field" '
    if $f == "input" then (.input_tokens // empty | tostring)
    elif $f == "output" then (.output_tokens // empty | tostring)
    elif $f == "total" then
      ((.input_tokens // 0) + (.output_tokens // 0) + (.cached_input_tokens // 0))
      | if . == 0 then empty else tostring end
    elif $f == "cache_read" then (.cached_input_tokens // 0 | tostring)
    elif $f == "cache_creation" then "0"
    else empty
    end
  ' "$json_file" 2>/dev/null) || tokens=""
  if [[ -z "$tokens" || "$tokens" == "null" ]]; then
    echo "unknown"
  else
    echo "$tokens"
  fi
}

backend_parse_stream_tokens() {
  local json_file="$1" field="${2:-total}"
  case "$field" in
    input) _codex_parse_usage_field "$json_file" input ;;
    output) _codex_parse_usage_field "$json_file" output ;;
    cache_read) _codex_parse_usage_field "$json_file" cached_input ;;
    cache_creation) echo "0" ;;
    total)
      local input output cached
      input=$(_codex_parse_usage_field "$json_file" input)
      output=$(_codex_parse_usage_field "$json_file" output)
      cached=$(_codex_parse_usage_field "$json_file" cached_input)
      if [[ "$input" =~ ^[0-9]+$ && "$output" =~ ^[0-9]+$ && "$cached" =~ ^[0-9]+$ ]]; then
        echo $(( input + output + cached ))
      else
        echo "unknown"
      fi
      ;;
    *) echo "unknown" ;;
  esac
}

backend_default_model() {
  printf 'gpt-6-astra\n'
}

backend_auth_mode() {
  command -v codex >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  _codex_auth_mode_from_status "$(_codex_login_status)"
}

backend_usage_banner() {
  command -v codex >/dev/null 2>&1 || return 0
  local auth_line auth_mode model
  model="${PAW_MODEL:-gpt-6-astra}"
  _codex_warn_anthropic_model "$model"
  auth_line=$(_codex_login_status)
  auth_mode=$(_codex_auth_mode_from_status "$auth_line")
  if [[ "$auth_mode" == "chatgpt" ]] && ! _codex_supported_chatgpt_model "$model"; then
    echo "warn: model '$model' is not in PAW's supported ChatGPT model list; prefer gpt-6-astra by default." >&2
  fi
  echo "codex: $auth_line" >&2
}

codex_run_capture()         { backend_run_capture "$@"; }
codex_run_stream()          { backend_run_stream "$@"; }
parse_codex_tokens()        { backend_parse_tokens "$@"; }
parse_codex_stream_tokens() { backend_parse_stream_tokens "$@"; }
