#!/usr/bin/env bash
# list-tasks.sh — list .agent/<task>/ directories in a repo and print their status.
#
# For each task directory it prints:
#   <task-name>
#       Plan position:       <value>
#       Estimated completion: <value>
#       Next work:           <value>
#
# Values come from the "Current Status" block in plan.md
# (see prompts/prompt_instructions.md for the required format).
#
# Usage:
#   scripts/list-tasks.sh [repo-path]
#
# If repo-path is omitted, the current directory is used.

set -euo pipefail

repo_path="${1:-$PWD}"

if [[ ! -d "$repo_path" ]]; then
  echo "error: '$repo_path' is not a directory" >&2
  exit 1
fi

agent_dir="$repo_path/.agent"

if [[ ! -d "$agent_dir" ]]; then
  echo "no .agent/ directory found in $repo_path"
  exit 0
fi

shopt -s nullglob
tasks=("$agent_dir"/*/)
shopt -u nullglob

if [[ ${#tasks[@]} -eq 0 ]]; then
  echo "no task directories under $agent_dir/"
  exit 0
fi

extract_field() {
  local file="$1" label="$2"
  # Match "- <label>:" inside the "## Current Status" block.
  awk -v label="$label" '
    /^## Current Status[[:space:]]*$/ { in_block = 1; next }
    in_block && /^## / { in_block = 0 }
    in_block {
      pattern = "^- " label ":[[:space:]]*"
      if ($0 ~ pattern) {
        sub(pattern, "", $0)
        print $0
        exit
      }
    }
  ' "$file"
}

for task_dir in "${tasks[@]}"; do
  task_name="$(basename "$task_dir")"
  plan_file="${task_dir%/}/plan.md"

  echo "$task_name"

  if [[ ! -f "$plan_file" ]]; then
    echo "    (no plan.md)"
    continue
  fi

  plan_position="$(extract_field "$plan_file" "Plan position")"
  estimated_completion="$(extract_field "$plan_file" "Estimated completion")"
  next_work="$(extract_field "$plan_file" "Next work")"

  printf '    Plan position:        %s\n' "${plan_position:-<missing>}"
  printf '    Estimated completion: %s\n' "${estimated_completion:-<missing>}"
  printf '    Next work:            %s\n' "${next_work:-<missing>}"
done
