# agent-skills

A collection of [Agent Skills](https://agentskills.io/) by [Martin Tech Labs](https://github.com/martintechlabs), published for use with Claude Code and other skill-aware AI agents.

[![skills.sh](https://skills.sh/b/martintechlabs/agent-skills)](https://skills.sh/martintechlabs/agent-skills)

## Install

Install every skill in this repo into your local agent:

```bash
npx skills add martintechlabs/agent-skills
```

Install a single skill:

```bash
npx skills add martintechlabs/agent-skills/<skill-name>
```

## Available skills

### codebase-triage

Rapid, time-boxed first-pass health check of an unfamiliar codebase. Produces a one-page scorecard: stack inventory, architecture sketch, a red/yellow/green health signal, top risks, and recommended next steps.

**Use when:**

- You've just been handed an unfamiliar repo and want a fast read on what it is and whether it's healthy
- You're onboarding to a client or legacy codebase and need orientation before going deep
- You want a quick health check before committing to a full audit

### codebase-audit

Deep, evidence-based technical audit of a codebase. Rates ten dimensions (architecture/DDD, event-driven design, data modeling, security, dependency currency, performance, cleanliness, testing, robustness, docs) with severity-tagged findings, prioritized recommendations, and an overall score.

**Use when:**

- You want a thorough, graded engineering review of a codebase
- You need detailed, actionable findings with file-level evidence
- You're deciding where to invest engineering effort to improve a system

### tech-due-diligence

Technical due diligence for investors, acquirers, or boards. Translates technical findings into deal risk and rough remediation cost — covering scalability, security/compliance, licensing/IP, maintainability, dependency/EOL risk, and key-person risk — ending in a clear recommendation.

**Use when:**

- You're evaluating a company's technology before investing in or acquiring it
- You need a non-technical-friendly risk write-up with a proceed/caution/walk recommendation
- You want to know roughly what it would cost to fix what's broken

### bug-class-audit

Quantify how systemic ONE specific bug class is in a codebase by classifying every recent fix-prefixed merged PR against explicit inclusion/exclusion criteria. Produces a headline percentage, a breakdown table, representative examples, patterns, and caveats — a number you can put in front of stakeholders instead of a vibe.

**Use when:**

- You suspect a specific pattern keeps recurring and want a defensible number
- You need to justify a refactor or initiative with evidence from PR history
- You want to replace "we keep shipping the same bug" with "19% of last 100 fix PRs are this class"

### weekly-risk-review

Whole-repository CRITICAL/HIGH-only risk pass with a prioritized walk order (auth → routes → webhooks → RLS → cron → integrations), a concrete anti-pattern catalog to scan against, and cross-reference checks for unfulfilled comment-promises. Outputs either a single weekly report or — when the user wants executable follow-up — an audit doc plus N remediation specs grouped by root cause.

**Use when:**

- You run a recurring weekly or pre-ship CTO-level risk check
- You want a small, prioritized fix list rather than a graded scorecard
- You need executable remediation specs grouped by root cause, not by file

### delivery-health

Evaluates how a team *ships* rather than what they built — the delivery and process signals in git history and GitHub. Measures review rigor, PR pickup and cycle time, PR size, CI health, branch protection, bus factor, rework/hotfix rate, and release cadence, anchored to DORA's four keys and scaled to team size, with every metric backed by a citable command. Renders a scorecard, a graded report, or a prioritized fix list, and degrades gracefully to git-only signals when GitHub isn't available.

**Use when:**

- You're a fractional/interim CTO assessing how healthy a team's delivery process is
- You want to know how well a team ships — review practices, velocity, CI reliability, release cadence — not whether the code is good
- You want reproducible delivery metrics you can re-run quarter over quarter

### evaluation-trend

Compares two evaluations of the same codebase over time and reports the trajectory — improving, declining, or measurement-dominated. Diffs the output of any of the other evaluation skills (audit, triage, delivery-health, weekly-risk-review, bug-class-audit) via two saved reports, a git-window diff, or a re-run at an old commit. Its discipline is comparability-first: it separates real change from method/measurement change before trusting any delta, and classifies findings as resolved, newly surfaced, persisting, or regressed.

**Use when:**

- You want to know how a codebase or team has changed since last quarter, not just its current state
- You're producing a retainer or board trajectory update and need direction plus drivers
- You're re-auditing and want to separate genuine improvement/regression from changes in how you measured

## Repository layout

```
agent-skills/
├── README.md          # This file
├── LICENSE            # MIT license
├── skills.sh.json     # skills.sh manifest (groupings, ordering)
└── skills/
    └── <skill-name>/
        ├── SKILL.md       # Skill definition (frontmatter + instructions)
        └── references/    # Optional supporting files the skill loads on demand
```

Each skill lives in its own directory under `skills/` and is defined by a single `SKILL.md` file with YAML frontmatter (`name`, `description`, optional `metadata`) followed by the instructions the agent should follow when the skill triggers.

## Adding a new skill

Each skill is a directory under `skills/` containing a single `SKILL.md`: YAML frontmatter followed by the Markdown instructions the agent follows when the skill triggers.

1. **Create the file** `skills/<skill-name>/SKILL.md`. Use a short, hyphenated `<skill-name>` (e.g. `codebase-audit`); it must match the `name` in the frontmatter.
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
4. **(Optional) Add supporting files** the skill loads on demand under `skills/<skill-name>/references/` (see `bug-class-audit`).
5. **List it** under **Available skills** above, mirroring the existing format (one-paragraph summary + a "Use when" list).
6. **(Optional) Group it** by adding the skill name to a grouping in `skills.sh.json`.
7. **Test it** by installing locally and confirming it triggers:

   ```bash
   npx skills add martintechlabs/agent-skills/<skill-name>
   ```

The `description` is the most important field for triggering: lead with what the skill does, then list the concrete situations and phrasings that should activate it. When skills overlap, say when to reach for this one versus the others.

## License

MIT
