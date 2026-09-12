# External backend adapters

[Back to backends](backends.md).

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
