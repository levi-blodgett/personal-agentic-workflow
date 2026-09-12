# GUI logs and recovery

[Back to gui](gui.md).

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
| Routine polling | Disclosures, overlays, draft bytes, focus/caret and page/table/document scroll; changed task data refreshes. |
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

Dashboard Validation is one linked status: **Passed**, **Attention**, **Recorded**, or
**Unvalidated**. Activate it by keyboard or pointer to open the exact task’s evidence.
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
interaction checks see the [browser harness](../../tests/browser-testing.md#recorded-validation-browser-regression).
