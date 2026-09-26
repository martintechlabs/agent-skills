# Review-value ledger template

Copy this structure into the run history's durable directory. Replace angle-bracket
fields with facts or `unknown — <reason>`; do not invent identifiers or amounts.
Use relative links for saved evidence. Keep baseline snapshots unchanged; append
dated corrections to assessments. Add a PR block per enrolled PR, including zeros
and incomplete cases. Remove the example rows when filling the tables.

```markdown
# Greptile value — <pilot>

- Repository: <owner/repo>
- Mode: <prospective or retrospective; selection date and rule>
- Target / enrolled: <10 / count>
- Start / end or current cutoff (UTC): <times>
- Eligibility / exclusions: <rule and excluded PR links with reasons>
- Earlier reviewer mechanism: <tool/model; note native self-review>
- Serious impact bar: <Critical/Major definitions from the skill>
- Storage / retention: <durable location; private/public status>

## Runs

| Run UTC | Selection rule / merge dates | Selected PRs | Already recorded / new PRs | Gaps |
|---|---|---|---|---|
| <time> | <ten most recently updated merged PRs, date range, or prospective cohort> | <IDs> | <IDs> | <uncovered history or evidence> |

Reuse each PR/finding block below on later runs. Preserve baseline artifacts and
append dated evidence/assessment changes. Count overlapping PRs once in cumulative
totals. Name the run/cohort for every count.

## Report — <UTC time>

- Selected: <N>; Greptile completed: <N>; comparable: <N>.
- New / overlapping PRs this run: <counts>; cumulative distinct PRs: <N>.
- Comparable PR IDs: <list>; incomplete/non-comparable IDs and reasons: <list>.
- Comparable PRs with extra serious findings: <X/N or N/A>.
- Known findings outside that cohort: <counts and limits; not pooled into rate>.

| Cohort | Assessed severity | Greptile-only | Both | Later-change | Unknown |
|---|---|---:|---:|---:|---:|
| <comparable or other PR IDs> | <Critical or Major> | <n> | <n> | <n> | <n> |

- Greptile canonical findings / finding mentions / extra duplicate mentions: <counts; earlier-only claims excluded>.
- False positives / non-defects / lower-severity defects / unresolved: <counts>.
- Evidence limits: <scope, missing artifacts, selection bias, small sample>.
- Cost/usage: <known amounts, units, currency, source, period, covered PRs/rounds,
  allocation, missing coverage — separately for Greptile and earlier reviewer>.
- Cost per extra serious finding: <matched cohort calculation or N/A + reason>.
- Upgrades (at most three): <class, independent PR/finding IDs, current gap,
  target file/review step, concrete assertion or instruction, verification;
  distinguish repeated misses from later changes, even with unknown attribution>.
- Already covered / retired: <existing regressions or guidance, obsolete code>.
- Recommendation: <bounded next step; acceptance policy unchanged>.

## PR <number or pending branch>

- URL / branch: <identifiers>
- Mode / enrollment time: <facts>
- Baseline status: <frozen before results, verifiable historical, or incomplete>
- Final pre-Greptile checkpoint: <full SHA + intended base SHA; dirty snapshot if any>
- Baseline frozen at (UTC) / proof of timing: <time, saved artifact or immutable link>

| Earlier pass | Reviewer/tool/model | Completed / captured UTC | Reviewed SHA / base SHA | Scope / skipped files / dirty snapshot | Full output link |
|---|---|---|---|---|---|
| <pass> | <mechanism> | <times> | <SHAs> | <coverage and artifacts> | <link> |

Retain all pre-Greptile findings and fixes here, including findings absent from a
later clean pass: <IDs, evidence and fix SHAs>.

| Greptile round | Account | Check run status / conclusion / summary | Completed / captured UTC | Reviewed SHA | Baseline pass for this round | Evidence URLs / local snapshots | Gaps |
|---|---|---|---|---|---|---|---|
| <round> | <author> | <e.g. completed/success, "N files reviewed, M comments added"; skipped + reason> | <times or unknown> | <SHA or unknown> | <latest saved earlier pass before this round, or none> | <PR body, reviews, inline, issue comments, check runs on every commit; all pages> | <gaps or none> |

- Comparable: <yes/no and reason; known later-change findings do not alone exclude a PR>.
- Costs/usage for this PR: <source, amount/units/currency, rounds, allocation or unknown>.

### Finding <stable ID>

- Root cause / affected behavior / defect class: <description>
- Mentions: <all source URLs/IDs, round, timestamps, original/current SHA and location>.
- Validity / original label / assessed severity: <values>
- Impact and code evidence: <trigger, consequence, immutable code links or local snapshots>.
- Attribution: <greptile-only / both / later-change / unknown / N/A>.
- Baseline comparison: <earlier matching finding or full-output absence, scope proof,
  code at baseline, intervening diff, introduction or reintroduction evidence>.
- Disposition: <fixed/open/rejected/unknown; fix/test link if known>.
- Gaps / dated corrections: <open question or changed assessment and why>.
```
