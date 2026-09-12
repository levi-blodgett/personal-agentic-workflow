# CLI Reference

[Workflow](workflow.md) owns approval, task storage, review and cleanup policy;
[GUI](gui.md) covers dashboard operation. Use `paw help` for the dispatcher synopsis.
All task-relative filenames below refer to the resolved central/legacy package.

## `paw` CLI

```text
paw plan <task-name> "<prompt>" [--dry-run]
paw architecture [--pick <candidate-number>] [focus...]
paw teach [focus...]
paw review <task-name> [extras...]
paw prototype <task-name> [extras...]
paw implement <task-name> [extras...]
paw implement-batch <task-name>...
paw diagnose <task-name> [extras...]
paw tighten <task-name> [extras...]
paw edit <task-name> [extras...]
paw to-issues <task-name> [--publish]
paw task-migrate [repo-path ...]
paw gui [start|stop|restart|kill] [--host 127.0.0.1] [--port 0|<port>] [--repo <path>] [--all]
paw completion zsh
paw pr-update <task-name> [--publish <preview-token>]
paw pr-submit <task-name> [--publish <preview-token>]
paw issue-submit <task-name>
paw pr-review <pr-number>
paw issue-review <issue-number>
paw pr-address-comments <pr-number>
paw gh-actions-review [--create-issue]
paw compact <task-name>
paw archive <task-name>
paw browse <task-name>
paw list [repo-path]
paw lint [task-dir|--repo p]
paw model [-v|--verbose]
paw setup [repo-path]
paw crash-log <task-name>
paw help
```

| Commands | Behavior / output |
|---|---|
| plan | Seed central task docs, record current assignment, inspect repo landmarks; `--dry-run` prints prompt without invoking backend. |
| edit / implement | Refine plan only / execute approved scope; optional trailing text becomes Human extras. |
| diagnose | Approved debugging: reproduce → hypothesize → instrument → fix → cleanup; keep debug notes in plan. |
| tighten | Plan-only, one highest-value question with recommended answer; discover repo answers locally. `tighten.md` tracks interaction, `plan.md` owns approval. |
| teach | Explain modules/callers/vocabulary; no task package or automatic durable-doc writing. |
| architecture | Save numbered candidates in `.agent/architecture/candidates.md`; `--pick` continues through `grill.md`; extras work on either pass. Durable design capture is optional. |
| review / prototype | Task-quality review / plan-only replacement followed by guarded cleanup; see [review rules](workflow.md#review-completion-and-inherited-findings). Old prototype `--question`, `--logic`, `--ui` flags are rejected with compatibility guidance. |
| implement-batch | Preflight all approved selections, launch normal implement children concurrently; [limits](workflow.md#branch-and-worktree-assignment). |
| to-issues | Draft `issues/index.md` and one issue file per slice. `--publish` sends reviewed drafts in dependency order, updates per-draft metadata and plan tracking. |
| pr-update | Preview a completed A-/higher reviewed task contribution; `--publish TOKEN` edits the exact open branch PR or creates a draft after confirmed absence. Manual commit/push only. |
| pr-submit | Same review, preview and visual gates; create-only, with guidance to use pr-update when a PR exists. [Publication and recovery](publication-workflow.md#reviewed-task-pr-publication). |
| issue-submit | Require `issue.md`, create issue and record number/URL in plan/issue. |
| pr-review | First fetch comments and save `review.md` for the PR task; later submit that saved draft as a COMMENT review. Separate from task-quality review. |
| issue-review | Refresh issue title/body into `issue.md` in `<number>-issue-review`; plan only from saved issue body. |
| pr-address-comments | Fetch `comments.md` into `<number>-review`, then plan only; execute later with approved `paw implement <number>-review`. |
| gh-actions-review | Inspect same-day failures; `--create-issue` creates at most one issue for the first undocumented pipeline, matching existing issues by workflow/job and normalized failing log. |
| compact / archive | Archive completed checklist detail / move central package out of active lists; [storage](workflow.md#architecture-of-workflow). |
| browse | Aggregate available Markdown and crash log with headings; missing optional docs skipped. Pager: PAW_BROWSE_PAGER → PAGER → less -R → stdout. |
| task-migrate / setup | Explicit legacy copy into central store / exclude `.agent/` locally. |
| list / lint | Current task status/running metadata / contract checks; lint exits nonzero for violations. |
| model | Resolved models; `-v` adds backend, streaming and max turns. Configuration reporting does not verify execution. |
| gui | Local foreground/managed dashboard; [options and lifecycle](gui.md#start-and-stop). |
| completion / crash-log / help | zsh subcommands / saved failure diagnostics / command synopsis. |

Issue drafts keep `## Draft Metadata`: stable slug, HITL/AFK type, blocker slugs,
submission status and eventual issue fields. `--publish` submits pending drafts and
rewrites blockers to published URLs. The index includes the review quiz. Issue submission
records `## Issue Tracking`; issue-review excludes comments unless later scope authorizes them.
PR-comment plans retain every item as addressed, deferred-with-reason or declined-with-reason;
implementation re-fetches feedback before handoff to catch newly posted comments.

GitHub helpers require authenticated `gh`; comment fetch/triage also requires `jq`.
They publish only on the corresponding explicit command, not from the GUI.

### Task Store And GUI

See [Command usage and authoring](cli-usage.md).

### Crash log (`paw crash-log`)

See [CLI diagnostics](cli-diagnostics.md).

## Makefile

| Target | Purpose |
|---|---|
| help | List targets (default) |
| install / uninstall | [Checkout-owned symlink](install.md); PREFIX is executable directory, default ~/bin |
| test | `bats tests/` |
| lint / list | Central/legacy repo task contracts / listings |
| shellcheck | Shell scripts and backend modules |
| check | test + lint + shellcheck; required final full local validation |
| ci-deps | Install Bats, jq and ShellCheck for CI |

Run make from the checkout or use `make -C /path/to/checkout`.
[Test-suite instructions](../../tests/README.md) distinguish local full validation from CI.

## Model And Backend Behavior

See [backend defaults, hooks and streaming](backends.md) and the canonical
[environment table](../../scripts/README.md#environment-variables).
Every AI launch prints `Launching: paw <sub> (PAW_BACKEND=… model=… stream=…)`
to stderr. `PAW_MODEL` applies to model-resolved commands; external plugins can
report an independently resolved model through `display-model`.

### Implementation handoff and review grades

[Completion vs Review and grade formatting](workflow.md#implementation-handoff-and-review-grades).

## Review completion and inherited findings

[Canonical review identity, attempts, CLI/GUI eligibility and source findings](workflow.md#review-completion-and-inherited-findings).

Branch PR review ownership and migration recovery are defined in the
[workflow guide](workflow.md#architecture-of-workflow). Shared body tracking never
overrides a unique task-owned PR record; conflicting owners require reconciliation.
