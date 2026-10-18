# ship-ready-pr-loop: Greploop returns, kodus-loop is removed — plan

Spec: `docs/superpowers/specs/2026-10-17-ship-ready-pr-loop-greploop-design.md`

1. ship-ready-pr-loop: restore Purpose items, steps 7–8, Acceptance Criteria, Hard
   Rules, and the Final Response Format from 0.6.1 without the lessons parts; drop
   the step 1 Kodus install check. Bump to 0.9.0.
2. Delete `skills/coding/kodus-loop/`; remove its `skills.sh.json` entry and README row.
3. Restore the ship-ready-pr-loop README row; update the shipit description and bump
   it to 0.1.1.
4. `grep -ri 'kodus\|kody' skills README.md skills.sh.json`: zero hits.
5. `bash scripts/check-frontmatter.sh` passes.
6. Commit, push, open a PR.
