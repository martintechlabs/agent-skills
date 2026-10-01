# ship-ready-pr-loop: Kodus replaces Greploop — design

## Goal

Make `kodus-loop` the final acceptance gate of `ship-ready-pr-loop` in place of
Greploop. The user asked for this "for now"; Greptile may come back later.

## Decisions

- Step 7 invokes the `kodus-loop` skill. The gate is kodus-loop's exit condition:
  Kody's review of the PR head commit is complete and no Kody thread is unresolved.
  There is no score.
- kodus-loop owns the review/fix/push iterations (max 5 passes) and the review
  reuse check. The Greptile reuse block in step 7 goes away; kodus-loop's step A
  already reuses a completed review of `HEAD_SHA` and triggers one otherwise.
- Automatic Kodus reviews are off by default in the user's repositories, so
  kodus-loop triggers every review. ship-ready-pr-loop does not post triggers.
- Lessons: `docs/agents/greptile-lessons.md` becomes `docs/agents/kodus-lessons.md`
  with the same quality bar, dedupe rules, and commit timing. Existing
  `greptile-lessons.md` files in target repos are not read (no compatibility shim);
  they can be renamed by hand.
- Version bump 0.6.1 → 0.7.0 (behavior change to the gate).
