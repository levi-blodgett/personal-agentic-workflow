# PAW Test Suite

Implement/diagnose completion requires full local validation after final changes, including batch, GUI and docs-only tasks. See [validation policy and recorded evidence](../examples/docs/testing.md).

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
| `list-tasks.bats` | `scripts/list-tasks.sh` status and running-state output |
| `lint-task.bats` | `scripts/lint-task.sh` |
| `task-store.bats` | central task-store resolution, archive moves/filtering, metadata, legacy fallback, eligibility/running-state predicates, and explicit multi-repo migration helpers |
| `gui-server.bats` | `paw gui` Markdown rendering, newest-first task sorting, auto-refresh fragment plumbing, main-table filters, active repo registry/selector behavior, combined repo/branch display, home navigation, concise action labels, overlay prompts/previews, no-extra GUI implementation, local plan/edit/implement/review/prototype/archive actions, click-time View PR lookup for saved live branches (success, missing branch/tool, no PR, auth guidance, escaped generic diagnostics, silent failure, and invalid/empty URLs), selected-task archive/delete, prototype markers and cleanup messages, guarded deletion, foreground smoke, managed start/stop/restart/kill lifecycle, stable default-port coverage, stale PID protection, and multi-repo dashboard coverage |
| `makefile.bats` | Make targets, conservative install ownership, spaces, launcher chains, source checks and relocation recovery |
| `plugin-install.bats` | Real copied external-plugin Makefile; install lifecycle, conflicts, overrides, source resources, capture/stream, failures, optional hooks and executable discovery |
| `paw-dispatcher.bats` | `scripts/paw` subcommand dispatch, review/prototype/archive command surfaces, `implement-batch`, worktree resume, and launcher behavior |
| `paw-completion-docs.bats` | Durable docs coverage for `paw completion zsh` and the narrowed `zsh`-only scope |
| `paw-codex.bats` | Default codex backend wiring, auth banner, sandbox flags, and usage parsing |
| `paw-crash.bats` | Crash classification, crash log writing, and prompt-size warnings |
| `paw-prompt-body.bats` | Prompt body + launch banner for every subcommand, including broader review records, immutable patch provenance capture, same-path drift/index preservation, literal unusual paths, binary/deletion/mode round trips, legacy/tampered evidence blocking, capture/resume and failure handling, and review-driven prototype planning/conservative cleanup behavior (stub backend) |
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
  the full argv and resolved prompt body to `$BATS_TEST_TMPDIR/backend.{args,prompt,mode}`; tests may set `PAW_STUB_MUTATE_FILE` to simulate a backend-created tracked file change.
- Task-store and GUI tests set `PAW_TASK_HOME` and, for lifecycle or repo-registry cases, `XDG_STATE_HOME` to `$BATS_TEST_TMPDIR` so central-store and GUI metadata behavior is hermetic and never writes to the operator's real local state.
- New top-level `paw` commands should usually extend both files above: dispatcher coverage locks the public command/model surface, and prompt-body coverage locks the shared prompt/template helpers.
- `paw-pr-workflow.bats`, `paw-issue-workflow.bats`, and `paw-gh-actions-workflow.bats` cover the shell-side GitHub workflow commands, including saved tracking metadata, issue-draft publication ordering, flag forwarding, and rerun behavior.
- `paw-codex.bats` stubs the Codex CLI. External-plugin seam coverage stays in `paw-dispatcher.bats`; backend-specific compatibility checks for separately distributed plugins should live with those plugin repos.
- `makefile.bats` requires `make` on `PATH` (pre-installed on `ubuntu-latest` and macOS).
- Tests that need a real git repo create a temporary one in `$BATS_TEST_TMPDIR`
  and clean up on teardown.

Prototype journey coverage in `gui-server.bats` includes `gui-prototype.py` behavior checks for replacement/source roles, instructions, immediate and linked run tracking, duplicate starts, cancellation, stale approval, failure logs, reuse and same-repo navigation. `paw-prompt-body.bats` verifies failed planning preserves source work, retry retains replacement notes, successful cleanup follows planning, and source archival preserves the replacement. Fixtures use isolated task stores and stub/local subprocesses; no model service is called.

`gui-validation.py`, invoked by `gui-server.bats`, covers diagnostic-invariant outcomes, named incomplete results, shared nested/compound vocabulary, exact per-check reruns, forward scope, unknown evidence, fenced/commented diagnostics, full escaped source, central/legacy task identity, substitutions and dashboard/detail fragments. [Canonical evidence semantics](../examples/docs/testing.md#recorded-validation-in-the-gui) describe the supported writing format.

### GUI live-state browser regression

`bats tests/gui-server.bats` covers JSON action results (`Accept: application/json`), ordinary POST fallback, unchanged launch arguments, and task/queue/repo guards in scoped and all-repo modes. These HTTP checks do not assert browser layout, focus, caret, or timer behavior. Run the following real-browser procedure for changes to live updates or dashboard actions, then run `make check` for shared GUI changes.

Use Chrome with JavaScript enabled. On macOS, AppleScript inspection also requires Chrome **View → Developer → Allow JavaScript from Apple Events**, and macOS may request permission to automate Chrome. Confirm access with `execute active tab of front window javascript "document.title"` on the fixture page. If any browser, JavaScript, automation, or other setting blocks a needed operation, stop implementation and ask the user to enable that setting. Do not change settings, bypass a restriction, install a browser dependency, or waive the blocked check. Recheck the operation after user enablement.

Create a temporary directory outside live task stores. Initialize two empty Git repos there, set `XDG_STATE_HOME` and `PAW_TASK_HOME` to temporary directories, and use an isolated stub backend. For a renderer-only fixture server, import `scripts/lib/gui_server.py` with `importlib`, register it in `sys.modules`, replace `launch_paw` with a function that records `(repo, task_home, task_path, args)` and returns `(True, "started paw … (fixture)")`, then call `main()` with `--repo`, `--task-home`, and an unused localhost `--port`. This exercises real HTTP handlers without launching a model or changing project files. Run with `PYTHONDONTWRITEBYTECODE=1`. Stub only the `gh` command for View PR; keep local Git calls intact. Do not use live task data or a real remote PR for mutation tests.

Seed both central (`task_home / repo_slug(repo) / name`, with `paw.repo-root` metadata) and legacy (`repo/.agent/name`) packages. Include same-named tasks in the two repos, ready tasks, a completed task awaiting review, a reviewed task below A-, and a blocked plan with a follow-up placeholder. Use the current test fixtures for plan/review/run metadata formats. Repeat relevant checks with `--all`; that mode lists central packages across repos. For logs, use a fixture-owned sleeper process and PID-bearing running metadata, plus matching `*-gui-*-implement-<task>.stdout.log` and `.stderr.log` files under its task's `runs/`. Only a fixture process with a PAW-like command should be used for actual Cancel testing.

Record the browser/version, fixture paths, commands, expected/observed results, and cleanup in the task plan. Check these scenarios:

1. Select a task, blur its checkbox, open path/validation disclosures and an Edit overlay, type a draft, and place the caret inside it. Mutate another task's status/mtime so rows reorder; wait at least two 2500 ms polls. The selection, disclosure, draft, focus/caret, and page/table scroll survive while changed data appears. Repeat without an open overlay and with same-named cross-repo tasks; remove or make one task ineligible and confirm only its selection disappears. Server-owned hidden fields and disabled controls must stay current.
2. On task detail and Stream, fill stdout/stderr with enough lines to scroll. Put one panel above the bottom and the other at the bottom, then append to both files. The first retains its reading position; only the second follows. Verify horizontal positions independently using long unbroken lines, and check page/document/table scroll too. Truncate the tail and confirm offsets clamp to available content. Start a run after page load, change run identity, and finish it; logs must appear/update/disappear without inheriting an unrelated run's reading state.
3. Delay a log response beyond a parent detail refresh. The connected stream target must continue polling, with one outstanding request per target and none newly scheduled for detached targets. Delay a task response, begin typing after the request starts, then release it; the input must survive. Return one 503 or reject one GET and verify that the last usable view remains and later polling recovers.
4. Exercise Plan, Queue, queued Edit/trigger/Remove, Edit/Answer Questions, both approval-preview actions, Review, Use as Prototype, row Archive/Delete/Cancel, selected Archive/Delete, Add repo, and View PR. Inspect recorded stub arguments, including the clicked Plan/Queue button and externally associated selected checkboxes. Verify accessible inline feedback (`role=status`), document identity, filter/repo retention, refreshed queue/repo/task controls, and retained unrelated selections/drafts. Successful Add repo intentionally changes the active repo. Explicit task/Stream/Home/Archived/PR links still navigate; task-detail forms and ordinary POST fallback retain their navigation behavior.
5. Hold a POST response and click/submit again; only one POST should be sent and the submitter must be disabled. Return a validation error or reject the request: retain draft/selection, re-enable submission, and never automatically retry the mutation. Perform a deliberate retry. Hold an old GET across an accepted action and release it afterward; it must not overwrite newer task state or feedback.

For DOM inspection, use `document.activeElement`, `selectionStart`/`selectionEnd`, `scrollTop`/`scrollLeft`, `isConnected`, and `document.querySelectorAll('[data-paw-refresh-url]')`. Keep references to the original selected control and stream target to detect replacement. Inspect actual request counts in Chrome's Network panel. When injecting a controlled fetch delay from AppleScript, install instrumentation in the page's script context (for example a temporary script element); AppleScript globals can be isolated from page globals. Verify the instrumentation records a request before relying on the delay/failure test. Restore the original fetch function afterward.

Close only fixture browser tabs, stop/reap fixture servers and sleeper processes, and remove only the temporary fixture directories. Confirm no live task, registry, repository, or remote state was used by the walkthrough.

### GUI request performance and validation disclosure

Run `PYTHONDONTWRITEBYTECODE=1 python3 tests/gui-performance.py --measure` for an isolated 12-task / 36-run fixture with reviewed sources and existing replacements. It reports a complete render's discovery/subprocess counts, cold HTTP response, five warm full-page responses and five task-list fragment responses. Compare the same fixture and machine before/after; timings are measurements, not CI thresholds. `gui-server.bats` runs the helper's deterministic discovery/read bounds, Git metadata semantics, concurrent isolation and next-request freshness tests without timing assertions.

Using the isolated browser fixture procedure above, record homepage time to a usable 12-row table separately from HTTP response time. Open task details normally and confirm the validation summary and badge are visible while evidence is closed. Focus the summary and press Space, then toggle with a mouse. Follow a dashboard `#validation` link and confirm it opens; close it and wait through two polls to ensure the hash does not repeatedly reopen it. Change the fixture's validation evidence and verify both open and closed states survive polling with updated escaped content. Check long multiline diagnostics at desktop and 390px widths, the plan source link, and native disclosure toggling with JavaScript disabled. Use an isolated Chrome profile/headless DevTools session if available; install no browser dependency or change existing browser permissions.

### Recorded validation browser regression

```bash
PYTHONDONTWRITEBYTECODE=1 node tests/gui-validation-browser.mjs
# For another installed Chrome/Chromium location:
CHROME_PATH=/path/to/chrome PYTHONDONTWRITEBYTECODE=1 node tests/gui-validation-browser.mjs
```

Requires Python 3, Git, Node 22+ with built-in WebSocket, and an installed Chrome
or Chromium supporting headless CDP. The default browser path is the macOS
Google Chrome application. No npm packages or permission changes are needed.
Missing prerequisites or failed required browser assertions block handoff;
record the blocker rather than waiving it.

The harness creates a temporary Git repo, task store, state directory and Chrome
profile. Both HTTP and DevTools request OS-assigned ports. It checks gray initial
state, scope and live badge transitions, exact reruns, unresolved nested/compound
checks, full hostile/long evidence, 390px wrapping, keyboard detail/source links,
and open/closed disclosure preservation across two polls. It reports the browser
version, fixture path and each assertion group, then reaps only its launched
children and removes only its temporary directory, on success or failure.

GUI Bats fixtures likewise use ephemeral ports and per-test state. Default-port
behavior is asserted at the launcher boundary without binding port 8765; a
cleanup regression checks that an independent fixture stays alive. Cleanup must
never match processes by port or stop a live dashboard to make tests pass.

The recorded-evidence parser/fragment matrix also covers instruction-like check names, exact-name reruns, all reserved metadata labels with multiline indentation ownership, compound tails, sibling resumption, diagnostic scope headings and movement of reruns into/out of diagnostics. Central/legacy fragments retain escaped history and task identity. The Chrome journey reproduces both reviewed false-Passed cases and checks dashboard/detail agreement, unrelated versus exact reruns and disclosure state through polling.

Formatting invariants cover dash, star and numbered bullets with spaces or tabs,
future/unknown outcomes and instruction-like names, both alone and beside an
unrelated success. Metadata cases move exact reruns through plain, fenced and
commented diagnostics, then back to real peers; case-mismatched reruns cannot
resolve the original check. Chrome also exercises a numbered nested `next check`.
