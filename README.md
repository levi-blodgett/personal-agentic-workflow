# Personal Agentic Workflow (PAW)

[![Tests](https://github.com/levi-blodgett/personal-agentic-workflow/actions/workflows/tests.yml/badge.svg)](https://github.com/levi-blodgett/personal-agentic-workflow/actions/workflows/tests.yml)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](https://github.com/levi-blodgett/personal-agentic-workflow)

> ## "You can outsource your thinking, but you can't outsource your understanding." - Andrej Karpathy

PAW is a plan-first, file-backed framework for AI-assisted development. The human owns scope review and commits; the agent implements inside an approved task package and leaves a local audit trail behind.

New task packages are stored in a local central task store by default:
`${PAW_TASK_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/paw/tasks}`. Existing repo-local `.agent/<task>/` packages remain supported and can be copied into the central store with `paw task-migrate [repo-path ...]`.

```mermaid
flowchart LR
    A([prompt]) --> B[paw plan]
    B --> C{Human review}
    C -->|iterate| D[paw edit]
    D --> C
    C -->|approve| E[paw implement]
    E --> F([review & merge])
```

## Install

```bash
# Install paw on your PATH (symlinks this checkout's scripts/paw into ~/bin by default)
make install
```

### Optional zsh Completion

```bash
# Enable zsh subcommand completion
autoload -U compinit && compinit
source <(paw completion zsh)   # current shell
paw completion zsh >> ~/.zshrc # future shells
```

## Quick Start

```bash
# In any target repo, wire up local-only task tracking
paw setup

# Start a new task (plan-only run)
paw plan <task-name> "<prompt>"

# Implement / resume an approved task
paw implement <task-name>

# Launch several approved, unblocked tasks at once
paw implement-batch <task-a> <task-b>

# Optional local dashboard
paw gui
paw gui start --all
paw gui stop

# Optional legacy task migration
paw task-migrate
paw task-migrate ../other-repo ../third-repo

# Optional PR helpers after implementation
paw pr-submit <task-name>
paw pr-review <pr-number>
paw pr-address-comments <pr-number>

# Optional issue helpers
paw to-issues <task-name>
paw to-issues <task-name> --publish
paw issue-submit <task-name>
paw issue-review <issue-number>

# Optional same-day GitHub Actions triage
paw gh-actions-review
paw gh-actions-review --create-issue
```

`paw` defaults to the `codex` backend today. Shipped built-ins load from the checkout the launcher resolves through `PAW_HOME`, and external backends remain separate executables on your `PATH` exposed as `paw-backend-<name>`. Switch backends with `PAW_BACKEND=<name>` when you need one of those built-ins (`claude` or the test-only `stub`) or an installed external plugin.

`paw completion zsh` prints a small `compdef` script for native `zsh` completion. Load it with `source <(paw completion zsh)` in the current shell, and append it to `~/.zshrc` for future shells. v1 is `zsh`-only and completes top-level subcommands only.

`paw gui` starts a local task dashboard on `127.0.0.1` in the foreground. It renders task Markdown as safe HTML, filters the main table by state, repo, and completion, can launch `paw plan`, `paw edit`, `paw implement`, and selected-task batch implementation through the same CLI paths, and can delete a resolved task package after exact-name confirmation. `paw gui start` runs it in the background, records PID/URL metadata under `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/`, and `paw gui stop` or `paw gui kill` stops only that recorded PAW GUI process. Add `--all` to show every central task store grouped by repo identity; `--repo <path>` keeps the scoped central-plus-legacy view. The GUI never replaces `contract.md`, `plan.md`, or `pr.md` as the source of truth.

## Documentation

- [examples/docs/workflow.md](examples/docs/workflow.md) — end-to-end workflow, task-package contract, review gates, and operational constraints
- [examples/docs/cli-reference.md](examples/docs/cli-reference.md) — complete `paw` subcommand reference, Makefile targets, and runtime behavior
- [examples/docs/architecture.md](examples/docs/architecture.md) — repo layout and how templates, examples, and local `.agent/` state fit together
- [examples/docs/testing.md](examples/docs/testing.md) — canonical validation entrypoints and test-suite notes
- [examples/docs/backends.md](examples/docs/backends.md) — backend selection, model behavior, and streaming details
- [scripts/README.md](scripts/README.md) — CLI subcommands, helper scripts, and environment variables
- [tests/README.md](tests/README.md) — canonical validation entrypoints and bats suite notes
- [scripts/lib/README.md](scripts/lib/README.md) — shared helpers and backend modules
