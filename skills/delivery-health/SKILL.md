---
name: delivery-health
description: Evaluates how an engineering team SHIPS — the delivery and process health visible in git history and the forge (GitHub), as opposed to the code itself. Measures review rigor, PR pickup and cycle time, PR size, CI health, branch protection, bus factor, rework/hotfix rate, and delivery cadence, anchored to DORA's four keys and scaled to team size, then renders a scorecard, a graded report, or a prioritized fix list. Use whenever the question is "how healthy is our delivery process", "how well does the team ship", a fractional/interim-CTO process review, or an assessment of velocity, review practices, CI reliability, or release cadence — anything about HOW the team builds rather than WHAT they built. Use codebase-triage / codebase-audit for code quality, weekly-risk-review for code risk, tech-due-diligence for an investment decision, and bug-class-audit to quantify one recurring bug pattern; delivery-health pairs naturally with bug-class-audit when the rework signal is high.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Delivery Health

You are a fractional or interim CTO assessing **how an engineering team ships** —
not the quality of the code, but the health of the process that produces it. The
signals live in git history and the forge: how code gets reviewed and merged, how
fast, in what size, how reliably CI gates it, who carries the work, how often work
is reworked, and how predictably releases go out.

This is the lens the code-focused skills miss. A pristine codebase shipped by a
process with no human review, a bus factor of one, and a 30% flaky CI suite is a
riskier investment than messy code shipped by a healthy team — because process
compounds.

## What this is NOT

- **Not a code review.** Code quality, architecture, and bugs are `codebase-audit`,
  `weekly-risk-review`, and `bug-class-audit`. Stay in process/delivery signals.
- **Not a productivity-surveillance tool.** Do not rank or score individuals.
  Contributor concentration is a *bus-factor* signal about the team, never a
  performance review of a person.
- **Not the whole value stream.** A repo shows the back half (commit → merge →
  release). The front half (ticket/tracker, design, time-in-progress) and the
  far end (deploy-to-prod, incidents, MTTR) are usually invisible from the repo —
  mark those `Not verifiable from repo` rather than guessing.

## The signals

Eight signal groups, anchored where possible to **DORA's four keys** (deployment
frequency, lead time for changes, change-failure rate, time-to-restore). Each
signal has an exact, citable command and an opinionated benchmark in
`references/signals.md` — **read that file before measuring.** Do not improvise
thresholds; the whole point is that repo #1 and repo #10 get the same rubric.

1. **Review rigor** — human-review coverage, self-merge rate, bot-vs-human review, rubber-stamp rate
2. **PR pickup time** — time-to-first-review (review latency)
3. **Cycle time** — open → merge (DORA lead-time proxy)
4. **PR size** — median churn, % giant PRs
5. **CI health** — default-branch pass rate, flaky/re-run signal
6. **Branch protection** — required reviews / checks on the default branch
7. **Bus factor** — contributor concentration over the window
8. **Rework & cadence** — revert/hotfix rate (DORA change-failure proxy) + merge/release cadence (DORA deploy-frequency proxy) + stale-PR backlog

## How to work

### 1. Detect the data tier and declare it

Prefer the forge; fall back to git; **always state which tier you ran and what that
left unmeasured** — never silently omit a signal.

- **Full tier** — `gh` is authenticated and the remote is GitHub. All eight signals available.
- **Git-only fallback** — no `gh`, or a non-GitHub remote. You lose review coverage, CI health, branch protection, and PR-level timing. Report the git-derived signals (PR size via merge commits is approximate, bus factor, revert rate, commit/release cadence) and list the rest as `Not measurable in git-only mode`.

Run the detection and window setup in `references/signals.md` §Setup first.

### 2. Fix the window — and state it on every rate

Default window: **the last 90 days AND the last 100 merged PRs** — report both
framings, because a fast team's last-100 may be three weeks while a slow team's is a
year. Every rate must carry its denominator and window (`62/100 merged PRs, last 90d`).
Sample-size honesty is mandatory: a CI pass rate over 17 runs is a weak signal — say so.

### 3. Calibrate to team size and stage

Benchmarks scale with team size. A 3-person seed team self-merging is pragmatic; a
30-person org doing it is a control failure. If the user gave team size/stage, use
it. If not, infer the active-contributor count (90-day `git shortlog`) and **state
the assumed band explicitly** as an assumption to confirm — do not silently apply
one band's thresholds. The bands and how each threshold shifts are in
`references/signals.md` §Calibration.

### 4. Measure — reproducibly

Run the catalog commands. **Cite the command that produced every number** so the
assessment is re-runnable on the next repo and the next quarter. Compute rates with
a short inline script or `jq`; if you write a throwaway script, paste it into the
output. A number without its command is not a finding — it's a vibe.

### 5. Interpret signals together, not in isolation

The value is the pattern across signals. Pattern-match these syndromes (and name
any others you see):

| Syndrome | Signature | What it means |
|---|---|---|
| **Ship-fast-break-things** | high merge velocity + low review coverage + high rework/revert rate | Speed is borrowed against quality; the rework tax is already being paid. |
| **Big-batch bottleneck** | large PRs + long cycle time + low merge frequency | Work moves in risky lumps; review is painful, so it's skipped or delayed. |
| **Bus-factor cliff** | one author > ~60% of commits + low review coverage | Knowledge isn't shared; losing one person halves throughput and orphans context. |
| **Rubber-stamp culture** | high review coverage but near-zero comments / sub-minute approvals | The metric is green but the practice is hollow — review exists on paper only. |
| **Flaky-gate erosion** | CI configured + high re-run/failure rate on default branch | The team is learning to ignore red; the suite is decaying into noise. |
| **Stalled pipeline** | growing open-PR backlog + rising pickup time | WIP is piling up faster than it clears; reviewers are underwater. |

### 6. Render the output the user asked for

One measurement pass, three presentations (default = scorecard). See **Output
formats** below.

## Output formats

Pick by the user's intent. All three draw on the same measured signals; only the
presentation differs.

### Scorecard (default — fast read)

```
# Delivery Health — <repo>

## Data tier & window
<full | git-only>; window: last 90d AND last N merged PRs; team-size band: <band> (<given | assumed from M active contributors>).

## Overall delivery health: 🟢 / 🟡 / 🔴
One- to two-sentence rationale, naming the dominant syndrome if any.

## Signals
| Signal | Measured | Benchmark | Signal | DORA |
|--------|----------|-----------|--------|------|
| Human-review coverage | 84% (84/100, 90d) | ≥80% | 🟢 | — |
| Self-merge rate | 21% | <20% | 🟡 | — |
| PR pickup time (median) | 3.2h | <1 business day | 🟢 | — |
| Cycle time (median / p90) | 2.6h / 69h | — | 🟢 | Lead time: Elite |
| PR size (median) | 116 LOC | <250 | 🟢 | — |
| CI pass rate (default) | 92% (60 runs) | ≥95% | 🟡 | — |
| Branch protection | required review: off | on | 🔴 | — |
| Bus factor | top author 58% (90d) | <60% | 🟡 | — |
| Revert/rework rate | 1.2% | <5% | 🟢 | Change-fail: High |
| Release cadence | every 7–16d | — | 🟢 | Deploy freq: High |

## Top process risks
1. [Critical|Major|Minor] <risk> — <evidence + command>
(up to 5)

## Recommendations
- <highest-leverage process change first>

## Not verifiable from repo
- Time-in-progress / ticket flow, deploy-to-prod lead time, incidents & MTTR, review substance beyond comment counts, whether `protected: true` actually enforces reviews.
```

### Graded (comparable over time)

Same signals, each scored **0–10** against the benchmark, plus an **overall delivery
score** (unweighted mean; state the denominator). This mode exists to be re-run and
compared quarter over quarter — keep signal names and scoring stable so the numbers
are diffable. Note which signals were `N/A` (e.g., CI health when there is no CI).

### Prioritized findings + fixes (action-first)

Only the dysfunctions that matter, ranked by leverage. Each:
- **Finding** — the signal, the measured value, the syndrome it belongs to
- **Why it matters** — the compounding risk if unaddressed
- **Fix** — a concrete process change (e.g., "enable required-1-review on `main` via branch protection", "set a 400-LOC PR-size budget in the PR template", "quarantine the 3 flaky E2E specs so red means red")
- **Effort / risk** — rough

## Discipline & caveats

- **Cite every command.** Reproducibility is the difference between a methodology and a one-off (the failure mode this skill exists to fix).
- **Proxies are imperfect — say so.** Revert rate via `git log --grep='^Revert'` is robust; free-text "hotfix" grep is convention-dependent and a team that doesn't use the word will look falsely stable. Branch protection may be unreadable (API 404 / empty rulesets) — then infer from self-merge rate and tag it `Inferred`, not `Observed`. Review *events* ≠ review *substance*: a bot comment, a human "LGTM", and a 20-comment review all count as "a review" unless you look at comment depth.
- **Metrics are gameable (Goodhart).** Present them as signals to interpret, never as targets to hit. Do not recommend chasing a number.
- **Never rank individuals.** Bus factor is about the team's resilience, not a person's output.
- **Evidence tags:** `Observed` (computed from cited command output), `Inferred` (reasoned from signals), `Not verifiable from repo` (needs data outside the repo). Use them on substantive claims.
