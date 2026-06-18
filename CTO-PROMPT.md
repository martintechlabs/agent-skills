# CTO Toolkit — Reusable Repo-Review Prompt

A copy-paste prompt that runs a fractional-CTO style review of **any** repository using
the skills in this repo, and produces a shareable plain-language report. Edit the
**Parameters** block, paste the whole thing to Claude Code (run from this repo so the
CTO toolkit skills are available), and let it work.

The toolkit skills it drives: `codebase-triage`, `delivery-health`,
`weekly-risk-review`, `codebase-audit`, `bug-class-audit`, `tech-due-diligence`,
`evaluation-trend` (under `skills/`).

---

## Parameters (edit these, then send everything below)

- **REPO:** `<github owner/repo OR a local path>`
- **ACCESS:** `<public | private>` — if private, confirm `gh` is authorized for it
- **DEPTH:** `<Quick | Standard | Deep>` (default: Standard)
- **ADD-ONS:** `<none | bug-class-audit | tech-due-diligence | both>`
  - if `tech-due-diligence`, give the **deal thesis** (e.g. "acquisition, expected 5× users in 24 months") or say "assume one"
- **OUTPUT DIR:** `<e.g. /tmp or ~/Desktop>` (default: `/tmp`)
- **READ-ONLY:** `yes` (default — never write, push, commit, or branch on the target repo)

---

## Task

Act as a fractional/interim CTO evaluating **REPO**. Use the CTO toolkit skills in
this repository (read each skill's `SKILL.md` and follow it). Produce two artifacts in
**OUTPUT DIR**: a detailed running file and a shareable plain-language report.

### Ground rules (do all of these)
1. **Strictly read-only on the target repo.** Clone it to a temp dir with **full
   history** (`gh repo clone …` — no `--depth`, several skills need real git history).
   Never write, edit, commit, push, or branch on it. Instruct every sub-agent the same.
2. **Run skills as parallel sub-agents.** They're independent — dispatch one per skill
   (or per dimension) in a single batch so they run concurrently, then synthesize.
3. **For `codebase-audit` on a large repo (>~150 source files), fan out** — one
   sub-agent per dimension group (e.g. Security+Robustness, Data Modeling, Dependency
   Currency [does live web research], DDD+Events, Performance, Cleanliness+Testing,
   Documentation) — then compose the report and scores yourself.
4. **Evidence over assertion.** Every finding cites a real file/path; classify on
   diffs and code, not titles. Tag claims Observed / Inferred / Not-verifiable. Verify
   dependency EOL dates against primary sources.
5. **Keep a running detailed file** at `OUTPUT/<repo>.md`, appending each tier's full
   findings as they complete.

### Tiers
- **Quick** — `codebase-triage` + `delivery-health` (orientation + process health).
- **Standard** *(default)* — Quick **+** `weekly-risk-review` (CRITICAL/HIGH security &
  reliability findings).
- **Deep** — Standard **+** full `codebase-audit` (10-dimension graded review via the
  fan-out above).

### Add-ons (if requested)
- **`bug-class-audit`** — calibration mode: pull the repo's `fix:`-prefixed merged PRs
  and classify them against `skills/bug-class-audit/references/bug-classes.md` (delegate
  the per-PR loop). Report which bug classes dominate and which module they cluster in.
  Note that a large share of `fix:` PRs are usually not real bug fixes — exclude those.
- **`tech-due-diligence`** — only if a transaction is in play; use the provided/assumed
  deal thesis; lead with a proceed/caution/walk recommendation.
- **`evaluation-trend`** — only when comparing two points in time (a re-review). Skip on
  a first pass.

### Synthesis & cross-checks
- Reconcile signals across skills (e.g. a fast triage may rate security 🟢 while the
  deeper risk pass finds a CRITICAL — that's the breadth→depth handoff, note it).
- Identify the **single most problematic module** (where the audit findings and the
  bug-fix history agree) and **dive deeper on it**: dispatch a focused read of that
  module and produce a concrete, sequenced improvement plan (characterization tests
  first, then cheap correctness fixes, then refactor) with rough effort per step.

### Deliverable 1 — running detailed file (`OUTPUT/<repo>.md`)
Working document: each tier's findings in full, with file-cited evidence, scores, the
bug-class distribution, and method notes. This is the technical backup.

### Deliverable 2 — shareable report (`OUTPUT/<repo>-report.md`)
A polished, **plain-language** summary for a technically-literate but non-expert reader
(a tech lead / eng manager / founder). Requirements:
- **Minimal jargon.** Explain or replace specialist terms (e.g. don't say "SSRF",
  "IDOR", "RLS", "DDD", "idempotency" without a plain gloss). Lead with the bottom line.
- **Top of the report:** a **Technology stack** table.
- **The big picture:** 1 short paragraph + a verdict box (overall quality, security,
  process, recommended action).
- **What's working well:** a few plain bullets (lead with strengths if they exist).
- **Clear action list**, grouped **Fix now / This quarter / Later**. Each item = the
  problem in plain terms + the concrete action + a rough effort estimate.
- **Focus area:** the deep-dive on the most-problematic module — what it does, why it
  keeps breaking, the specific bugs found, and a **sequenced fix plan in a table** (with
  effort), noting which first step gives the most value fastest.
- **Appendix:** a plain-labelled score breakdown and a short "how this review was done"
  note (read-only, what was inspected, what wasn't verifiable).
- Frame risks honestly but constructively (e.g. "a focused tune-up, not a rewrite" when
  that's true).

### Finish
Tell me where both files are, give a 5-bullet summary of the headline findings, and ask
whether to (a) clean up the temp clone/files, (b) copy the report somewhere (e.g.
`~/Desktop`), or (c) go deeper on a specific area.
