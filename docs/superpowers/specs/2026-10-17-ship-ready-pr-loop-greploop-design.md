# ship-ready-pr-loop: Greploop returns, kodus-loop is removed — design

## Goal

The user no longer uses Kodus. Reverse the 2026-09-30 switch
(`2026-09-30-ship-ready-pr-loop-kodus-design.md`): Greploop is the final gate of
`ship-ready-pr-loop` again, and the `kodus-loop` skill leaves the repo.

## Decisions

- Steps 7–8, Purpose, Acceptance Criteria, Hard Rules, and the Final Response
  Format return to their 0.6.1 Greploop text (target 5/5, max 5 passes, reuse a
  completed review of `HEAD_SHA`, one review per fix batch).
- The Greptile lessons file stays out. Commit 2168598 removed the lessons handling
  on its own merits, not as part of the Kodus switch.
- The reuse check keys on the Greptile check run, as 0.6.1 did. greploop itself
  polls that check run, so a repository without one cannot pass the gate either way.
- greploop commits with `git add -A`. Step 8 overrides it: stage explicit paths and
  check `git diff --cached` before each commit. kodus-loop had this rule, and 0.6.1
  did not (Greptile finding on PR #52).
- Step 1's Kodus install check goes, with no Greptile replacement. 0.6.1 had none,
  and greploop stops after a 10-minute timeout when no review arrives. A timeout is
  a blocker, not a reason to fall back to another reviewer.
- `kodus-loop` is deleted: its directory, README row, and `skills.sh.json` entry.
  Git history keeps it. The Kodus specs and plans stay as design history.
- `shipit`'s description drops its Kodus pointer and now says when to prefer
  `ship-ready-pr-loop` (no PR yet, or the change needs its own review pass first).
- Versions: ship-ready-pr-loop 0.8.0 → 0.9.0 (gate change), shipit 0.1.0 → 0.1.1.
