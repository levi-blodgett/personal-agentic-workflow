# CLI diagnostics

[Back to cli-reference](cli-reference.md).

### Crash log (`paw crash-log`)

When `paw` invokes the backend and it exits non-zero, a crash record is appended to `<task>/crash.log`. Silent failures (exit 0 but JSON contains an `.error` field) are also recorded.

```text
===
timestamp:      YYYY-MM-DD HH:MM TZ
exit_code:      <n>
api_code:       <HTTP status code, e.g. 429|503|none>
model:          <model>
subcommand:     <plan|implement|pr-address-comments|...>
classification: <see table below>
input_tokens:   <n|unknown>
stderr:
<last 20 lines of backend stderr>
---
```

Read the crash log with:

```bash
paw crash-log <task-name>
```

#### Classification codes

When a JSON error type is available, it is prepended to the classification (e.g. `content_filter: content_filter`). Classifications in priority order:

| Classification | Trigger |
|---|---|
| `content_filter` | stderr/JSON contains: `content_filter`, `content policy`, `harmful content`, `moderation`, `flagged`, `output blocked` |
| `too_many_requests` | stderr contains: `429`, `too many requests`, `request.*limit` |
| `rate limit` | stderr contains: `rate limit` |
| `overloaded` | stderr/JSON contains: `overloaded`, `service unavailable`, `503` |
| `context overflow` | stderr contains: `context window`, `context length`, `too long`, `maximum context` |
| `timeout` | stderr contains: `timeout`, `timed out`, `deadline exceeded` |
| `OOM/killed` | stderr contains: `out of memory`, `oom`, `killed`, `signal 9` |
| `API error` | stderr contains: `api error`, `internal server error`, `500`, `502` |
| `interrupted (SIGINT)` | exit code 130 |
| `terminated (SIGTERM)` | exit code 143 |
| `unknown (exit N)` | none of the above |

For quota/rate limits, overload, timeout or 5xx errors, inspect provider status and retry
when appropriate. Lower PAW_MAX_TURNS/split long tasks for resource pressure; compact
context overflow. Inspect/rephrase policy-sensitive content for content_filter. Resume
SIGINT/SIGTERM interruptions with approved `paw implement <task>`; inspect stderr for
unknown failures. `paw crash-log` prints “no crashes recorded” and exits zero when absent.

#### Always-on exit status line

After every `run_claude()` call — success or failure — `paw` prints a colored status line to stderr:

```text
paw: exit 0               # green — success
paw: exit 1 [429]         # red — non-zero exit, API code shown
paw: exit 1 [rate limit]  # red — non-zero exit, classification shown when no API code
```

Set `NO_COLOR` or `PAW_NO_COLOR` to any non-empty value to suppress ANSI codes (plain text only).

**Context-pressure telemetry:** before each backend call, `paw` estimates the prompt token count from its byte length (÷ 4). To avoid noisy per-turn output, it only prints a notice once the estimate reaches meaningful pressure bands relative to `PAW_PROMPT_WARN_TOKENS` (default: `150000`):

- `>= 75%` of the threshold: warn that context pressure is building and recommend leaner updates, `paw compact <task>`, archiving stale detail, and splitting the task if growth continues.
- `>= 100%` of the threshold: escalate to a context-overflow-risk warning with the same concrete next steps before retrying.

```text
warn: estimated prompt size ~N tokens (80% of warning threshold: 150000); context pressure is building. Keep updates lean, archive stale detail, use `paw compact <task>`, and split the task if growth continues.
```

The task package and prompt contract are expected to follow the same pattern: notify only at meaningful pressure changes, keep those notices short, and prefer task-doc references over re-pasting large resolved context.

### GH PR comments (`scripts/gh-pr-comments.sh`)

Lists all unresolved PR feedback, grouped into three labelled sections:

```bash
scripts/gh-pr-comments.sh <pr-number> [--repo OWNER/REPO]
```

Output format:

```text
INLINE path/to/file.ts:42
  @author: comment body

REVIEW SUMMARY @author (REQUEST_CHANGES)
  review body

PR COMMENT @author
  comment body
```

- **INLINE** — unresolved review threads (resolved threads are filtered out).
- **REVIEW SUMMARY** — review-level bodies (e.g. `REQUEST_CHANGES`); reviews with an empty body or `APPROVED` state and empty body are filtered.
- **PR COMMENT** — top-level issue comments on the PR.

Pagination is followed for all three collections. Set `PAW_PR_PAGE_LIMIT` (default `10`) to cap pages per collection; a warning is printed to stderr if the cap is hit.

`paw pr-address-comments` invokes this script on the shell side before the AI call,
writing output to `<resolved-number-review>/comments.md`. The first pass of
`paw pr-review` also uses this script when it builds `<resolved-task>/review.md`.
No dependency on a user-local `gh_pr_comments` shell function. Requires `gh`
(authenticated) and `jq`.
