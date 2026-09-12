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

### Name and install your adapter

Use backend id `acme`, executable `paw-backend-acme`, and selector
`PAW_BACKEND=acme`. The repository/directory name is independent. Lowercase
letters, digits, and hyphens are a convention, not an enforced backend-id grammar.
Avoid `codex`, `claude`, and `stub`: built-ins take precedence over PATH plugins.
Otherwise PAW selects the first executable `paw-backend-acme` found on PATH.

Copy the [standalone Makefile](../backend-plugin/Makefile) into your plugin repo
and follow its [README](../backend-plugin/README.md). Supply your own adapter at
`scripts/paw-backend-acme`; the test fixture is not a production backend.

```bash
cd "/path/to/acme integration"
chmod +x scripts/paw-backend-acme
make install
export PATH="$HOME/bin:$PATH"
command -v paw-backend-acme
PAW_BACKEND=acme paw model -v
# After provider setup and compatibility tests, in your target repo:
PAW_BACKEND=acme paw implement my-approved-task
# Back in the plugin repo:
make uninstall
```

Persist PATH in your shell startup file. The installer uses HOME/bin by default;
PREFIX overrides the executable directory directly. Keep the source checkout
available and use the same name/source/PREFIX for uninstall. Read the example’s
collision and relocation recovery steps before removing any existing link.

### Resolve resources from the source

A symlinked adapter must resolve its own source before reading sibling resources;
its current working directory is normally the user's target repo. For a Bash
adapter, place this after the shebang (absolute, relative, and chained links are
supported; cyclic/broken links must be repaired):

```bash
source_path="${BASH_SOURCE[0]}"
while [ -L "$source_path" ]; do
  source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
  target="$(readlink "$source_path")"
  case "$target" in
    /*) source_path="$target" ;;
    *) source_path="$source_dir/$target" ;;
  esac
done
source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
# Read resources under "$source_dir", not "$PWD".
```

### Implement and validate the protocol

The four required subcommands are `run-capture`, `run-stream`, `parse-tokens`,
and `parse-stream-tokens`; `display-model` and `usage-banner` are optional.
Use the [interface contract](../../scripts/lib/backends/_iface.md) for exact
arguments, output and fallback behavior. Translate PAW-generated tool arguments
into your provider's CLI/API vocabulary. Keep prompt text and paths as intact
arguments; never eval them. Install and document your provider dependencies and
credentials in your own repo.

Capture writes JSON with a `.result` string for PAW to display. Streaming writes
raw events to the output file and readable text to stdout. Both return the
provider exit status. Token parsers report an integer or `unknown`, including
for absent/malformed files; optional field selectors are described in the
interface. Model hooks may honor PAW_MODEL or resolve their own model.

`paw model -v` checks discovery/model reporting only. Your repo must test actual
capture and stream calls, provider failures, prompt/path quoting, token parsing,
and optional-hook fallback. PAW's hermetic tests exercise the copied installer
and generic seam with harmless adapters; they do not certify a live provider.

### Troubleshooting

- Missing backend: check `command -v paw-backend-acme`, PATH order, executable
  mode (`chmod +x`), and the symlink target. Restart/source your shell after PATH
  changes. A later PATH executable may be shadowed by an earlier one.
- Stale launcher/plugin: inspect `ls -ld` and `readlink`; remove only a confirmed
  obsolete link and reinstall from the intended checkout.
- Unexpected backend: built-in names always win. Choose a distinct plugin id.
- Startup failure: PAW selects the backend before dispatching even help/model;
  an invalid PAW_BACKEND can prevent those commands. Correct/unset the selector.
- Model reporting succeeds but execution fails: verify the adapter's dependencies,
  provider configuration and authentication, and capture/stream compatibility.
- Unexpected resources: PAW_HOME selects PAW templates/instructions and paths
  passed to the backend. Built-ins/helpers still load from the resolved launcher
  checkout; plugin sibling resources belong to the plugin's resolved source.

### Choose a plugin vs a built-in

Keep private tooling, separate release ownership and provider-specific compatibility
in a plugin repo. Built-ins belong to PAW's versioned/tested supported surface.

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
