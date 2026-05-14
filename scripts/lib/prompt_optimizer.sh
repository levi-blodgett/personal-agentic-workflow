#!/usr/bin/env bash
# prompt_optimizer.sh — haiku pre-optimizer for paw plan prompts.
#
# Source this file; then call prompt_optimize.
#
# When PAW_PROMPT_OPTIMIZE=1, prompt_optimize fires a haiku call that rewrites
# the raw user prompt + the plan template structure into a tighter, more
# structured form before the main plan model run.
#
# prompt_optimize <task_dir> <raw_prompt>
#   Prints the optimized prompt to stdout.
#   When PAW_PROMPT_OPTIMIZE != 1, prints the raw prompt unchanged (pass-through).
#   The haiku call is suppressed when the backend CLI is unavailable.
#
# Dependencies (must be sourced before this file):
#   backends/<name>.sh  — backend_parse_tokens

_OPTIMIZER_MODEL="haiku"
_OPTIMIZER_SYSTEM="You are a prompt-engineering assistant. Rewrite the given planning prompt into a tighter, more structured form that will help a planning agent produce a concise, accurate implementation plan. Preserve all requirements and constraints. Remove filler phrases and redundant context. Output ONLY the rewritten prompt — no explanation, no preamble."

prompt_optimize() {
  local raw_prompt="$2"

  if [[ "${PAW_PROMPT_OPTIMIZE:-0}" != "1" ]]; then
    printf '%s' "$raw_prompt"
    return 0
  fi

  # Require the claude backend CLI.
  if ! command -v claude >/dev/null 2>&1; then
    echo "warn: PAW_PROMPT_OPTIMIZE=1 but \`claude\` not on PATH; skipping optimizer" >&2
    printf '%s' "$raw_prompt"
    return 0
  fi

  local tmp_json
  tmp_json=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_json'" RETURN

  # Run haiku call: -p with json output.  Feed the raw prompt as the user turn.
  claude -p \
    --output-format json \
    --model "$_OPTIMIZER_MODEL" \
    --max-turns 1 \
    --system "$_OPTIMIZER_SYSTEM" \
    "$raw_prompt" > "$tmp_json" 2>/dev/null || true

  # Extract the optimized prompt text.
  local optimized
  optimized=$(jq -r '.result // empty' "$tmp_json" 2>/dev/null || true)

  if [[ -n "$optimized" ]]; then
    printf '%s' "$optimized"
  else
    echo "warn: prompt optimizer returned empty result; using raw prompt" >&2
    printf '%s' "$raw_prompt"
  fi
}
