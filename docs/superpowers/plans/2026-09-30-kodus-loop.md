# kodus-loop — plan

Spec: `docs/superpowers/specs/2026-09-30-kodus-loop-design.md`

1. Verify the GitHub shapes against public Kodus-reviewed PRs (read-only): bot
   logins, check-run name and outcomes, inline badge format, GraphQL thread query.
2. Write `skills/coding/kodus-loop/SKILL.md` (frontmatter `version: "0.1.0"`) and
   `references/github-queries.md`.
3. Add `kodus-loop` to the "Coding" grouping in `skills.sh.json` and to README's
   Coding table.
4. Add a `BACKLOG.md` entry for non-GitHub platforms.
5. Re-run every read-only query in the skill against a public PR and show the
   output. State that the full loop was not run live.
6. Commit, push, open a ready-for-review PR.
