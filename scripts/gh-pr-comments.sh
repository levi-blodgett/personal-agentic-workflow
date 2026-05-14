#!/usr/bin/env bash
# gh-pr-comments.sh — list unresolved PR review threads, review summaries, and PR comments.
#
# Output is grouped into three labelled sections emitted in this order:
#
#   INLINE path/to/file.ts:42
#     @author: comment body
#
#   REVIEW SUMMARY @author (REQUEST_CHANGES)
#     review body
#
#   PR COMMENT @author
#     comment body
#
# Usage:
#   scripts/gh-pr-comments.sh <pr-number> [--repo OWNER/REPO]
#
# Options:
#   --repo OWNER/REPO   override the repo (default: inferred via `gh repo view`)
#
# Environment:
#   PAW_PR_PAGE_LIMIT   max pages per collection (default: 10); warns to stderr on cap-hit
#
# Requirements: gh (authenticated via `gh auth login`), jq.
#
# Exits non-zero if gh or jq are missing, if gh is unauthenticated, or if
# the API call fails.

set -euo pipefail

# ── argument parsing ──────────────────────────────────────────────────────────

usage() {
  echo "usage: $(basename "$0") <pr-number> [--repo OWNER/REPO]" >&2
  exit 2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: '${1}' not found on PATH — install it and try again." >&2
    exit 1
  fi
}

PR_NUMBER="${1:-}"
[[ -z "$PR_NUMBER" ]] && usage
shift

REPO_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      shift
      REPO_ARG="${1:-}"
      [[ -z "$REPO_ARG" ]] && { echo "error: --repo requires OWNER/REPO" >&2; exit 2; }
      shift
      ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

require_command gh
require_command jq

PAW_PR_PAGE_LIMIT="${PAW_PR_PAGE_LIMIT:-10}"

# ── resolve owner/repo ────────────────────────────────────────────────────────

if [[ -z "$REPO_ARG" ]]; then
  REPO_ARG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "error: could not determine repo. Run from a git repo or pass --repo OWNER/REPO." >&2
    exit 1
  }
fi

OWNER="${REPO_ARG%%/*}"
REPO_NAME="${REPO_ARG#*/}"

TMPF=$(mktemp) || { echo "error: mktemp failed" >&2; exit 1; }
trap 'rm -f "$TMPF"' EXIT

# ── GraphQL queries ───────────────────────────────────────────────────────────

# shellcheck disable=SC2016  # $owner/$name/$pr/$after are GraphQL variables, not shell — single quotes intentional
QUERY_THREADS='
query($owner: String!, $name: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $after) {
        nodes {
          isResolved
          path
          line
          originalLine
          comments(first: 100) {
            nodes { author { login } body }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'

# shellcheck disable=SC2016
QUERY_REVIEWS='
query($owner: String!, $name: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviews(first: 100, after: $after) {
        nodes { author { login } body state }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'

# shellcheck disable=SC2016
QUERY_COMMENTS='
query($owner: String!, $name: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      comments(first: 100, after: $after) {
        nodes { author { login } body }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'

# ── fetch helper ──────────────────────────────────────────────────────────────

_call_gh() {
  # Writes raw JSON response to TMPF; exits non-zero on gh failure.
  local query="$1" after="${2:-}"
  local args=(-f query="$query" -f owner="$OWNER" -f name="$REPO_NAME" -F pr="$PR_NUMBER")
  [[ -n "$after" ]] && args+=(-f "after=$after")
  if ! gh api graphql "${args[@]}" > "$TMPF"; then
    echo "error: gh api graphql failed" >&2
    exit 1
  fi
}

# ── section printers ──────────────────────────────────────────────────────────

print_inline_threads() {
  local after="" page=0 has_next
  while true; do
    page=$(( page + 1 ))
    if (( page > PAW_PR_PAGE_LIMIT )); then
      echo "warning: PAW_PR_PAGE_LIMIT ($PAW_PR_PAGE_LIMIT) reached for reviewThreads; some items may be missing." >&2
      break
    fi
    _call_gh "$QUERY_THREADS" "$after"
    jq -r '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | . as $t
      | ("INLINE " + $t.path + ":" + (($t.line // $t.originalLine // "?") | tostring)),
        ($t.comments.nodes[] | "  @" + .author.login + ": " + .body),
        ""
    ' < "$TMPF"
    has_next=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' < "$TMPF")
    [[ "$has_next" != "true" ]] && break
    after=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' < "$TMPF")
  done
}

print_review_summaries() {
  local after="" page=0 has_next
  while true; do
    page=$(( page + 1 ))
    if (( page > PAW_PR_PAGE_LIMIT )); then
      echo "warning: PAW_PR_PAGE_LIMIT ($PAW_PR_PAGE_LIMIT) reached for reviews; some items may be missing." >&2
      break
    fi
    _call_gh "$QUERY_REVIEWS" "$after"
    jq -r '
      .data.repository.pullRequest.reviews.nodes[]
      | select(.body != null and .body != "")
      | ("REVIEW SUMMARY @" + .author.login + " (" + .state + ")"),
        ("  " + .body),
        ""
    ' < "$TMPF"
    has_next=$(jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage' < "$TMPF")
    [[ "$has_next" != "true" ]] && break
    after=$(jq -r '.data.repository.pullRequest.reviews.pageInfo.endCursor' < "$TMPF")
  done
}

print_pr_comments() {
  local after="" page=0 has_next
  while true; do
    page=$(( page + 1 ))
    if (( page > PAW_PR_PAGE_LIMIT )); then
      echo "warning: PAW_PR_PAGE_LIMIT ($PAW_PR_PAGE_LIMIT) reached for comments; some items may be missing." >&2
      break
    fi
    _call_gh "$QUERY_COMMENTS" "$after"
    jq -r '
      .data.repository.pullRequest.comments.nodes[]
      | ("PR COMMENT @" + .author.login),
        ("  " + .body),
        ""
    ' < "$TMPF"
    has_next=$(jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage' < "$TMPF")
    [[ "$has_next" != "true" ]] && break
    after=$(jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor' < "$TMPF")
  done
}

# ── main ──────────────────────────────────────────────────────────────────────

print_inline_threads
print_review_summaries
print_pr_comments
