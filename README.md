# Personal Agentic Workflow (PAW)

[![Tests](https://github.com/levi-blodgett/personal-agentic-workflow/actions/workflows/tests.yml/badge.svg)](https://github.com/levi-blodgett/personal-agentic-workflow/actions/workflows/tests.yml)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](https://github.com/levi-blodgett/personal-agentic-workflow)

> ## "You can outsource your thinking, but you can't outsource your understanding."

PAW is a plan-first, file-backed framework for AI-assisted development. The human owns scope review and commits; the agent implements inside an approved task package and leaves a local audit trail behind.

This repo ships a GitHub PR template, so tasks planned here seed `.agent/<task>/pr.md` automatically.

```mermaid
flowchart LR
    A([prompt]) --> B[paw plan]
    B --> C{Human review}
    C -->|iterate| D[paw edit]
    D --> C
    C -->|approve| E[paw implement]
    E --> F([review & merge])
```

## Quick Start

```bash
# Install paw on your PATH
make install

# Optional: enable zsh subcommand completion for paw
autoload -U compinit && compinit
source <(paw completion zsh)   # current shell
paw completion zsh >> ~/.zshrc # future shells

# In any target repo, wire up local-only task tracking
paw setup

# Start a new task (plan-only run)
paw plan <task-name> "<prompt>"

# Implement / resume an approved task
paw implement <task-name>

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

`paw` defaults to the `codex` backend today. Switch backends with `PAW_BACKEND=<name>` when you need a shipped built-in (`claude` or the test-only `stub`) or an installed external plugin exposed as `paw-backend-<name>` on your `PATH`.

`paw completion zsh` prints a small `compdef` script for native `zsh` completion. Load it with `source <(paw completion zsh)` in the current shell, and append it to `~/.zshrc` for future shells. v1 is `zsh`-only and completes top-level subcommands only.

## Documentation

- [examples/docs/workflow.md](examples/docs/workflow.md) — end-to-end workflow, task-package contract, review gates, and operational constraints
- [examples/docs/cli-reference.md](examples/docs/cli-reference.md) — complete `paw` subcommand reference, Makefile targets, and runtime behavior
- [examples/docs/architecture.md](examples/docs/architecture.md) — repo layout and how templates, examples, and local `.agent/` state fit together
- [examples/docs/testing.md](examples/docs/testing.md) — canonical validation entrypoints and test-suite notes
- [examples/docs/backends.md](examples/docs/backends.md) — backend selection, model behavior, and streaming details
- [scripts/README.md](scripts/README.md) — CLI subcommands, helper scripts, and environment variables
- [tests/README.md](tests/README.md) — canonical validation entrypoints and bats suite notes
- [scripts/lib/README.md](scripts/lib/README.md) — shared helpers and backend modules
