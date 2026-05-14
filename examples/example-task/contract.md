> **EXAMPLE — illustrative only.** This is a sample task package for a hypothetical CLI repo, included to show what a real `.agent/<task-name>/` directory looks like in practice. It is committed here as documentation; real task packages live under `.agent/<task-name>/` in their target repos and are excluded from git via `.git/info/exclude`.

# Contract — `add-version-flag`

## Task Summary

Add a `--version` / `-v` flag to the `foo` CLI tool that prints the package version and exits with status 0.

## Repo Context

- Repo: hypothetical `foo-cli` (Python, packaged via `pyproject.toml`)
- Entrypoint: `foo/__main__.py`
- Arg parsing: `argparse`
- Version source: `foo/__init__.py` defines `__version__`
- Test runner: `pytest` (already wired into `make test`)

## Explicit User Constraints

- Do not introduce new dependencies.
- Must work even when no subcommand is given.
- Output format: `foo <version>` on a single line, e.g. `foo 1.4.2`.
- Exit code 0 on `--version`; no other side effects.

## Known Inputs / Links / Examples

- Existing flag handling lives in `foo/cli.py::build_parser`.
- Conventions: every flag has a unit test in `tests/test_cli.py`.

## Unresolved Assumptions To Validate During Planning

- Whether `__version__` is the canonical source or whether the version is read from package metadata. Confirm by reading `foo/__init__.py` and `pyproject.toml`.
- Whether `argparse`'s built-in `action="version"` is acceptable, or whether the team prefers a manual handler for consistency with other flags.
