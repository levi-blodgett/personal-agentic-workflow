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
| pr-submit | Same review, preview and visual gates; create-only, with guidance to use pr-update when a PR exists. [Publication and recovery](workflow.md#reviewed-task-pr-publication). |
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

[Task layout and migration](workflow.md#architecture-of-workflow),
[GUI journeys](gui.md), [recorded validation](testing.md#recorded-validation-in-the-gui).

### Batch implementation

[Selection preflight and worktree limits](workflow.md#branch-and-worktree-assignment).

### `paw completion zsh`

```bash
autoload -U compinit && compinit
source <(paw completion zsh)     # current shell
paw completion zsh >> ~/.zshrc # future shells
```

Only top-level zsh subcommands are completed (for example `paw gh-` + Tab).
See [installation](install.md#optional-zsh-completion).

### Branch/worktree assignment

[Recorded assignment and safe resume](workflow.md#branch-and-worktree-assignment).

### Required follow-up answer workflow

[Answer placeholders and edit reconciliation](workflow.md#required-follow-up-answer-workflow).

### Implementation checklist discipline

[Adjacent Progress notes and status format](workflow.md#implementation-checklist-discipline).

### Extra prompt argument (`paw implement` / `paw diagnose` / `paw tighten` / `paw edit`)

```bash
paw implement my-task "Focus on the README diff; run the required validation."
paw diagnose flaky-test "Find the shortest deterministic reproduction."
paw tighten my-task "Pressure-test the acceptance criteria."
paw edit my-task "Tighten the non-goals."
```

Trailing positional arguments join into `Human extras:` without replacing the standard
prompt; omitted extras add no header. GUI implementation sends no extras after approval.

### `paw diagnose`

Use when reproduction/root cause is still unknown; approved fixes may finish in the
same run. The plan records the feedback loop, ranked hypotheses, instrumentation and
cleanup. [Validation](testing.md) applies to both implement and diagnose.

### `paw tighten`

Use for ambiguous scope/acceptance before implementation. Existing answer placeholders
are allowed; the checkpoint does not replace the approved plan. Optional durable docs
belong only where the repo/conversation establishes a lasting decision or glossary need.

### `paw teach`

```bash
paw teach "focus on command dispatch and branch/worktree assignment"
```

A discovered implementation need should become an explicit follow-up plan.

### `paw review` / `paw prototype`

Review loads `$PAW_HOME/templates/review.md` on demand; invalid resources fail before
backend launch and preserve prior review state. See the
[template lifecycle](workflow.md#review-completion-and-inherited-findings).

```bash
paw review my-task "Also grade the current review/prototype workflow and cleanup readiness."
paw prototype my-task "Preserve the CLI behavior and address every source blocker."
```

Review records task scope/grade, threshold/result, design choices, blockers and
recommendations; requested overall subsystem grading is additional.
Replacement plans retain a Prototype Source section with source/review/grade and cleanup
context. See [completion and inheritance](workflow.md#review-completion-and-inherited-findings)
and [cleanup proof and recovery](workflow.md#prototype-cleanup).

### `paw architecture`

```bash
paw architecture "focus on test/data seams"
paw architecture --pick 2 "Prefer the smallest reviewable seam."
```

### Shared command authoring contract

When adding a new top-level `paw` command, treat the shell surface as shared infrastructure:

- Add the public entry once in `_paw_command_table()` so `paw help`, completion, and dispatch do not drift.
- Add AI-backed entries to `_paw_model_command_table()` so `paw model` reflects the same command set that actually resolves models and launches prompts.
- Reuse the shared prompt/template helpers in `scripts/paw` instead of copying heredoc assembly, task-template seeding, or `Human extras:` formatting into each command body.
- Update `tests/paw-dispatcher.bats` and `tests/paw-prompt-body.bats` with the smallest coverage that proves dispatch, prompt anchor/body, and launcher behavior for the new command.
- In the resolved task package for that command, record which upstream skill files and repo touchpoints were actually inspected so later resumes have a verifiable trail.

### Crash log (`paw crash-log`)

When `paw` invokes the backend and it exits non-zero, a crash record is appended to `<task>/crash.log`. Silent failures (exit 0 but JSON contains an `.error` field) are also recorded.

```text
===
timestamp:      YYYY-MM-DD HH:MM TZ
exit_code:      <n>
api_code:       <HTTP status code, e.g. 429|503|none>
model:          <model>
subcommand:     <plan|implement|pr-address-comments|...>
classification: <see table below>
input_tokens:   <n|unknown>
stderr:
<last 20 lines of backend stderr>
---
```

Read the crash log with:

```bash
paw crash-log <task-name>
```

#### Classification codes

When a JSON error type is available, it is prepended to the classification (e.g. `content_filter: content_filter`). Classifications in priority order:

| Classification | Trigger |
|---|---|
| `content_filter` | stderr/JSON contains: `content_filter`, `content policy`, `harmful content`, `moderation`, `flagged`, `output blocked` |
| `too_many_requests` | stderr contains: `429`, `too many requests`, `request.*limit` |
| `rate limit` | stderr contains: `rate limit` |
| `overloaded` | stderr/JSON contains: `overloaded`, `service unavailable`, `503` |
| `context overflow` | stderr contains: `context window`, `context length`, `too long`, `maximum context` |
| `timeout` | stderr contains: `timeout`, `timed out`, `deadline exceeded` |
| `OOM/killed` | stderr contains: `out of memory`, `oom`, `killed`, `signal 9` |
| `API error` | stderr contains: `api error`, `internal server error`, `500`, `502` |
| `interrupted (SIGINT)` | exit code 130 |
| `terminated (SIGTERM)` | exit code 143 |
| `unknown (exit N)` | none of the above |

For quota/rate limits, overload, timeout or 5xx errors, inspect provider status and retry
when appropriate. Lower PAW_MAX_TURNS/split long tasks for resource pressure; compact
context overflow. Inspect/rephrase policy-sensitive content for content_filter. Resume
SIGINT/SIGTERM interruptions with approved `paw implement <task>`; inspect stderr for
unknown failures. `paw crash-log` prints “no crashes recorded” and exits zero when absent.

#### Always-on exit status line

After every `run_claude()` call — success or failure — `paw` prints a colored status line to stderr:

```text
paw: exit 0               # green — success
paw: exit 1 [429]         # red — non-zero exit, API code shown
paw: exit 1 [rate limit]  # red — non-zero exit, classification shown when no API code
```

Set `NO_COLOR` or `PAW_NO_COLOR` to any non-empty value to suppress ANSI codes (plain text only).

**Context-pressure telemetry:** before each backend call, `paw` estimates the prompt token count from its byte length (÷ 4). To avoid noisy per-turn output, it only prints a notice once the estimate reaches meaningful pressure bands relative to `PAW_PROMPT_WARN_TOKENS` (default: `150000`):

- `>= 75%` of the threshold: warn that context pressure is building and recommend leaner updates, `paw compact <task>`, archiving stale detail, and splitting the task if growth continues.
- `>= 100%` of the threshold: escalate to a context-overflow-risk warning with the same concrete next steps before retrying.

```text
warn: estimated prompt size ~N tokens (80% of warning threshold: 150000); context pressure is building. Keep updates lean, archive stale detail, use `paw compact <task>`, and split the task if growth continues.
```

The task package and prompt contract are expected to follow the same pattern: notify only at meaningful pressure changes, keep those notices short, and prefer task-doc references over re-pasting large resolved context.

### GH PR comments (`scripts/gh-pr-comments.sh`)

Lists all unresolved PR feedback, grouped into three labelled sections:

```bash
scripts/gh-pr-comments.sh <pr-number> [--repo OWNER/REPO]
```

Output format:

```text
INLINE path/to/file.ts:42
  @author: comment body

REVIEW SUMMARY @author (REQUEST_CHANGES)
  review body

PR COMMENT @author
  comment body
```

- **INLINE** — unresolved review threads (resolved threads are filtered out).
- **REVIEW SUMMARY** — review-level bodies (e.g. `REQUEST_CHANGES`); reviews with an empty body or `APPROVED` state and empty body are filtered.
- **PR COMMENT** — top-level issue comments on the PR.

Pagination is followed for all three collections. Set `PAW_PR_PAGE_LIMIT` (default `10`) to cap pages per collection; a warning is printed to stderr if the cap is hit.

`paw pr-address-comments` invokes this script on the shell side before the AI call,
writing output to `<resolved-number-review>/comments.md`. The first pass of
`paw pr-review` also uses this script when it builds `<resolved-task>/review.md`.
No dependency on a user-local `gh_pr_comments` shell function. Requires `gh`
(authenticated) and `jq`.

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
