# Backlog

Deferred improvements surfaced during real-repo validation of the CTO toolkit. None
are blocking; each was consciously kept out of scope to keep PRs focused.

## 1. `weekly-risk-review`: split the pattern catalog into core + stack packs

The anti-pattern catalog is heavily Supabase/Next.js-flavored. The *method* (auth →
money → DB → webhooks → cron → integrations, each with grep targets) generalizes
fine, but the concrete grep strings don't: the Rails/Django subsection is thin and
there's no tRPC/GraphQL coverage at all, so a reviewer on a non-Supabase repo gets
much less leverage.

**Do:** restructure into a stack-agnostic core (the questions to ask at each surface)
plus stack packs — Supabase, Rails, Django, Prisma, tRPC/GraphQL — so a non-Supabase
repo isn't reviewed with Supabase greps. *Biggest remaining item.*

## 2. `delivery-health/references/signals.md`: review-coverage fetch + concentration denominator

- The bulk `gh pr list --json …,reviews` call **times out (502/504)** on active
  repos because the `reviews` field payload is heavy. Document a fallback: pull
  `reviewDecision` in bulk (cheap) and fetch full reviews per-PR or via a sample.
  Flag that this is the one signal that doesn't window cleanly for trend use.
- **Bus-factor / concentration:** report human contributor concentration on a
  **human-only denominator**. A changing bot-authorship share between periods
  mechanically moves the human top-author share (a denominator artifact, not the lead
  dev doing more) — `signals.md §7` says "report bot share separately" but doesn't
  connect it to this distortion.

## 3. Diffability stamps for `evaluation-trend`

Each evaluation skill's output should stamp **date + commit SHA + skill version** and
keep section/dimension/signal labels stable across versions, so `evaluation-trend`
gets cleanly comparable inputs. The trend skill degrades gracefully without them
(it flags the comparison "approximate"), but the stamps remove that caveat.

## 4. (Optional) `skills.sh.json` grouping

Done — all seven skills are grouped under "CTO toolkit". Listed here only as a marker
that the grouping decision was made deliberately; revisit if the suite grows enough to
warrant sub-groups.
