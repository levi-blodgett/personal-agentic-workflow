# `tests/fixtures/`

Pre-built `.agent/<task>/` packages and JSON blobs used as test inputs by the bats suite. Each fixture is intentionally small and exercises one contract edge.

## Fixtures

| Directory | State | Used by |
|-----------|-------|---------|
| `sample-task-valid/` | `contract.md`, `plan.md`, and a legacy optional `pr.md` fixture present; all required sections exist in canonical order; `## Current Status` contains the required status fields. | `lint-task.bats` (valid-task pass), `list-tasks.bats`, CI smoke (`scripts/lint-task.sh tests/fixtures/sample-task-valid`). |
| `sample-task-missing-sections/` | Intentionally incomplete: one or more required sections are absent. `lint-task.sh` should warn and exit non-zero. | `lint-task.bats` (missing-sections warn). |
| `sample-task-bloated/` | `plan.md` exceeds the 350-line working-surface budget (real content lines, excluding blanks and HTML comment lines). `lint-task.sh` must WARN under `PAW_LINT_LENGTH=1`. | `lint-task.bats` (length-budget checks). |
| `backend-plugins/` | Executable fixture plugins that exercise the external `paw-backend-<name>` protocol without needing real remote services. | `paw-dispatcher.bats`. |
| `gh-pr-comments/` | JSON fixture files for the `gh-pr-comments.sh` tests. `unresolved.json` — one unresolved thread; `resolved.json` — one resolved thread. | `gh-pr-comments.bats`. |

## Adding a new fixture

1. Create a subdirectory under `tests/fixtures/<fixture-name>/`.
2. Add the relevant subset of the task docs (`contract.md`, `plan.md`, `pr.md`).
3. Aim for the smallest file that exercises the condition you want to test — fixtures are not meant to be realistic plans.
4. Add a row to the table above describing the state and which test file uses it.

The convention is: `*-valid` fixtures should pass `scripts/lint-task.sh`; `*-missing-*` or `*-broken-*` fixtures should not.
