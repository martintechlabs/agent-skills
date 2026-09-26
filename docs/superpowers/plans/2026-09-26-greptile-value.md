# Greptile Value Implementation Plan

> **For agentic workers:** Use executing-plans to implement inline. Use fresh agents for behavioral validation and final review.

**Goal:** Deliver a reusable periodic history scan that recommends review/test upgrades and measures Greptile's extra value where earlier evidence permits.

**Architecture:** Markdown instructions plus a ledger template. The agent assesses
code and evidence; there is no collector, classifier runtime or analytics service.

**Tech Stack:** Markdown, Git and read-only GitHub CLI evidence.

**Spec:** `docs/superpowers/specs/2026-09-26-greptile-value-design.md`

## Global constraints

- Name `greptile-value`, category `coding`, initial version `0.1.0`.
- Existing review evidence only; no paid review requests or GitHub comments.
- Preserve `ship-ready-pr-loop` and its acceptance gate.
- Save durable local records; keep implementation checkpoints in ignored `.progress/`.
- No runtime dependencies; unknown evidence and costs stay unknown.

## Review focus

- A final clean report must not erase earlier matching findings.
- A moved inline comment must not change the original finding's code revision.
- Missing review surfaces or unresolved findings must not become zero-yield PRs.
- Dirty code, partial baseline scope and later regressions must not inflate misses.
- Repeated comments are not independent defects or repeated cross-PR patterns.

## Task 1: Implement the skill and discovery entries

Files: create `skills/coding/greptile-value/SKILL.md`,
`references/ledger.md`, `tests/scenarios.md`; update `README.md` and `skills.sh.json`.
Input: preserved review artifacts, commits and code. Output: ledger and concise report.

- [ ] Record a no-skill control on mixed attribution before writing the skill.
- [ ] Write reusable behavioral prompts and expected outcomes, including review-focus cases.
- [ ] Write the minimal workflow and ledger fields from the spec.
- [ ] Add Coding discovery entries.
- [ ] Run fresh-agent forward tests using raw evidence and the skill, withholding the rubric.
- [ ] Correct demonstrated gaps and rerun affected scenarios.
- [ ] Incorporate the clarified periodic-history workflow: ten most recently updated merged PRs,
  overlapping-run deduplication, existing-check inspection, and concrete upgrades
  even when earlier reviewer attribution is unknown.

## Task 2: Validate and prepare the branch

Files: local evidence and results under `.progress/review-value/`; no production-code edits.
Input: Task 1 skill and historical PR #39. Output: tested, reviewable branch.

- [ ] Apply the workflow to PR #39 using all existing GitHub review surfaces and original code.
- [ ] Save the result, evidence limits and command output in `.progress/`.
- [ ] Run skill-creator `quick_validate.py`, parse the manifest, check links and run `git diff --check`.
- [ ] Fetch and merge `origin/main`; do not import the originating worktree's branch.
- [ ] Obtain an independent whole-change review, fix material issues and rerun affected checks.
- [ ] Commit and push green changes to this branch; create one ready PR if permitted.
- [ ] Report the skill, validation output and remaining limits. Do not run Greploop or merge.
