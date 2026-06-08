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

### hello-world

A minimal skill used to verify that skills from this repo install and trigger correctly. Useful as a smoke test after installation.

**Use when:**

- You've just installed this repo and want to confirm skills are wired up
- You ask the agent to "say hello" or "test the hello-world skill"

## Repository layout

```
agent-skills/
├── README.md          # This file
├── skills.sh.json     # skills.sh manifest (groupings, ordering)
└── skills/
    └── <skill-name>/
        └── SKILL.md   # Skill definition (frontmatter + instructions)
```

Each skill lives in its own directory under `skills/` and is defined by a single `SKILL.md` file with YAML frontmatter (`name`, `description`, optional `metadata`) followed by the instructions the agent should follow when the skill triggers.

## Contributing

Adding a new skill:

1. Create `skills/<skill-name>/SKILL.md` with the required frontmatter.
2. Add an entry for it under **Available skills** in this README.
3. Optionally add it to a grouping in `skills.sh.json`.

## License

MIT
