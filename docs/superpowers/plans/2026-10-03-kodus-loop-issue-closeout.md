# kodus-loop issue closeout — plan

Spec: `docs/superpowers/specs/2026-10-03-kodus-loop-issue-closeout-design.md`

1. SKILL.md: read PR state first; route `MERGED`/`CLOSED` to closeout.
2. SKILL.md: add "GitHub threads and Kody Issues are separate" explainer.
3. Loop: prefer Kody's suggested code (D); reply `Fixed in <sha>.` before resolving
   a fixed thread (E); do not answer Kody issue offers while the PR is open (B.4).
4. Closeout section: wait 5 min after close, classify threads (§7), post one
   `@kody Yes, …` reply per thread, poll 5 min for Kody's answer, report.
5. references §7: closeout query. Verify read-only on merged PR #46 and on a
   synthetic fixture covering every class.
6. Bump 0.1.1 → 0.2.0; update README row.
7. Talking with Kody section + reference §8; replies carry evidence; closeout
   reply carries the issue lookup hint. Verify §8 on PR #46 and the fixture.
8. Live closeout run on a real merged PR (posts comments; needs user OK).
