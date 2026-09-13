> **EXAMPLE — illustrative only.** See [`contract.md`](contract.md) for context.

# Add `--version` / `-v` flag to `foo` CLI

## Summary

Adds a `--version` / `-v` flag to the `foo` CLI. Prints `foo <version>` and exits 0. Version is sourced from `foo.__version__`.

## Motivation

Users currently have no way to check which version of `foo` they have installed without inspecting package metadata manually.

## Changes

- `foo/cli.py` — register the flag in `build_parser` using `argparse`'s built-in `action="version"`.
- `tests/test_cli.py` — unit tests for the long and short forms.
- `README.md` — document the new flag in the CLI flags table.

## Validation

- `make test` — 47 passed, 0 failed.
- Manual: `python -m foo --version` and `python -m foo -v` both print `foo 1.4.2` and exit 0.

## Risk

Low — single-flag addition, no new dependencies, no behavior change to existing flags.

## Release Notes

- Added `--version` / `-v` flag to the `foo` CLI.

## Illustrative Review

The fictional [independent review](review.md) meets A- / no production blockers
on `synthetic-example-code`. Version-source migration (I1) is deferred outside scope.
All example checks and identities are synthetic, not PAW validation evidence.
