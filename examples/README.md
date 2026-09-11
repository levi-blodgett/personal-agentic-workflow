# `examples/`

Committed examples, including the [external backend installer](backend-plugin/README.md) and
[backend author guide](docs/backends.md), plus reference task packages showing what a real `.agent/<task-name>/` directory looks like after a task has actually been executed end-to-end.

## Contents

| Directory | Description |
|-----------|-------------|
| [`example-task/`](example-task/) | A hypothetical task (`add-version-flag`) demonstrating a completed task package: `contract.md`, `plan.md`, and `pr.md`. All implementation phases are marked `- [x]`, each completed checkbox has an inline `Progress:` note, and the `## Validation Performed` section shows the wrap-up result. |

## Usage

Read these files when the empty templates are not enough. `templates/` gives you the canonical blank skeleton; `examples/` shows the filled-in shape of a finished task, including realistic status updates, validation logging, and handoff notes. Actual `.agent/<task-name>/` directories in target repos remain local-only via `.git/info/exclude` and are never committed.
