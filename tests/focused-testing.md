# Focused regression checks

[Back to README](README.md).

## Focused checks

```bash
PYTHONDONTWRITEBYTECODE=1 bats tests/makefile.bats tests/plugin-install.bats tests/paw-dispatcher.bats
PYTHONDONTWRITEBYTECODE=1 python3 tests/gui-validation.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/gui-prototype.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/review-record.py
PYTHONDONTWRITEBYTECODE=1 bats tests/gui-server.bats
```

The installer suite copies the published [plugin Makefile](../examples/backend-plugin/Makefile)
into a temporary external checkout and invokes installed PAW from a third directory.
HOME/PREFIX/PATH/task storage are isolated; capture and streaming are both checked.
Model discovery alone cannot certify provider execution.

Python review/prototype journeys cover source/replacement roles, run linkage, duplicate
starts, stale approval, cancellation/failure/reuse, complete reviews, grade grammar and
archived ancestry. The evidence classifier covers formatting/diagnostic invariants,
exact reruns, scope and central/legacy fragment identity; the
[canonical writing grammar](../examples/docs/testing.md#recorded-validation-in-the-gui)
explains expected outcomes. These are hermetic fixtures, not model-quality evidence.

### Compact GUI and overlay journeys

`PYTHONDONTWRITEBYTECODE=1 node tests/gui-validation-browser.mjs` also runs `gui-ux-browser.mjs`. Both use installed Chrome/Chromium (set `CHROME_PATH` if needed), Node 22+ built-in WebSocket, Python and Git, without npm dependencies. UX fixtures isolate repos, task stores, registry, browser profile and OS-assigned ports, stub model launches, and terminate only their owned children. Run the UX helper directly for focused iteration. Set `PAW_GUI_EVIDENCE=/absolute/output/directory` to retain viewport screenshots. `node tests/gui-ux-browser.mjs --baseline` captures the committed HEAD renderer for before/after comparison.

Journeys cover compact table placement, duplicate-name repo targeting, preserved filters, queue discovery, approval/action placement, input draft retention, accessible dismissal/focus, late preview responses, unchanged polling, pending submissions, contextual bulk controls and archived recovery. Layout checks cover 1440×900, 1024×768, 390×844 and the 720×450 CSS viewport equivalent of 200% desktop zoom. Inspect captured desktop/narrow/dialog images for visual hierarchy, readable contrast, visible focus and reachable action controls; surrounding content must fit while tables may scroll. Run the targeted GUI Bats suite first and the full `PYTHONDONTWRITEBYTECODE=1 make check` after final changes. Browser checks supplement the full command.

### Saved run history regression

`PYTHONDONTWRITEBYTECODE=1 bats tests/gui-server.bats --filter 'history'` covers
exact selected-run HTTP/fragment identity, terminal launch-reference retention,
legacy ambiguity, per-stream availability, task/path containment and bounded reads
(including growth during a read). History lists must not open log bodies. Existing
`gui-performance.py` bounds continue to apply.

The UX browser harness also verifies History → Logs keyboard/native navigation,
selected terminal output through new runs/polling, independent scroll/follow,
disclosure/focus retention, light/dark narrow layouts and delayed old responses after
switching or closing. Set `PAW_GUI_EVIDENCE` to retain history screenshots. The combined
browser command below includes existing live Stream and prototype journeys; run it
and final `PYTHONDONTWRITEBYTECODE=1 make check` before implementation handoff.

### GUI live-state browser regression

See [Browser regression checks](browser-testing.md).

### Transient GUI messages

The UX harness also checks keyboard dismissal, navigation route/type parity,
4999/5000 ms boundaries using controlled message timers, and a foreground elapsed
smoke (100 ms observation interval, at most 1 second scheduling tolerance).
It covers inline retry/replacement, identical text, dismissal followed by a new
result, empty live regions, real polling without deadline reset/resurrection,
draft/focus preservation, escaped long text, PR links, narrow light/dark
layouts and readable no-JavaScript POST feedback with hidden close controls.
Use the installed-browser prerequisites above; combined browser validation includes
these checks. Controlled time intercepts only five-second timers; real fetch and
2500 ms polling continue. Fixture POST replies avoid real launches or PR requests.

Branch PR regressions in `task-store.bats` and `paw-pr-workflow.bats` cover exact
branch identity, worktree/repository boundaries, saved assignments, preserved
migration/retry bytes, stubbed submission and structural task ownership. Producer
prompt coverage checks the canonical path; existing GUI HTTP/browser journeys
retain remote View PR, drafts and polling.

Dashboard retirement coverage asserts eight columns on populated full/fragment pages,
distinct empty/filter recovery and
404/no package mutation for stale selected-action POSTs in scoped and all-repo modes.
The UX browser fixture measures long prototype rows at 1440/1920px: Task + Repo >=35%,
Stage <=15% and at most three lines, with full diagnostics and lineage in detail.
Capture the original renderer with `PAW_GUI_EVIDENCE=/tmp/paw-layout node tests/gui-ux-browser.mjs --baseline`,
then run the required browser command with the same evidence directory to compare widths.
Record HEAD and renderer hashes: baseline uses committed code, not pending edits.
The refinement regression retains Task/Repo width and checks visible Stage text edges
and desktop control centerlines within 2 CSS pixels. Light/dark screenshots cover
390/720/1024/1440/1920px, open disclosures, long labels and queued counts. Narrow rows
retain named table/header/cell accessibility semantics without horizontal panning.
Native Tools keyboard, exact form targets and focus survive two polling refreshes;
HTTP fixtures cover single Answer Questions and Clear filters retaining a different
active repo in all-central-store mode. Combined journeys retain pending/delayed action,
preview, draft/caret, native form, theme/contrast and saved/live log regressions.
Validation browser checks cover all four single-line linked statuses at desktop, 390px
and 200%-equivalent widths, keyboard evidence access, escaping and polling.

Review resource regressions live in `review-record.py` (runtime slots, malformed and
unreadable resources, exact history, retry and completed lineage), `paw-prompt-body.bats`
(PAW_HOME overrides with spaces, central/legacy Review-only seeding and backend refusal),
and `gui-prototype.py` (rendered pending/adverse/passing records through GUI guards).
`templates.bats` checks the illustrative review through the shared reader. These
fixtures establish lifecycle behavior, not model compliance or independent grades.

PR publication checks: `PYTHONDONTWRITEBYTECODE=1 python3 tests/pr-publication.py`
exercises eligibility, managed body/visual parsing, two-task ownership, remote
identity, stale previews, locks, partial success and native/JSON HTTP parity.
`bats tests/paw-pr-workflow.bats tests/task-store.bats` includes this check and
CLI fixtures. The named `node tests/gui-validation-browser.mjs` entrypoint also
runs `tests/gui-pr-browser.mjs`: retained Next/preview/result screenshots, two-task
contributions, lower grades, duplicate clicks, delayed preview/draft/caret retention,
errors, native fallback and narrow dark layout. Set `PAW_GUI_EVIDENCE` to retain
artifacts. All remote transport is stubbed; no live GitHub publication occurs.
Required full local validation remains `PYTHONDONTWRITEBYTECODE=1 make check`.
