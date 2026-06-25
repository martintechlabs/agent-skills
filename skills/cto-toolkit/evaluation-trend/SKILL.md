---
name: evaluation-trend
description: Compares two evaluations of the SAME codebase at two points in time and reports the trajectory — is it getting better or worse? Produces per-dimension/signal score movements, a resolved / new / persisting / severity-changed breakdown of findings, and a short stakeholder-facing trajectory narrative. Use whenever the question is about change over time rather than current state — "how has this changed since last quarter", a re-audit, a retainer or board trajectory update, regression-vs-improvement tracking, or diffing two runs of codebase-audit, codebase-triage, delivery-health, weekly-risk-review, or bug-class-audit. It diffs those skills' outputs and does not replace them — run the underlying skill first (or twice). The hard part is establishing the two runs are actually comparable before trusting any delta.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Evaluation Trend

You turn point-in-time evaluations into **trajectory**: given two assessments of the
same codebase over time, you report whether it is getting better or worse, what
drove the change, and whether the team is paying down risk or accruing it. This is
the recurring fractional-CTO/retainer deliverable the other evaluation skills don't
provide on their own — they each produce a single snapshot.

This skill **diffs the output of another evaluation skill** (`codebase-audit`,
`codebase-triage`, `delivery-health`, `weekly-risk-review`, `bug-class-audit`). It
does not perform the evaluation itself — run the underlying skill first, or twice.

## The cardinal rule: comparability before delta

A delta between two non-comparable runs is noise dressed as signal — and the most
common way a trend report misleads. **Before reporting any movement, establish that
the two runs are actually comparable, and state it.** Check:

- **Same skill and same skill version.** A method change (e.g. `codebase-audit`
  0.1 → 0.2 changed scoring, or a benchmark was retuned) can move a score with zero
  change to the code. Never attribute a method-driven delta to the team.
- **Same scope / window / denominator.** `delivery-health` window length,
  `codebase-audit` dimensions in vs. N/A, `bug-class-audit` denominator and inclusion
  criteria, `weekly-risk-review` severity bar.
- **Same data tier.** Full (gh + git) vs. git-only changes which signals exist.
- **Same benchmarks / team-size band.** A team that grew bands will be judged by a
  stricter rubric — that's a real change in expectations, not in the code.

If the runs differ on any of these, say so and either normalize (re-derive the older
number under the new method) or down-weight that part of the delta. **Always
distinguish real change from measurement change.** When in doubt, label a movement
"possibly measurement-driven" rather than claiming improvement or regression.

When the saved reports lack the detail to re-derive the old score under the new
method, **normalization may be infeasible** — then present both overall scores
side by side, **refuse to subtract them**, and say why. That is a valid, honest
outcome, not a failure to produce a delta.

## Getting the "before" state — three modes, pick what fits

1. **Two saved reports.** The user supplies two prior reports of the same kind; diff
   them directly. Simplest, works for every skill. Depends on the reports having been
   saved with a date and commit SHA — if a report lacks them, say the comparison is
   approximate.
2. **Git-window diff** (`delivery-health` and any time-windowed metric). Compute the
   same signals over two windows — e.g. the last 90 days vs. the 90 days before —
   from git/gh in one pass. No stored state; the trend falls out for free. Cheapest
   where it applies.
3. **Re-run at an old commit.** Check out a past commit or tag in a **git worktree**
   (don't disturb the working tree) and re-run the evaluation, then diff against HEAD.
   No saved reports needed, fully automated — but expensive (a full `codebase-audit`
   at an old commit costs a full audit), and you MUST run the **same skill version**
   at both points or you are measuring the method, not the code.

For the **git-window** mode specifically, compute *every* signal identically over both
windows. If you fall back to sampling one signal (e.g. review coverage when the bulk
API times out), sample **both** windows the same way — an asymmetric sample is a
method delta. And watch for composition shifts that mechanically move a ratio: e.g. a
bot's authorship share changing between windows inflates the *human* top-author share,
so report human concentration on a human-only denominator.

Pick per situation: saved reports when they exist, git-window for `delivery-health`,
re-run-at-commit as the automated fallback. **State which mode you used** — it
determines how much to trust the comparison.

## How to work

1. **Establish comparability** (above). State the two points compared — dates and
   commit SHAs — and any caveats, up front.
2. **Diff the scores.** Per dimension/signal, show `before → after → Δ` with
   direction. For graded modes (`codebase-audit` 0–10, `delivery-health` graded),
   include the overall score and state the denominator both times.
3. **Diff the findings.** If the underlying reports are scores-plus-notes (or a
   git-window metrics vector) rather than a discrete findings list, the score/signal
   movements table is the headline and this findings diff is best-effort — derive it
   from the notes or from threshold crossings and say so; don't force "Resolved (0)"
   or per-commit attribution onto continuous rates. Otherwise classify each finding:
   - **Resolved** — flagged before, gone now.
   - **New / regressed** — flagged now, wasn't before, and the code change introduced it.
   - **Newly surfaced (detection change, not regression)** — appears only in the later
     run because the method got deeper (a new pass, a stricter rule, a more thorough
     read) while the code didn't change. The finding was always there; you can now see
     it. Do NOT file these under New/regressed — that implies the team introduced them.
     This is the finding-level form of measurement-vs-real change.
   - **Persisting** — flagged in both runs. *Often the most important signal:* a
     CRITICAL flagged two quarters running is a process failure, not just a bug.
   - **Severity changed** — same finding, moved up or down the scale.
4. **Separate signal from noise.** A small score wobble with no concrete change
   behind it is not a trend. Tie each real movement to evidence — ideally the
   commit/PR that resolved or introduced it (`git log` between the two SHAs). Wobble
   within measurement error gets called out as such, not as improvement.
5. **Write the trajectory narrative.** 2–4 sentences for a stakeholder: the overall
   direction, the one or two things that drove it, and whether risk is being paid
   down or accrued. Lead with whatever is **most actionable** — often a persisting
   CRITICAL, but sometimes the method-change caveat or a newly-surfaced bug. If
   method change swamps any real signal, the honest trajectory is **Indeterminate
   (measurement-dominated)**, not a confident arrow.

## Output format

```
# Evaluation Trend — <repo> · <skill> · <date A → date B>

## Comparability
Mode: <saved reports | git-window | re-run-at-commit>.
Same skill version: <yes | no — caveat>. Same scope/window/tier/band: <…>.
Commits: <shaA> → <shaB>. Caveats: <anything that makes a delta measurement-driven>.

## Trajectory: 📈 Improving / ➡️ Flat / 📉 Declining / 🔀 Mixed / 🌫️ Indeterminate (measurement-dominated)
2–4 sentences for a stakeholder: direction, the drivers, risk paid-down vs. accrued.

## Score movements
| Dimension / Signal | Before | After | Δ | Note |
|--------------------|--------|-------|---|------|
| …                  |        |       |   |      |
Overall: <before> → <after> (Δ); denominator stated for both.

## Findings movement
- ✅ Resolved (N): … (link the fixing commit/PR where findable)
- 🔴 New / regressed (N): … (code change introduced it)
- 🔍 Newly surfaced (N): … pre-existing, exposed by a deeper/changed method — NOT introduced by the team
- ⚠️ Persisting (N): … — flagged in both runs; the risks being ignored
- ↕️ Severity changed (N): …

## Caveats
- Method/version/scope changes and anything that makes a delta measurement-driven
  rather than real.
```

## Diff-stability (a note for the evaluation skills)

A trend is only as trustworthy as the comparability of its inputs. Evaluation outputs
should be made diffable: stamp the **date and commit SHA**, name the **skill version**,
and keep section names and dimension/signal labels stable across versions. This skill
assumes that; when a prior report lacks a SHA or date, say the comparison is
approximate rather than pretending to precision you don't have.

## Anti-patterns

| Anti-pattern | Why it misleads | Instead |
|---|---|---|
| Diffing two runs that used different skill versions/scopes and crediting the codebase | Measurement change masquerades as real change | Normalize or flag; never attribute a method delta to the team |
| Reporting score deltas with no concrete change behind them | Wobble reads as a trend | Tie every movement to a commit/PR or call it noise |
| Burying persisting findings | The risks flagged every quarter are the real story | Make persisting CRITICAL/HIGH items the headline |
| A single arrow with no narrative | A board wants "why", not just the direction | Always write the 2–4 sentence trajectory |
| Comparing different repos or different skills | Not a trend at all | Same repo, same skill, two points in time |
