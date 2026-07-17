# `git-merge-origin-main` Skill Design

## Goal

Add the supplied `git-merge-origin-main` skill to this repository while tightening its safety around dirty working trees and preserving its focused purpose: merging the latest `origin/main` into the current non-main branch.

## Repository integration

- Place the skill at `skills/coding/git-merge-origin-main/SKILL.md` because it guides a coding-agent Git workflow rather than provisioning infrastructure.
- Add `git-merge-origin-main` to the Coding grouping in `skills.sh.json`.
- Add a concise row to the Coding table in `README.md`.
- Replace the supplied unsupported `summary` frontmatter field with the required `description` field. Keep the folder name and frontmatter `name` identical.

No scripts, references, assets, or product-specific `agents/openai.yaml` metadata are needed because the skill is self-contained and this repository does not use `agents/openai.yaml` for its existing skills.

## Safety behavior

The skill must inspect repository state before any fetch or merge:

1. Confirm the current directory is a Git worktree.
2. Stop if the current branch is `main` or detached.
3. Stop if a merge, rebase, cherry-pick, or revert is already in progress.
4. Check tracked, staged, and untracked changes with `git status --short`.
5. If any entry is present, stop and show the status. Do not fetch, merge, stash, commit, reset, clean, or discard anything. Tell the user to make the tree clean or explicitly request a separate handling strategy.

After those gates pass, fetch `origin`, verify `origin/main` exists, and merge `origin/main` into the current branch. Do not substitute local `main`.

If the merge conflicts, stop, list the conflicted files, and leave the repository in the merge-conflict state. Ask whether the user wants help resolving the conflicts or wants to abort. Do not resolve, stage, commit, continue, or abort without explicit direction.

## Output contract

Report only the current branch, clean/dirty state, fetch and merge result, conflict files when present, and the exact next action when user intervention is required.

## Verification

- First confirm the supplied frontmatter fails the required-field check because it has `summary` instead of `description`.
- Run the canonical skill validator on the installed skill when its dependency is available, plus dependency-free checks for frontmatter, folder/name consistency, README registration, manifest validity, and manifest/category agreement.
- Review the final diff and confirm no unrelated files changed.

Behavioral forward-testing with subagents is out of scope because this task did not authorize delegation. The static safety contract is therefore explicit enough to audit directly.
