# `ship-ready-pr-loop` code-review-and-quality Mechanism Design

## Goal

Replace the open-code-review (OCR) delegate as the first review mechanism with the `code-review-and-quality` skill from `addyosmani/agent-skills`.

## Behavior

- Mechanism 1 becomes `code-review-and-quality` when it is installed. OCR is removed; no fallback to it remains.
- Missing skill: ask the user first. On a yes, install it globally (`npx -y skills add addyosmani/agent-skills --skill code-review-and-quality -g -y`) so the target repo stays clean. If the harness cannot load it before restart, read the installed `SKILL.md` and follow it. If the user declines, no user is available (unattended run), or the install fails, fall through to Codex.
- Scope: the complete change against the intended PR base (same base resolution as mechanism 2), including uncommitted and untracked files, plus the spec or issue path when one exists.
- Run it in a fresh subagent when the harness has one. The skill runs inside the host agent, so in the author's own context it is not an independent review and must carry a transparency note, like native self-review.
- Severity mapping: `Critical:` → Critical; unprefixed (required) → Major; `Optional:`/`Consider:`/`Nit:`/`FYI` → Minor or lower. Its presumptive blockers are Minor unless they hide a real defect.
- Its interactive prompts (confirm dead-code deletion, split oversized changes) become findings for triage; they do not pause the loop.

### Matt Pocock's `code-review` (mechanism 3)

Same install flow when it is missing and mechanism 3 is reached: ask first, install globally on a yes, read the installed `SKILL.md` if the harness cannot load it before restart, and fall through to native self-review when declined, unattended, or the install fails. Never overwrite a different skill already installed as `code-review`.

## Out of scope

- Reordering mechanisms 2–4.
- Vendoring the skill into this repo.
