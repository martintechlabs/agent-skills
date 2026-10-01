# ship-ready-pr-loop: Kodus replaces Greploop — plan

Spec: `docs/superpowers/specs/2026-09-30-ship-ready-pr-loop-kodus-design.md`

1. kodus-loop: always trigger (automatic reviews are off); read Kody's reaction on
   the trigger comment; stop if Kody does not respond in 2 minutes.
2. ship-ready-pr-loop: replace Purpose items, step 1 and step 3 lesson references,
   the step 6 PR bullet, steps 7–8, Acceptance Criteria, Hard Rules, and the Final
   Response Format. Bump to 0.7.0.
3. README row for ship-ready-pr-loop.
4. `grep -i 'greptile\|greploop'` the skill: zero hits.
5. Commit, push to PR #46, update the PR description.
