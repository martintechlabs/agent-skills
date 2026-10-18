# shipit absorbs ship-ready-pr-loop — design

## Intent

Two skills shipped PRs: `shipit` (greploop with guardrails) and
`ship-ready-pr-loop` (a local review ladder, then greploop). The user wants one.
`shipit` stays; `ship-ready-pr-loop` is deleted.

Greptile reviews cost money, and a one-line change does not need one. So Codex
reviews every PR, and only a larger change goes on to greploop.

## User decisions

- `shipit` is the only PR-shipping skill. `ship-ready-pr-loop` is deleted.
- The cost and safety lessons from `ship-ready-pr-loop` land first (first commit).
- Codex is the only local reviewer, and it always runs. The other mechanisms
  (`code-review-and-quality`, Matt Pocock's `code-review`, native self-review)
  are dropped.
- Codex reviews against the PR.
- A minor change stops after Codex. A larger change goes on to the full greploop.
- A PR must exist at the start. If none exists, ask for one.

## Flow

### 1. Find the PR (at the start)

Keep shipit's existing input rules (PR number or URL, else the current branch's
PR, ask if ambiguous). If no PR exists, ask the user to give one or to let shipit
open it. Do not open one unasked. With no user to ask (unattended), stop and
report. Do nothing else before a PR exists.

### 2. Prerequisites for every change

- The local branch contains the PR head (existing check).
- Inspect the working tree (existing rule: never include unrelated user changes).
- `codex` is installed and authenticated. If it is missing, stop and report. There
  is no fallback reviewer. Under a ChatGPT-plan login, check
  `~/.codex/models_cache.json` before assuming the default model works (AGENTS.md).
- The PR is on GitHub (builder's call). Every new step uses `gh`, and Codex cannot
  review a Perforce changelist. On GitLab or Perforce, stop and say shipit is
  GitHub-only. The old one-line GitLab/Perforce note in the install check goes.

The Greptile prerequisites (greploop available, Greptile installed) move to the
greploop phase. A minor change must not block on them.

### 3. Codex loop (every change)

- Base: the PR's base branch, never a guessed default.

  ```bash
  BASE=$(gh pr view <PR> --json baseRefName -q .baseRefName)
  git fetch origin "$BASE"
  codex exec review --base "origin/$BASE" -o <scratch file>
  ```

  If the base does not resolve, that is a blocker. Do not substitute `main`.
- Scope: the PR branch. Commit each fix before the next pass so the review sees it.
- Triage every finding with shipit's existing "Validate every review finding"
  rules. Fix only validated Critical and Major defects. List the rest in the
  report.
- Run validation after each fix pass (existing "Verify changes" section).
- Stop when no valid Critical or Major finding remains, or after 5 passes.
- Commit fixes locally and push once, when the loop ends. On a repo that reviews
  every push, each push starts a paid Greptile review.
- If 5 passes end with valid Critical or Major findings, push the validated fixes,
  skip the size gate and greploop, and report "Blocked by review findings"
  (builder's call). A paid review of known defects is waste.
- If Codex fails mid-loop, that is a blocker.
- Unrelated user edits must not become findings. (Superseded: the prompt-argument
  approach first written here does not work. See "Implementation notes".)

### 4. Size gate (after the Codex loop, on the final PR diff)

Minor (builder's call, accepted by the user without change):

- 10 changed lines or fewer in total (added plus deleted), and
- no added, deleted, or renamed files, and
- nothing in a risky area: auth or permissions, security, secrets or config,
  data model or migrations, public API, dependencies or lockfiles, CI or build
  config.

Anything else is extensive. When in doubt, extensive. The user can override either
way ("run Greptile anyway", "skip Greptile").

### 5a. Minor path

Push, then report "Greptile skipped: minor change (<reason>)". Do not request a
Greptile review and do not wait for one. If the PR already has unresolved
Greptile threads (for example, from a review-on-push repo), list them as
remaining items. Then the status cannot be "Ready to merge".

### 5b. Extensive path

Check the Greptile prerequisites (existing: greploop available, Greptile
confirmed), then run greploop with shipit's existing overrides. These lessons
from `ship-ready-pr-loop` are new:

- **Reuse a current review.** Before every greploop pass:
  1. If local `HEAD` is not the PR's `headRefOid`, push and start the check again.
  2. If a Greptile check run exists on `HEAD_SHA` and is `queued` or
     `in_progress`, do not request a review. Let greploop wait, then check again.
  3. A completed Greptile check run that is not `success` is not a review.
  4. Reuse when a Greptile summary (PR body, or the most recently updated Greptile
     PR comment that has a score) shows a confidence score and its
     `Last reviewed commit` link ends in `HEAD_SHA`. Tell greploop to read those
     results and not post `@greptile review`.
  5. Otherwise request a new review. Right after a push, first recheck every 10
     seconds for up to 2 minutes: a running check run (rule 2) or a summary for
     `HEAD_SHA` (rule 4) means an automatic review exists, so do not request one.

     Known limit (builder's call): on a repo that reviews every push and has no
     check run, nothing shows until the summary posts. A review that takes over 2
     minutes then gets a duplicate request. shipit does not try to detect the repo's
     review mode. The fix is Greptile's manual-only setting (see below).

  The check keys on the summary, not on a check run. shipit's 2026-10-13 spec
  found that Greptile-reviewed PRs often have no check run. Paginate all API reads.
- **One review per fix batch.** Request the next review only after every fix for
  the current findings is committed, pushed, and validated. Never one per commit.
- **Pass limit.** At most 5 greploop passes. A pass that reuses a review counts.
- **Timeout.** greploop polls the Greptile check run and times out after about 10
  minutes. Many repos have no check run. On a timeout, run the reuse check. If a
  summary for `HEAD_SHA` exists, read it and continue. If not, it is a blocker.
  Never fall back to another reviewer for this phase.
- Run greploop as a skill, never as a shell command.
- Do not claim 5/5 unless the latest run shows it for `HEAD_SHA`.

### 6. Report

Keep the existing completion report. Add:

- Review path: minor (with the reason Greptile was skipped) or extensive.
- Codex passes.
- Greptile passes, final score, and how many passes reused a review.

## Repository changes

- Delete `skills/coding/ship-ready-pr-loop/`. Its specs and plans stay as history.
- Remove it from `skills.sh.json` and README's Coding table. Rewrite the `shipit`
  README row for the new flow.
- AGENTS.md lists `ship-ready-pr-loop` among the skills that run `codex`. Replace it
  with `shipit`.
- `shipit` description: drop the "Use ship-ready-pr-loop instead" clause. Mention
  Codex and the size gate. Absorb the old trigger phrasings ("harden this change",
  "get this ready to ship"). Keep `description: >-`.
- `shipit` version 0.1.1 → 0.2.0 (new capability).
- One PR, two commits in the order the user asked for: (1) the greploop cost and
  safety rules, (2) PR at start, Codex loop, size gate, deletion and listings, and
  the version bump.

## Consequence for the user to know

shipit cannot stop a paid review that the repo starts on its own. If Greptile
reviews every push, opening the PR or the single push at the end of the Codex loop
starts one, even for a minor change. The lever is Greptile's own setting
(manual-only reviews, `"autoReview": []`), not this skill.

## Out of scope

- Editing the third-party greploop skill.
- The Greptile lessons file. Commit 2168598 removed it on its own merits.
- Any reviewer other than Codex and Greptile.
- Merging, deploying, releasing (unchanged).

## Validation

shipit has no test suite. Run `bash scripts/check-frontmatter.sh`. Spot-check the
reuse-check `gh` queries read-only against a real Greptile-reviewed PR (this repo's
PR #52) so the field names match what `gh` returns. Run `bash -n` on each extracted
bash snippet. Codex and greploop are not run live in this change.

## Implementation notes (verified 2026-10-17)

- codex-cli 0.162.1 rejects `--base` with a prompt: "the argument '--base
  <BRANCH>' cannot be used with '[PROMPT]'". shipit passes no prompt.
- Codex's base-branch review diffs the merge base against the working tree, so
  it reads uncommitted edits to tracked files. A local edit could hide a
  committed defect, so shipit runs Codex in a temporary worktree at `HEAD`
  (Greptile finding on PR #53).
- The reuse check trusts only sources Greptile wrote: a check run whose app is
  `greptile-apps`, and comments by `greptile-apps[bot]`. The PR author can edit
  the description, so a description score counts only when the latest entry in
  its edit history (`userContentEdits`) is by `greptile-apps`. A check run does
  not authenticate the description text (Greptile and Codex findings on PR
  #53). Greptile marks a review below the repository's score threshold as
  `failure` (check title "Confidence 1/5 — below your required 3/5"), so
  `failure` is still a review.
- Codex's exit status must survive the worktree cleanup (Greptile and Codex
  findings on PR #53). The live Codex run on PR #53 worked end to end in a
  temporary worktree.
- `gh pr view` returns merged and closed PRs (`"state":"MERGED"` for PR #52).
  shipit requires `OPEN`, and requires the local branch to contain the PR head
  (`git merge-base --is-ancestor`).
- The size gate shows raw `--numstat` and `--name-status` output, not a summed
  count. `--numstat` prints `-` for a binary file, and a sum would count it as 0.
  A binary file is not minor.
- The plan's Codex snippet (with a prompt) and its `awk` sum were replaced by the
  above during the build.
