# Task storage and identity

[Back to workflow](workflow.md).

## Architecture of Workflow

```text
${PAW_TASK_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/paw/tasks}/
  <repo-slug>/
    <task>/
      contract.md          request, exact constraints, context and assumptions
      plan.md              approved scope, checklist, progress and evidence
      metadata.gitconfig   repo/worktree/branch provenance and timestamps
      runs/*.gitconfig     observed command/backend/model/status/exit metadata
    v2-<prefix>-<sha256>-pr.md  seeded when the repo has a PR template
```

Central tasks resolve before legacy `.agent/<task>/` packages. Legacy `pr.md`
remains a fallback when no branch body or ambiguous historical file exists. Branch
bodies use a bounded readable prefix and the full SHA-256 of the exact branch name;
linked worktrees share the main repository’s body store. Saved task assignments
determine the branch; invalid or detached assignments require reconciliation.

An old `<branch-name-safe>-pr.md` is never automatically adopted. If PAW reports
one, verify its intended branch and content, copy it to the reported canonical
path **only if absent**, and retain the original. An existing canonical body wins;
retries never overwrite it. Reconcile differing old/new content explicitly.

PR review first selects a unique task-owned `## PR Tracking` record in `plan.md`
or legacy `pr.md`, or metadata in a PR review draft. Shared branch tracking is a
fallback only for one eligible task. If several tasks own or share the PR, reconcile
tracking on the intended task before retrying; prose and fenced examples are not
ownership records. GUI View PR still opens the remote PR for the saved live branch.

Run `paw setup` to exclude `.agent/` through `.git/info/exclude`;
local task docs and metadata are never committed. Migration explicitly copies
legacy packages for the selected repos:

```bash
paw task-migrate               # current repo
paw task-migrate ../api ../web
PAW_BROWSE_PAGER=cat paw browse my-task
paw archive my-task           # central tasks; migrate legacy first
```

Archive moves a package under its repo store's `.archive/`, outside active CLI/GUI
lists. [GUI Archived/Unarchive](gui.md#move-a-task-forward) restores without overwriting.
Markdown remains authoritative; metadata supplies identity and observational run state.
