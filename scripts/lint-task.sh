#!/usr/bin/env bash
# lint-task.sh — check a .agent/<task>/ package against the workflow contract.
#
# Verifies that the required sections from prompts/prompt_instructions.md are present
# in plan.md and that the Current Status block contains the required fields.
#
# Usage:
#   scripts/lint-task.sh <task-dir>          # lint one task package
#   scripts/lint-task.sh --repo [repo-path]  # lint every .agent/<task>/ under a repo
#
# Exits 0 when all checked tasks pass, 1 when any task has issues.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/task_store.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/task_store.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <task-dir>          lint one task package
  $(basename "$0") --repo [repo-path]  lint every .agent/<task>/ under a repo
  $(basename "$0") -h | --help         show this message

Environment:
  PAW_LINT_LENGTH  working-surface budget check; default: 1 (enabled).
                   Set PAW_LINT_LENGTH=0 to disable.
                   (blank lines and single-line HTML comment lines are excluded)

Exits 0 when all checked tasks pass, 1 when any task has issues, 2 on usage error.
EOF
}

REQUIRED_PLAN_SECTIONS=(
  "Objective"
  "Open Questions"
  "Acceptance Criteria"
  "Implementation Phases"
  "Scope"
  "Non-Goals"
  "Current Status"
  "Approval Boundaries"
  "Risk Classification"
  "Durable Documentation Requirements"
  "Validation Contract"
  "Decisions Made"
  "Changed Files"
  "Validation Performed"
  "Remaining Work"
  "Risks"
)

REQUIRED_SUMMARY_FIELDS=(
  "Plan position"
  "Estimated completion"
  "Next work"
)

# Returns 0 if the heading exists in the file. Heading match is loose:
# we look for "## " followed by text containing the section keyword.
has_section() {
  local file="$1" section="$2"
  grep -E "^##[[:space:]]+.*${section}" "$file" >/dev/null 2>&1
}

has_status_field() {
  local file="$1" field="$2"
  awk -v field="$field" '
    /^## Current Status[[:space:]]*$/ { in_block = 1; next }
    in_block && /^## / { in_block = 0 }
    in_block {
      pattern = "^- " field ":"
      if ($0 ~ pattern) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

check_unticked_when_done() {
  local plan="$1"
  local completion_line
  completion_line=$(awk '
    /^## Current Status[[:space:]]*$/ { in_block = 1; next }
    in_block && /^## / { in_block = 0 }
    in_block && /^- Estimated completion:/ { print; exit }
  ' "$plan")
  if [[ "$completion_line" == *"100%"* ]]; then
    # Only scan the Implementation Phases section for unticked items.
    local has_unticked
    has_unticked=$(awk '
      /^## Implementation Phases/ { in_phases = 1; next }
      in_phases && /^## / { in_phases = 0 }
      in_phases && /^- \[ \]/ { print; exit }
    ' "$plan")
    if [[ -n "$has_unticked" ]]; then
      echo "  WARN: plan.md claims 100% complete but still has unticked items"
      return 1
    fi
  fi
  return 0
}

check_completed_items_have_progress() {
  local plan="$1"
  local missing
  missing=$(awk '
    /^## Implementation Phases/ { in_phases = 1; next }
    in_phases && /^## / {
      if (awaiting_progress) {
        printf "%d:%s\n", pending_line, pending_text
        exit
      }
      in_phases = 0
    }
    !in_phases { next }
    awaiting_progress {
      if ($0 ~ /^[[:space:]]+Progress:/) {
        awaiting_progress = 0
        next
      }
      if ($0 ~ /^[[:space:]]+/) {
        next
      }
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*<!--.*-->[[:space:]]*$/) {
        next
      }
      printf "%d:%s\n", pending_line, pending_text
      exit
    }
    /^- \[x\]/ {
      awaiting_progress = 1
      pending_line = NR
      pending_text = $0
    }
    END {
      if (awaiting_progress) {
        printf "%d:%s\n", pending_line, pending_text
      }
    }
  ' "$plan")
  if [[ -n "$missing" ]]; then
    local line_number="${missing%%:*}"
    echo "  WARN: completed checklist item missing Progress: note directly beneath it (line $line_number)"
    return 1
  fi
  return 0
}

check_length_budget() {
  local plan="$1"
  local in_archive=0 working_lines=0
  # _html_re must be a variable: bash [[ =~ ]] misparsed < and > when the pattern
  # is written inline, treating them as redirects rather than regex metacharacters.
  local _html_re='^[[:space:]]*<!--.*-->[[:space:]]*$'
  while IFS= read -r line; do
    if [[ "$line" =~ ^###[[:space:]]+Archived ]]; then
      in_archive=1
    elif [[ $in_archive -eq 1 && "$line" =~ ^#{1,2}[[:space:]] ]]; then
      in_archive=0
    fi
    [[ $in_archive -eq 1 ]] && continue
    # Exclude blank lines and single-line HTML comment lines from the count.
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ $_html_re ]] && continue
    working_lines=$(( working_lines + 1 ))
  done < "$plan"
  if [[ $working_lines -gt 350 ]]; then
    echo "  WARN: plan.md working surface is $working_lines lines (budget: 350); archive older content under '### Archived ...' to stay within budget"
    return 1
  fi
  return 0
}

lint_one() {
  local task_dir="$1"
  local task_name
  task_name="$(basename "$task_dir")"
  local issues=0

  echo "task: $task_name"

  local plan="$task_dir/plan.md"
  if [[ ! -f "$plan" ]]; then
    echo "  ERROR: plan.md missing"
    issues=$((issues + 1))
  else
    for section in "${REQUIRED_PLAN_SECTIONS[@]}"; do
      if ! has_section "$plan" "$section"; then
        echo "  WARN: plan.md missing section: $section"
        issues=$((issues + 1))
      fi
    done

    for field in "${REQUIRED_SUMMARY_FIELDS[@]}"; do
      if ! has_status_field "$plan" "$field"; then
        echo "  WARN: Current Status missing field: $field"
        issues=$((issues + 1))
      fi
    done
    python3 "$SCRIPT_DIR/lib/quality_plan.py" "$plan" || issues=$((issues + 1))
    check_unticked_when_done "$plan" || issues=$((issues + 1))
    check_completed_items_have_progress "$plan" || issues=$((issues + 1))
    if [[ "${PAW_LINT_LENGTH:-1}" != "0" ]]; then
      check_length_budget "$plan" || issues=$((issues + 1))
    fi
  fi

  if [[ ! -f "$task_dir/contract.md" ]]; then
    echo "  INFO: contract.md missing (optional but recommended)"
  fi

  if [[ $issues -eq 0 ]]; then
    echo "  OK"
  fi

  return "$issues"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
  fi

  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac

  local total_issues=0

  if [[ "$1" == "--repo" ]]; then
    local repo_path="${2:-$PWD}"
    if [[ ! -d "$repo_path" ]]; then
      echo "error: '$repo_path' is not a directory" >&2
      exit 2
    fi
    local task_rows task_name _task_source task_dir
    task_rows="$(paw_task_list "$repo_path")"
    if [[ -z "$task_rows" ]]; then
      echo "no task directories found for $(paw_repo_physical_path "$repo_path")"
      exit 0
    fi
    while IFS=$'\t' read -r task_name _task_source task_dir; do
      [[ -n "$task_dir" ]] || continue
      lint_one "${task_dir%/}" || total_issues=$((total_issues + $?))
    done <<< "$task_rows"
  else
    lint_one "${1%/}" || total_issues=$((total_issues + $?))
  fi

  if [[ $total_issues -gt 0 ]]; then
    echo
    echo "lint failed: $total_issues issue(s)"
    exit 1
  fi
}

main "$@"
