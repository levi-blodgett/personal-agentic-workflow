# `scripts/lib/`

| Module | Boundary |
|---|---|
| [task_store.sh](task_store.sh) | Central-first task lookup, legacy fallback, provenance, branch PR paths, migration/archive and run state |
| [gui_lifecycle.sh](gui_lifecycle.sh) | Managed GUI state and verified recorded-process start/stop/restart/kill |
| [gui_server.py](gui_server.py) | stdlib HTTP, safe Markdown, action guards, recorded-evidence parser, polling and themes |
| [pr_publication.py](pr_publication.py) | Shared PR eligibility, visual/body preparation, preview snapshots, branch locks and gh publication/recovery |
| [review_record.py](review_record.py) | Shared CLI/GUI review completeness, template rendering, code/attempt identity and exact history |
| [review_lineage.py](review_lineage.py) | Read-only same-repo active/archived/legacy ancestry resolution |
| [quality_plan.py](quality_plan.py) | Opt-in v1 planned-evidence lint; no execution attestation |
| [crash_log.sh](crash_log.sh) | Failure classification and task-local crash records |
| [prompt_optimizer.sh](prompt_optimizer.sh) | Opt-in planning pre-pass |
| [claude_invoke.sh](claude_invoke.sh) | Compatibility shim for the Claude backend |
| [backends](backends/README.md) | Built-in modules; [_iface.md](backends/_iface.md) owns exact protocol |

GUI GET requests share discovery and Git-compatible metadata within a context-local
snapshot; POST guards read live state. Polling reconciles task/run identity and owns
only connected log pollers. Dialogs retain drafts/focus and invalidate late previews;
submissions capture FormData before freezing controls. Named STYLE tokens own presentation.

Source/replacement views prefer the linked source GUI run for Stream/Cancel. Immediate
GUI PID metadata and terminal reaping complement CLI run records;
`paw.prototype-replacement-name` bridges early discovery, with lineage fallback for old runs.
Archive skips launch tracking to avoid blocking itself.

Operator guarantees: [GUI](../../examples/docs/gui.md),
[review/lineage](../../examples/docs/workflow.md#review-completion-and-inherited-findings),
[evidence grammar](../../examples/docs/testing.md#recorded-validation-in-the-gui).

Branch PR helpers keep exact-byte SHA-256 identity separate from historical-file
resolution. They share the main repository’s body store across linked worktrees,
validate saved branch/repository assignments, and refuse ambiguous old files before
seeding or submission. See [migration recovery](../../examples/docs/workflow.md#architecture-of-workflow).

`review_record.begin(..., template=None)` defaults to the checkout review resource;
CLI `begin --template PATH` supplies the PAW_HOME selection. Seed validation is separate
from historical completion parsing. Render and validate before archiving or changing
attempt state, then retain archive-before-replacement and atomic final review replacement.

`markdown_budget.py` owns physical counting and scoped file enumeration.
`markdown_documents.py` writes linked history and reads explicit validation
references without loading unrelated history. Counting helpers support AI authoring;
CLI, GUI, lint and CI do not enforce length. Missing linked validation remains visible as a failure.
