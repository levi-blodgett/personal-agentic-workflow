# Local GUI

The dashboard reads task Markdown and run metadata and launches local PAW actions.
It renders Markdown safely; task files and logs remain authoritative.

## Start and stop

```bash
paw gui                       # foreground: http://127.0.0.1:8765/
paw gui --port 0 --repo ..     # explicit ephemeral localhost port
paw gui start --all           # managed background, all central repos
paw gui restart               # reuse recorded options unless overridden
paw gui stop                  # graceful stop of the recorded PAW GUI
paw gui kill                  # force-stop fallback for that process
```

Only `127.0.0.1` and `localhost` binds are accepted. Foreground/start/restart default
to port 8765. Managed state is `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/active.gitconfig`:
PID, URL, host/port, repo, task home, all-repo mode, logs and start time.
Start refuses an active recorded process and removes stale metadata for a gone PID.
Restart validates/stops the recorded PAW process and reuses its options; without
active metadata it starts a new managed server. Stop/kill validate process identity.

## Pick a repo and plan

1. **Manage repos → Add repo path** registers an existing local Git repo and switches to it.
2. **Active repo** selects the scoped central-plus-legacy task list and destination for **New Plan**.
3. **New Plan** shows that destination. Enter a task name and prompt, then Plan or Queue.
4. **Queued Plans (count)** opens the same overlay: inspect full prompts, Edit, Plan or Remove.

`--repo` seeds the default repo. Registry: `${XDG_STATE_HOME:-$HOME/.local/state}/paw/gui/repos.gitconfig`.
Stale/non-Git paths are rejected. In `--all` mode, listings remain all central stores;
Active repo controls new Plan launches. With JavaScript it navigates on selection,
retaining applicable filters; native **Switch** is the fallback.
Task-specific actions use the task's own repo.

Queue entries stay local under the active repo store. Invalid names, blank prompts,
missing entries and duplicate queued names fail without changing saved prompts.
Editing never launches work. Triggering removes an entry after a successful start.

## Move a task forward

| Current state / control | Result |
|---|---|
| **Needs edit → Answer Questions** | Shows parseable pending questions; submitted answers go to `paw edit` extras for reconciliation, never directly into `plan.md`. |
| **Approve Implementation** | Opens safe `plan.md` preview with Edit, manual path and approval controls. Approval launches `paw implement` with no extras, including if unexpected extras were posted. |
| **Review** | Launches task-quality review with optional instructions. |
| **Reviewed → Use as Prototype** | Requires a complete current review; GUI disables A- or higher. See [CLI/GUI eligibility](workflow.md#review-completion-and-inherited-findings). |
| **Running → Stream / Cancel** | Shows bounded task-local logs and verified process cancellation when eligible. |
| **Archive / Archived → Unarchive** | Moves central packages out of active lists or restores them without overwriting an active package. Migrate legacy packages first. |
| **Delete** | Requires confirmation and exact listed/resolved path; unavailable for running tasks. Removes only that task package. |

Rows sort by recent run end/start, then task creation/migration, then legacy file mtime.
Stage/Next derives from task files: active runs, answer markers, source prototype status,
replacement planning state, review artifacts and completion. Failed/incomplete replacement
planning remains Needs edit; successful replacement lineage continues through approval/review.
Source prototype statuses offer archival guidance. `100%` / `Review.` awaits Review;
incomplete current reviews show Review incomplete → Run Review; complete current reviews show Reviewed.
Pending grades have no badge. [Grade formatting](workflow.md#implementation-handoff-and-review-grades)
describes supported/unknown values.

State/repo-text/completion filters start collapsed unless active. The filtered/total
count and **Filters active** indicator describe the current listing. **Clear filters**
removes all three filters while retaining Active repo and the server's all-repo mode.
No-match results offer that recovery; an empty repository points to **New Plan** for
the selected destination. Neither recovery launches work automatically.

Task names open details. **Next** keeps the current workflow action visible; **Tools**
is a native keyboard-accessible disclosure for **Preview plan**, Edit and available
PR/log links. Answer Questions appears once when it is the next action. Archive/Delete
remain separate and guarded. Task metadata/path details expand independently; workflow
warnings and validation remain visible. Polling preserves open Tools and focus.

Desktop retains the compact table. At narrower widths (1180px and below), the same
rows become labelled groups: Task, Repo, Stage, Next, metrics, Validation and Actions.
Primary information needs no horizontal panning; long documents/logs scroll locally.
The active document tab has an underline and programmatic current-page state.

The dashboard has eight columns, with 35% of its width reserved for Task and Repo.
Desktop Stage shows at most three compact lines: stage, a prototype/attention indicator when
applicable, and **Details / lineage**. Task detail retains full plan position, cleanup
messages, prototype origin and same-repo lineage links, including unavailable-source
explanations. Cleanup blocked/failed/incomplete conditions keep a visible attention label.
Individual Archive/Delete actions remain available with their existing guards.
Task selection and bulk Archive/Delete are retired; old `/actions/selected` POSTs return 404.
Concurrent implementation uses CLI `paw implement-batch`.

AI authors keep documentation concise. File length does not affect approval, launch
or completion; unresolved answers and other approval safeguards still apply.
A successful launch is still separate from completion.

## Replacement journey

Both home and detail collect optional prototype instructions and disclose replacement reuse.
The source remains the launch view; **Open replacement** and **Open source** link same-repo
packages as discovery finds them, or explain an archived/unavailable source.
Both views share the source GUI operation's Stream/Cancel when available. Duplicate starts
and replacement actions are blocked during planning.

Failure, cancellation or interruption preserves existing documents and failure logs.
Inspect task detail, then deliberately retry from the source or edit/reconcile the replacement;
there is no automatic retry. Successful planning enables approval even when cleanup is
blocked/unavailable; its warning remains visible. Preview and POST recheck readiness.
Completed replacement implementation proceeds to Review; reviews older than successful
replacement planning are stale (metadata mtime is the conservative fallback for old packages).
Archive the used source separately: the replacement remains active.

See [cleanup guards and recovery](review-workflow.md#prototype-cleanup): launch acceptance,
planning success and cleanup success are separate outcomes.

## Logs and cancellation

See [GUI logs and recovery](gui-recovery.md).

### Update PR under Next

Completed tasks with current complete A-/A/A+ reviews and no production blockers
offer **Update PR** and **Archive** under Next. View PR remains a lookup utility.
Update PR prepares a candidate with repository/head identity, body diff, exact
content, visual diagnostics and manual code-publication status. **Publish PR body**
is the separate remote action; success provides a validated link and keeps the task
active until Archive. Missing prerequisites leave Archive and repair guidance.
Native forms and JavaScript use identical server-side guards. No GET, polling or
completion event publishes. Changed body/review/remote state invalidates previews;
late previews cannot replace a newer dialog or its unsent text.
See [eligibility, contribution fields and recovery](publication-workflow.md#reviewed-task-pr-publication).
