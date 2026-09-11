# External backend installer template

Copy this [Makefile](Makefile) into your own plugin repository. It is standalone:
it does not call PAW checkout helpers. Supply your own executable adapter at
`scripts/paw-backend-acme`; this directory intentionally ships no provider adapter.
See the [author guide](../docs/backends.md#external-plugin-backend-example) and
[executable protocol](../../scripts/lib/backends/_iface.md).

The backend id is `acme`, its installed executable is `paw-backend-acme`, and the
selector is `PAW_BACKEND=acme`. Your Git repository/directory may have any name.
Use lowercase letters, digits, and hyphens as a naming convention; avoid built-in
ids `codex`, `claude`, and `stub` because built-ins take precedence.

```bash
cd "/path/to/your plugin repo"
# After writing your adapter:
chmod +x scripts/paw-backend-acme
make help
make install
export PATH="$HOME/bin:$PATH"
command -v paw-backend-acme
PAW_BACKEND=acme paw model -v
make uninstall
```

Install prerequisites are make, a POSIX shell, and standard macOS/Linux utilities.
The adapter owns its runtime/provider dependencies. Model discovery is a local
configuration smoke check; test capture/stream behavior in your plugin repository
before running against a real provider and approved PAW task.

Overrides (use the same values for uninstall):

```bash
make install PREFIX="$HOME/custom bin" PLUGIN_NAME=paw-backend-other PLUGIN_SOURCE="adapters/my adapter"
make uninstall PREFIX="$HOME/custom bin" PLUGIN_NAME=paw-backend-other PLUGIN_SOURCE="adapters/my adapter"
```

PREFIX is the executable directory, not a parent for another `bin`. PLUGIN_SOURCE
may be absolute or relative to the directory where make runs; use `make -C` when
elsewhere. The default source follows PLUGIN_NAME. Source paths are quoted and
made absolute; use the same source spelling for uninstall. Keep the source repo
in place. Update it and rerun install to upgrade; no files are copied and no
shell profiles or dependencies are modified. Persist the PATH export in your
shell startup file and confirm PATH ordering with `command -v`.

Only the exact link target installed for this source is owned. Reinstall is
idempotent; absent uninstall succeeds, and owned dangling links can be removed.
Files, directories, foreign links (including dangling ones), and links to
directories are refused. Inspect `ls -ld "$HOME/bin/paw-backend-acme"` and
`readlink "$HOME/bin/paw-backend-acme"` before manually removing a conflicting or
stale link, then reinstall. Uninstall before moving/deleting the source repo.
Ordinary shell operations do not provide locking against concurrent changes.

The [Bats suite](../../tests/plugin-install.bats) copies this actual Makefile to
an isolated external checkout and injects harmless executables to verify it.
