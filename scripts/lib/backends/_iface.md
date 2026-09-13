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

- Write a JSON object to `<out-json-path>` with a `.result` string for PAW
  to display via `jq -r`. Include usage data readable by `backend_parse_tokens`.
- Return the underlying tool's exit code (0 = success).

### `backend_run_stream <out-json-path> [tool args...]`

Run the AI model in streaming mode, printing text to stdout live.

- Tee the raw stream data to `<out-json-path>` (must be parseable by
  `backend_parse_stream_tokens`).
- Print each content block on its own line (newline at `content_block_stop`,
  blank line at `message_stop`).
- Return the underlying tool's exit code (0 = success).
- PAW currently requires `jq` on `PATH` before invoking streaming, even if
  the external adapter uses another parser.

### `backend_parse_tokens <json-file> [field]`

Parse the approximate total token count from a capture result file.

- Print the count as a plain integer string, or `unknown` on failure.
- Must not error when the file is absent or malformed; print `unknown` and exit 0.
- Optional field selectors: `total` (default), `input`, `output`, `cache_read`,
  `cache_creation`. Return the requested integer or `unknown` if unavailable.
  Do not write diagnostic prose to parser stdout.

### `backend_parse_stream_tokens <json-file> [field]`

Parse the approximate total token count from a stream result file.

- Same output contract as `backend_parse_tokens`.

## Optional capability exports

These functions are not required.  Callers must check with `declare -f` before
invoking any optional function.

### `backend_display_model [fallback-model]`

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

- `run-capture` and `run-stream` receive the output path first, then PAW-generated
  arguments: `--model <model> --add-dir <PAW_HOME> --permission-mode
  bypassPermissions --max-turns <count>`, then the prompt (and any forwarded args).
  The prompt is an argument, not stdin. Translate these arguments for your own
  provider; preserve boundaries for paths/prompts containing spaces. Each plugin
  invocation is a separate process, so do not rely on shell state between hooks.
- Write to the supplied output path; do not replace it with a plugin-chosen path.
  Capture displays `.result`; stream stdout is displayed live and the output file
  retains raw provider events for the stream parser. Preserve the provider's exit
  status through pipes (for Bash adapters, use `pipefail` or `PIPESTATUS`). PAW
  propagates failures and also recognizes error responses in capture mode.
- Missing required run arguments or unknown subcommands should produce a clear
  stderr diagnostic and nonzero status; missing/malformed telemetry inputs return
  `unknown` successfully. Required subcommands are not probed at discovery time.
- `parse-tokens` and `parse-stream-tokens` must print a plain integer string or `unknown`.
- `display-model` should print exactly one model id when it overrides the fallback.
  Missing, failing, or empty output falls back to the supplied resolved model;
  stderr is suppressed.
- `usage-banner` should stay fast and non-networked. Its stdout is redirected to
  stderr; failure is ignored (unsupported-hook diagnostics may remain visible).

## Shipped built-ins

| Name     | File                              | `backend_display_model`        | `backend_usage_banner`              |
|----------|-----------------------------------|--------------------------------|-------------------------------------|
| `claude`  | `scripts/lib/backends/claude.sh`  | — (uses `PAW_MODEL`)           | —                                   |
| `codex`   | `scripts/lib/backends/codex.sh`   | — (uses `PAW_MODEL`)           | Yes (codex login status)            |
| `stub`    | `scripts/lib/backends/stub.sh`    | — (uses `PAW_MODEL`)           | —                                   |

Additional external plugins can be installed independently without changing
`scripts/paw`.
