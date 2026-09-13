#!/usr/bin/env bash
# Optional AI authoring audit of one task and branch body; never a workflow gate.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/task_store.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/task_store.sh"
task_dir="$1"
repo_path="${2:-$PWD}"
args=(--task "$task_dir")
if [[ -f "$repo_path/.github/pull_request_template.md" || -f "$repo_path/.github/PULL_REQUEST_TEMPLATE.md" ]]; then
  body="$(paw_task_branch_pr_body_file "$repo_path" "$task_dir")"
  [[ ! -f "$body" ]] || args+=("$body")
fi
python3 -B "$SCRIPT_DIR/lib/markdown_budget.py" "${args[@]}"
