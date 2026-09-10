# `scripts/`

Scripts that power the `paw` CLI and its helper utilities.

> **Quick start:** a top-level [`Makefile`](../Makefile) wraps the most common operator commands. Run `make help` from the repo root to see all targets.

## Top-level scripts

| Script | Purpose |
|--------|---------|
| [`paw`](paw) | Main CLI wrapper for the plan/edit/implement/diagnose/tighten/prototype workflow plus lightweight repo teaching, architecture review, PR/issue helpers, lint, compact, migration, local GUI, and setup. `paw plan` seeds one task package in the central task store by default, investigates repo landmark files directly, and records the current branch/worktree assignment when inside Git. `paw gui` foregrounds the read-only localhost dashboard, `paw gui start` records managed background PID/URL metadata, `paw gui stop`/`kill` stop only that recorded process, and `paw gui --all` shows every central task store grouped by repo identity. `paw teach` is a lighter-weight top-level explainer that maps the relevant modules and callers for an unfamiliar area using repo vocabulary, without creating a dedicated task package or silently writing durable docs. `paw architecture` explores the repo first, saves numbered candidates under `.agent/architecture/candidates.md`, and resumes the selected candidate via `--pick <n>` plus `.agent/architecture/grill.md`. `paw prototype` runs a bounded throwaway prototype workflow for one concrete question, seeds `prototype.md` as the required durable verdict record, and keeps prototype runs distinct from production implementation tasks. `paw diagnose` reuses the same approved task package and branch/worktree safety rules as `paw implement`, but adds a feedback-loop-first debugging workflow with reviewable debug notes in `plan.md`. `paw tighten` stays plan-only, sharpens an existing task package one question at a time, and seeds `tighten.md` as the interactive checkpoint while leaving `plan.md` as the actual plan source of truth. `paw edit`, `paw implement`, `paw diagnose`, `paw tighten`, `paw prototype`, `paw to-issues`, `paw pr-submit`, `paw pr-review`, and `paw issue-submit` try to resume the saved assignment when safe. For full subcommand behavior and examples, see [`examples/docs/cli-reference.md`](../examples/docs/cli-reference.md). |
| [`setup-repo.sh`](setup-repo.sh) | Adds `.agent/` to a target repo's `.git/info/exclude` so task docs stay local-only. |
| [`list-tasks.sh`](list-tasks.sh) | Lists central-store and legacy `.agent/<task>/` packages found for a repo, with their current status line. |
| [`lint-task.sh`](lint-task.sh) | Verifies a task package (or all central/legacy packages for a repo) against the single-plan workflow contract. Exits non-zero when issues are found. |
| [`gh-pr-comments.sh`](gh-pr-comments.sh) | Fetches unresolved PR review comments from GitHub via `gh api graphql` + `jq`, emitting the same three labelled groups documented in the CLI reference: `INLINE path:line`, `REVIEW SUMMARY @author (state)`, and `PR COMMENT @author`. Used by `paw pr-address-comments` and the first pass of `paw pr-review`. Requires `gh` (authenticated) and `jq`. |
| [`gh-actions-review.sh`](gh-actions-review.sh) | Reviews same-day GitHub Actions failures in the current repo, checks open issues for a deterministic match based on workflow/job names plus normalized failing-log text, and when `--create-issue` is present creates at most one linked issue for the first undocumented failing pipeline. Requires `gh` (authenticated) and `jq`. |

## `lib/` — shared helpers

See [`lib/README.md`](lib/README.md) for the helper files and the pluggable backend system.

## Environment variables

All env vars are documented in the `paw` header comment and in `paw help`. Short reference:

| Variable | Default | Purpose |
|----------|---------|---------|
| `PAW_HOME` | derived from the resolved `paw` launcher path | Path to the PAW checkout whose built-ins/templates/docs should be used |
| `PAW_INSTRUCTIONS` | `$PAW_HOME/prompts/prompt_instructions.md` | Override path to the workflow instructions file |
| `PAW_MODEL` | backend-specific | Model override for all model-resolved AI subcommands (`paw plan`, `paw architecture`, `paw teach`, `paw prototype`, `paw edit`, `paw implement`, `paw diagnose`, `paw tighten`, `paw to-issues`, `paw issue-review`, and `paw pr-address-comments`) |
| `PAW_MAX_TURNS` | `100` | `--max-turns` value passed to the backend |
| `PAW_STREAM` | `0` | Set to `1` to stream live output; JSON-streaming backends require `jq` |
| `PAW_BACKEND` | `codex` | Backend name: resolves either `scripts/lib/backends/<name>.sh` or an external `paw-backend-<name>` executable on `PATH` |
| `PAW_PROMPT_OPTIMIZE` | `0` | Set to `1` to run the opt-in haiku pre-optimizer for `paw plan` |
| `PAW_PROMPT_WARN_TOKENS` | `150000` | Context-pressure telemetry threshold used for the 75% "building" warning and 100% overflow-risk warning before backend invocation |
| `PAW_TASK_HOME` | `${XDG_STATE_HOME:-$HOME/.local/state}/paw/tasks` | Central local task-store root. Tests and advanced users can override it. |
| `PAW_CODEX_DANGEROUS` | `0` | Codex backend only: use dangerous no-sandbox mode instead of `-s danger-full-access` |
| `PAW_LINT_LENGTH` | `1` | Working-surface budget check (350-line limit) in `paw lint` / `lint-task.sh`. Default is enabled; set `PAW_LINT_LENGTH=0` to disable. (blank lines and single-line HTML comment lines excluded) |
When these defaults matter operationally, defer to `paw model` and the backend docs: when `PAW_MODEL` is unset, resolution still varies by backend, and `codex` is the current default backend.

## Adding commands

Future top-level `paw` commands should extend the shared shell scaffolding instead of cloning existing command bodies.

- Register every public command once in `_paw_command_table()` so help text, completion generation, and dispatch stay aligned.
- Register every AI-backed command in `_paw_model_command_table()` so `paw model` stays in sync with the actual prompt-running surface.
- Reuse `_seed_task_templates()`, `_join_prompt_extras()`, `_prompt_append_human_extras()`, `_prompt_pr_md_usage_note()`, and `_run_model_subcommand()` before adding new one-off heredoc plumbing.
- Reuse `scripts/lib/task_store.sh` for task package creation, lookup, repo-wide listing, and migration; do not hard-code new `$PWD/.agent/<task>` lookups.
- Reuse `scripts/lib/gui_lifecycle.sh` for managed GUI PID/URL metadata and process signalling; keep browser-facing GUI routes read-only.
- Preserve existing task-package semantics unless the task plan explicitly changes them; shared scaffolding should not silently widen workflow behavior.
- If a command introduces a command-specific task artifact (for example `prototype.md` for `paw prototype`), seed it deterministically and document the lifecycle contract in the operator docs.
- When a command adapts an upstream skill or workflow, record the exact upstream skill files inspected and the repo touchpoints inspected in the child task package so future resumes know what source material actually informed the implementation.
- Keep task-package semantics single-task and deterministic unless an approved plan explicitly changes that contract.

Minimum shared coverage for a new command:

- `tests/paw-dispatcher.bats` for help/dispatch/model-surface behavior when applicable.
- `tests/paw-prompt-body.bats` for the prompt anchor, task-path references, extras behavior, and launch banner.
- `examples/docs/cli-reference.md` plus this file for operator-facing behavior changes.
