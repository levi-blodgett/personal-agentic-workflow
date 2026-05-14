# prompts/

This directory contains the master workflow contract loaded by every agent-facing `paw` run.

| File                      | Purpose                                                  |
|---------------------------|----------------------------------------------------------|
| `prompt_instructions.md`  | Canonical PAW agent contract (plan, implement, review, …) |

Do not treat the files in this directory as normal repo prose. `prompts/prompt_instructions.md` is the operational source of truth for plan/edit/implement/review-feedback behavior, and other docs should align to it rather than paraphrase it loosely. For the workflow narrative around that contract, see [`examples/docs/workflow.md`](../examples/docs/workflow.md).
