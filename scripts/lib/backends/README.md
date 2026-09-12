# Built-in backends

| Module | Selector | Role |
|---|---|---|
| [codex.sh](codex.sh) | `codex` (default) | Codex CLI capture/stream, auth banner and usage parsing |
| [claude.sh](claude.sh) | `claude` | Claude CLI capture/stream and session token aggregation |
| [stub.sh](stub.sh) | `stub` | Test-only argv/prompt capture under BATS_TEST_TMPDIR |

## Adding a built-in backend

Implement the four required functions in [_iface.md](_iface.md), plus model/banner
hooks as needed; add this table row and focused tests. `PAW_BACKEND=<name>` selects it
without dispatcher changes. Built-ins/helpers load from the resolved launcher checkout;
PAW_HOME changes templates/instructions and passed resource paths.

## External plugins

For separate ownership, install `paw-backend-<name>` on PATH. Built-ins take precedence.
Keep provider-specific compatibility tests with the plugin; PAW tests the shared seam.
Use the [author guide](../../../examples/docs/backends.md#external-plugin-backend-example)
and [standalone installer](../../../examples/backend-plugin/README.md).
