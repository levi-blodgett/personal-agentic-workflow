> **EXAMPLE — illustrative only.** See [`contract.md`](contract.md) for context.

# Plan — `add-version-flag`

## Objective

Add a `--version` / `-v` flag to the `foo` CLI that prints `foo <version>` and exits 0.

## Open Questions / Follow-Ups

- None. Planning confirmed `foo <version>` is the only in-scope output; reporting the Python runtime stays a follow-up idea.

## Implementation Phases / Checklist

- [x] Add a failing test for `python -m foo --version`.
  Progress: Added `tests/test_cli.py::test_version_long` asserting stdout and exit code.
- [x] Implement `--version` using the existing `foo.__version__` source.
  Progress: Wired `argparse` `action="version"` with `version=f"foo {__version__}"`.
- [x] Add the short-flag test and implementation parity for `-v`.
  Progress: Added `test_version_short` and confirmed the short flag shares the same parser behavior.
- [x] Update the README and run validation.
  Progress: Added the CLI-flags row and ran the planned test and manual version checks.

## Acceptance Criteria

- [x] `python -m foo --version` prints exactly `foo <version>` and exits 0.
- [x] `python -m foo -v` behaves identically.
- [x] New unit tests pass.
- [x] Existing unit tests still pass.
- [x] README CLI flags table includes the new flag.
- [x] No new dependencies introduced.

## Scope

- `foo/cli.py` — add the flag to `build_parser`.
- `tests/test_cli.py` — add unit tests covering both `--version` and `-v`.
- `README.md` — add a one-line usage example under "CLI flags".

## Non-Goals

- No changes to how the version is stored.
- No new subcommands.
- No packaging, release, telemetry, or upgrade-check changes.

## Current Status

- Plan position: All implementation phases complete.
- Estimated completion: 100%
- Next work: Review.

## Approval Boundaries

Stop and ask before:

- changing the version source
- adding any dependency
- modifying packaging or release config

## Risk Classification

**Low** — single-flag addition, isolated to one subsystem, fully unit-testable.

## Durable Documentation Requirements

- README "CLI flags" table must include `--version` / `-v` after this change.

## Validation Contract

- `make test` — full unit suite, must pass.
- `python -m foo --version` — manual check, expect `foo <version>` and exit 0.
- `python -m foo -v` — manual check, same behavior.
- `git status` and `git diff` review before handoff.

## Decisions Made

- Used `argparse`'s built-in `action="version"` rather than a manual handler.
- Captured stdout via `capsys` in tests rather than mocking `sys.stdout`.

## Changed Files / Areas

- `foo/cli.py` — added the new CLI flag.
- `tests/test_cli.py` — added the long and short version tests.
- `README.md` — documented the new flag.

## Validation Performed

- `make test` — 47 passed, 0 failed.
- `python -m foo --version` — `foo 1.4.2`, exit code 0.
- `python -m foo -v` — `foo 1.4.2`, exit code 0.
- `git status` and `git diff` reviewed — only the three planned files changed.
- Code best-practices checklist applied — see `prompts/prompt_instructions.md` "Code Best Practices".

## Remaining Work

- None.

## Risks / Follow-Ups

- If the project later migrates to `importlib.metadata.version`, this flag wiring will need a separate follow-up change.

## Quality Contract

Quality policy version: 1

## Acceptance Evidence

| Criterion | Observable behavior | Planned check | Evidence destination |
|---|---|---|---|
| Version output and parity | Both flags print the same version and exit 0 | Long/short CLI behavior tests | Validation Performed: named CLI checks, final code identity |
| Regression safety | Existing behavior remains supported | Full unit suite | Validation Performed: full-suite log |
| Documentation | README shows both flags accurately | CLI docs review | Reviewed README diff |
| Dependency constraint | Existing parser and version source are reused | Dependency diff inspection | Reviewed code identity |

## Post-Implementation Review Requirement

Independent Review: A- or higher with no production blockers. Preserve explicit
older/inherited thresholds; record their source and retain A- as the improvement
target when the authoritative threshold differs. Independent grading and
production sign-off follow implementation completion.
