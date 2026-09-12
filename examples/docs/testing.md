# Validation and recorded evidence
## Required validation
```bash
# Start with checks for the changed area, for example:
PYTHONDONTWRITEBYTECODE=1 bats tests/makefile.bats tests/plugin-install.bats tests/paw-dispatcher.bats
# After the final implementation/doc change:
PYTHONDONTWRITEBYTECODE=1 make check
```
Every implement/diagnose completion requires the named full local validation command after the final implementation change, including batch, GUI and docs-only tasks. Start with targeted changed-area checks, escalate earlier for shared/high-risk behavior or failures, then run `PYTHONDONTWRITEBYTECODE=1 make check` on final code. Reuse a successful full run on that final implementation; later implementation changes require another full run. Missing tools and failed checks block completion, including 100%/Review status. Record `Validation tier chosen: full` and the rationale in `plan.md`, followed by status/diff review.
New plans name both targeted and full commands. For older plans, discover and record the canonical repository command from build targets/docs in preflight; if none can be established, report a specific blocker. Routine local validation needs no repeated approval, but this policy does not authorize dependencies or external services. Plan/edit/read-only review stays proportionate. These are agent instructions, not a machine-enforced execution attestation. See [`tests/README.md`](../../tests/README.md) for fixtures and coverage.

| Decision | Required action |
|---|---|
| Preflight | Name targeted checks and the repository full command in the plan. |
| Changed-area work | Run targeted checks first; preserve each failure/blocker by name. |
| Higher risk | Escalate earlier for shared/high-risk areas, CI/workflows, security, targeted failures, explicit request, unclear blast radius or PR-ready handoff without a full run. |
| Before final full run | Bounded [Quality Contract self-check](quality.md): selected families, counterexamples/checks and specific exclusions. |
| Handoff | Full command passes on final content; map Acceptance Evidence to actual checks and log/code identity; review status/diff; record 100% / Review. |
Independent grading and production sign-off follow implementation; inherited thresholds
remain in the Review requirement. A review never substitutes for required implementation
checks. Runnable suites, prerequisites, fixtures and browser harness instructions belong
to the [test-suite guide](../../tests/README.md).
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

The dashboard shows a single linked status without reason paragraphs. The link opens
the exact task’s **Validation details** disclosure, which retains complete escaped source records,
including historical failures, diagnostics and scope markers. A record containing
both resolved and active checks is labelled partially superseded; its active
failure remains Attention. Reasons identify
unresolved checks; the source link opens the exact task's plan. It starts closed
on ordinary navigation, opens from dashboard evidence links, and supports
keyboard toggling and polling without losing the open/closed choice.

These are recorded-evidence summaries, not proof that every required check ran
or that results belong to the current run. Starting a run does not reset them.
The task's validation contract still determines which checks must run.

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
