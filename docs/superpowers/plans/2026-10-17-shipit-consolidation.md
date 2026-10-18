# shipit consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `shipit` absorbs `ship-ready-pr-loop`: Codex reviews every PR, a size gate sends only larger changes to greploop, and greploop gains the cost and safety rules.

**Architecture:** Markdown-only change to one skill (`skills/coding/shipit/SKILL.md`), plus deleting the other skill and its listings. No scripts, so "tests" are the frontmatter check, `bash -n` on each bash snippet, and read-only `gh` runs of the snippets.

**Tech Stack:** Markdown, bash, `gh`, `jq`, `codex` CLI 0.162.1.

**Spec:** `docs/superpowers/specs/2026-10-17-shipit-consolidation-design.md`

## Global Constraints

- `shipit` frontmatter: `description: >-`, `metadata.version: "0.2.0"`.
- Codex base: `gh pr view <PR> --json baseRefName`; never substitute `main`.
- Codex: at most 5 passes; fix only validated Critical and Major findings.
- Minor: 10 changed lines or fewer (added plus deleted), no added/deleted/renamed
  files, nothing in auth or permissions, security, secrets or config, data model or
  migrations, public API, dependencies or lockfiles, CI or build config.
- greploop: at most 5 passes; a reused pass counts; post-push wait 10 s × 2 min.
- GitHub only.
- Prose follows the user's style rule: short sentences, one idea each.
- Two commits, in this order: Task 1, then Task 2.

## Review Focus

- Local commits not pushed when the reuse check runs → it must stop and say push,
  not read the old head's score. (Task 1, Step 3.)
- A Greptile summary for an older commit → not reused. (Task 1, Step 3.)
- A branch with no PR → shipit asks, and does nothing else. (Task 2, Step 4.)
- A stacked PR whose base is not `main` → Codex and the size gate use that base.
  (Task 2, Step 4.)
- A pure rename, or a new one-line file → not minor. (Task 2, Step 4.)

---

### Task 1: greploop cost and safety rules

**Files:**
- Modify: `skills/coding/shipit/SKILL.md` ("Run greploop" section)

**Interfaces:**
- Produces: a subsection named `### Reuse a current review`, holding the reuse
  check snippet. Task 2's timeout rule links to it by that name.

- [ ] **Step 1: Add the rules to "Run greploop"**

Add, after the existing override bullets: run greploop as a skill, never as a
shell command; `### Reuse a current review` (spec 5b rules 1–5, the known limit,
the summary-not-check-run reason); one review per fix batch; at most 5 passes, a
reused pass counts; do not claim 5/5 unless the latest run shows it for
`HEAD_SHA`. Adapt the snippet from `ship-ready-pr-loop` step 7, with two changes:
the check-run read prints nothing when no check run exists (not an error), and
the summary grep is compared against `HEAD_SHA`.

- [ ] **Step 2: Syntax-check the snippet**

Run: extract the reuse snippet to a scratch file, substitute `<PR_NUMBER>` with
`52`, then `bash -n <file>`.
Expected: no output, exit 0.

- [ ] **Step 3: Run the snippet read-only against PR #52**

Run it from a checkout of `ab90d32f198fe91b41055a7bc013b79ae3b025cc` (detached,
in a scratch worktree), then again from this branch's `HEAD`.
Expected: at `ab90d32`, it prints `Greptile Review completed success`,
`greptile_confidence_score:5`, and a `Last reviewed commit` link ending in
`ab90d32f198fe91b41055a7bc013b79ae3b025cc`. On this branch, it prints
`Local HEAD is not the PR head` and reads nothing.

- [ ] **Step 4: Frontmatter check**

Run: `bash scripts/check-frontmatter.sh`
Expected: exit 0, no `shipit` error.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/shipit/SKILL.md
git commit -m "feat(shipit): reuse current Greptile reviews and cap review requests"
```

### Task 2: PR first, Codex loop, size gate; delete ship-ready-pr-loop

**Files:**
- Modify: `skills/coding/shipit/SKILL.md`
- Delete: `skills/coding/ship-ready-pr-loop/`
- Modify: `skills.sh.json` (drop `"ship-ready-pr-loop",` from "Coding")
- Modify: `README.md` (drop the `ship-ready-pr-loop` row; rewrite the `shipit` row)
- Modify: `AGENTS.md` ("What this repo is": `ship-ready-pr-loop` → `shipit` in the
  list of skills that run `codex`)
- Add: the spec and this plan

**Interfaces:**
- Consumes: `### Reuse a current review` from Task 1.

- [ ] **Step 1: Rewrite `shipit/SKILL.md`**

Follow spec sections 1–6, in this order of sections: inputs (PR at start, ask if
none, unattended → stop; GitHub only; `codex` prerequisite with the
`models_cache.json` note), implementation context (unchanged), `## Run the Codex
review`, `## Size gate`, minor path, `## Run greploop` (Greptile prerequisites
move here from the inputs section; add the timeout rule that runs the Task 1 check),
and the existing finding-validation, scope, escalation, verification, and boundary
sections. Report gains review path, Codex passes, Greptile passes, final score, and
reused passes. Status list gains "Ready to merge" only when no unresolved Greptile
threads remain on the minor path.

The Codex snippet:

```bash
BASE=$(gh pr view <PR_NUMBER> --json baseRefName -q .baseRefName)
git fetch origin "$BASE"
codex exec review --base "origin/$BASE" -o <scratch file> \
  "Review only the committed changes on this branch. Ignore uncommitted files."
```

The size gate snippet (decides the line and file rules; the risky-area rule is a
judgement on the file list):

```bash
git diff --numstat "origin/$BASE...HEAD" | awk '{n += $1 + $2} END {print n + 0}'
git diff --name-status -M "origin/$BASE...HEAD" | grep -v '^M' || true
```

Minor needs the first line ≤ 10 and the second command to print nothing.

Description: lead with what it does (Codex review of the PR, size gate, greploop for
larger changes, never merges). Triggers: "shipit", "ship this PR", "get this PR
ready to ship", "harden this change", "get this ready to ship". No pointer to
`ship-ready-pr-loop`. Version `"0.2.0"`.

- [ ] **Step 2: Delete the skill and its listings**

`git rm -r skills/coding/ship-ready-pr-loop`, then edit `skills.sh.json`,
`README.md`, `AGENTS.md`.

- [ ] **Step 3: Check for leftovers**

Run: `grep -rn 'ship-ready-pr-loop' --exclude-dir=.git --exclude-dir=docs --exclude-dir=.progress .`
Expected: no output.
Run: `jq . skills.sh.json >/dev/null && bash scripts/check-frontmatter.sh`
Expected: exit 0.

- [ ] **Step 4: Run the new snippets read-only**

- `bash -n` on the Codex and size-gate snippets: no output.
- On this branch before its PR exists: `gh pr view --json number` fails. This is
  the "no PR" case; the skill text must say "ask" for it.
- Size gate on this branch against `origin/main`: the count is above 10, and the
  name-status output lists `D` for the deleted `ship-ready-pr-loop/SKILL.md` and
  `A` for the spec and plan → extensive.
- Size gate on a pure rename (scratch worktree: `git mv README.md README2.md`,
  commit, diff against the previous commit): count 0, name-status prints `R100` →
  not minor.
- Stacked base: confirm by reading the skill text that both snippets use
  `origin/$BASE` and nothing names `main`.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/shipit/SKILL.md skills.sh.json README.md AGENTS.md \
  docs/superpowers/specs/2026-10-17-shipit-consolidation-design.md \
  docs/superpowers/plans/2026-10-17-shipit-consolidation.md
git commit -m "feat(shipit): Codex review every PR, size-gate Greptile; remove ship-ready-pr-loop"
```

### After both tasks

Merge `origin/main`, push the branch, open a ready-for-review PR, and record the
state in `.progress/`. Do not merge. Codex and greploop were not run live; say so
in the PR.
