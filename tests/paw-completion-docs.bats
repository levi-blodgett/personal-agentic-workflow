#!/usr/bin/env bats
# Docs coverage for the paw completion workflow.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

run_doc_match() {
  run grep -En -- "$1" "${@:2}"
}

@test "completion docs: README references the zsh completion workflow" {
  run_doc_match "paw completion zsh|autoload -U compinit|source <\\(paw completion zsh\\)|current shell|future shells" \
    "$REPO_ROOT/README.md"

  [ "$status" -eq 0 ]
}

@test "completion docs: operator docs cover the zsh-only v1 scope" {
  run_doc_match "paw completion zsh|zsh-only|top-level subcommands only|current shell immediately|future shells|already-open shell does not change|source <\\(paw completion zsh\\)" \
    "$REPO_ROOT/scripts/README.md" \
    "$REPO_ROOT/examples/docs/cli-reference.md"

  [ "$status" -eq 0 ]
}

@test "command authoring docs: shared command tables and helper contract are documented" {
  run_doc_match "_paw_command_table\\(\\)|_paw_model_command_table\\(\\)|_seed_task_templates\\(\\)|_join_prompt_extras\\(\\)|_prompt_append_human_extras\\(\\)|_run_model_subcommand\\(\\)|upstream skill files|repo touchpoints" \
    "$REPO_ROOT/scripts/README.md" \
    "$REPO_ROOT/examples/docs/cli-reference.md"

  [ "$status" -eq 0 ]
}
