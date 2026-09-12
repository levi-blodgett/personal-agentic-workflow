# Backends

How to configure, compare, and extend PAW's pluggable AI backend system.

For selective-read guidance and optional tool evaluation, see the
[context minimization decision](context-minimization.md).

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

## Shipped backends at a glance

| Backend | Default? | Typical use | Notes |
|---|---|---|---|
| `codex` | Yes | Day-to-day planning and implementation | Uses `codex exec`, defaults to `gpt-6-astra`, prints auth status, and supports streamed output. |
| `claude` | No | Anthropic CLI workflow | Uses the `claude` CLI, supports capture and streaming, and enforces the no-haiku guardrail for `paw implement`. |
| `stub` | Test-only | Bats fixtures and prompt-body tests | Never makes real API calls; records argv/prompt into `$BATS_TEST_TMPDIR`. |

## External plugin backends

The installed launcher still discovers separate `paw-backend-<name>` executables on PATH;
it does not copy plugins into PREFIX. [Protocol](../../scripts/lib/backends/_iface.md).

## `claude` backend

Uses PAW_MODEL when set, otherwise its backend default. `paw implement` rejects
`PAW_MODEL=haiku`. `PAW_PROMPT_OPTIMIZE=1` enables an opt-in haiku planning pre-pass.

## External plugin backend example

See [External backend adapters](backend-plugins.md).

## `codex` backend

The `codex` backend wraps the [OpenAI Codex CLI](https://github.com/openai/codex).

**Prerequisite:** `codex` must be on `PATH` (install via Homebrew: `brew install codex`, or
`npm install -g @openai/codex`).

```bash
paw implement my-task
PAW_MODEL=gpt-6-astra paw implement my-task
```

Key properties:

- **Model from `PAW_MODEL`:** `codex exec` accepts `-m <model>`, so `PAW_MODEL`
  is forwarded as-is for every model-resolved subcommand. When unset, PAW defaults
  codex runs to `gpt-6-astra`.

- **ChatGPT vs API-key auth:** `paw` prints `codex login status` at launch so you
  can see which access path the CLI is using before a run starts.
  - ChatGPT login: `gpt-6-astra` is the default and is included in PAW's supported model list.
    PAW warns for models outside that list, including older `o*` / `gpt-4*` models.
  - OpenAI API key: named OpenAI model IDs are forwarded normally.

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

## Streaming output (`PAW_STREAM=1`)

By default `paw` captures backend output silently, then prints the final result after the run. Set `PAW_STREAM=1` to stream assistant text live in the terminal:

```bash
PAW_STREAM=1 paw implement my-task
```

Each content block starts on its own line (newline at `content_block_stop`, blank line at `message_stop`) so distinct thoughts do not concatenate into one paragraph. `claude` and `codex` both support this mode. `jq` is required on `PATH` for the JSON-streaming backends, and some external plugins may require it for their own capture or stream parsing path.
