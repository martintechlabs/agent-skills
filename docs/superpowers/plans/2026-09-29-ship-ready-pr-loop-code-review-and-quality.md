# Ship-Ready code-review-and-quality Mechanism Implementation Plan

**Goal:** Implement `docs/superpowers/specs/2026-09-29-ship-ready-pr-loop-code-review-and-quality-design.md` in `skills/coding/ship-ready-pr-loop/SKILL.md`.

**Architecture:** Documentation-only change to step 2, the PR description list, and the hard rules. No scripts, references, manifest entries, or README changes.

## Tasks

- [x] Step 2: replace mechanism 1 (OCR delegate) with `code-review-and-quality`, including scope, subagent preference, severity mapping, and non-interactive handling.
- [x] Step 2: when missing, ask the user, and on a yes install the skill globally; read the installed `SKILL.md` if the harness cannot load it before restart; fall through when declined, unattended, or the install fails.
- [x] Step 2: apply the same ask-then-install flow to mechanism 3 (Matt Pocock's `code-review`), without overwriting a different `code-review` skill.
- [x] Step 2: when mechanism 3 runs and `docs/agents/issue-tracker.md` is missing, offer the one-time `setup-matt-pocock-skills` setup (user-run), commit its output separately, and review anyway when declined.
- [x] Extend the transparency note and hard rule to cover `code-review-and-quality` run in the author's context.
- [x] Bump `metadata.version` to 0.5.0 (mechanism change).
- [x] Validate: `git diff --check`; no remaining OCR references in the skill.
