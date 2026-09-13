# Quality policy version 1

New plans target **A- or higher with no production blockers** at independent
post-implementation Review. A- means every scoped criterion is met, boundary
behavior is demonstrated, final evidence is credible, changes are maintainable,
and user-facing documentation is accurate. B+ may have material limitations such as an unverified retry/browser race; name
the limitation. Test counts are not grades.
Explicit older or inherited thresholds remain authoritative; A- is the improvement
target when a source requires a different threshold. Reconcile conflicting approved
gates before implementation. Implementation self-checks and final full validation
precede 100% / Review; independent grading and production sign-off follow it.

## Plan and evidence

Mark new plans `Quality policy version: 1`. Include an Acceptance Evidence table
with Criterion, Observable behavior, Planned check and Evidence destination.
Cover every user constraint and inherited blocker. Before handoff add actual named
check results and log/code identities, or a justified waiver; missing required
checks cannot be waived into success. Unversioned historical plans remain valid.

Select applicable risk families below; for each selected family name a concrete
counterexample and behavioral check. Give a specific not-applicable rationale for
excluded families. Keep the selection proportional to the task.

| Family | Counterexample to consider | Observable check |
|---|---|---|
| State transitions / entry-point parity | CLI refuses pending review but HTTP POST starts replacement | Assert both refuse and no replacement or cleanup starts |
| Producer-consumer identity | A same-named task in another repo supplies ownership | Assert repo/task identity and immutable content/index postconditions |
| Partial success / failure / retry | Child starts, then bookkeeping write fails | Inject post-spawn failure; assert ownership remains recoverable or child is reaped |
| Parsing invariants | Metadata or differently named rerun clears a failed check | Move indentation, names and metadata boundaries; preserve unresolved failures |
| Browser races / interaction | Delayed action completion discards a newer unsent draft | Delay the response; assert exact draft bytes, current dialog and affected controls |
| Scope / docs / evidence attribution | A source's passing log is claimed for replacement code | Match each criterion to current code identity and named evidence |

## Worked historical mechanisms (anonymized)

A parser saw `browser: failed`, then `lint: passed`; the browser failure must remain
active. Even `lint: passed (rerun)` cannot clear browser. Only an explicit successful
same-name browser rerun can supersede it. The retained validation classifier and
browser journeys exercise this rule; see [testing](testing.md).

A launcher spawned a child before its metadata write failed. A failing API result
alone is insufficient: the child must remain tracked by a recoverable owner or be
terminated and reaped. A focused repair plan should inject that exact failure;
this quality-policy change does not claim to repair historical launcher behavior.

An operator dismissed a submitted dialog, opened another and typed unsent input.
The first response must not close the new dialog or clear its bytes. Existing
browser helpers delay responses and assert the active dialog and its exact input;
presence of a generic button elsewhere on the page is not evidence.

For replacement planning retain each source blocker as finding → invariant →
acceptance/test, with attempt/code/source identities. Deduplicate overlapping
ancestors without losing origins. Non-blockers need planned, deferred-with-reason
or resolved-with-evidence dispositions. A higher overall grade does not resolve a
specific finding. A narrow repair can be preferable to another broad replacement;
missing evidence never authorizes reverting retained source work.

Prompt assertions prove routing, stub journeys prove workflow behavior, and manual
historical dry runs demonstrate retrospective coverage. None proves model
compliance or improved first-pass grades. Measure first independent reviews
prospectively, keeping replacements and interrupted attempts separate.
