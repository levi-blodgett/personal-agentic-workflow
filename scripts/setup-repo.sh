#!/usr/bin/env bash
# setup-repo.sh — prepare a target repo for the personal-agentic-workflow.
#
# Adds `.agent/` to the repo's local `.git/info/exclude` so legacy/imported AI
# working docs stay untracked without committing a `.gitignore` change. New task
# packages use the central local task store by default.
#
# Usage:
#   scripts/setup-repo.sh [repo-path]
#
# If repo-path is omitted, the current directory is used.

set -euo pipefail

repo_path="${1:-$PWD}"

if [[ ! -d "$repo_path" ]]; then
  echo "error: '$repo_path' is not a directory" >&2
  exit 1
fi

cd "$repo_path"

if [[ ! -d .git ]]; then
  echo "error: '$repo_path' is not a git repository (no .git directory)" >&2
  exit 1
fi

exclude_file=".git/info/exclude"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"

if grep -qxF '.agent/' "$exclude_file"; then
  echo "ok: '.agent/' already excluded in $repo_path/$exclude_file"
else
  printf '.agent/\n' >> "$exclude_file"
  echo "added: '.agent/' to $repo_path/$exclude_file"
fi
