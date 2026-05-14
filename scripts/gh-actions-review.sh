#!/usr/bin/env bash
# gh-actions-review.sh — inspect same-day GitHub Actions failures and optionally file one issue.
#
# Usage:
#   scripts/gh-actions-review.sh [--create-issue] [--date YYYY-MM-DD] [--repo OWNER/REPO]
#
# Options:
#   --create-issue      create one issue for the first undocumented failing pipeline
#   --date YYYY-MM-DD   override the day filter (default: local today)
#   --repo OWNER/REPO   override the repo (default: inferred via `gh repo view`)
#
# Environment:
#   PAW_GH_ACTIONS_RUN_LIMIT    max same-day runs to inspect (default: 100)
#   PAW_GH_ACTIONS_ISSUE_LIMIT  max open issues to fetch per candidate (default: 100)
#
# Requirements: gh (authenticated) and jq.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") [--create-issue] [--date YYYY-MM-DD] [--repo OWNER/REPO]" >&2
  exit 2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: '${1}' not found on PATH — install it and try again." >&2
    exit 1
  fi
}

normalize_text() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E $'s/\r//g; s/\x1B\\[[0-9;]*[[:alpha:]]//g; s#https?://[^[:space:]]+# #g' \
    | tr -cs 'a-z0-9' ' ' \
    | awk '{$1=$1; print}'
}

normalize_signature_text() {
  normalize_text "${1:-}" | sed -E '
    s/^[0-9]{4} [0-9]{2} [0-9]{2}t[0-9]{2} [0-9]{2} [0-9]{2}z[[:space:]]+//
    s/^(error|errors|fatal|failed|failure|exception|panic)[[:space:]]+//
  '
}

sanitize_search_term() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed 's/"/ /g' | awk '{$1=$1; print}'
}

extract_error_signature() {
  printf '%s\n' "${1:-}" | awk '
    BEGIN { IGNORECASE = 1 }
    {
      gsub(/\r/, "", $0)
      gsub(/\033\[[0-9;]*[[:alpha:]]/, "", $0)
      if ($0 ~ /error|exception|failed|failure|fatal|panic|timed out|timeout/) {
        sub(/^[[:space:]]+/, "", $0)
        print
        exit
      }
      if (first == "" && $0 ~ /[^[:space:]]/) {
        first = $0
      }
    }
    END {
      if (first != "") {
        print first
      }
    }
  ' | head -n1
}

emit_state() {
  local state="$1" repo="$2" date_ref="$3" workflow_name="$4" job_name="$5" run_url="$6" job_url="$7" signature="$8" issue_url="${9:-}" issue_number="${10:-}" issue_title="${11:-}"
  printf 'state: %s\nrepo: %s\ndate: %s\n' "$state" "$repo" "$date_ref"
  if [[ -n "$workflow_name" ]]; then
    printf 'workflow: %s\njob: %s\nrun_url: %s\njob_url: %s\nsignature: %s\n' \
      "$workflow_name" "$job_name" "$run_url" "$job_url" "$signature"
  fi
  if [[ -n "$issue_url" ]]; then
    printf 'issue_url: %s\n' "$issue_url"
  fi
  if [[ -n "$issue_number" ]]; then
    printf 'issue_number: %s\n' "$issue_number"
  fi
  if [[ -n "$issue_title" ]]; then
    printf 'issue_title: %s\n' "$issue_title"
  fi
}

FAIL_CONCLUSIONS_JSON='["failure","startup_failure","timed_out","action_required"]'

CREATE_ISSUE=0
DATE_REF=$(date +%Y-%m-%d)
REPO_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-issue)
      CREATE_ISSUE=1
      shift
      ;;
    --date)
      shift
      DATE_REF="${1:-}"
      [[ -n "$DATE_REF" ]] || { echo "error: --date requires YYYY-MM-DD" >&2; exit 2; }
      shift
      ;;
    --repo)
      shift
      REPO_ARG="${1:-}"
      [[ -n "$REPO_ARG" ]] || { echo "error: --repo requires OWNER/REPO" >&2; exit 2; }
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      ;;
  esac
done

require_command gh
require_command jq

PAW_GH_ACTIONS_RUN_LIMIT="${PAW_GH_ACTIONS_RUN_LIMIT:-100}"
PAW_GH_ACTIONS_ISSUE_LIMIT="${PAW_GH_ACTIONS_ISSUE_LIMIT:-100}"

if [[ -z "$REPO_ARG" ]]; then
  REPO_ARG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "error: could not determine repo. Run from a git repo or pass --repo OWNER/REPO." >&2
    exit 1
  }
fi

RUNS_JSON=$(gh run list \
  --repo "$REPO_ARG" \
  --limit "$PAW_GH_ACTIONS_RUN_LIMIT" \
  --created "$DATE_REF" \
  --json databaseId,displayTitle,event,headBranch,status,conclusion,createdAt,url,workflowName)

FAILING_RUNS=$(printf '%s\n' "$RUNS_JSON" | jq -c --argjson failing "$FAIL_CONCLUSIONS_JSON" '
  [
    .[]
    | select(.status == "completed")
    | select(.conclusion as $c | $failing | index($c))
  ]
')

if [[ "$(printf '%s\n' "$FAILING_RUNS" | jq 'length')" -eq 0 ]]; then
  emit_state "no-failures" "$REPO_ARG" "$DATE_REF" "" "" "" "" ""
  exit 0
fi

first_documented=""

while IFS= read -r run_entry; do
  [[ -n "$run_entry" ]] || continue

  run_id=$(printf '%s\n' "$run_entry" | jq -r '.databaseId')
  RUN_VIEW_JSON=$(gh run view "$run_id" --repo "$REPO_ARG" --json databaseId,displayTitle,event,headBranch,jobs,url,workflowName)

  CANDIDATE_JSON=$(printf '%s\n' "$RUN_VIEW_JSON" | jq -c --argjson failing "$FAIL_CONCLUSIONS_JSON" '
    . as $run
    | (($run.jobs // [])
      | map(select(.conclusion as $c | $failing | index($c)))
      | .[0]) as $job
    | select($job != null)
    | {
        runId: ($run.databaseId | tostring),
        workflowName: ($run.workflowName // "Unknown workflow"),
        runUrl: ($run.url // ""),
        displayTitle: ($run.displayTitle // ""),
        headBranch: ($run.headBranch // ""),
        event: ($run.event // ""),
        jobId: (($job.databaseId // $job.id) | tostring),
        jobName: ($job.name // "Unknown job"),
        jobUrl: (($run.url // "") + "/job/" + (($job.databaseId // $job.id) | tostring))
      }
  ')

  [[ -n "$CANDIDATE_JSON" ]] || continue

  workflow_name=$(printf '%s\n' "$CANDIDATE_JSON" | jq -r '.workflowName')
  run_url=$(printf '%s\n' "$CANDIDATE_JSON" | jq -r '.runUrl')
  job_id=$(printf '%s\n' "$CANDIDATE_JSON" | jq -r '.jobId')
  job_name=$(printf '%s\n' "$CANDIDATE_JSON" | jq -r '.jobName')
  job_url=$(printf '%s\n' "$CANDIDATE_JSON" | jq -r '.jobUrl')

  JOB_LOG=$(gh run view "$run_id" --repo "$REPO_ARG" --job "$job_id" --log-failed 2>/dev/null || true)
  signature_raw=$(extract_error_signature "$JOB_LOG")
  signature_norm=$(normalize_signature_text "$signature_raw")
  if [[ -z "$signature_raw" ]]; then
    signature_raw="No failed log line captured"
    signature_norm=$(normalize_signature_text "$signature_raw")
  fi

  workflow_term=$(sanitize_search_term "$workflow_name")
  job_term=$(sanitize_search_term "$job_name")
  signature_term=$(sanitize_search_term "$signature_raw")
  ISSUE_SEARCH_QUERY="\"$workflow_term\" \"$job_term\" \"$signature_term\""

  ISSUES_JSON=$(gh issue list \
    --repo "$REPO_ARG" \
    --state open \
    --limit "$PAW_GH_ACTIONS_ISSUE_LIMIT" \
    --search "$ISSUE_SEARCH_QUERY" \
    --json number,title,body,url)

  MATCHED_ISSUE=$(printf '%s\n' "$ISSUES_JSON" | jq -c \
    --arg workflow_norm "$(normalize_text "$workflow_name")" \
    --arg job_norm "$(normalize_text "$job_name")" \
    --arg signature_norm "$signature_norm" '
      map(
        . + {
          combinedNorm: (((.title // "") + "\n" + (.body // "")) | ascii_downcase | gsub("[^a-z0-9]+"; " "))
        }
      )
      | map(select(
          ((($signature_norm | length) > 0) and (.combinedNorm | contains($signature_norm)))
          or
          ((.combinedNorm | contains($workflow_norm)) and (.combinedNorm | contains($job_norm)) and (($signature_norm | length) > 0) and (.combinedNorm | contains($signature_norm)))
        ))
      | .[0] // empty
    ')

  if [[ -n "$MATCHED_ISSUE" ]]; then
    if [[ -z "$first_documented" ]]; then
      first_documented=$(jq -nc \
        --arg repo "$REPO_ARG" \
        --arg date "$DATE_REF" \
        --arg workflow "$workflow_name" \
        --arg job "$job_name" \
        --arg run_url "$run_url" \
        --arg job_url "$job_url" \
        --arg signature "$signature_raw" \
        --arg issue_url "$(printf '%s\n' "$MATCHED_ISSUE" | jq -r '.url')" \
        --arg issue_number "$(printf '%s\n' "$MATCHED_ISSUE" | jq -r '.number | tostring')" \
        --arg issue_title "$(printf '%s\n' "$MATCHED_ISSUE" | jq -r '.title')" \
        '{
          repo: $repo,
          date: $date,
          workflow: $workflow,
          job: $job,
          run_url: $run_url,
          job_url: $job_url,
          signature: $signature,
          issue_url: $issue_url,
          issue_number: $issue_number,
          issue_title: $issue_title
        }')
    fi
    continue
  fi

  if [[ "$CREATE_ISSUE" -eq 0 ]]; then
    emit_state "undocumented" "$REPO_ARG" "$DATE_REF" "$workflow_name" "$job_name" "$run_url" "$job_url" "$signature_raw"
    exit 0
  fi

  ISSUE_TITLE="GitHub Actions failure: $workflow_name / $job_name"
  ISSUE_BODY_FILE=$(mktemp)
  cat > "$ISSUE_BODY_FILE" <<EOF
## Summary

Same-day GitHub Actions failure detected in \`$REPO_ARG\`.

## Failure

- Date: $DATE_REF
- Workflow: $workflow_name
- Job: $job_name
- Workflow run: $run_url
- Job URL: $job_url
- Error signature: $signature_raw

## Notes

- Created by \`paw gh-actions-review --create-issue\`
- This flow intentionally creates at most one issue per invocation.
EOF

  ISSUE_CREATE_OUTPUT=$(gh issue create --repo "$REPO_ARG" --title "$ISSUE_TITLE" --body-file "$ISSUE_BODY_FILE")
  rm -f "$ISSUE_BODY_FILE"
  created_issue_url=$(printf '%s\n' "$ISSUE_CREATE_OUTPUT" | grep -Eo 'https://[^[:space:]]+/issues/[0-9]+' | tail -n1)
  if [[ -z "$created_issue_url" ]]; then
    echo "error: gh issue create did not return an issue URL." >&2
    exit 1
  fi
  created_issue_number=$(printf '%s\n' "$created_issue_url" | sed -E 's#.*/issues/([0-9]+)$#\1#')
  emit_state "created" "$REPO_ARG" "$DATE_REF" "$workflow_name" "$job_name" "$run_url" "$job_url" "$signature_raw" "$created_issue_url" "$created_issue_number" "$ISSUE_TITLE"
  exit 0
done < <(printf '%s\n' "$FAILING_RUNS" | jq -c '.[]')

if [[ -n "$first_documented" ]]; then
  emit_state "documented" \
    "$(printf '%s\n' "$first_documented" | jq -r '.repo')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.date')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.workflow')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.job')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.run_url')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.job_url')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.signature')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.issue_url')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.issue_number')" \
    "$(printf '%s\n' "$first_documented" | jq -r '.issue_title')"
  exit 0
fi

emit_state "no-failures" "$REPO_ARG" "$DATE_REF" "" "" "" "" ""
