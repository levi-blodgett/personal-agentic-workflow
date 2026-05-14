# `scripts/lib/backends/`

Built-in AI backend modules for `paw`. Each module is a self-contained bash file that implements the required runtime functions defined in [`_iface.md`](_iface.md).

## Shipped built-ins

| File | `PAW_BACKEND` value | Required functions | `backend_display_model` | Purpose |
|------|---------------------|--------------------|-------------------------|---------|
| [`claude.sh`](claude.sh) | `claude` | ✓ | — (uses `PAW_MODEL`) | Wraps the `claude` CLI. Supports capture and streaming modes. Aggregates token counts across all session iterations. |
| [`codex.sh`](codex.sh) | `codex` (default) | ✓ | — (uses `PAW_MODEL`, default `gpt-5.4`) | Wraps the `codex` CLI (`codex exec`). Honors `PAW_MODEL` for model selection, defaults to `gpt-5.4`, and parses current Codex JSONL usage when available. |
| [`stub.sh`](stub.sh) | `stub` | ✓ | — (uses `PAW_MODEL`) | Test-only backend. Writes argv and the prompt to `$BATS_TEST_TMPDIR` without making any real API calls. Used by `tests/paw-prompt-body.bats`. |

## Adding a built-in backend

1. Create `scripts/lib/backends/<name>.sh` and implement the four required functions from `_iface.md`.
2. If the backend ignores `PAW_MODEL` and uses its own model, add `backend_display_model` so the banner and `paw model` report the correct model.
3. Optionally add `backend_usage_banner` or `backend_display_model` when the backend needs custom launch context or model reporting.
4. Set `PAW_BACKEND=<name>` — no other changes to `scripts/paw` are required.
5. Add a row to the table above and backend-specific coverage under `tests/`.

## External plugins

When a backend should live outside this repo, install an executable named `paw-backend-<name>` on `PATH` instead of adding a new built-in file here. The executable protocol is documented in [`_iface.md`](_iface.md). Keep backend-specific compatibility coverage with the plugin's own repo; this repo only carries the generic dispatcher and protocol seam tests.
