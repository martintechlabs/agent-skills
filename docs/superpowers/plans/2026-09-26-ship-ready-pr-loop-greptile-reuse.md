# Ship-Ready Greptile Review Reuse Implementation Plan

**Goal:** Implement `docs/superpowers/specs/2026-09-26-ship-ready-pr-loop-greptile-reuse-design.md` in `skills/coding/ship-ready-pr-loop/SKILL.md`.

**Architecture:** Documentation-only change to steps 7 and 8. No scripts, references, manifest entries, or README changes.

## Tasks

- [x] Step 7: add the head-commit reuse check (push-parity check, completed check run or review on `headRefOid`, reuse instead of trigger) and state that a reuse pass counts toward the limit.
- [x] Step 8: add the one-trigger-per-fix-batch rule, covering manual-only and review-on-push repositories.
- [x] Bump `metadata.version` to 0.4.0 (new loop behavior).
- [x] Validate: `git diff --check`; confirm the `gh api` jq filters run against a real PR (read-only).
- [x] Run a review pass and Greploop on the PR.
