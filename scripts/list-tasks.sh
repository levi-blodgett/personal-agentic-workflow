#!/usr/bin/env bash
# list-tasks.sh — list PAW task packages for a repo and print their status.
#
# For each task directory it prints:
#   <task-name> (<central|legacy>)
#       Plan position:       <value>
#       Estimated completion: <value>
#       Next work:           <value>
#       Running:             yes|no
#
# Values come from the "Current Status" block in plan.md
# (see prompts/prompt_instructions.md for the required format).
#
# Usage:
#   scripts/list-tasks.sh [repo-path]
#
# If repo-path is omitted, the current directory is used.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/task_store.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/task_store.sh"

repo_path="${1:-$PWD}"

if [[ ! -d "$repo_path" ]]; then
  echo "error: '$repo_path' is not a directory" >&2
  exit 1
fi

task_rows="$(paw_task_list "$repo_path")"
repo_path="$(paw_repo_physical_path "$repo_path")"

if [[ -z "$task_rows" ]]; then
  echo "no task directories found for $repo_path"
  if [[ ! -d "$repo_path/.agent" ]]; then
    echo "    no .agent/ legacy directory found"
  fi
  echo "    central store: $(paw_task_repo_store "$repo_path")"
  echo "    legacy store:  $repo_path/.agent"
  exit 0
fi

while IFS=$'\t' read -r task_name task_source task_dir; do
  [[ -n "$task_name" ]] || continue
  plan_file="$task_dir/plan.md"

  printf '%s (%s)\n' "$task_name" "$task_source"

  if [[ ! -f "$plan_file" ]]; then
    echo "    (no plan.md)"
    continue
  fi

  plan_position="$(paw_task_plan_field "$plan_file" "Plan position")"
  estimated_completion="$(paw_task_plan_field "$plan_file" "Estimated completion")"
  next_work="$(paw_task_plan_field "$plan_file" "Next work")"

  printf '    Plan position:        %s\n' "${plan_position:-<missing>}"
  printf '    Estimated completion: %s\n' "${estimated_completion:-<missing>}"
  printf '    Next work:            %s\n' "${next_work:-<missing>}"
  if paw_task_has_active_run "$task_dir"; then
    printf '    Running:              yes\n'
  else
    printf '    Running:              no\n'
  fi
done <<< "$task_rows"
