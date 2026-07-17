---
name: git-merge-origin-main
description: Use when the user asks to merge the latest origin/main into the current working branch, update or sync a feature branch from remote main, or handle conflicts from that merge; not for rebases or while on main.
---

# Git Merge Origin Main

Safely bring the latest `origin/main` into the current non-main branch without disturbing unrelated work.

## Preconditions

Before fetching or merging:

1. Confirm the current directory is a Git worktree.
2. Confirm the current branch is neither `main` nor detached HEAD.
3. Stop if a merge, rebase, cherry-pick, or revert is already in progress.
4. Run `git status --short`, which includes staged, unstaged, and untracked changes.
5. If it prints anything, stop and show the status. Do not fetch or merge. Ask the user to make the tree clean or explicitly request a separate handling strategy.

Never stash, commit, reset, clean, restore, or discard changes automatically.

## Workflow

1. Run all precondition checks above.
2. Fetch the latest remote refs with `git fetch origin`.
3. Verify the remote-tracking ref `refs/remotes/origin/main` exists. Stop with a clear error if it does not.
4. Merge `origin/main` into the current branch with `git merge origin/main`.
5. If the merge succeeds, verify `git status --short --branch` and summarize the result.
6. If conflicts occur, stop and list the conflicted files. Ask whether the user wants help resolving them or wants to abort.

## Rules

- Never merge into `main` unless the user explicitly asks for that different operation.
- Never substitute local `main` for `origin/main`.
- Require a completely clean working tree before fetching or merging.
- Do not auto-stash or auto-commit unrelated work.
- Do not resolve, stage, continue, commit, or abort a conflicted merge without explicit user direction.

## Commands

```bash
git rev-parse --is-inside-work-tree
git branch --show-current
git status --short
git fetch origin
git show-ref --verify --quiet refs/remotes/origin/main
git merge origin/main
git status --short --branch
```

Use `git rev-parse --git-path` to locate Git operation state files and directories before starting:

```bash
git rev-parse --git-path MERGE_HEAD
git rev-parse --git-path rebase-merge
git rev-parse --git-path rebase-apply
git rev-parse --git-path CHERRY_PICK_HEAD
git rev-parse --git-path REVERT_HEAD
```

If any corresponding path exists, stop and report the in-progress operation.

## Conflict handling

If merge conflicts occur:

1. Run `git status --short`.
2. List conflicted files with `git diff --name-only --diff-filter=U`.
3. Leave the repository in its current conflict state.
4. Ask whether the user wants help resolving the conflicts or wants to abort.
5. Only after explicit direction, use the appropriate next action such as `git merge --continue` or `git merge --abort`.

## Response style

Keep output short:

- current branch
- whether the tree is clean
- whether fetch and merge succeeded
- conflicted files, if any
- exact next action when user intervention is needed
