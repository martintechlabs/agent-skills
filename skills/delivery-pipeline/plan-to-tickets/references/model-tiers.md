# Model tiers

`create-tickets.sh` never sees this file — it just applies whatever `model-tier:<tier>`
label the agent already chose. This table is what the agent (via SKILL.md's procedure)
crosses complexity × task-nature against to make that choice, and it's meant to be edited
per project: rename a tier, collapse two into one, or add one back, as long as every
ticket still ends up with exactly one `model-tier:*` label.

No specific model or vendor name ever appears on a ticket — only an abstract capability
tier. Mapping a tier to an actual model (which Claude/GPT/Gemini/open-weight model, which
provider) is a decision for whatever dispatches the ticket, made separately from this
skill, so a ticket never goes stale as a team's model roster changes.

## The four tiers

- **`lite`** — no code-reasoning required: docs, copy, config-only changes.
- **`efficient`** — cheap but code-capable: small, fully-specified, mechanical code changes.
- **`standard`** — everyday integration work: multi-file but well-understood, moderate judgment.
- **`flagship`** — the hardest judgment calls: architecture-adjacent decisions, ambiguous
  specs, cross-cutting design.

## Default cross table

All `small`/`medium` complexity × `text`/`mechanical`/`judgment` task-nature combinations.
The two marked *rare* are edge cases folded into a neighboring tier rather than earning a
distinct fifth tier:

| complexity | task nature | model tier             |
|-----------|-------------|--------------------------|
| small     | text        | `lite`                   |
| small     | mechanical  | `efficient`              |
| small     | judgment    | `standard` *(rare)*      |
| medium    | text        | `efficient` *(rare)*     |
| medium    | mechanical  | `standard`               |
| medium    | judgment    | `flagship`               |

## Why four

Four is the smallest set that distinguishes every complexity × task-nature combination
this skill actually produces (complexity is only `small`/`medium` — see SKILL.md's
"never emit a large/hard ticket" rule — crossed with three task natures). Fewer tiers
would collapse genuinely different capability requirements (a docs-only edit and a
judgment-heavy integration are not the same job); more would split hairs no real
complexity/nature combination in this skill's own output calls for.
