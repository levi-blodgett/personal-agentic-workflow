# Context minimization decision

Keep PAW's default free of a context-compression dependency. There is no PAW
workload benchmark demonstrating a need or net benefit. If measurement later
shows shell output dominates, RTK is the first optional trial candidate. This
decision authorizes no installation, hooks, proxy, settings changes or paid trial.

## Start with selective reads

Use `rg` to locate relevant files and symbols, then read bounded ranges. Keep
task state concise and reference complete raw logs by path, named check and
code/run identity. Preserve exact constraints, approval markers, source blockers
and failed-check history; a differently named passing check cannot clear a failure.
Reopen original evidence whenever a summary is insufficient.

These are local code observations, not measured savings:

- `cmd_compact` in [scripts/paw](../../scripts/paw) moves completed checkboxes and
  their complete records to linked files, reducing the active plan. All Markdown,
  including history, has a 150-physical-line AI authoring target; this is not a runtime gate or token limit.
  Explicitly linked validation is loaded for evidence classification; other history
  stays available through document links.
- `emit_prompt_context_notice` estimates launch text length divided by four
  against a warning threshold. It does not observe later file reads, tool output,
  injected instructions or live context occupancy.
- [prompt_optimize](../../scripts/lib/prompt_optimizer.sh) is off by default.
  `PAW_PROMPT_OPTIMIZE=1` adds a Claude/Haiku rewrite of the planning launch prompt,
  with fallback for unavailable CLI or empty output. Its preservation instruction
  is not a semantic check. Count that extra call when evaluating savings.
- The [backend interface](../../scripts/lib/backends/_iface.md) launches external
  CLIs and consumes their results. It has no in-session tool-output transformation
  hook. Filtering PAW's displayed output after execution cannot shrink context
  already consumed by the agent; reduction must happen in its environment or
  request path. This is an inference from the local interface.

## Candidate fit

Primary sources rechecked **2026-09-12**. Upstream claims describe mutable project
documentation, not verified PAW compatibility or a tested release. License labels
reflect upstream declarations; pin versions before evaluating.

| Option | Mechanism and setup | Assessment |
|---|---|---|
| No additional tool | Selective reads, scoped task documents and file-backed raw evidence | Use now. Avoid retrieving irrelevant material before considering compression. |
| [Caveman](https://github.com/JuliusBrussee/caveman) | A skill shortens response prose; the project also offers wrappers and a compression engine. [Licensing](https://github.com/JuliusBrussee/caveman/blob/main/LICENSING.md) distinguishes MIT skill/adoption surfaces from BSL-1.1 engine-linked runtime. | Skip adoption as PAW's prose policy. Output reduction does not establish whole-task savings; instruction overhead and human readability matter. Evaluate the engine separately if revisited. |
| [RTK](https://github.com/rtk-ai/rtk) | Apache-2.0 Rust CLI filters command output. Upstream documents a Claude shell hook and Codex AGENTS.md/RTK.md instructions; these are different adoption mechanisms. | First optional trial for shell-heavy tasks. Its advertised 60–90% reductions concern common command output, not PAW bills. Verify Bats/make/ShellCheck coverage, exit status and actual agent use. Keep complete raw logs independently of recovery features. |
| [Headroom](https://github.com/headroomlabs-ai/headroom) | Apache-2.0 library, proxy, wrapper and MCP paths compress request content. Wrapper setup can register Serena at user scope. | Defer until a request-payload bottleneck is measured. PAW does not own an in-process message list for its SDK. Routing, authentication, streaming, storage and recovery require a separate compatibility trial. |
| [Serena](https://github.com/oraios/serena) | MIT MCP toolkit retrieves symbols through language tooling, requiring server/language setup and agent use. | Consider per large target repository when code discovery dominates. Semantic retrieval may avoid irrelevant reads; dynamic shell relationships still need direct inspection. No global dependency. |
| [LLMLingua](https://github.com/microsoft/LLMLingua) | MIT Python/model-based learned prompt compression adds inference and transformed prompts. | Defer. Better fit for an application controlling request construction; published results do not validate preservation of PAW contracts. |

Headroom's [architecture](https://github.com/headroomlabs-ai/headroom/blob/main/docs/content/docs/architecture.mdx)
describes in-place live-zone compression without dropping/reordering messages and
opt-in source-code compression. Retaining message order does not prove every
removed detail was irrelevant. Original retrieval depends on retention, tool
availability and the agent recognizing the need to retrieve it.

## Gate for a separately approved trial

First measure a no-tool baseline. Shell bytes, response-prose tokens, live context
occupancy, provider input/output usage, cache usage and billed cost have different
denominators. Byte-based token estimates are not billing evidence. PAW's backend
usage fields differ; inspect provider field semantics and avoid double-counting
cached input. Include instructions/tool schemas, compression compute, extra reads,
retries and optimizer calls. Subscription token reductions need not save cash.

Use sanitized, identical repository/task snapshots for exploration, a small
implementation, long validation with a buried failure, and review with an earlier
unresolved failure. Include a larger target repo. Pin tool, backend/model, settings
and permissions; alternate baseline and explicit RTK commands for at least three
paired repeats per scenario. Evaluate hook/instruction adoption separately. Do
not stack compressors; keep the existing optimizer off in both arms.

Measure whole-task input/output/cache usage where exposed, shell bytes, elapsed
time, extra calls/retrievals, task outcomes, required findings and independent
first-review results. Mark unavailable telemetry unknown. Retain raw logs and
canonical task files/backend events unchanged. Include skipped tests, sparse
nonzero exits, quoted paths, pipelines, significant removed diff lines, negated
requirements, exact USER ANSWER markers and named rerun history as loss checks.

Proposed engineering gate: at least **15% median whole-task input-token reduction**
(or measured net API cost reduction), **no more than 10% median elapsed-time
regression**, zero lost constraints/failure evidence or missed outcomes in any
paired case, complete raw-log recovery and reversible setup. These are prospective
thresholds, not measured results or statistical proof. Failures or inconclusive
results retain the default. Independent Review targets A- or higher with no
production blockers; a savings percentage cannot compensate for lost evidence.

Only reconsider Headroom for measured non-shell payload pressure. A separate
approved trial must verify routing for the chosen CLI/auth mode, streaming and
tool-call identity, failed requests, proxy restart/retrieval loss, cache accounting
and isolation from other sessions. No trial or live compatibility test has run.
