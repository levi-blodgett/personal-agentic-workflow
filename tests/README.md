# PAW Test Suite

Bash tests for the PAW scripts, written with [bats-core](https://github.com/bats-core/bats-core).

## Install bats-core

```bash
# macOS
brew install bats-core

# or via npm
npm install -g bats
```

## Run all tests

```bash
bats tests/
make test
make check
```

Run a single file:

```bash
bats tests/lint-task.bats
```

## Test files

| File | Covers |
|---|---|
| `setup-repo.bats` | `scripts/setup-repo.sh` |
| `list-tasks.bats` | `scripts/list-tasks.sh` |
| `lint-task.bats` | `scripts/lint-task.sh` |
| `task-store.bats` | central task-store resolution, metadata, legacy fallback, and explicit multi-repo migration helpers |
| `gui-server.bats` | `paw gui` Markdown rendering, main-table filters, combined repo/branch display, local plan/edit/implement actions, guarded deletion, foreground smoke, managed start/stop/kill lifecycle, stale PID protection, and multi-repo dashboard coverage |
| `makefile.bats` | `Makefile` targets (install, uninstall, help, -n dry-runs) |
| `paw-dispatcher.bats` | `scripts/paw` subcommand dispatch, worktree resume, and launcher behavior |
| `paw-completion-docs.bats` | Durable docs coverage for `paw completion zsh` and the narrowed `zsh`-only scope |
| `paw-codex.bats` | Default codex backend wiring, auth banner, sandbox flags, and usage parsing |
| `paw-crash.bats` | Crash classification, crash log writing, and prompt-size warnings |
| `paw-prompt-body.bats` | Prompt body + launch banner for every subcommand (stub backend) |
| `paw-pr-workflow.bats` | Shell-side `paw pr-submit` / `paw pr-review` workflow coverage |
| `paw-issue-workflow.bats` | Shell-side `paw issue-submit` / `paw issue-review` / `paw to-issues --publish` workflow coverage |
| `paw-gh-actions-workflow.bats` | Shell-side `paw gh-actions-review` dispatch and flag-forwarding coverage |
| `paw-compact.bats` | `paw compact` subcommand (archive-on-tick and idempotency) |
| `templates.bats` | Template file structure and `prompts/prompt_instructions.md` anchor guarantees |
| `gh-pr-comments.bats` | `scripts/gh-pr-comments.sh` (stub `gh` on PATH, reads JSON fixtures) |
| `gh-actions-review.bats` | `scripts/gh-actions-review.sh` (stub `gh` on PATH, hermetic run/issue triage coverage) |

## Fixtures

`tests/fixtures/` holds pre-built `.agent/<task>/` packages and JSON responses used as input:

- `sample-task-valid/` — all required sections present; lint must pass
- `sample-task-missing-sections/` — required sections intentionally absent; lint must warn
- `sample-task-bloated/` — plan exceeds the 350-line working-surface budget; triggers PAW_LINT_LENGTH=1 warn
- `backend-plugins/` — executable backend-plugin fixtures used by dispatcher tests
- `gh-pr-comments/` — JSON GraphQL responses for `gh-pr-comments.bats` (`unresolved.json`, `resolved.json`)

## Helpers

`tests/helpers/` contains shared bash utilities sourced by every test file:

| File | Purpose |
|------|---------|
| `hermetic.bash` | Sets `LC_ALL=C`, `LANG=C`, `TZ=UTC` and unsets all `PAW_*` env vars so tests behave identically on macOS (BSD coreutils) and Linux (GNU coreutils) CI. |
| `exit_code` | bats-core helper (loaded via `load`) for asserting specific exit codes. |

## Notes

- `paw-dispatcher.bats` uses a PATH-shimmed `claude` fake for the dispatcher-focused tests that still exercise the Anthropic backend path.
- `paw-prompt-body.bats` uses `PAW_BACKEND=stub`, so no real backend binary is required. The stub backend (`scripts/lib/backends/stub.sh`) writes
  the full argv and resolved prompt body to `$BATS_TEST_TMPDIR/backend.{args,prompt,mode}`.
- Task-store and GUI tests set `PAW_TASK_HOME` and, for lifecycle cases, `XDG_STATE_HOME` to `$BATS_TEST_TMPDIR` so central-store and GUI metadata behavior is hermetic and never writes to the operator's real local state.
- New top-level `paw` commands should usually extend both files above: dispatcher coverage locks the public command/model surface, and prompt-body coverage locks the shared prompt/template helpers.
- `paw-pr-workflow.bats`, `paw-issue-workflow.bats`, and `paw-gh-actions-workflow.bats` cover the shell-side GitHub workflow commands, including saved tracking metadata, issue-draft publication ordering, flag forwarding, and rerun behavior.
- `paw-codex.bats` stubs the Codex CLI. External-plugin seam coverage stays in `paw-dispatcher.bats`; backend-specific compatibility checks for separately distributed plugins should live with those plugin repos.
- `makefile.bats` requires `make` on `PATH` (pre-installed on `ubuntu-latest` and macOS).
- Tests that need a real git repo create a temporary one in `$BATS_TEST_TMPDIR`
  and clean up on teardown.
