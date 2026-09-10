# `scripts/lib/`

Shared bash helpers sourced by `scripts/paw`. Each file exports one or more functions and is designed to be independently testable.

## Helper files

| File | Exports | Purpose |
|------|---------|---------|
| [`crash_log.sh`](crash_log.sh) | crash classification and append helpers | Records backend failures to `.agent/<task>/crash.log` with structured metadata and a stderr tail. |
| [`task_store.sh`](task_store.sh) | task path, metadata, listing, and migration helpers | Resolves central task-store packages first, falls back to legacy `.agent/<task>/`, writes `metadata.gitconfig`, and copies legacy packages for `paw task-migrate`. |
| [`prompt_optimizer.sh`](prompt_optimizer.sh) | `prompt_optimize` | Optional `paw plan` pre-pass that rewrites the user prompt when `PAW_PROMPT_OPTIMIZE=1`; otherwise it passes the prompt through unchanged. |
| [`gui_server.py`](gui_server.py) | local HTTP server | Python standard-library server used by `paw gui` to render read-only task lists and Markdown detail pages from local files. |
| [`claude_invoke.sh`](claude_invoke.sh) | (thin shim) | Backwards-compatibility shim that sources `backends/claude.sh`. Callers that imported `claude_invoke.sh` directly continue to work. |

## `backends/` — pluggable AI backends

`scripts/paw` resolves a backend based on the `PAW_BACKEND` env var:

```bash
source "$LIB_DIR/backends/$PAW_BACKEND.sh"   # built-in, e.g. backends/codex.sh
paw-backend-$PAW_BACKEND                     # external executable plugin on PATH
```

Built-ins implement four required shell functions (`backend_run_capture`, `backend_run_stream`, `backend_parse_tokens`, `backend_parse_stream_tokens`) plus optional hooks such as `backend_display_model` and `backend_usage_banner`. External plugins expose the same runtime surface through an executable subcommand protocol. The full contract is defined in [`backends/_iface.md`](backends/_iface.md); the built-ins shipped today are listed in [`backends/README.md`](backends/README.md).
