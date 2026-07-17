# `git-merge-origin-main` Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the supplied `git-merge-origin-main` skill with a strict clean-working-tree safety gate and register it in this repository.

**Architecture:** Keep the skill self-contained in one `SKILL.md` under the Coding category. Convert its unsupported `summary` metadata to a trigger-focused `description`, make all unsafe repository states explicit stop conditions, and update both repository indexes.

**Tech Stack:** Markdown, YAML frontmatter, JSON, Git CLI.

## Global Constraints

- Stop before `git fetch` or `git merge` whenever `git status --short` has any staged, unstaged, or untracked entry.
- Never auto-stash, commit, reset, clean, restore, or discard dirty-tree changes.
- Never merge into `main`, operate from detached HEAD, or start while another Git operation is in progress.
- Never resolve, stage, continue, commit, or abort a conflicted merge without explicit user direction.
- Use `origin/main`, never local `main` as a substitute.
- Do not commit or push repository changes unless the user explicitly asks.

---

### Task 1: Add and register the tightened skill

**Files:**
- Create: `skills/coding/git-merge-origin-main/SKILL.md`
- Modify: `README.md`
- Modify: `skills.sh.json`

**Interfaces:**
- Consumes: the supplied `/Users/smartin/Downloads/SKILL (3).md` workflow and this repository's Coding category conventions.
- Produces: a discoverable skill named `git-merge-origin-main`, a matching README row, and a matching Coding manifest entry.

- [ ] **Step 1: Run the frontmatter check against the supplied file and verify it fails**

Run:

```bash
ruby -e 'require "yaml"; text = File.read("/Users/smartin/Downloads/SKILL (3).md"); frontmatter = YAML.safe_load(text.match(/\A---\n(.*?)\n---/m)[1]); abort("Missing required description field") unless frontmatter.key?("description"); abort("Unexpected summary field") if frontmatter.key?("summary")'
```

Expected: exit 1 with `Missing required description field`.

- [ ] **Step 2: Create the skill with compatible metadata and hard safety gates**

Create `skills/coding/git-merge-origin-main/SKILL.md` with:

```markdown
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
```

- [ ] **Step 3: Register the skill in both indexes**

Add this Coding table row to `README.md`:

```markdown
| [`git-merge-origin-main`](skills/coding/git-merge-origin-main/SKILL.md) | Safely merges the latest `origin/main` into the current non-main branch, with hard stops for dirty working trees, in-progress Git operations, detached HEAD, and conflicts. |
```

Add `"git-merge-origin-main"` after `"optimize-agents-md"` in the Coding `skills` array in `skills.sh.json`.

- [ ] **Step 4: Validate the installed skill and repository integration**

Run the canonical validator when PyYAML is available:

```bash
python3 /Users/smartin/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/coding/git-merge-origin-main
```

Expected: `Skill is valid!`.

Also run dependency-free checks:

```bash
ruby -rjson -ryaml -e 'skill = "skills/coding/git-merge-origin-main/SKILL.md"; text = File.read(skill); fm = YAML.safe_load(text.match(/\A---\n(.*?)\n---/m)[1]); abort unless fm["name"] == File.basename(File.dirname(skill)); abort unless fm["description"].is_a?(String); manifest = JSON.parse(File.read("skills.sh.json")); coding = manifest["groupings"].find { |g| g["title"] == "Coding" }; abort unless coding["skills"].include?(fm["name"]); abort unless File.read("README.md").include?("skills/coding/#{fm["name"]}/SKILL.md"); puts "integration valid"'
git diff --check
```

Expected: `integration valid`, then no whitespace errors.

- [ ] **Step 5: Review scope without committing**

Run:

```bash
git status --short
git diff -- docs/superpowers/specs/2026-07-17-git-merge-origin-main-design.md docs/superpowers/plans/2026-07-17-git-merge-origin-main.md skills/coding/git-merge-origin-main/SKILL.md README.md skills.sh.json
```

Expected: only the design, plan, new skill, README row, and manifest entry are changed. Do not commit or push unless the user asks.
