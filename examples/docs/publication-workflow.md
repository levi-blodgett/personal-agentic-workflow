# Handoff and publication

[Back to workflow](workflow.md).

## Troubleshooting Crashes

Run `paw crash-log <task>` and inspect the classification and stderr.
[CLI diagnostics](cli-reference.md#crash-log-paw-crash-log) lists codes and telemetry.
On context-pressure warnings, keep updates lean, archive stale detail with
`paw compact <task>` and split growing work. Resume interrupted approved work
with `paw implement <task>` after checking state.

## Recommended Review Before Merging

```bash
paw pr-update my-task           # inspect candidate; printed --publish TOKEN updates/creates
paw pr-submit my-task           # same preview gates, create-only
paw pr-review 123               # first: save draft; later: submit saved review
paw pr-address-comments 123     # plan only
paw implement 123-review        # after approval
paw to-issues my-task           # review drafts before --publish
```

### Before Committing

Inspect `git status`, `git diff`, `git diff --cached` and the resolved contract/plan.
Confirm scope matches approval, durable docs are current, named final evidence is
recorded, completed checkboxes have Progress, local notes remain untracked and the
branch PR body reflects the final change. Record scope deferrals or contract conflicts.
Run `paw lint <resolved-task-dir>`. The human owns commits.

### Before Merging

Review the draft PR and any follow-up fixes, take ownership of the complete diff,
then request reviewers/mark ready. Independent grading and production sign-off
follow implementation; a completion percentage is not sign-off.

### Reviewed task PR publication

After implementation and final validation, independent Review must be complete,
current, A- or higher, and explicitly record `None` for production blockers.
Publication requires completed attempt and matching reviewed-code evidence; rerun
legacy reviews without those identities. Pending answers, unchecked work, active
runs and newer implement/diagnose/prototype records block publication.

Write `## PR Contribution` in the task plan with one concrete `- Outcome:`,
`- Validation:`, `- Risks:` and `- Visual:` field. Attribute only this task's reviewed
outcome and named checks. `Visual` explains why the branch visual covers this scope;
refresh the evidence when scope changes. Put shared evidence in the branch body's
`## Visual Evidence` section: explanatory prose followed by a nonempty Mermaid
fence or screenshot image. Prefer Mermaid for nonvisual changes and screenshots
for visible UI. Images must use HTTPS or exist in the published head at their
repository-relative path. Local absolute paths, badges and example fences fail.
Review must assess relevance and rendering; structural checks cannot establish them.
Refresh currently appends changed shared evidence while preserving existing human
and legacy visuals. Repeated refresh can accumulate obsolete diagrams; inspect the
exact candidate diff. Automatic removal needs a separately designed PAW-owned visual
region and adoption policy, and is deferred.

`paw pr-update TASK` prepares an exact candidate and diff without publishing.
Inspect it, then run the printed `paw pr-update TASK --publish TOKEN` command.
An existing exact repository/head PR receives only a body edit; confirmed absence
creates a draft. `paw pr-submit` uses the same preview/gates but remains create-only.
Preview tokens and recovery receipts bind the operation (`update-or-create` or
`create-only`). Publish and retry with the same command that prepared the token;
cross-command, missing-mode and incompatible receipt requests refuse before writes.
Old previews without an operation must be prepared again. A PR appearing after a
create-only preview invalidates it; use a fresh pr-update preview to edit that PR.
Configure the saved branch's exact remote tracking first. The remote head must
exist and match local HEAD. Commit/push manually when it does not. Uncommitted
changes are explicitly identified as absent from the PR. PAW never stages, commits,
pushes, merges or changes branches during publication.

Task contributions have managed repo/task birth identities. Repeating one replaces
it once; other contributions and human remote text remain. Unmarked local prose
stays local, excluded from publication; the preview shows this adoption choice.
One task owns structural PR Tracking; later contributors retain separate result
records. Archived task names do not establish ownership for a new package.

PAW serializes publication per repository/branch, snapshots local body/review/code,
and rereads remote state before mutation. Changed previews require preparation
again. Candidate bytes and successful remote receipts are retained under the Git
common directory's `paw-publication/`; task previews/results stay in its package.
If remote success precedes local bookkeeping failure, inspect the reported PR and
retry the token with its original command. Recovery verifies operation, token, remote
head, PR URL and exact candidate body before local bookkeeping. If state changed,
prepare anew with pr-update to resolve the existing PR without
creating another. Do not overwrite newer human content to recover. External GitHub
editors do not share PAW's lock, and GitHub offers no body compare-and-swap: an edit
in the final read/write gap remains possible and requires human reconciliation.
