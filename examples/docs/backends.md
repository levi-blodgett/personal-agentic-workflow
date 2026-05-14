# Backends

How to configure, compare, and extend PAW's pluggable AI backend system.

## `PAW_BACKEND`

By default `paw` wraps the `codex` CLI. Set `PAW_BACKEND` to swap to a
different AI backend without changing any other code:

```bash
PAW_BACKEND=codex  paw implement my-task   # default
PAW_BACKEND=claude paw implement my-task
PAW_BACKEND=stub   paw implement my-task   # test-only stub (writes args to $BATS_TEST_TMPDIR)
```

`paw` first looks for a built-in shell module at `scripts/lib/backends/<name>.sh`.
If no built-in exists, it looks for an external executable plugin named
`paw-backend-<name>` on `PATH`.

Built-ins implement four required functions: `backend_run_capture`,
`backend_run_stream`, `backend_parse_tokens`, and `backend_parse_stream_tokens`.
External plugins expose the same runtime surface through subcommands:
`run-capture`, `run-stream`, `parse-tokens`, and `parse-stream-tokens`.
The full contract is documented in
[`scripts/lib/backends/_iface.md`](../../scripts/lib/backends/_iface.md).

Optional hooks such as `backend_display_model` and `backend_usage_banner` let a
backend report its resolved model and print fast local context to stderr
immediately after the standard launch banner. The shipped
`codex` backend uses this to surface `codex login status` before a run starts.

See [`scripts/lib/backends/README.md`](../../scripts/lib/backends/README.md) for the built-ins that ship in this repo and the plugin-install path for private backends.

The `codex`, `claude`, and `stub` backends ship in this repo today. `codex` is the default. Private or separate-distribution backends can install as external plugins without changing this repo.

## Shipped backends at a glance

| Backend | Default? | Typical use | Notes |
|---|---|---|---|
| `codex` | Yes | Day-to-day planning and implementation | Uses `codex exec`, defaults to `gpt-5.4`, prints auth status, and supports streamed output. |
| `claude` | No | Anthropic CLI workflow | Uses the `claude` CLI, supports capture and streaming, and enforces the no-haiku guardrail for `paw implement`. |
| `stub` | Test-only | Bats fixtures and prompt-body tests | Never makes real API calls; records argv/prompt into `$BATS_TEST_TMPDIR`. |

## External plugin backends

Install an executable named `paw-backend-<name>` on `PATH` when a backend
should live outside this repo. That keeps private integrations out of the
public PAW tree while preserving the same `PAW_BACKEND=<name>` operator surface.

Plugin subcommands:

- `run-capture <out-json-path> [tool args...]`
- `run-stream <out-json-path> [tool args...]`
- `parse-tokens <json-file> [field]`
- `parse-stream-tokens <json-file> [field]`
- Optional: `display-model [fallback-model]`
- Optional: `usage-banner`

## `claude` backend

The claude backend wraps the `claude` CLI. Model is selected from `PAW_MODEL`
when set and otherwise falls back to the backend default model family.

## External plugin backend example

Use an external plugin when a backend should live outside this repo because it
is private, separately distributed, or owned by another team. PAW discovers any
executable named `paw-backend-<name>` on `PATH`, so an operator can install the
plugin independently and then activate it with `PAW_BACKEND=<name>`.

Example install flow for a generic `backend-plugin` checkout:

```bash
cd /path/to/paw-backend-plugin
make install
```

```bash
PAW_BACKEND=backend-plugin paw implement my-task
```

The plugin executable must be named `paw-backend-backend-plugin` after
installation so PAW can discover it automatically.

### Required runtime surface

Every external plugin must support the same minimum contract that built-in
backends implement:

- `run-capture <out-json-path> [tool args...]`
- `run-stream <out-json-path> [tool args...]`
- `parse-tokens <json-file> [field]`
- `parse-stream-tokens <json-file> [field]`

Optional subcommands:

- `display-model [fallback-model]` when the plugin resolves its own model and
  needs the launch banner plus `paw model` to report the true value.
- `usage-banner` when the plugin can print fast local launch context to stderr
  before the run starts.

See [`scripts/lib/backends/_iface.md`](../../scripts/lib/backends/_iface.md) for
the full protocol details.

### Install and validation expectations

After installation, validate the plugin the same way an operator would use it:

```bash
command -v paw-backend-backend-plugin
PAW_BACKEND=backend-plugin paw model
PAW_BACKEND=backend-plugin paw implement my-task
```

Plugin-specific compatibility tests should live with the plugin repo itself.
PAW keeps dispatcher-level seam coverage for external plugin discovery and
failure handling, but not backend-specific behavior for every separately
distributed plugin.

### Model, streaming, and env-var expectations

- **Model selection:** plugins may honor `PAW_MODEL`, ignore it, or resolve
  models independently. If they do not follow PAW's default model resolution,
  they should implement `display-model` so the operator-facing banner stays
  accurate.
- **Token telemetry:** plugins should return an integer token count when they
  can parse one, otherwise `unknown`.
- **Streaming:** plugins are responsible for the `run-stream` contract, including
  teeing raw output to the capture file and printing readable content blocks to
  stdout.
- **Plugin-specific env vars:** backend-specific toggles belong to the plugin's
  own docs unless PAW itself consumes the variable.

### Choose a plugin vs a built-in

Prefer an external plugin when the backend:

- depends on private tooling or credentials that should not ship in this repo
- has its own release cadence or ownership boundary
- needs richer backend-specific validation than PAW should carry centrally

Prefer a built-in backend when the integration is part of PAW's core supported
surface and should be versioned, documented, and tested in-repo.

## `codex` backend

The `codex` backend wraps the [OpenAI Codex CLI](https://github.com/openai/codex).

**Prerequisite:** `codex` must be on `PATH` (install via Homebrew: `brew install codex`, or
`npm install -g @openai/codex`).

```bash
paw implement my-task
PAW_MODEL=gpt-5.5 paw implement my-task
```

Key properties:

- **Model from `PAW_MODEL`:** `codex exec` accepts `-m <model>`, so `PAW_MODEL`
  is forwarded as-is for every model-resolved subcommand. When unset, PAW defaults
  codex runs to `gpt-5.4`.

- **ChatGPT vs API-key auth:** `paw` prints `codex login status` at launch so you
  can see which access path the CLI is using before a run starts.
  - ChatGPT login: `gpt-5.4` is the default path; `gpt-5.5` is the preferred upgrade.
    PAW warns when you pick older `o*` / `gpt-4*` style models on this path.
  - OpenAI API key: named OpenAI model IDs are forwarded normally.

- **Usage banner:** when the codex backend is active, `paw` prints the output of
  `codex login status` to stderr immediately after the standard launch line.  This
  gives you immediate auth context before a long-running run starts.
  (`codex login status` writes to stderr; the backend captures both streams.)

- **Streaming errors:** when `PAW_STREAM=1`, API errors (e.g. unsupported model) are
  printed as `paw/codex error: <message>` so they are visible instead of silently dropped.

- **Sandbox:** defaults to `-s danger-full-access` (full filesystem access within
  codex's sandbox policy).  Set `PAW_CODEX_DANGEROUS=1` to use
  `--dangerously-bypass-approvals-and-sandbox` instead — intended for externally
  sandboxed CI environments only.

- **Session isolation:** `--ephemeral` is always added so no session state persists
  between paw runs.

- **Token telemetry:** the backend parses current Codex JSONL usage from
  `turn.completed.usage` plus older `token_count` events so shared prompt and
  debugging flows can still inspect usage counts when needed.

Example invocations:

```bash
# Default Codex path
paw implement my-task
PAW_MODEL=gpt-5.5 paw implement my-task
PAW_MODEL=gpt-5.5 paw plan my-task "add observability"
PAW_BACKEND=codex PAW_CODEX_DANGEROUS=1 PAW_MODEL=o4-mini paw implement my-task  # CI
```

## Streaming output (`PAW_STREAM=1`)

By default `paw` captures backend output silently, then prints the final result after the run. Set `PAW_STREAM=1` to stream assistant text live in the terminal:

```bash
PAW_STREAM=1 paw implement my-task
```

Each content block starts on its own line (newline at `content_block_stop`, blank line at `message_stop`) so distinct thoughts do not concatenate into one paragraph. `claude` and `codex` both support this mode. `jq` is required on `PATH` for the JSON-streaming backends, and some external plugins may require it for their own capture or stream parsing path.
