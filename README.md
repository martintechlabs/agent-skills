# agent-skills

A collection of [Agent Skills](https://agentskills.io/) by [Martin Tech Labs](https://www.martintechlabs.com/), published for use with Claude Code and other skill-aware AI agents.

[![skills.sh](https://skills.sh/b/martintechlabs/agent-skills)](https://skills.sh/martintechlabs/agent-skills)

## Install

Install every skill in this repo into your local agent:

```bash
npx skills add martintechlabs/agent-skills
```

Install specific skills by name (comma-separate to install several):

```bash
npx skills add martintechlabs/agent-skills --skill <skill-name>
```

Add `-g` to install globally (user-level, available across all projects) instead of into the current project, and `-y` to skip the prompts:

```bash
npx skills add martintechlabs/agent-skills -g --skill consult-codex,codex-review -y
```

## Available skills

Skills are grouped into the same categories as the [`skills/`](skills/) directories.

### CTO toolkit

Evaluate and steer an engineering org straight from the repo.

| Skill | What it does |
|-------|--------------|
| [`codebase-triage`](skills/cto-toolkit/codebase-triage/SKILL.md) | Rapid, time-boxed health check of an unfamiliar codebase: stack inventory, architecture sketch, red/yellow/green signal, top risks, and next steps. |
| [`codebase-audit`](skills/cto-toolkit/codebase-audit/SKILL.md) | Deep, graded technical audit across ten dimensions, with severity-tagged, file-level findings, prioritized recommendations, and an overall score. |
| [`tech-due-diligence`](skills/cto-toolkit/tech-due-diligence/SKILL.md) | Investor/acquirer technical due diligence: turns findings into deal risk and rough remediation cost, ending in a proceed/caution/walk recommendation. |
| [`bug-class-audit`](skills/cto-toolkit/bug-class-audit/SKILL.md) | Quantifies how systemic one bug class is by classifying recent fix PRs into a defensible headline percentage with a breakdown and examples. |
| [`weekly-risk-review`](skills/cto-toolkit/weekly-risk-review/SKILL.md) | Recurring CRITICAL/HIGH-only risk pass with a prioritized walk order; outputs a weekly report or executable remediation specs grouped by root cause. |
| [`delivery-health`](skills/cto-toolkit/delivery-health/SKILL.md) | Evaluates how a team *ships* — review rigor, cycle time, CI health, cadence — against DORA's four keys, not whether the code is good. |
| [`evaluation-trend`](skills/cto-toolkit/evaluation-trend/SKILL.md) | Compares two evaluations of the same codebase over time and reports the trajectory, separating real change from measurement change. |

### Productivity

Everyday workflow helpers that make working with AI faster.

| Skill | What it does |
|-------|--------------|
| [`meta-prompt`](skills/productivity/meta-prompt/SKILL.md) | Turns a fuzzy intent into a sharp, reusable prompt by gathering the goal, the context, and examples of good output, then engineering the prompt for you. |
| [`critical-partner`](skills/productivity/critical-partner/SKILL.md) | Switches the agent into a constructive-disagreement thinking partner that pressure-tests your ideas and names weaknesses first instead of affirming you. |

### Coding

Skills the coding agent reaches for while working.

| Skill | What it does |
|-------|--------------|
| [`consult-codex`](skills/coding/consult-codex/SKILL.md) | Gets a second opinion from Codex (the OpenAI coding agent) when the agent is genuinely stuck or weighing competing technical approaches. |
| [`codex-review`](skills/coding/codex-review/SKILL.md) | Gets a second-opinion code review from Codex on a branch, PR, diff, or commit, then triages the findings on their merits. |
| [`ship-ready-pr-loop`](skills/coding/ship-ready-pr-loop/SKILL.md) | Drives a change from review findings to a ship-ready PR: fixes Critical/Major issues, then loops Greptile until it reaches 5/5. |
| [`optimize-agents-md`](skills/coding/optimize-agents-md/SKILL.md) | Audits and patches a repo's AGENTS.md for a fast, safe SDLC — reinforcing TDD, brainstorming, verification, and subagent dispatch — generating one from scratch only if none exists, and keeps CLAUDE.md as a one-line pointer to it. |

### DevOps

Skills for provisioning and wiring up development infrastructure.

| Skill | What it does |
|-------|--------------|
| [`conductor-neon-db`](skills/devops/conductor-neon-db/SKILL.md) | Sets up fully isolated per-workspace databases for Conductor — each workspace gets its own instant schema-only Neon branch (full schema, zero production data) with the ORM's migration history baselined (Prisma or Drizzle) and fixtures seeded, plus the `.conductor/settings.toml` that wires setup/run/archive. |
| [`github-lockdown`](skills/devops/github-lockdown/SKILL.md) | Locks down a GitHub repo — protects the default branch behind a required PR (0 approvers by default), blocks force-pushes and branch deletion, and auto-deletes merged branches — via GitHub repository rulesets and the `gh` CLI. Manual-only, idempotent, with a short interview and a `--dry-run` preview. |

## Repository layout

```
agent-skills/
├── README.md          # This file
├── LICENSE            # MIT license
├── skills.sh.json     # skills.sh manifest (groupings, ordering)
└── skills/
    └── <category>/        # Category directory, mirrors a skills.sh.json grouping
        └── <skill-name>/
            ├── SKILL.md       # Skill definition (frontmatter + instructions)
            └── references/    # Optional supporting files the skill loads on demand
```

Skills are organized into **category directories** under `skills/` — currently `cto-toolkit/`, `productivity/`, `coding/`, and `devops/`. Each skill lives in its own `<skill-name>/` directory inside a category and is defined by a single `SKILL.md` file with YAML frontmatter (`name`, `description`, optional `metadata`) followed by the instructions the agent should follow when the skill triggers.

The category directories **mirror the groupings in `skills.sh.json`** — that file remains the source of truth for how skills are grouped and ordered on the skills.sh page; the folders just make the same taxonomy visible when browsing the repo. Keep the two in sync: a skill's directory should sit under the category whose grouping lists it. Note that nothing tooling-side enforces this — the skills.sh CLI and the `--skill` flag resolve skills by their frontmatter `name`, not their path, so the category folder is purely organizational.

## Adding a new skill

Each skill is a directory under a category in `skills/` containing a single `SKILL.md`: YAML frontmatter followed by the Markdown instructions the agent follows when the skill triggers.

1. **Pick a category** under `skills/` (`cto-toolkit/`, `productivity/`, `coding/`, or `devops/`) — or add a new one if none fit, and create a matching grouping in `skills.sh.json` (step 6). **Create the file** `skills/<category>/<skill-name>/SKILL.md`. Use a short, hyphenated `<skill-name>` (e.g. `codebase-audit`); it must match the `name` in the frontmatter.
2. **Write the frontmatter.** `name` and `description` are required; `metadata` is optional but recommended:

   ```yaml
   ---
   name: my-skill
   description: One or two sentences on WHAT the skill does and, most importantly, WHEN to use it (the situations, phrasings, and keywords that should trigger it — and when to use a different skill instead).
   metadata:
     author: your-name
     version: "0.1.0"
   ---
   ```

3. **Write the instructions** below the frontmatter: be concrete about procedure, output format, and anti-patterns (follow the house style of the existing skills).
4. **(Optional) Add supporting files** the skill loads on demand under `skills/<category>/<skill-name>/references/` (see `bug-class-audit`).
5. **List it** under **Available skills** above, mirroring the existing format (one-paragraph summary + a "Use when" list).
6. **Group it** by adding the skill name to the matching grouping in `skills.sh.json` — the same category whose directory you placed it under. Folders and groupings should agree.
7. **Test it** by installing locally and confirming it triggers (use `--skill` to select by the frontmatter `name`, not a path — the CLI resolves skills by name regardless of which category directory they live in):

   ```bash
   npx skills add martintechlabs/agent-skills --skill <skill-name>
   ```

The `description` is the most important field for triggering: lead with what the skill does, then list the concrete situations and phrasings that should activate it. When skills overlap, say when to reach for this one versus the others.

## License

MIT
