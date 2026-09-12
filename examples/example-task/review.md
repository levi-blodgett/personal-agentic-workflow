> **EXAMPLE — illustrative only.** This is a hypothetical independent review of the
> fictional `foo` task. All attempt/code/log identities and outcomes are synthetic;
> commands below were not executed in PAW. See [contract.md](contract.md).

# Task Quality Review — `add-version-flag`

## Review Metadata

- Task: `add-version-flag`
- Quality Policy Version: 1
- Attempt: synthetic-example-attempt
- Reviewed Code: synthetic-example-code (fictional final foo delta)
- Review Date: 2026-09-12 (illustrative)
- Completion: complete
- Scope Reviewed: fictional version flag delta, tests, README and task acceptance evidence
- Grade: A-
- Overall Workflow / Subsystem Grade: not-assessed (whole CLI outside this example's scope)
- Quality Threshold: A- or higher with no production blockers; source: plan.md Post-Implementation Review Requirement
- Threshold Result: met within the hypothetical reviewed scope
- Prototype Cleanup Production-Ready: not-assessed (cleanup outside this version-flag task)

## Summary

The hypothetical implementation meets the scoped criteria: both flags print the
existing version and exit successfully, regression checks pass and README documents
the behavior. This illustrates a completed independent review; it assigns no grade
to PAW itself. No inherited blockers apply to this fictional task.

## Blocking Production-Readiness Issues

None within the hypothetical reviewed scope.

## Validation and Evidence

### Historical / Recorded Evidence

- full-unit-suite: passed (fictional implementation record: 47 tests).
  Command: make test
  Tier: full
  Log: synthetic-example-logs/implementation-full.log; code: synthetic-example-code
- version-flags: passed (fictional implementation record: both print foo 1.4.2, exit 0).
  Command: python -m foo --version; python -m foo -v
  Tier: targeted
  Log: synthetic-example-logs/implementation-flags.log; code: synthetic-example-code

These illustrate the plan's recorded checks. No real source logs exist for this
fictional task; none is claimed inspected or used as PAW completion evidence.

### Fresh Review Checks

- version-parity: passed (hypothetical reviewer rerun).
  Command: python -m pytest tests/test_cli.py -k version
  Tier: targeted
  Log: synthetic-example-logs/review-parity.log; code: synthetic-example-code
- scope-and-docs: passed (hypothetical diff inspection).
  Command: git diff synthetic-example-base synthetic-example-code
  Tier: targeted
  Log: synthetic-example-logs/review-diff.log; inspected foo/cli.py, tests/test_cli.py and README.md

The fictional reviewer uses targeted parity and diff inspection and relies on the
fictional recorded full suite. These are teaching examples, not freshly executed checks.

## Architectural / Design Choices

Reuse `argparse` version handling and `foo.__version__`. This is simpler than a new
handler or dependency and keeps both aliases on the same output path. Tests assert
stdout and exit status, so changing parser internals need not rewrite the assertions.

## Improvement Opportunities

- I1 — Non-blocking, deferred: migrating the version source to package metadata could
  reduce future packaging duplication. Location: `foo/cli.py` version registration.
  Counterexample: metadata and `foo.__version__` diverge after a future packaging change.
  Recommendation: revisit only with that packaging change; the current plan explicitly
  excludes changing the version source and the hypothetical parity checks pass.

## Recommendations

Accept the hypothetical scoped change at A-. Defer I1 because packaging is outside
the approved task; retain both flag aliases, stdout/exit behavior and no-new-dependency
constraint. No replacement is warranted by this example. A review grade does not
supply source-cleanup authority.
