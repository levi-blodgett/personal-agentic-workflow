# Testing

How to install and run the PAW test suite, plus which commands count as canonical validation for docs and code changes.

The `tests/` directory contains a [bats-core](https://github.com/bats-core/bats-core) suite covering the `paw` CLI, helper scripts, backend adapters, and task-package contract checks.

```bash
# Install bats (macOS)
brew install bats-core

# Run the full bats suite
bats tests/

# Or use the repo entrypoints
make test
make shellcheck
make check   # canonical full validation: test + lint + shellcheck
```

For day-to-day implementation wrap-up, start with the task plan's targeted changed-area validation and record the validation tier plus rationale in `plan.md`. Escalate to broader or full validation when the change touches shared/high-risk code, workflow or CI files, security-sensitive behavior, targeted checks fail, the blast radius is unclear, a user or reviewer asks for it, or the task is PR-ready and full validation has not otherwise run. `make check` remains the reusable full-suite gate, followed by manual `git status` / `git diff` review. See [`tests/README.md`](../../tests/README.md) for fixture details and per-file coverage.

Key implementation details:

- `paw-dispatcher.bats` uses a PATH-shimmed `claude` fake for dispatcher and worktree-resume tests.
- The dispatcher suite covers subcommand help/completion output, task-assignment resume behavior, and shell-side launcher behavior without calling live backends.
- `paw-pr-workflow.bats` covers the shell-side `paw pr-submit` / `paw pr-review` flow, including PR tracking metadata and saved `review.md` drafts.
- `paw-issue-workflow.bats` covers the shell-side `paw issue-submit` / `paw issue-review` / `paw to-issues --publish` flow, including `issue.md` tracking metadata, per-draft issue metadata, dependency-ordered publication, and rerun refreshes of fetched issue bodies.
- `paw-prompt-body.bats` uses `PAW_BACKEND=stub` so prompt-body assertions never need a real backend binary.
- Dedicated `paw-codex.bats` coverage stays in this repo, while backend-specific compatibility checks for separately distributed plugins should live with each plugin repo; PAW itself keeps seam-level external-plugin coverage in `paw-dispatcher.bats`.
- Every `*.bats` file sources `tests/helpers/hermetic.bash`, which sets `LC_ALL=C`, `LANG=C`, and `TZ=UTC` and unsets all `PAW_*` env vars so tests behave identically on macOS and Linux CI runners.
