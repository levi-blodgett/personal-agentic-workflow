# Installation

Install prerequisites: Git to obtain/update the checkout, make, Bash, and standard
macOS/Linux tools (`mkdir`, `ln`, `readlink`, `rm`). Task workflows also use Git,
`jq`, and standard shell utilities. Install your selected backend CLI and its
own dependencies separately. Python 3 is needed for the optional GUI; GitHub
helpers require `gh`. Contributors need Bats and ShellCheck for `make check`.

```bash
git clone https://github.com/levi-blodgett/personal-agentic-workflow.git
cd personal-agentic-workflow
make install
export PATH="$HOME/bin:$PATH"
paw help
paw model -v
```

Add the PATH export once to your shell startup file (for example `~/.zshrc`),
then open a new shell or source that file. `make install` creates a symlink; it
does not install dependencies or edit shell configuration. `paw model` reports
configuration, so it does not prove your provider is installed/authenticated or
that a model call will succeed.

`PREFIX` is the executable directory itself, defaulting to `$HOME/bin`:

```bash
make install PREFIX="$HOME/local bin"
export PATH="$HOME/local bin:$PATH"
make uninstall PREFIX="$HOME/local bin"
```

Run make from the checkout (or use `make -C "/path/to/checkout"`). Keep the
checkout in place: installed `paw` loads helpers from it. To upgrade, update
that checkout with Git and rerun `make install` using the same PREFIX. Repeated
install/uninstall succeeds; uninstall removes only the exact absolute link
created for this checkout, including when its launcher source has disappeared.

Files, directories, and foreign links are refused without replacement. On a
collision or after moving the checkout, inspect `ls -ld "$HOME/bin/paw"` and
`readlink "$HOME/bin/paw"` (substitute your PREFIX). Remove the old link manually
only after confirming it is safe, then install from the intended checkout.
Equivalent relative/chained links can launch PAW, but the installer deliberately
requires its own exact link target for ownership. Uninstall before deleting a
checkout; shell recipes do not protect against concurrent filesystem changes.

For separately maintained backends, follow the [plugin author guide](backends.md#external-plugin-backend-example)
and [copyable installer example](../backend-plugin/README.md).

### Optional zsh Completion

```bash
# Enable zsh subcommand completion
autoload -U compinit && compinit
source <(paw completion zsh)   # current shell
paw completion zsh >> ~/.zshrc # future shells
```


Completion is zsh-only and completes top-level subcommands; Bash and argument completion are not included.

Next: [first task](../../README.md#quick-start), [backend selection](backends.md), [GUI](gui.md).
