# Backend Interface Contract

`scripts/paw` resolves `PAW_BACKEND` (default `codex`) in this order:

1. Built-in shell module: `scripts/lib/backends/<name>.sh`
2. External executable plugin on `PATH`: `paw-backend-<name>`

Both integration paths expose the same minimum runtime surface.

## Built-in shell modules

Every built-in backend module under `scripts/lib/backends/` must implement the four functions below and be sourceable by `bash`.

## Required exports

### `backend_run_capture <out-json-path> [tool args...]`

Run the AI model in non-streaming mode.

- Write a JSON-ish result blob to `<out-json-path>` (must be parseable by
  `backend_parse_tokens`).
- Return the underlying tool's exit code (0 = success).

### `backend_run_stream <out-json-path> [tool args...]`

Run the AI model in streaming mode, printing text to stdout live.

- Tee the raw stream data to `<out-json-path>` (must be parseable by
  `backend_parse_stream_tokens`).
- Print each content block on its own line (newline at `content_block_stop`,
  blank line at `message_stop`).
- Return the underlying tool's exit code (0 = success).
- Requires `jq` on `PATH`.

### `backend_parse_tokens <json-file>`

Parse the approximate total token count from a capture result file.

- Print the count as a plain integer string, or `unknown` on failure.
- Must not error when the file is absent or malformed.

### `backend_parse_stream_tokens <json-file>`

Parse the approximate total token count from a stream result file.

- Same output contract as `backend_parse_tokens`.

## Optional capability exports

These functions are not required.  Callers must check with `declare -f` before
invoking any optional function.

### `backend_display_model`

Echo the canonical model identifier that the backend will actually use,
regardless of the `--model` flag passed by `scripts/paw`.

- Print a single model id string to stdout (e.g. `azure::gpt-5.4`).
- When absent, `scripts/paw` falls back to the value returned by `_resolve_model`
  (i.e. the effective `PAW_MODEL` override or backend default) for the banner
  and `paw model`.
- Implement this for backends that hardcode or independently resolve their model
  and therefore ignore `PAW_MODEL`.

### `backend_usage_banner`

Optional display hook called by `print_launch_banner` in `scripts/paw`
immediately after the standard "Launching: paw …" line.

- Print zero or more lines to **stderr** providing backend-specific context
  (e.g. auth status, prior usage).
- Takes no arguments; return value is ignored.
- When absent, `scripts/paw` skips the call silently.
- Keep fast: no blocking network calls; local commands only.

## External executable plugins

An external backend plugin is any executable named `paw-backend-<name>` on `PATH`.
It must support these subcommands:

- `run-capture <out-json-path> [tool args...]`
- `run-stream <out-json-path> [tool args...]`
- `parse-tokens <json-file> [field]`
- `parse-stream-tokens <json-file> [field]`

Optional subcommands:

- `display-model [fallback-model]` — print the effective model id when the plugin ignores `PAW_MODEL` or resolves models independently.
- `usage-banner` — print zero or more fast local context lines for the launch banner hook.

The runtime contract for each subcommand matches the built-in function with the same name:

- `run-capture` and `run-stream` receive the same paw-generated tool args after the output path.
- `parse-tokens` and `parse-stream-tokens` must print a plain integer string or `unknown`.
- `display-model` should print exactly one model id when it overrides the fallback.
- `usage-banner` should stay fast and non-networked.

## Shipped built-ins

| Name     | File                              | `backend_display_model`        | `backend_usage_banner`              |
|----------|-----------------------------------|--------------------------------|-------------------------------------|
| `claude`  | `scripts/lib/backends/claude.sh`  | — (uses `PAW_MODEL`)           | —                                   |
| `codex`   | `scripts/lib/backends/codex.sh`   | — (uses `PAW_MODEL`)           | Yes (codex login status)            |
| `stub`    | `scripts/lib/backends/stub.sh`    | — (uses `PAW_MODEL`)           | —                                   |

Additional external plugins can be installed independently without changing
`scripts/paw`.
