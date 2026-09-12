#!/usr/bin/env bats
# Docs coverage for the paw completion workflow.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"
# shellcheck source=helpers/documentation.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/documentation.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Guides may be split or relocated without losing documented topics.
DOCS=("$REPO_ROOT/scripts/README.md" "$REPO_ROOT"/examples/docs/*.md)

@test "completion docs: README references the zsh completion workflow" {
  doc_contains 'source <(paw completion zsh)' "$REPO_ROOT/README.md"
}

@test "completion docs: operator docs cover the zsh-only v1 scope" {
  local topic
  for topic in 'autoload -U compinit' 'source <(paw completion zsh)' \
    'paw completion zsh >> ~/.zshrc' 'current shell' 'future shells' \
    'zsh-only' 'top-level subcommands'; do
    doc_contains "$topic" "${DOCS[@]}" || return 1
  done
}

@test "command authoring docs: shared command tables and helper contract are documented" {
  local topic
  for topic in '_paw_command_table()' '_paw_model_command_table()' \
    '_seed_task_templates()' '_join_prompt_extras()' \
    '_prompt_append_human_extras()' '_run_model_subcommand()' \
    'upstream skill' 'repo touchpoints'; do
    doc_contains "$topic" "${DOCS[@]}" || return 1
  done
}
