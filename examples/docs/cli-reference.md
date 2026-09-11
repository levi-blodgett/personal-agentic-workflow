# CLI Reference

Complete reference for the `paw` CLI subcommands, environment overrides, Makefile targets, and operator-facing runtime behavior.

## `paw` CLI

`scripts/paw` wraps the prompts below so day-to-day invocation stays short. Put `scripts/` on your `PATH` (or run `make install` to symlink `scripts/paw` into `~/bin`) to use it from any repo. The install target adds only the `paw` launcher; by default that launcher resolves built-in helper modules from the checkout it points at, and any external `paw-backend-<name>` plugin must already be on your `PATH`.

```text
paw plan <task-name> "<prompt>" [--dry-run]
                                       launch a plan-only run; seeds template files into
                                       the central task store by default, records the current
                                       branch/worktree assignment when inside a
                                       git repo, and investigates repo landmark
                                       files directly; --dry-run prints the prompt
                                       and exits without invoking the backend;
                                       model: PAW_MODEL
                                       (backend-specific default)
paw architecture [--pick <candidate-number>] [focus...]
                                       run a repo-aware architecture review;
                                       the first pass explores the repo and
                                       writes numbered candidates to
                                       `.agent/architecture/candidates.md`,
                                       then follow-up runs use
                                       `--pick <candidate-number>` to resume
                                       the selected path through
                                       `.agent/architecture/grill.md`; model:
                                       PAW_MODEL (backend-specific default)
paw teach [focus...]                   map the relevant modules and callers for
                                       an unfamiliar area; lightweight repo
                                       orientation only, with no task package
                                       and no automatic durable-doc writing;
                                       model: PAW_MODEL
                                       (backend-specific default)
paw review <task-name> [extras...]     run a short task-quality review for a
                                       completed task package; seeds
                                       `review.md` and prompts for a grade,
                                       quality threshold comparison,
                                       architectural/design choices,
                                       improvement notes, and recommendations;
                                       model: PAW_MODEL
paw prototype <task-name> [extras...]  create a plan-only replacement package
                                       from a reviewed task plus its
                                       `review.md`; writes prototype lineage
                                       metadata, asks the planner to add a
                                       `## Prototype Source` section, and after
                                       successful planning attempts to revert
                                       the reviewed task's tracked local diff
                                       from saved Git metadata; model: PAW_MODEL
paw implement <task-name> [extras...]  resume/complete the in-progress task;
                                       reuses the task's saved branch/worktree
                                       assignment when safe and otherwise
                                       errors; also refuses to run while
                                       plan.md still contains `USER ANSWER
                                       (UNRESOLVED):` or `USER ANSWER
                                       (PROVIDED):`; optional extra text is
                                       appended as "Human extras:" to the prompt
paw implement-batch <task-name>...     launch multiple eligible approved tasks
                                       concurrently; rejects the whole batch
                                       before launch if any selected task is
                                       missing, complete, already running, or
                                       still has `USER ANSWER` placeholders
paw diagnose <task-name> [extras...]   run the debugging-specific workflow for
                                       an approved task; reuses the same saved
                                       branch/worktree assignment and
                                       placeholder guardrails as
                                       `paw implement`, but forces a
                                       feedback-loop-first reproduce →
                                       hypothesize → instrument → fix →
                                       cleanup flow and keeps reviewable debug
                                       notes in `plan.md`; model: PAW_MODEL
paw tighten <task-name> [extras...]    sharpen an existing task package one
                                       question at a time before implementation;
                                       reuses the task's saved branch/worktree
                                       assignment when safe, seeds or reuses
                                       `.agent/<task>/tighten.md` as the
                                       interactive checkpoint, keeps `plan.md`
                                       as the plan source of truth, and uses
                                       PAW_MODEL (backend-specific default)
paw edit <task-name> [extras...]       iterate on .agent/<task>/ plan docs
                                       (plan-only); reuses the task's saved
                                       branch/worktree assignment when safe;
                                       uses PAW_MODEL (backend-specific
                                       default); errors if task missing
paw completion zsh                     print the zsh completion script for paw;
                                       v1 is zsh-only and completes top-level
                                       subcommands only
paw task-migrate [repo-path ...]       copy legacy `.agent/<task>/` packages for
                                       one or more explicit repos into the
                                       central task store and write local
                                       provenance metadata beside the copied
                                       Markdown files
paw gui [start|stop|restart|kill] [--host 127.0.0.1] [--port 0|<port>] [--repo <path>] [--all]
                                       foreground, background, stop, restart, or
                                       force-stop the read-only local dashboard;
                                       scoped mode shows central plus legacy
                                       `.agent/<task>/` packages for one repo,
                                       while `--all` shows every central task
                                       store grouped by repo identity; binds to
                                       127.0.0.1 by default, prints the URL,
                                       and refuses non-local hosts
paw to-issues <task-name>              draft tracer-bullet issue slices under
                                       .agent/<task>/issues/ for an approved
                                       task package; writes an index.md review
                                       breakdown plus one draft file per slice;
                                       model: PAW_MODEL
paw to-issues <task-name> --publish    publish the reviewed drafts in
                                       .agent/<task>/issues/*.md through GitHub
                                       in dependency order; updates per-draft
                                       metadata and plan.md issue tracking;
                                       requires gh
paw pr-submit <task-name>              create a draft PR from the branch PR body;
                                       reuses the task's saved branch/worktree
                                       assignment when safe; records PR number +
                                       URL back into plan.md and the PR body;
                                       requires gh
paw issue-submit <task-name>           create a GitHub issue from
                                       .agent/<task>/issue.md; reuses the task's
                                       saved branch/worktree assignment when
                                       safe; records issue number + URL back
                                       into plan.md and issue.md; requires gh
paw pr-review <pr-number>              first run collects PR comments into
                                       .agent/<task>/review.md; later runs submit
                                       that saved draft as a PR review comment;
                                       requires gh (and jq on first-run fetch)
paw issue-review <issue-number>        create or refresh
                                       .agent/<issue-number>-issue-review/,
                                       fetch the GitHub issue title/body into
                                       issue.md, and run a plan-only pass from
                                       the saved issue body; model: PAW_MODEL;
                                       requires gh
paw pr-address-comments <pr-number>    create a plan for addressing PR review
                                       comments; seeds .agent/<pr-number>-review/
                                       with templates and comments.md; plan only —
                                       use 'paw implement <pr-number>-review' to
                                       execute; model: PAW_MODEL;
                                       requires gh and jq
paw compact <task-name>                archive completed Implementation Phases items
                                       in plan.md to keep the working surface lean;
                                       idempotent
paw archive <task-name>                move a central task package under the
                                       repo store's `.archive/` folder so
                                       active CLI and GUI task lists omit it
paw browse <task-name>                 browse a resolved task package's Markdown
                                       docs in the terminal; resolves central
                                       tasks before legacy `.agent/<task>/`
                                       packages; uses PAW_BROWSE_PAGER, then
                                       PAGER, then less -R, otherwise stdout
paw crash-log <task-name>              print crash log for a task
                                       (.agent/<task>/crash.log); prints
                                       "no crashes recorded" when absent; exit 0
paw list [repo-path]                   list central and legacy task packages plus current status
                                       and lightweight running state
paw lint [task-dir|--repo p]           verify task package(s) against the contract
paw model [-v|--verbose]               print resolved model for each subcommand;
                                       with -v/--verbose also prints PAW_BACKEND,
                                       PAW_STREAM, and PAW_MAX_TURNS
paw setup [repo-path]                  add .agent/ to .git/info/exclude for legacy/local compatibility
paw help                               show this message
```

Every AI-backed subcommand prints a consistent launch banner to stderr before invoking the backend:

```text
Launching: paw <sub> (PAW_BACKEND=<backend> model=<model> stream=<0|1>) for .agent/<task>/
```

Environment overrides: see the canonical reference table in [`scripts/README.md`](../../scripts/README.md). The most operationally important ones are `PAW_BACKEND`, `PAW_MODEL`, `PAW_STREAM`, `PAW_PROMPT_OPTIMIZE`, `PAW_PROMPT_WARN_TOKENS`, and `PAW_BROWSE_PAGER`.

### Task Store And GUI

PAW stores new task packages under `${PAW_TASK_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/paw/tasks}` by default. The store is grouped per repo using a stable local repo slug, and each task package keeps Markdown docs plus `metadata.gitconfig` with repo path, Git common dir, worktree, branch/head state, and created or migrated timestamps.

Legacy `.agent/<task>/` packages remain readable. `paw list`, `paw lint --repo`, `paw edit`, `paw implement`, `paw review`, `paw prototype`, `paw browse`, PR/issue helpers, `paw compact`, and `paw crash-log` resolve central tasks first and fall back to legacy packages. `paw archive` archives central packages; migrate legacy packages before archiving them. If you already have repo-local task packages, run `paw task-migrate` from that repo or pass one or more explicit repo paths:

```bash
paw task-migrate
paw task-migrate ../api ../web
```

Use `paw browse <task-name>` when you want to inspect a task package from the terminal without finding the central store path manually. The command aggregates available docs such as `contract.md`, `plan.md`, `review.md`, issue/tighten/comment notes, and `crash.log` with readable file headings; missing optional docs are skipped. For deterministic output in scripts or tests:

```bash
PAW_BROWSE_PAGER=cat paw browse my-task
```

`paw gui` serves the local dashboard:

```bash
paw gui                              # foreground on http://127.0.0.1:8765/
paw gui --port 0 --repo ..           # foreground with an ephemeral localhost port
paw gui start --all                  # background server showing every central repo
paw gui restart                      # replace the recorded background server
paw gui stop                         # graceful stop of recorded PAW GUI process
paw gui kill                         # force-stop fallback for the recorded process
```

`paw gui`, `paw gui start`, and `paw gui restart` use port `8765` by default. Pass `--port 0` to opt into an ephemeral localhost port. Managed GUI lifecycle metadata lives under `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/active.gitconfig` with the PID, host, port, repo path, task-home path, `--all` mode, URL, log paths, and start time. `paw gui start` refuses to overwrite an active recorded process and cleans stale metadata when the PID is gone. `paw gui restart` stops only the validated recorded PAW GUI process, then starts a managed replacement using the recorded host, port, repo path, task-home path, and `--all` mode unless you pass new options. With no active metadata, restart behaves like managed start. `paw gui stop` and `paw gui kill` validate the recorded command before signalling it so unrelated processes are not stopped.

The GUI is a local task control surface. It shows task lists, repo identity plus branch/head-state context, Markdown detail pages, checklist counts, follow-up placeholder blocks, validation state, and per-task run status recorded under `runs/*.gitconfig`. `--repo <path>` seeds the startup/default repo, and the Add repo path form can register more existing local Git repos at runtime. Registered repos are stored in `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/repos.gitconfig`, while stale or non-Git paths are rejected with browser-visible errors. The Active repo dropdown changes scoped central-plus-legacy task listing and the working directory used for new Plan actions. With `--all`, the table still shows every central task store, and Active repo controls only where a new Plan action launches. The main table lists newest activity first, preferring run end/start timestamps, then task metadata creation or migration timestamps, then task-file modification time for legacy packages. State, repo-text, and completion filters live behind a closed-by-default disclosure that opens when a filter is active. Each row has a Stage column plus a Next column with the next eligible workflow action. Stage is derived from current task files and metadata: active `running` metadata becomes `Running`; unresolved/provided user-answer markers become `Needs edit`; prototype metadata becomes `Prototype`; `review.md` becomes `Reviewed`; and `100%` completion with `Next work: Review.` becomes `Review` until review/prototype artifacts move the workflow forward. Default `Review.` next-work text is not repeated in Review, Reviewed, or Prototype Next cells. For reviewed tasks, the Next column also shows the first non-pending `- Grade:` value from `review.md` as a color-coded grade badge; pending, empty, or missing grades are omitted. The reviewed-task prototype control is labelled `Use as Prototype` while still calling `paw prototype`, except grades of `A-` or higher disable the GUI control and direct GUI prototype POST. Task names open task details; action rows no longer include a redundant Open control. Archive occupies the first action position, followed by editing, approval preview for implementation-ready tasks, deleting, and `plan.md` preview where available; `contract.md` remains available from task detail pages. The approval preview renders `plan.md` with the safe Markdown path, then offers `paw edit`, the local manual `plan.md` path, and an `Approve Implementation` button that posts to the existing implement endpoint. Blocked tasks use an `Answer Questions` edit overlay that shows parseable pending question text and an answer textarea when `plan.md` contains `USER ANSWER` placeholders. The compact header keeps Home, Archived, and the page title on one row with concise scope context; repo paths, task paths, repo slugs, worktree paths, and central-store paths are available behind expandable details rather than always visible. Header and body content share a responsive wide shell, and dense tables scroll horizontally inside the content area on narrow or crowded views. The index plus task detail pages poll local HTML fragments so open views reflect task file and run metadata changes without a browser refresh. Every normal page includes Home and Archived links. Task Markdown is rendered with a safe built-in subset: headings, paragraphs, emphasis, inline code, links, lists, task checkboxes, tables, blockquotes, horizontal rules, and fenced code blocks. Raw HTML from task files is escaped.

Archived central tasks live under `${PAW_TASK_HOME}/<repo-slug>/.archive/<task-name>` and are excluded from normal `paw list`, scoped GUI views, and `paw gui --all`. The GUI's Archived header link opens a scoped archived-task dashboard; it lists central archived packages for the current repo or all central stores, shows a clear empty state, and offers Unarchive for packages whose submitted path still resolves under the central `.archive` root. Unarchive moves the package back beside active tasks, records `paw.unarchived-at` when metadata is present, and refuses to overwrite an existing active package or trust arbitrary paths. Prototype replacement tasks record `paw.prototype-source`, `paw.prototype-review`, and `paw.prototype-status` metadata so the GUI can show lineage/status markers without parsing Markdown.

Task `## Current Status` keeps the source label `Estimated completion`, but the value should be a bare integer percentage such as `25%` or `100%`. `Next work` is free-form unless completion is `100%`; then use `Review.` or `Review.` plus a genuinely important follow-up.

The index page can start `paw plan <task-name> "<prompt>"` from an overlay prompt in the currently active repo. The same overlay can Queue a valid task name and prompt as a local-only saved item under the active repo task store, without launching PAW. Queued prompts appear in the Plan overlay with prompt previews plus Plan and Remove actions; triggering one launches the normal `paw plan` flow for the active repo and removes the queued item after a successful start. The Queue button has a tooltip explaining that it saves the prompt locally so planning can be started later. The top action row keeps Plan separate from a selected-task action dropdown. Checkboxes remain for unfinished, not-running, unblocked tasks; selected Archive moves central tasks under `.archive`, and selected Delete removes resolved central/legacy task packages only after confirmation, exact listed-path validation, and all-or-nothing preflight. The GUI no longer exposes selected mass implementation or posts to `/actions/implement-batch`; use CLI `paw implement-batch` for concurrent approved implementation. Home-row Next controls can start approval preview, `paw review`, `paw prototype`, or `paw archive` directly when that is the derived next stage; blocked tasks point to the `Answer Questions` edit overlay. Running tasks with a live PID-bearing `runs/*-<pid>.gitconfig` entry show Cancel, which verifies the recorded PID still looks like a PAW process, sends `SIGTERM` to its process group when it is the group leader or to that process otherwise, waits briefly, and records `paw.status=cancelled` plus an exit status if the GUI performs the terminal update. Pidless running metadata remains active for duplicate-run blocking but is not presented as safely cancellable; stale PID metadata is ignored. Task pages retain controls for `paw edit <task-name> [extras...]`, `paw review <task-name> [extras...]`, `paw prototype <task-name> [extras...]`, `paw archive <task-name>`, and approval-gated `paw implement <task-name>`. GUI plan/edit/review/prototype actions collect optional instructions in overlays where needed; for blocked edit actions, submitted answers are appended to the `paw edit` extras so the edit run can replace or reconcile the `USER ANSWER` placeholders. The GUI does not write those answers directly into `plan.md`. GUI implementation deliberately sends no extras after approval and ignores any unexpected submitted `extras` field, while CLI `paw implement <task-name> [extras...]` remains unchanged. GUI actions delegate to `scripts/paw` in a background subprocess from the selected repo for new Plan actions and from each task's own recorded repo for task-specific actions, so prompt construction, task-store metadata, branch/worktree assignment, archive filtering, prototype metadata, and implement follow-up guards stay in the CLI path. The HTTP request returns immediately with a status message; subprocess stdout/stderr logs are written under the task's `runs/` directory, and CLI run metadata continues to appear as `runs/*.gitconfig`.

### Batch implementation

Use `paw implement-batch <task-a> <task-b> ...` when several already-approved tasks should run at the same time. The command preflights every selected task before launching any subprocess. It refuses missing tasks, duplicated names, completed tasks, tasks with active `runs/*.gitconfig` status, and tasks whose `plan.md` still contains `USER ANSWER (UNRESOLVED):` or `USER ANSWER (PROVIDED):`.

Each accepted task launches through the normal `paw implement <task-name>` path in the background, so saved branch/worktree assignment, prompt construction, run metadata, crash logging, and placeholder guardrails remain the same as single-task implementation. Batch launch does not add a scheduler or conflict resolver; use separate branches/worktrees for tasks that might touch overlapping files.

Archive is the normal cleanup path for central task packages that should leave active views without being deleted, and Unarchive is the guarded restore path from the archived dashboard. Delete is intentionally narrow: the submitted task must resolve from the central/legacy task list, the submitted path must match that listed task path, the confirmation must come from the GUI's "Are you sure?" prompt, and deletion is unavailable while a running PAW subprocess is recorded. The GUI does not publish PRs/issues, bind externally, expose arbitrary shell commands, expose arbitrary filesystem previews, stop arbitrary non-PAW processes, or make a database authoritative.

### `paw completion zsh`

Use the built-in completion generator to enable native `zsh` completion for `paw`:

```bash
autoload -U compinit && compinit
source <(paw completion zsh)
paw completion zsh >> ~/.zshrc
```

`source <(paw completion zsh)` makes completion available in the current shell immediately. Appending the same output to `~/.zshrc` keeps it enabled for future shells.

If you only append to `~/.zshrc`, your already-open shell does not change; run `source <(paw completion zsh)` there too if you want completion before opening a new terminal.

The generated script completes top-level subcommands only in v1. For example, typing `paw gh-` and pressing Tab can expand to `gh-actions-review`. Bash and argument-level completion remain out of scope for this first slice.

### Branch/worktree assignment

When `paw plan` runs inside a Git worktree, it stores the task's current branch/worktree assignment in local metadata under the repo's Git common dir. That metadata is shared across sibling worktrees in the same repo and is not committed.

- `paw` does not create branches or worktrees. It only records the branch/worktree you were already using.
- `paw edit`, `paw implement`, `paw diagnose`, `paw to-issues`, `paw pr-submit`, `paw issue-submit`, and `paw pr-review` try to resume from the saved assignment before touching task-local state.
- If the saved assignment is another registered worktree in the same repo, `paw` re-execs from that worktree path after checking the current worktree is clean apart from `.agent/` docs.
- If resuming would require clobbering dirty state, auto-detaching HEAD, auto-creating/switching to an unborn branch, or crossing into another repo/common-dir, `paw` stops with a clear error instead.

### Required follow-up answer workflow

Use indented hyphenated answer placeholders in `plan.md` whenever a follow-up needs user input:

```markdown
- <question>
  - USER ANSWER (UNRESOLVED):
```

When the user replies, replace that line with:

```markdown
  - USER ANSWER (PROVIDED): <answer>
```

Then run `paw edit <task-name>` so the plan absorbs the answer. `paw implement <task-name>` exits non-zero while either placeholder form still exists anywhere in `plan.md`.

`paw diagnose <task-name>` uses the same placeholder guardrail.

`paw tighten <task-name>` intentionally does not use that guardrail, because tightening runs are allowed to reconcile existing placeholder answers back into the task docs.

### Implementation checklist discipline

Implementation plans can and should use multiple phases when the task warrants it. When a checklist item under `## Implementation Phases / Checklist` is completed, flip it to `- [x]` and add an adjacent `Progress:` line in the same edit before starting the next item. `paw lint` exits non-zero if a completed implementation item is missing that line.

### Extra prompt argument (`paw implement` / `paw diagnose` / `paw tighten` / `paw edit`)

Any positional arguments after `<task-name>` are joined and appended to the
standard prompt body as a `Human extras:` block:

```bash
paw implement my-task "Focus on the README diff and skip tests."
paw diagnose flaky-test "Focus on the shortest deterministic repro loop."
paw tighten my-task "Pressure-test the acceptance criteria wording."
paw edit my-task "Tighten the non-goals section."
```

This is an *extension* — the standard prompt body is unchanged. Omitting the
extras leaves the prompt unchanged (no trailing `Human extras:` header).

### `paw diagnose`

Use `paw diagnose` when the next unknown is reproduction, root cause, or the smallest useful instrumentation, not when the fix path is already obvious.

```bash
paw diagnose flaky-test
paw diagnose flaky-test "Prefer a single failing test before adding logs."
```

- `paw diagnose` is a sibling of `paw implement`, not a hidden mode inside it.
- It still works inside an approved `.agent/<task>/` package and may finish the fix in the same run.
- The prompt requires a deterministic feedback loop first, then narrowed reproduction, ranked hypotheses, targeted instrumentation, the fix, and explicit cleanup.
- Diagnose runs should keep concise reviewable debug notes in `plan.md`, including the feedback loop, ranked hypotheses, instrumentation/debug artifacts, and cleanup expectations.

### `paw tighten`

Use `paw tighten` when the task package exists but the plan language still needs pressure: ambiguous scope, fuzzy acceptance criteria, unresolved terminology, or a likely mismatch between the draft plan and the repo.

```bash
paw tighten my-task
paw tighten my-task "Focus on the test strategy and approval boundaries."
```

- `paw tighten` is a first-class top-level command, not a hidden mode inside `paw edit`.
- It works inside an existing `.agent/<task>/` package and keeps the run plan-only: task docs first, no normal implementation work.
- Each run asks at most one highest-value next question unless the latest answer or repo exploration already resolves the uncertainty.
- User-facing questions must include a recommended answer with brief reasoning.
- Repo-discoverable answers should come from direct code/doc inspection instead of bouncing the question back to the user.
- The command seeds or reuses `.agent/<task>/tighten.md` as the running checkpoint for repo findings, settled decisions, the current top question, the recommendation, and the latest user answer.
- `plan.md` remains the source of truth for the actual approved plan. `tighten.md` is only the interactive checkpoint.
- Durable docs such as `CONTEXT.md` or `docs/adr/` remain optional. Only suggest or update them when the repo already uses them or the discussion surfaces a genuinely durable glossary/decision need.

### `paw teach`

Use `paw teach` when the next need is orientation rather than planning: you want a concise map of the relevant modules, main callers, and repo vocabulary for an unfamiliar area.

```bash
paw teach
paw teach "focus on command dispatch and branch/worktree assignment"
```

- `paw teach` is a first-class top-level command, not a hidden mode inside `paw plan` or `paw architecture`.
- It stays intentionally lighter-weight than planning: no `.agent/<task>/` package is required, and the default run should not silently write durable docs.
- If the map reveals a real follow-up need, the response should recommend an explicit next step such as `paw plan <task> "..."` or a focused documentation task instead of doing that work automatically.

### `paw review` / `paw prototype`

Use `paw review` after a task reaches completion and you want a durable quality read before deciding whether to keep the work.

```bash
paw review task-quality-pass
paw review task-quality-pass "Use B+ as the minimum quality threshold."
```

- `paw review` seeds `review.md` and launches an implementation-class review session against the resolved task package.
- The review prompt asks for a grade, the quality threshold used, whether the work meets that threshold, architectural/design choices, whether those choices could be improved, and concrete recommendations.
- This task-quality review is separate from GitHub PR review helpers. Use `paw pr-review` or `paw pr-address-comments` for PR comments.

Use `paw prototype` after a reviewed task falls below the threshold, or when the review says the implementation should become source material for a cleaner replacement plan.

```bash
paw prototype task-quality-pass
paw prototype task-quality-pass "Preserve the CLI behavior but simplify the GUI slice."
```

- `paw prototype` now requires the source task to have `review.md`; the old throwaway `--question`, `--logic`, and `--ui` flags are rejected with compatibility guidance.
- The command seeds or reuses a `<task-name>-prototype` task package and runs a plan-only `<!-- PAW:PLAN -->` prompt using the source task docs and `review.md`.
- Replacement plans should include a `## Prototype Source` section with source task, review, grade/recommendation context, and revert/prototype status.
- Metadata keys `paw.prototype-source`, `paw.prototype-review`, and `paw.prototype-status` let the GUI show lineage without parsing Markdown.
- After successful planning, PAW tries to reverse the reviewed task's tracked non-`.agent` diff from its saved `paw.head-sha`. If Git metadata is missing, the commit is unavailable, or untracked files make cleanup ambiguous, PAW leaves a clear status/error instead of deleting work blindly.

### `paw architecture`

Use `paw architecture` when you want a repo-aware architecture review without opening a normal implementation task first.

```bash
paw architecture
paw architecture "focus on the test/data seams around scripts/paw"
paw architecture --pick 2 "Prefer the smallest reviewable seam first."
```

- The first run explores the repo, presents numbered deepening candidates, and writes the same list to `.agent/architecture/candidates.md`.
- Follow-up runs use `--pick <candidate-number>` to continue the selected candidate through `.agent/architecture/grill.md`.
- Extra trailing text is appended as `Human extras:` on both the exploration pass and the `--pick` follow-up pass, so you can narrow scope or answer the latest grilling question.
- The workflow keeps durable design capture optional; only write long-lived design docs when the conversation surfaces a real decision worth preserving.

### Shared command authoring contract

When adding a new top-level `paw` command, treat the shell surface as shared infrastructure:

- Add the public entry once in `_paw_command_table()` so `paw help`, completion, and dispatch do not drift.
- Add AI-backed entries to `_paw_model_command_table()` so `paw model` reflects the same command set that actually resolves models and launches prompts.
- Reuse the shared prompt/template helpers in `scripts/paw` instead of copying heredoc assembly, task-template seeding, or `Human extras:` formatting into each command body.
- Update `tests/paw-dispatcher.bats` and `tests/paw-prompt-body.bats` with the smallest coverage that proves dispatch, prompt anchor/body, and launcher behavior for the new command.
- In the child `.agent/<task>/` package for that command, record which upstream skill files and repo touchpoints were actually inspected so later resumes have a verifiable trail.

### Crash log (`paw crash-log`)

When `paw` invokes the backend and it exits non-zero, a crash record is appended to `.agent/<task>/crash.log`. Silent failures (exit 0 but JSON contains an `.error` field) are also recorded.

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
writing output to `.agent/<pr-number>-review/comments.md`. The first pass of
`paw pr-review` also uses this script when it builds `.agent/<task>/review.md`.
No dependency on a user-local `gh_pr_comments` shell function. Requires `gh`
(authenticated) and `jq`.

## Makefile

The repo ships a top-level `Makefile` that consolidates the central operator commands. Run `make help` from the repo root to discover all targets:

| Target | Purpose |
|--------|---------|
| `help` | List all targets (default) |
| `install` | Symlink `scripts/paw` into `$(PREFIX)` (default: `~/bin`); external `paw-backend-<name>` plugins stay separately installed on `PATH` |
| `uninstall` | Remove the `$(PREFIX)/paw` symlink |
| `test` | Run the full bats test suite |
| `lint` | Lint all `.agent/` task packages in this repo |
| `shellcheck` | Run shellcheck over all shell scripts |
| `check` | `test` + `lint` + `shellcheck` — canonical local validation |
| `list` | List `.agent/` task packages |
| `ci-deps` | Install CI dependencies (bats, jq, shellcheck) |

```bash
make check   # run all validation locally
make install # put paw on your PATH via ~/bin
```

`make install` only creates the launcher symlink. By default, the installed launcher derives `PAW_HOME` from its resolved path back to the checkout it points at, so built-ins keep working even when the repo lives somewhere other than `$HOME/git/personal-agentic-workflow`. Set `PAW_HOME` explicitly only when you want the launcher to use a different checkout.

## Model And Backend Behavior

Use `paw model` to print the resolved model for each subcommand. Add `-v` to also print the active backend, streaming mode, and max-turn setting.

`paw` resolves models through the active backend:

- On the default `codex` backend, an unset `PAW_MODEL` resolves to `gpt-5.4`.
- On the `claude` backend, an unset `PAW_MODEL` falls back to the backend's own default model family.
- External plugins may honor `PAW_MODEL` directly or resolve models independently. When a plugin ignores `PAW_MODEL`, it should expose `display-model` so `paw model` and the launch banner report the actual effective model.

Use `PAW_MODEL` to override the model for every model-resolved AI subcommand: `paw plan`, `paw architecture`, `paw teach`, `paw review`, `paw prototype`, `paw edit`, `paw implement`, `paw diagnose`, `paw tighten`, `paw to-issues`, `paw issue-review`, and `paw pr-address-comments`.

Backend-specific details and tradeoffs live in [`docs/backends.md`](backends.md).

**Quality guardrail:** on the `claude` backend, `paw implement` rejects `PAW_MODEL=haiku` at launch and prints a clear error.

**Prompt optimization (opt-in):** set `PAW_PROMPT_OPTIMIZE=1` to enable a `claude`-backend haiku pre-pass that tightens your `paw plan` prompt before the main model run.
