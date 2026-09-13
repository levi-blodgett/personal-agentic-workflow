#!/usr/bin/env bash
# Require each caller-selected topic while permitting Markdown prose reflow.
doc_contains() {
  local topic="$1" text
  shift
  text="$(awk '{ for (i = 1; i <= NF; i++) printf "%s ", $i }' "$@")" || return
  if [[ "$text" != *"$topic"* ]]; then
    printf 'Missing documentation topic: %s\n' "$topic" >&2
    return 1
  fi
}
