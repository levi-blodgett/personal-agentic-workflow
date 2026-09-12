# `scripts/`

| Script | Responsibility |
|---|---|
| [paw](paw) | CLI dispatcher, prompt assembly and workflow orchestration; [command reference](../examples/docs/cli-reference.md) |
| [install-paw.sh](install-paw.sh) | Exact checkout-owned launcher links; [installation](../examples/docs/install.md) |
| [setup-repo.sh](setup-repo.sh) | Local `.agent/` exclusion |
| [list-tasks.sh](list-tasks.sh) / [lint-task.sh](lint-task.sh) | Central/legacy status and contract checks |
| [gh-pr-comments.sh](gh-pr-comments.sh) | Paginated unresolved PR feedback; [format](../examples/docs/cli-diagnostics.md#gh-pr-comments-scriptsgh-pr-commentssh) |
| [gh-actions-review.sh](gh-actions-review.sh) | Same-day failure triage and optional deduplicated issue creation |
| [lib](lib/README.md) | Shared storage, GUI, review and backend modules |

## Environment variables

Shared overrides (backend-specific behavior: [backends](../examples/docs/backends.md)):

| Variable | Default | Purpose |
|----------|---------|---------|
| `PAW_HOME` | derived from the resolved `paw` launcher path | Templates/instructions root and resource path passed to backends; built-ins/helpers always use the resolved launcher checkout |
| `PAW_INSTRUCTIONS` | `$PAW_HOME/prompts/prompt_instructions.md` | Override path to the workflow instructions file |
| `PAW_MODEL` | backend-specific | Model override for all model-resolved AI subcommands (`paw plan`, `paw architecture`, `paw teach`, `paw review`, `paw prototype`, `paw edit`, `paw implement`, `paw diagnose`, `paw tighten`, `paw to-issues`, `paw issue-review`, and `paw pr-address-comments`) |
| `PAW_MAX_TURNS` | `100` | `--max-turns` value passed to the backend |
| `PAW_STREAM` | `0` | Set to `1` to stream live output; JSON-streaming backends require `jq` |
| `PAW_BACKEND` | `codex` | Backend name: resolves either `scripts/lib/backends/<name>.sh` or an external `paw-backend-<name>` executable on `PATH` |
| `PAW_BROWSE_PAGER` | unset | Pager override for `paw browse`; set to `cat` for deterministic stdout in scripts and tests |
| `PAW_PROMPT_OPTIMIZE` | `0` | Set to `1` to run the opt-in haiku pre-optimizer for `paw plan` |
| `PAW_PROMPT_WARN_TOKENS` | `150000` | Context-pressure telemetry threshold used for the 75% "building" warning and 100% overflow-risk warning before backend invocation |
| `PAW_TASK_HOME` | `${XDG_STATE_HOME:-$HOME/.local/state}/paw/tasks` | Central local task-store root. Tests and advanced users can override it. |
| `PAW_CODEX_DANGEROUS` | `0` | Codex backend only: use dangerous no-sandbox mode instead of `-s danger-full-access` |
| `PAW_LINT_LENGTH` | retired | AI authors keep Markdown within 150 physical lines; no runtime length check. |
When these defaults matter operationally, defer to `paw model` and the backend docs: when `PAW_MODEL` is unset, resolution still varies by backend, and `codex` is the current default backend.


## Adding commands

Register public commands in `_paw_command_table()` and model-resolved AI commands
in `_paw_model_command_table()`. Reuse `_seed_task_templates()`, `_join_prompt_extras()`,
`_prompt_append_human_extras()`, `_prompt_pr_md_usage_note()`, branch PR helpers and
`_run_model_subcommand()`; use task_store helpers for lookup, metadata and status.
Extend dispatcher/prompt-body regressions and update the [CLI reference](../examples/docs/cli-usage.md#shared-command-authoring-contract).
Record inspected upstream skills/repo touchpoints in the task package.

PR commands resolve canonical branch bodies through `task_store.sh`; review lookup
selects structural task-owned tracking before unique shared-body fallback. Ambiguous
old filenames and conflicting owners produce recovery diagnostics before remote calls.
