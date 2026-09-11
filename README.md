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

# Review completed task quality, then optionally plan a replacement
paw review <task-name>
paw prototype <task-name>

# Hide a task from active task lists without deleting it
paw archive <task-name>

# Launch several approved, unblocked tasks at once
paw implement-batch <task-a> <task-b>

# Optional local dashboard
paw gui
paw gui start --all
paw gui restart
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

Implementation wrap-up uses targeted validation first: run the changed-area commands named in the task plan, record the validation tier and rationale in `plan.md`, then escalate to broader or full validation when risk warrants it. `make check` remains the canonical full-suite gate for PR-ready or high-risk handoffs.

`paw review <task-name>` launches a short task-quality review and records the reviewed scope, grade, optional overall workflow/subsystem grade, quality threshold comparison, architectural/design choices, production-readiness blockers, improvement notes, and recommendations in `review.md`. Successful `paw implement` runs compare the saved task head to the post-run worktree and record newly changed tracked paths as `paw.prototype-owned-path` metadata when provenance is safe to prove; otherwise they record `paw.prototype-provenance-status/message` instead of guessing. When reviewed work should become a prototype rather than the final approach, `paw prototype <task-name>` creates a new plan-only `<task-name>-prototype` package from the task docs plus `review.md`, marks prototype lineage in metadata, and conservatively reverts only tracked source-task files proven by saved owned-path metadata. Replacement planning exits successfully and remains in place even when cleanup is blocked or unavailable; operators should read `paw.prototype-status` and `paw.prototype-cleanup-message` for the manual follow-up reason. `paw browse <task-name>` opens the resolved task package's Markdown docs in the terminal, resolving central tasks before legacy `.agent/<task>/` packages; set `PAW_BROWSE_PAGER=cat` for plain stdout. `paw archive <task-name>` moves a central task package under that repo store's `.archive/` folder so normal CLI and GUI listings omit it.

`paw gui` starts a local task dashboard on `127.0.0.1:8765` in the foreground by default; pass `--port 0` when you explicitly want an ephemeral localhost port. It renders task Markdown as safe HTML, sorts tasks newest-first by recent run or task metadata, keeps the index and task detail views fresh with local polling, hides state/repo/completion filters by default, and presents each task as a Stage/Next workflow with a primary control for the next eligible step. Use the Add repo path form to register another existing local Git repo, then switch the Active repo dropdown to change the scoped central-plus-legacy task list and the target repo for new Plan actions without restarting the server. The local repo registry lives at `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/repos.gitconfig`; `--repo <path>` seeds the startup/default repo. Reviewed tasks show their non-pending `review.md` grade as a color-coded badge in the `Next` column; reviewed-task prototype controls are labelled `Use as Prototype`, and grades of `A-` or higher disable GUI prototype actions. The dashboard uses a compact Home/Archived/title header, a responsive wide shell, scrollable dense tables, and expandable path details so full repo/task/store paths remain available without dominating the view. Task names open details; row actions begin with Archive, then concise edit, approval-preview, delete, and `plan.md` preview controls. Tasks with saved PAW branch metadata and an existing local branch also show `View PR`; clicking it looks up the current PR with `gh pr view <branch>` and returns a local page linking to the PR URL without creating or editing remote state. Implementation-ready tasks show `Approve Implementation`, which opens an in-window `plan.md` preview with controls to run `paw edit`, inspect the manual `plan.md` path, or approve the unchanged `paw implement` launch. The top action row keeps Plan separate from a selected-task Archive/Delete dropdown. Plan prompts can also be queued locally from the Plan overlay, reviewed later in that overlay, triggered through the normal `paw plan` flow, or removed. Running tasks with live PID-bearing PAW run metadata and matching GUI-created stdout/stderr logs show `Stream` to the left of `Cancel`; the task detail page also embeds a polling live log panel, and the standalone stream page tails bounded task-local logs under `runs/`. Pidless or stale running metadata remains blocked instead of exposing unsafe process signalling or log guesses. The Archived header link opens central `.archive` packages for the current scope, where they can be unarchived when no active package would be overwritten. GUI actions collect optional plan/edit/review/prototype instructions in overlays where needed, launch implementation without GUI extras after approval, and delete a resolved task package only after confirmation plus exact path match. CLI `paw implement-batch` remains available for concurrent approved implementation, but the GUI no longer exposes selected mass implementation. Blocked tasks with `USER ANSWER` placeholders expose an `Answer Questions` edit overlay that displays parseable pending questions and passes submitted answers to `paw edit`; the GUI does not write answers directly into `plan.md`. `paw gui start` runs it in the background, records PID/URL metadata under `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/`, and `paw gui restart` replaces only that recorded PAW GUI process while reusing its recorded host, port, repo, task-home, and `--all` mode unless options override them. `paw gui stop` or `paw gui kill` stops only that recorded PAW GUI process. Add `--all` to show every central task store grouped by repo identity; in that mode the Active repo dropdown still controls where new Plan actions launch. The GUI never replaces `contract.md`, `plan.md`, `review.md`, or `runs/` logs as the source of truth.

## Documentation

- [examples/docs/workflow.md](examples/docs/workflow.md) — end-to-end workflow, task-package contract, review gates, and operational constraints
- [examples/docs/cli-reference.md](examples/docs/cli-reference.md) — complete `paw` subcommand reference, Makefile targets, and runtime behavior
- [examples/docs/architecture.md](examples/docs/architecture.md) — repo layout and how templates, examples, and local `.agent/` state fit together
- [examples/docs/testing.md](examples/docs/testing.md) — canonical validation entrypoints and test-suite notes
- [examples/docs/backends.md](examples/docs/backends.md) — backend selection, model behavior, and streaming details
- [scripts/README.md](scripts/README.md) — CLI subcommands, helper scripts, and environment variables
- [tests/README.md](tests/README.md) — canonical validation entrypoints and bats suite notes
- [scripts/lib/README.md](scripts/lib/README.md) — shared helpers and backend modules
