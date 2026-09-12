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
retaining applicable filters and clearing task selection; native **Switch** is the fallback.
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

State/repo-text/completion filters start collapsed unless active. Task names open details;
secondary row tools include Edit and plan preview, then adjacent Archive/Delete.
Task metadata/path details expand separately; workflow warnings remain visible.
Dense tables scroll on narrow screens.

Eligible unfinished, unblocked, non-running selections expose **Archive selected / Delete selected**.
Delete adds confirmation; exact-path/all-or-nothing preflight precedes selected actions.
Native selected-action/Apply forms remain available. Concurrent implementation uses
CLI `paw implement-batch`; there is no GUI mass-implementation action.

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

See [cleanup guards and recovery](workflow.md#prototype-cleanup): launch acceptance,
planning success and cleanup success are separate outcomes.

## Logs and cancellation

GUI launches write immediate PID-bearing run metadata and stdout/stderr under `runs/`;
CLI backend metadata is separate. Archive is exempt from launch tracking so it cannot
block its own guard. Source/replacement views link the same operation within one repo.

On a task page, choose **Run History → Logs** to open that GUI operation's saved
stdout/stderr inline, then **Close logs** to return to history. These native links
preserve the task, repo and document tab and work without JavaScript. Running,
completed, failed and cancelled captures remain readable without a live PID.
New GUI records store exact relative stream filenames. Older records require a unique
command/task capture in the same recorded second and no competing or overlapping GUI
operation; missing timestamps, second-boundary differences and ambiguity show unavailable.
Old records are never rewritten. Backend-only rows explain that their output was not
saved; a GUI operation capture is not a backend transcript or the task's crash log.

Each selected stream reads at most the last 64 KiB, escapes text and replaces invalid
UTF-8. Empty, missing and unreadable streams have separate states, so one absent stream
does not hide the other. No history log bodies are read until selected. With JavaScript,
the selected run refreshes every 2.5 seconds while focus, disclosures and independent
scroll/follow positions stay in place. New runs do not replace the selection. Selecting
another run or closing navigates to a new page, isolating it from old pending polls;
a deleted selected record becomes unavailable instead of choosing another capture.

Stream requires a live PAW PID and matching GUI stdout/stderr log pair within its active
run window. Reads stay inside the resolved owner's `runs/` and return bounded tails.
Cancel verifies the PAW process, sends SIGTERM to its process group if leader (otherwise
the PID), waits briefly and records cancellation/exit status when performing terminal update.
Pidless running metadata blocks duplicate runs but grants neither Stream nor Cancel;
stale PIDs provide no safe signalling or live Stream authority.

stdout/stderr scroll independently. New output follows only a panel already at bottom;
reading older output stops following. Truncation may remove old content. Polling discovers
new/changed/finished runs without assigning unrelated logs the prior run's reading state.
Use `paw crash-log <task>` for backend failure records.

## Interaction limits and recovery

| Interaction | What persists / what to do |
|---|---|
| Routine polling | Eligible selections, disclosures, overlays, draft bytes, focus/caret and page/table/document scroll; changed task data refreshes. |
| Close, Escape or backdrop click | Dismisses overlay; inside clicks keep it open. Focus stays in the labelled dialog and returns to opener/navigation fallback on close; background scrolling is restored. |
| Dismiss/reopen an input dialog | Unsent input survives within the current page. Deliberate reload or repo navigation ends that lifetime. |
| Submit | Inline feedback reports **launch acceptance**, not subprocess completion. Check task/run state and logs. |
| Pending submission | Overlapping submissions blocked, submitted inputs frozen even after dismissal/reopening. Closing does not cancel work; eventual feedback appears for five seconds. |
| Error / uncertain network result | Drafts remain for deliberate retry. Check task state before retrying an uncertain launch. |
| Late preview/action response | A dismissed/replaced preview is not reopened; an old completion must not discard a newer dialog's draft. |
| JavaScript disabled | Native GET/POST forms and navigation remain available. Task/Stream/Home/Archived/PR links explicitly navigate. |

Top-of-page notices and errors have a **Dismiss message** button and clear after
five seconds with JavaScript enabled. Each result gets a fresh countdown; polling
does not extend it. Dismissal only clears the message, leaving actions, drafts,
workflow warnings and logs intact. PR links remain usable while displayed; use
**View PR** again after expiry. Without JavaScript, native feedback stays readable
and close controls are hidden. A suspended/background browser can delay timers;
five seconds is the foreground deadline, not a guarantee while suspended.

**Validation details** shows complete escaped evidence and its exact plan source, initially
collapsed on normal navigation. Dashboard evidence links open it; keyboard Space toggles
it; polling preserves the choice. Badge meanings and freshness/completeness limits belong
to [recorded evidence](testing.md#recorded-validation-in-the-gui).

**View PR** appears for saved PAW branch metadata with an existing local branch. On click,
`gh pr view <branch> --json url --jq .url` returns an inline PR link (local result page without
JavaScript). It does not publish or mutate remote/task state. Errors distinguish missing gh,
deleted branch, authentication/configuration, no PR, invalid URL and other CLI failures;
CLI diagnostics are escaped, with an exit-status fallback for empty output.

**Theme: System / Light / Dark** defaults to live OS appearance. Explicit choices persist
per browser origin; a different host/port has separate preferences. Storage failure still
allows current-page switching. Without JavaScript the system appearance applies.

The GUI does not expose arbitrary shell commands, filesystem previews or external binds.
For extras and PR/issue publication use the [CLI](cli-reference.md); for reproducible
interaction checks see the [browser harness](../../tests/README.md#recorded-validation-browser-regression).
