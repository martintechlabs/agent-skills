# Ship-Ready Greptile Lessons Implementation Plan

**Goal:** Implement `docs/superpowers/specs/2026-09-29-ship-ready-pr-loop-greptile-lessons-design.md` in `skills/coding/ship-ready-pr-loop/SKILL.md`.

**Architecture:** Documentation-only change. No scripts, references, manifest entries, or README changes.

## Tasks

- [x] Step 1: read `docs/agents/greptile-lessons.md` when it exists.
- [x] Step 3: pass the entries to every mechanism as a checklist; a match is Major.
- [x] Step 7: confirm every entry was checked before requesting a Greptile review.
- [x] Step 8: record lessons in the Greptile fix-batch commit (format, dedupe, 40-entry cap).
- [x] Step 6, Hard Rules, Final Response Format: report lessons; forbid a lessons-only commit after 5/5.
- [x] Bump `metadata.version` to 0.6.0 (new loop behavior).
- [x] Validate: `git diff --check`.
