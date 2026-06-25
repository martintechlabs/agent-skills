# Delivery-Health Signals — Commands & Benchmarks

The reproducibility catalog. Each signal has an exact command, how to compute the
metric, and an opinionated benchmark. Benchmarks are **rule-of-thumb heuristics**,
not laws — they are scaled by team size (see §Calibration) and should be stated as
heuristics in the output. The point of fixed commands and thresholds is that every
repo gets the same rubric; do not improvise either.

Most `gh` commands take `--repo <owner>/<repo>`, but **`gh repo view` takes the repo
as a positional argument** (`gh repo view <owner>/<repo>`), not `--repo`. Every
`git` command below uses `--no-pager` and an explicit `HEAD` so it does not hang
reading stdin or invoke a pager in a non-interactive shell — this matters most for
`git shortlog`, which silently returns **zero contributors** without it. Replace
`<default>` with the default branch (from §Setup).

The bot filter `test("\\[bot\\]|greptile|devin";"i")` catches GitHub Apps (the
`[bot]` login suffix) plus two common AI reviewers. **Adjust the alternation per
repo** — AI reviewers like `coderabbit`, `greptile-apps`, or a custom bot may not
carry the `[bot]` suffix; add their logins so they don't get counted as human review.

---

## Setup — detect tier, default branch, and pull the dataset once

```bash
# Tier + default branch. If this fails, you are in git-only mode.
# NOTE: gh repo view takes the repo as a POSITIONAL arg, not --repo.
gh repo view <owner>/<repo> --json nameWithOwner,defaultBranchRef -q '{repo:.nameWithOwner, default:.defaultBranchRef.name}'

# One dataset for the PR-based signals (raise --limit to cover 90 days if needed).
gh pr list --state merged --limit 200 --json \
  number,title,author,createdAt,mergedAt,additions,deletions,changedFiles,reviews,reviewDecision,mergedBy,baseRefName \
  > /tmp/dh_prs.json

# Window: keep PRs with mergedAt within 90 days AND, separately, the most recent 100.
# Report both framings. State N and window on every rate.
```

**Full history required for git signals.** The git-derived signals (§7 bus factor,
§8 rework & cadence) need complete history. If the working copy was shallow-cloned
(`git clone --depth …`, common in CI and some tooling), they silently truncate to a
handful of commits — run `git fetch --unshallow` first, or clone without `--depth`.
Sanity-check with `git --no-pager log --oneline | wc -l` before trusting any
git-history number.

Git-only mode: skip the `gh` calls; use the git commands in each signal (PR size,
bus factor, rework, cadence are derivable) and mark review coverage, PR timing, CI
health, and branch protection `Not measurable in git-only mode`.

---

## 1. Review rigor

**Compute from `/tmp/dh_prs.json`:**
- **Human-review coverage** = share of merged PRs with ≥1 review whose author is a human (`login` not ending `[bot]`, not `greptile`/`devin`/known bots) and is not the PR author.
- **Self-merge rate** = share where `mergedBy.login == author.login`.
- **Bot-only review** = has reviews, but all from bots.
- **Rubber-stamp rate** = approved with 0 review comments, OR merged < ~10 min after `createdAt`. (`reviews[].body` empty + `state == APPROVED`.)

```bash
# Excludes bots AND the PR author from the "human review" count.
jq -r '[.[] | . as $pr | {
  self: ($pr.author.login == $pr.mergedBy.login),
  human: ([ $pr.reviews[]?
            | select((.author.login|test("\\[bot\\]|greptile|devin";"i"))|not)
            | select(.author.login != $pr.author.login) ] | length)
}] | {n:length,
      human_cov_pct: ((([.[]|select(.human>0)]|length)/length*100)|floor),
      self_merge_pct: ((([.[]|select(.self)]|length)/length*100)|floor),
      no_human: ([.[]|select(.human==0)]|length)}' /tmp/dh_prs.json
```

**Benchmark** (scale by §Calibration): human-review coverage 🟢 ≥80% · 🟡 50–80% ·
🔴 <50%. Self-merge 🟢 <20% · 🟡 20–50% · 🔴 >50%. Always note if an AI reviewer is
substituting for human review — that is a finding, not a pass. In a 2-person team
the only human reviewers may BE the two authors reviewing each other; call that out
as a bus-factor signal, not healthy review.

## 2. PR pickup time (time-to-first-review)

Median time from PR open to first **human** review — exclude bots and the author,
or the metric collapses to a near-zero bot artifact (an AI reviewer comments in
seconds).

```bash
jq -r '[.[] | . as $pr
  | ([ $pr.reviews[]?
       | select((.author.login|test("\\[bot\\]|greptile|devin";"i"))|not)
       | select(.author.login != $pr.author.login) | .submittedAt ] | sort | .[0]) as $first
  | select($first != null)
  | (($first|fromdate) - ($pr.createdAt|fromdate))]
  | sort | {reviewed_prs: length, median_hours: (.[length/2|floor]/3600*10|floor/10)}' /tmp/dh_prs.json
```

**Benchmark:** 🟢 < 1 business day · 🟡 1–3 days · 🔴 > 3 days. This is often a
better review-health signal than cycle time; report it separately. If you also
report a bot-inclusive pickup time, label it as the bot artifact it is.

## 3. Cycle time (DORA lead-time proxy)

Median and p90 of (`mergedAt − createdAt`). True DORA lead time is commit→prod; this
is the in-repo proxy — label it as such.

**DORA-anchored benchmark:** median 🟢 Elite < 1 day · High < 1 week · Medium < 1
month · 🔴 Low > 1 month. Report median **and** p90 (the tail is where pain hides).

## 4. PR size

Median of (`additions + deletions`); median `changedFiles`; % of PRs > 1000 LOC.

```bash
jq -r '[.[]|(.additions+.deletions)] | sort | {median: .[length/2|floor], n:length,
  giant_pct: (([.[]|select(.>1000)]|length) / length * 100 | floor)}' /tmp/dh_prs.json
```

**Benchmark:** median 🟢 < 250 LOC · 🟡 250–600 · 🔴 > 600. Giant-PR share 🟢 < 10%.
Small batches are the strongest single predictor of reviewability and flow.

## 5. CI health

```bash
# Pass rate = success / COMPLETED (success+failure). Skipped/cancelled are NOT failures
# and must be excluded from the denominator, or path-filtered workflows look broken.
gh run list --branch <default> --limit 200 \
  --json name,conclusion,createdAt -q \
  'group_by(.name)[] | {workflow: .[0].name,
     completed: ([.[]|select(.conclusion=="success" or .conclusion=="failure")]|length),
     pass: ([.[]|select(.conclusion=="success")]|length),
     skipped: ([.[]|select(.conclusion=="skipped" or .conclusion=="cancelled")]|length),
     span_days: (((.[0].createdAt|fromdate) - (.[-1].createdAt|fromdate))/86400|floor)}'
```

Pass rate per workflow = `pass / completed` (exclude skipped/cancelled). Flaky
signal = failure/re-run rate on a branch that should be green. Two honesty checks
the catalog can't do for you:
- **`--limit` is a run *count*, not a time window.** Note the `span_days` the runs
  actually cover; if it's far shorter than your 90-day frame (busy repo), treat CI
  as a recent snapshot and say so.
- **Only workflows that run on the default branch appear here.** Cross-check against
  `.github/workflows/` — a workflow that gates PRs on feature branches won't show up,
  so "2 of 5 workflows seen" is a coverage caveat, not 3 missing suites.

**Benchmark:** default-branch pass rate 🟢 ≥ 95% · 🟡 85–95% · 🔴 < 85%. Any
required-gate workflow flaking > 10% is a finding (the team learns to ignore red).

## 6. Branch protection

```bash
gh api repos/{owner}/{repo}/branches/<default>/protection 2>/dev/null \
  -q '{reviews:.required_pull_request_reviews.required_approving_review_count, checks:.required_status_checks.contexts}'
gh api repos/{owner}/{repo}/rulesets 2>/dev/null
```

Look for: required approving reviews ≥ 1, required status checks, and whether the
default branch is actually covered. If the protection API returns 404 and rulesets
are empty, the branch is likely **unprotected** — cross-check against the self-merge
rate (§1) and report `Inferred`, not `Observed`. Also note absence of `CODEOWNERS`
and a PR template (`.github/`), which make review assignment purely cultural.

**Benchmark:** 🟢 required review + required checks on default · 🟡 protected but no
required review · 🔴 unprotected / unverifiable + high self-merge.

## 7. Bus factor

```bash
# --no-pager + explicit HEAD are REQUIRED: bare `git shortlog` reads stdin in a
# non-interactive shell and silently returns NOTHING (zero contributors).
git --no-pager shortlog -sne --since=90.days.ago HEAD    # active window
git --no-pager shortlog -sne HEAD | head -20             # all-time
```

Top author's share of commits in the window; count of contributors above ~10% in 90
days (exclude bots, but **report bot-authored share separately** — an AI agent
authoring 10% of merges is itself a finding). This is a team-resilience signal;
never frame it as individual performance.

**Benchmark:** top-author 90-day share 🟢 < 50% · 🟡 50–70% · 🔴 > 70%. Effective
contributors (>10% share) 🟢 ≥ 3 · 🟡 2 · 🔴 1.

## 8. Rework & cadence

**Rework (DORA change-failure proxy):**
```bash
git --no-pager log --since=90.days.ago --grep='^Revert' --oneline | wc -l   # robust: reverts use a standard prefix
git --no-pager log --since=90.days.ago --oneline | wc -l                     # denominator
# Soft secondary only (convention-dependent — do NOT headline this number):
git --no-pager log --since=90.days.ago -i --grep='hotfix' --grep='revert' --oneline | wc -l
```
Revert rate = `^Revert` reverts / total commits. The free-text `hotfix` grep is
**convention-dependent** — a team that doesn't use the word looks falsely stable, so
keep it secondary and labeled. For depth on *what* keeps breaking, hand off to
`bug-class-audit`.

**Cadence (DORA deploy-frequency proxy):**
```bash
gh release list --limit 30                          # release intervals, if releases are used
git --no-pager tag --sort=-creatordate | head -20  # fallback: tag cadence
# else: merges-to-default per week from /tmp/dh_prs.json (baseRefName == <default>)
```

**Backlog / WIP:**
```bash
gh pr list --state open --json number,createdAt -q \
  '{open: length, stale: ([.[]|select((now - (.createdAt|fromdate)) > 2592000)]|length)}'   # >30d
```

**Benchmarks:** revert/rework rate 🟢 < 5% · 🟡 5–15% · 🔴 > 15%. Deploy frequency
(DORA) 🟢 Elite on-demand/daily · High weekly–monthly · Medium monthly–6mo · 🔴 Low
< every 6 months. Stale-PR backlog 🟢 < 5 open > 30d · 🔴 a growing pile.

---

## DORA four keys — where they map

| DORA key | This skill's signal | Caveat |
|---|---|---|
| Deployment frequency | §8 cadence (release/tag/merge frequency) | Merge ≠ deploy unless CD is visible. |
| Lead time for changes | §3 cycle time (open→merge) | True lead time is commit→prod; this is the repo proxy. |
| Change-failure rate | §8 revert/rework rate | A proxy; real CFR needs deploy+incident data. |
| Time to restore (MTTR) | usually **Not verifiable from repo** | Needs incident timestamps; approximate only if revert→fix timing is clearly traceable. |

State plainly that deploy frequency and MTTR are partially or wholly outside the
repo; do not fabricate DORA tiers you can't support.

---

## Calibration — team-size bands

Infer the band from 90-day active contributors (§7) if not given, and **state it as
an assumption**. Thresholds shift as follows:

| Band | Active contributors (90d) | How thresholds shift |
|---|---|---|
| **Solo / pair** | 1–2 | Self-merge and low human-review coverage are expected — report them as *context*, not red, but flag bus factor as the dominant risk and recommend external/AI review as a partial mitigation. |
| **Small team** | 3–9 | The default benchmarks above apply directly. Required-1-review and a real second pair of eyes become reasonable expectations. |
| **Mid team** | 10–30 | Tighten: human-review coverage 🟢 ≥ 90%, self-merge 🔴 > 10%, branch protection expected, CODEOWNERS expected. Bus factor should be ≥ 4 effective contributors. |
| **Large org** | 30+ | Expect enforced protection, required reviews, CODEOWNERS, stable CI, and no single author > 30%. Process gaps here are control failures, not pragmatism. |

When in doubt about the band, show the metric against the two adjacent bands rather
than forcing one — and say which band you assumed.
