# Testing

How to install and run the PAW test suite, plus which commands count as canonical validation for docs and code changes.

The `tests/` directory contains a [bats-core](https://github.com/bats-core/bats-core) suite covering the `paw` CLI, helper scripts, backend adapters, and task-package contract checks.

```bash
# Install bats (macOS)
brew install bats-core

# Run the full bats suite
bats tests/

# Or use the repo entrypoints
make test
make shellcheck
make check   # canonical full validation: test + lint + shellcheck
```

Every implement/diagnose completion requires the named full local validation command after the final implementation change, including batch, GUI and docs-only tasks. Start with targeted changed-area checks, escalate earlier for shared/high-risk behavior or failures, then run `PYTHONDONTWRITEBYTECODE=1 make check` on final code. Reuse a successful full run on that final implementation; later implementation changes require another full run. Missing tools and failed checks block completion, including 100%/Review status. Record `Validation tier chosen: full` and the rationale in `plan.md`, followed by status/diff review.

New plans name both targeted and full commands. For older plans, discover and record the canonical repository command from build targets/docs in preflight; if none can be established, report a specific blocker. Routine local validation needs no repeated approval, but this policy does not authorize dependencies or external services. Plan/edit/read-only review stays proportionate. These are agent instructions, not a machine-enforced execution attestation. See [`tests/README.md`](../../tests/README.md) for fixtures and coverage.

Key implementation details:

- `paw-dispatcher.bats` uses a PATH-shimmed `claude` fake for dispatcher and worktree-resume tests.
- The dispatcher suite covers subcommand help/completion output, task-assignment resume behavior, and shell-side launcher behavior without calling live backends.
- `paw-pr-workflow.bats` covers the shell-side `paw pr-submit` / `paw pr-review` flow, including PR tracking metadata and saved `review.md` drafts.
- `paw-issue-workflow.bats` covers the shell-side `paw issue-submit` / `paw issue-review` / `paw to-issues --publish` flow, including `issue.md` tracking metadata, per-draft issue metadata, dependency-ordered publication, and rerun refreshes of fetched issue bodies.
- `paw-prompt-body.bats` uses `PAW_BACKEND=stub` so prompt-body assertions never need a real backend binary.
- Dedicated `paw-codex.bats` coverage stays in this repo, while backend-specific compatibility checks for separately distributed plugins should live with each plugin repo; PAW itself keeps seam-level external-plugin coverage in `paw-dispatcher.bats`.
- Every `*.bats` file sources `tests/helpers/hermetic.bash`, which sets `LC_ALL=C`, `LANG=C`, and `TZ=UTC` and unsets all `PAW_*` env vars so tests behave identically on macOS and Linux CI runners.

Installer/plugin changed-area validation:

```bash
bats tests/makefile.bats tests/plugin-install.bats tests/paw-dispatcher.bats
```

The plugin suite copies the [published Makefile](../backend-plugin/Makefile) into
a temporary external checkout, supplies a harmless adapter, and runs installed
PAW from a third directory with isolated HOME/PREFIX/PATH/task storage. It checks
capture and streaming separately; model discovery alone is insufficient. Full
`make check` is required for installer changes before handoff.

## Recorded validation in the GUI

The dashboard and task details summarize `plan.md` → **Validation Performed**.
Use one named check per bullet, followed by its explicit result and indented
Command/Tier/Log metadata or diagnostics:

```markdown
## Validation Performed

### Context
- Historical tests: passed

### Development history
- classifier: failed — regression reproduced during development

### Implementation results
- classifier: passed
  Command: PYTHONDONTWRITEBYTECODE=1 python3 tests/gui-validation.py
  Tier: targeted
- browser: not executed — browser check still required
- full: failed because expected output differs
  Command: PYTHONDONTWRITEBYTECODE=1 make check
  Tier: full
  Log: /tmp/check.log
- full: passed (rerun; supersedes earlier result)
```

This example is **Recorded**: the exact full-check rerun resolves its failure,
but browser validation is still unexecuted. A successful substitute, even when
approved, leaves the original incomplete check inspectable and the aggregate
neutral. Record the substitution and its rationale; do not erase the original.

| Badge | Meaning |
| --- | --- |
| Gray **Unvalidated** | Missing, empty, template-only or exclusively context/development evidence. |
| **Passed** | Explicit successes with no unresolved failures or uncertain/incomplete checks. |
| **Attention** | An unresolved failed, blocked or unavailable check, including negated success or nonzero exit. |
| **Recorded** | A named unexecuted, skipped, pending, unknown or otherwise uncertain check, or unfamiliar evidence. |

Attention takes precedence over Recorded, which takes precedence over Passed.
Supported explicit results include `passed`, `OK`, `succeeded`, `successful`,
`exit 0`, `failed`, `error`, `blocked`, `unavailable`, `did not pass`,
`not passed`, `not successful`, and `exit 1` (any nonzero exit). Named `not run`,
`not yet run`, `not executed`, `has not run`, `skipped` and other incomplete
results remain Recorded, even alongside success. Named future wording such as
`browser: expected to run later` also remains Recorded. An explicit result is read
before its diagnostic tail: `failed because expected output differs` remains
Attention. Unknown results cannot borrow “passed” from their explanations.
Commands, instructions and `0 failures, 0 errors` alone do not prove success.

Named syntax takes precedence over instruction vocabulary: `Run browser: failed`,
`next check: failed`, and `planning-only checks: failed` all require Attention.
Renaming an ordinary check does not change its outcome; keep names stable so
exact, case-sensitive reruns can resolve their own earlier results.

Reserved metadata labels (case-insensitive, optionally backticked) are `Command`,
`Tier`, `Log`, `Note`, `Source`, `Provenance`, `Rationale`, and `Validation tier chosen`.
They are not check names. A plain or bulleted metadata label owns its entire inline
value and all more-indented following lines, including blank-separated nested lists,
headings and rerun markers. Parsing resumes at the next nonblank line at the label's
indentation or less. Tabs use four-column stops. A compound metadata tail also owns
more-indented continuation lines; real checks before that tail remain active.

```markdown
- browser: failed
- tests: passed
  Log: diagnostic output; browser: passed (rerun; supersedes earlier result)
    ### Implementation results
    browser: passed (rerun; supersedes earlier result)

    - deeper diagnostic: passed
  sibling: failed
- browser: passed (rerun; supersedes earlier result)
```

The logged reruns and heading are inert. The dedented real browser rerun resolves
browser, but the peer `sibling: failed` keeps Attention. Indentation is the supported
ownership boundary: put every diagnostic continuation deeper than its metadata
label, or use a fenced block. A same-level named result is a real peer check, not an
inferred diagnostic continuation. Complete source text remains available in details.

Scope is forward-only. `### Context` and `### Development history` exclude
subsequent checks from the implementation aggregate until `### Implementation
results`. The corresponding top-level bullets (`- Context:`, `- Development
history:`, `- Implementation results:`) and legacy `Planning investigation only.`
or `Planning validation only.` markers are supported. Boundaries never erase
earlier implementation results; planning/development successes cannot resolve
implementation failures. Unmarked legacy records keep implementation semantics.

Only `check: passed (rerun; supersedes earlier result)` (or another explicit
success with the same marker) resolves earlier results for that exact,
case-sensitive check name. Use it after actually rerunning that check. A marker
inside a diagnostic sentence does not count; unnamed or combined ambiguous
names cannot supersede results. Top-level, indented and semicolon-separated
named checks share the same outcome rules. A tests rerun cannot clear a browser
failure nested beneath it or in the same compound record. Standalone `OK` and
legacy command/check results such as `make check passed` remain supported;
canonical named bullets provide reliable rerun identity. Indented legacy list
results use the same recognizer; unfamiliar list results remain Recorded. Unsupported result-like
lines stay uncertain. Command/Tier/Log and Note/Source/Provenance/Rationale
metadata, fenced blocks and HTML comments do not invent execution results.

The **Validation details** disclosure retains complete escaped source records,
including historical failures, diagnostics and scope markers. A record containing
both resolved and active checks is labelled partially superseded; its active
failure remains Attention. Reasons identify
unresolved checks; the source link opens the exact task's plan. It starts closed
on ordinary navigation, opens from dashboard evidence links, and supports
keyboard toggling and polling without losing the open/closed choice.

These are recorded-evidence summaries, not proof that every required check ran
or that results belong to the current run. Starting a run does not reset them.
The task's validation contract still determines which checks must run.

Run the reproducible isolated browser regression after relevant GUI changes:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/gui-validation.py
PYTHONDONTWRITEBYTECODE=1 bats tests/gui-server.bats
PYTHONDONTWRITEBYTECODE=1 node tests/gui-validation-browser.mjs
```

See [browser prerequisites and fixture ownership](../../tests/README.md#recorded-validation-browser-regression).
These checks supplement the required full `make check` gate for shared GUI changes.

Implementation completion includes self-checks and final full local validation.
Independent grading/production sign-off follows in Review; keep inherited quality
thresholds in a post-implementation review requirement when writing new plans.
An independent review is not a substitute for required implementation checks.
