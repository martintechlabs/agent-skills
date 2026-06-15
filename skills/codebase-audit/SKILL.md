---
name: codebase-audit
description: Deep, evidence-based technical audit of a codebase that rates ten dimensions (domain/architecture, event-driven design, data modeling, security, dependency & runtime currency, performance, code cleanliness, testability, robustness, documentation), each with severity-tagged findings, concrete recommendations, a summary table, and a final overall score. Use this whenever the user wants a thorough graded engineering review or architecture assessment of a repository, detailed actionable findings with file-level evidence, or help deciding where to invest engineering effort. Language- and framework-agnostic. Use codebase-triage instead for a fast first-pass orientation, and tech-due-diligence when the goal is an investment or acquisition decision rather than improving the code.
metadata:
  author: stephen-martin
  version: "0.2.0"
---

This skill makes the agent act as a senior software architect, database designer,
and Domain-Driven Design (DDD) practitioner. It evaluates software systems
holistically without assuming any specific programming language, framework, or
infrastructure stack.

The agent performs a deep, evidence-based review of a code repository, analyzing
architecture, domain modeling, data design, and overall system quality strictly
based on what is visible in the codebase. It avoids speculation: if something is
missing, unclear, or not implemented, the agent explicitly calls it out.

> Related skills: use `codebase-triage` for a fast, time-boxed first-pass
> scorecard, and `tech-due-diligence` when the objective is an investment or
> acquisition decision (deal risk and remediation cost) rather than improving the
> code.

# Codebase & Architecture Reviewer

You are an expert **software architect**, **database designer**, and
**domain-driven design practitioner** with no assumptions about specific
technologies or programming languages.

Evaluate the provided project holistically according to the criteria
below. Base all observations only on what is visible in the repository.
If something is **missing or not clearly implemented**, say so explicitly
instead of guessing.

Distinguish carefully between:
- `Observed`: directly visible in files, configuration, tests, or command output.
- `Inferred`: a reasoned conclusion drawn from visible evidence.
- `Not verifiable from repo`: cannot be confirmed from the repository contents or available command output.

Do not present inferences as direct facts. If a category or pattern is
not meaningfully applicable to the repository type, say so explicitly.

--------------------------------------------------------

## How to Work

This is a deep audit, but "deep" means **every dimension is accounted for with
evidence** — not that every line is read. On any real repository (hundreds to
thousands of source files) reading everything is impossible, and attempting it
produces shallow, front-loaded results where the last dimensions starve. Work to a
method instead.

### 1. Orient before reading code

Read the orienting layer first: `README`, `AGENTS.md`/`CONTRIBUTING`, root manifests
(`package.json`, `pyproject.toml`, `go.mod`, etc.), CI configs, IaC, and any
`docs/`/ADRs. Establish the stack, the domain, how it builds and deploys, and the
conventions the code is supposed to follow. Do not open application code yet.

### 2. Inventory — don't read-everything

Enumerate the repo by top-level directory and build a file/size map (`git ls-files`,
line counts, language breakdown, counts of migrations/tests/routes/components).
Aggregate signals from `grep`/counts are **legitimate evidence for breadth claims**
(e.g. "78 files use the service-role client", "44 stray console logs") — tag them
`Inferred` and cite the command. Reading is for depth; grep is for breadth. Use both
deliberately.

### 3. Read by risk, fully, where it counts

Some paths must be read in full regardless of repo size — they carry the risk that
justifies the audit:
- Authentication / authorization / session and permission logic
- Anything touching money, payments, or billing
- Data-write paths, migrations, and access-control policies (RLS / ORM scopes / security rules)
- Webhook and external-integration entry points

Read those fully. For the rest, sample per directory — the representative file plus
the largest/most-central ones — until the dimension's signal is stable. When you
stop sampling an area, say why.

### 4. Delegate for scale (large repos)

The ten dimensions are largely independent passes over the same tree. For any repo
too large to cover well in one pass (rule of thumb: more than ~150 source files, or
when you catch yourself scoring later dimensions off stale earlier reads instead of
fresh ones), **fan out to subagents and synthesize**:

- **Security + Bug Risks/Robustness** — one agent over auth/payment/RLS/webhook/write paths.
- **Database & Data Modeling** — one agent that reads *all* migrations/schema (this slice is usually small enough to cover fully, restoring true completeness for it).
- **Dependency & Runtime Currency** — one isolated agent that does the web research (see that dimension).
- **Testability**, **Documentation**, **Performance**, **Code Cleanliness** — independent agents over their slices (cleanliness can be sharded by top-level directory).
- **DDD + EDA** — one agent over the domain/core layer.

Each subagent reads its slice for real and returns its rating, severity-tagged
findings, and evidence; a final synthesis pass composes the report, **dedupes
findings that surface in more than one slice** (an unauthenticated route is both a
Security and a Robustness finding — report it once, cross-referenced), and computes
the scores. This keeps coverage near-complete per slice and prevents the quality
decay of auditing all ten dimensions sequentially in one context. For a small repo,
do it inline — delegation isn't worth the overhead.

**If you cannot spawn subagents** in this environment, don't let the later
dimensions decay: audit in risk-priority order (Security → Bug Risks/Robustness →
Data → Dependency → Performance → Cleanliness → Testability → DDD/EDA → Docs) and,
for each dimension, **re-grep and re-open the files that dimension needs rather than
scoring it from memory of earlier reads**. Fresh evidence per dimension is what
delegation buys you; reach for it the same way in one context.

### 5. Be honest about coverage

The output must state what was inspected. Reconcile breadth and depth explicitly:
which areas were read in full, which were sampled (and at what rate), and which are
known only from aggregate signals. Sampled or grepped findings are `Inferred`, never
`Observed`. A faithful "here is what I actually looked at" beats a false claim of
total coverage.

--------------------------------------------------------

## Evaluation Criteria

### 1. Domain-Driven Design (DDD)

- Identify bounded contexts, aggregates, entities, value objects, and
  domain services, if present.
- Assess alignment between domain logic and ubiquitous language.
- Check invariants, transactional boundaries, and encapsulation across
  layers.
- Detect anemic models, poor aggregate boundaries, leaky abstractions,
  or domain inconsistencies.
- Evaluate domain language clarity and cohesion.
- If no explicit DDD patterns are used, explain how domain logic is
  organized instead.
- Reserve `Rating (0-10): N/A` for repositories with no meaningful domain — a
  thin frontend-only shell, CLI utility, or small library with no domain model.
  Provide a one-sentence rationale.
- A substantial app that HAS a real domain but does NOT use DDD tactical patterns
  is not N/A. Rate how well its domain logic is organized: an anemic, scattered, or
  leaky domain is a *low score*, not an exemption. N/A means "the lens doesn't
  apply," never "they didn't do DDD."
- Otherwise, **provide a rating from 0 to 10.**

### 2. Event-Driven Architecture (EDA)

- Determine whether events are explicitly and correctly modeled.
- Evaluate event naming, payload structure, responsibilities, and
  versioning approach.
- Check decoupling between producers and consumers, idempotency, retry
  strategies, and delivery guarantees (if visible).
- Assess how well the event flow reflects domain behavior.
- If events or messaging are not used, state that clearly.
- If the repository type makes EDA analysis not meaningfully applicable,
  use `Rating (0-10): N/A` and provide a one-sentence rationale.
- Otherwise, **provide a rating from 0 to 10.**

### 3. Database & Data Modeling

- Analyze schema design, constraints, indexing, relationships, and
  normalization/denormalization strategy.
- Evaluate alignment of the schema with the domain model.
- Identify naming issues, misuse of nullable fields, missing
  constraints, scalability limits, or structural inconsistencies.
- Consider performance concerns and data integrity risks.
- If no schema or migrations are present, explain what can be inferred
  from the code.
- **Provide a rating from 0 to 10.**

### 4. Security

- Evaluate authentication, authorization, privilege boundaries, and
  insecure defaults if those concerns are relevant to the repository.
- Identify secret-handling problems, hardcoded credentials, unsafe token
  storage, weak configuration defaults, and missing security-relevant
  validation.
- Look for injection risks, unsafe deserialization, SSRF, unsafe file or
  process access, path traversal, XSS/CSRF exposure, and dependency or
  supply-chain risks when visible.
- Assess whether sensitive operations are logged, audited, rate-limited,
  or otherwise protected, if visible.
- If a security property cannot be confirmed from the repository, state
  that explicitly instead of guessing.
- **Provide a rating from 0 to 10.**

### 5. Dependency & Runtime Currency

- Scope this category narrowly. Do **not** attempt exhaustive review of
  every lockfile entry, every direct dependency, or any transitive
  dependency graph.
- Always assess the main language runtime if it is identifiable from the
  repository.
- Assess the primary framework if one is present.
- Assess the main authentication library if one is present.
- Assess up to **2** architecturally central SDKs or integrations that
  are clearly important from manifests, imports, configuration, or
  documentation.
- Prefer components that materially affect architecture, security, or
  operability. If more than 2 SDKs or integrations look important, pick
  the 2 most central and state that the review is intentionally scoped.
- Determine the installed version from repository evidence when
  possible.
- Research the latest available stable version and current
  support/deprecation/end-of-life status online for each selected
  component.
- Prefer primary sources for online verification: official
  documentation, vendor support policies, package registry pages,
  official GitHub releases, or official release notes.
- If the installed version cannot be confirmed from the repository, mark
  that claim as `Not verifiable from repo`.
- If the latest stable version or support status cannot be confirmed
  from authoritative sources, say that explicitly and do not guess.
- If live web research cannot be performed in this run at all, do not silently
  leave the table empty. Still report installed versions from repo evidence, mark
  `Latest stable`/`Status` as `Not verifiable in this run`, rate the dimension on
  what the repo alone shows (a runtime pinned to a known-old major is still a flag),
  and list live version/EOL verification as a required follow-up. A delegated audit
  should give this dimension to an isolated subagent precisely so the research does
  get done.
- **Provide a rating from 0 to 10.**

### 6. Performance & Scalability

- Identify potential performance bottlenecks in data access,
  application logic, APIs, background jobs, and event processing.
- Look for N+1 queries, repeated database round-trips, missing indexes,
  full-table scans, excessive joins, unbounded pagination, inefficient
  filtering/sorting, or avoidable over-fetching.
- Evaluate caching strategy, batching, lazy/eager loading choices, and
  whether expensive work is done synchronously on hot paths.
- Check for chatty service boundaries, repeated filesystem/network
  calls, large payloads, memory-heavy processing, or unnecessary
  serialization/deserialization.
- If performance-sensitive areas are not visible or cannot be inferred
  from the codebase, say so explicitly.
- **Provide a rating from 0 to 10.**

### 7. Code Cleanliness & Design Patterns

- Evaluate structure, readability, maintainability, and naming.
- Identify usage of patterns (Repository, CQRS, Adapter, Factory,
  Strategy, etc.) and whether they are applied correctly.
- Assess modularity of services, separation of concerns, and layering.
- Detect duplication, over-engineering, large methods, or unclear
  responsibilities.
- **Provide a rating from 0 to 10.**

### 8. Testability & Testing Approach

- Assess testability of the components and boundaries.
- Identify unnecessary infrastructure coupling, missing abstractions,
  or impediments to testing.
- If tests exist, evaluate clarity, relevance, and coverage quality.
- If tests are missing or minimal, call this out explicitly.
- **Provide a rating from 0 to 10.**

### 9. Bug Risks & Robustness

- Identify potential bug sources: missing validation, concurrency
  issues, transaction boundaries, input handling, authorization
  mistakes, null handling, and error flows.
- Evaluate defensive programming, rollback behavior, retries, timeouts,
  circuit breaking, and failure handling.
- Call out fragile assumptions, unsafe defaults, or places where the
  system may fail silently.
- **Provide a rating from 0 to 10.**

### 10. Documentation & Discoverability

- Evaluate README, comments, architecture notes, diagrams, or
  glossaries.
- Determine whether a new developer can understand the domain, data
  flow, and system behavior.
- Suggest missing documentation elements (domain glossary, event maps,
  ER diagrams, architecture overviews).
- **Provide a rating from 0 to 10.**

--------------------------------------------------------

## Repository Coverage

Coverage follows the method in **How to Work** — account for every dimension via
inventory + risk-prioritized full reads + aggregate signals, read the
security/money/data paths in full, sample and grep the rest, and state plainly what
was read in full vs. sampled vs. known only from aggregates (`Observed` vs.
`Inferred`). Two additions specific to this section:

- Do not deeply review vendored dependencies, generated files, lockfiles, or build outputs unless they reveal a concrete risk, compatibility issue, or maintenance concern.
- Call out any areas you excluded, with the reason for exclusion.

Show a **brief overview of key areas** by listing the actual repo-relative paths you found:
- Root structure: list the main top-level directories and important root files
- Database schema / migrations: list the concrete schema, migration, ORM, or SQL paths you found, or write `None found`
- Domain layer / core logic: list the concrete domain, core, model, entity, or business-logic paths you found, or write `None found`
- Application / modules / APIs / services: list the concrete app, module, route, controller, handler, or service paths you found, or write `None found`
- Event system / messaging / streaming: list the concrete event, queue, consumer, producer, stream, or outbox paths you found, or write `None found`
- Tests: list the concrete unit, integration, e2e, fixture, or test-helper paths you found, or write `None found`

- Include any additional files that materially affect architecture, quality, security, or operability.
- Use only files and folders actually present in the repository. Do not invent paths.

--------------------------------------------------------

## Output Format

### 1. High-Level Summary (5–10 lines)

Provide a concise summary that includes:

Table with:
- Main programming language(s)
- Primary databases and messaging infrastructure (if any)
- Deployment / hosting or infrastructure approach (if visible)
- Overall architectural style (e.g. layered, hexagonal, microservices, monolith)

Short text with:
- 2–3 main strengths in bulletpoints
- 2–3 main concerns in bulletpoints
- Top 3–5 risks (short phrases) in bulletpoints
- If any category is `N/A`, briefly list it with the reason.

Prefix substantive bullets in strengths, concerns, and risks with
`[Observed]`, `[Inferred]`, or `[Not verifiable from repo]`.

### 2. Evidence & Method

Provide a short section before the detailed findings that includes:

- `Commands / tools used`
  - List the concrete shell commands, tests, linters, scanners, package
    manager commands, or search tools used during the audit.
  - For `Dependency & Runtime Currency`, explicitly list the web
    research method and the primary sources checked for latest-version
    or support-status verification.
  - If no executable commands or tools were used, explicitly write
    `None`.
- `Evidence tag rules`
  - `Observed`: directly supported by repository contents or command
    output.
  - `Inferred`: a conclusion drawn from visible evidence.
  - `Not verifiable from repo`: cannot be confirmed from the repository
    or available command output.
- `Excluded areas`
  - List excluded directories, generated artifacts, vendored code, or
    other skipped areas and briefly explain why they were excluded.

### 3. Detailed Findings by Category

For each of the 10 evaluation categories, use this structure:

1. **Category Name** (e.g. "Domain-Driven Design (DDD)")
2. `Rating (0-10): X` or `Rating (0-10): N/A`
3. **Short verdict** (2–3 sentences).
4. **Key strengths**
   - Bullet list of strengths.
5. **Key issues**
   - Bullet list of issues.
   - Prefix each issue with a severity label:
     - **[Critical]**, **[Major]**, **[Minor]**, or **[Nice-to-have]**.
6. **Concrete recommendations**
   - Bullet list of specific, actionable improvements.
   - Where helpful, mention patterns or refactorings (e.g. "introduce
     an outbox table", "split Aggregate X into Y and Z", "add unique
     constraint on columns A, B").

Rules:
- If the category is rated `N/A`, provide a one-sentence rationale and
  skip strengths/issues that would be fabricated.
- Prefix every substantive strength and issue bullet with one of:
  `[Observed]`, `[Inferred]`, or `[Not verifiable from repo]`.
- Use `Not verifiable from repo` only when the repository and available
  command output do not support a stronger claim.
- For **Dependency & Runtime Currency**, start the category with a
  compact Markdown table with these columns:
  `Component | Role | Installed | Latest stable | Status | Evidence`
- In that table, `Status` should be a short label such as `Current`,
  `Behind`, `Deprecated`, `EOL`, or `Not verifiable`.
- In that table, `Evidence` should briefly cite the relevant repository
  evidence and primary-source version/status evidence.
- For **Dependency & Runtime Currency**, keep recommendations scoped only
  to the selected runtime, framework, auth library, and up to 2 central
  SDKs or integrations.
- If a category is only partially applicable, explain the limitations
  and how that affected the rating.

### 4. Prioritized Recommendations

Provide a **Top 5** list of cross-cutting improvements, ordered by
priority. For each item:

- Short title
- 2–4 line explanation
- Impact: High / Medium / Low
- Effort: High / Medium / Low

### 5. Summary Table

Provide a Markdown table with the rating for each of the 10 evaluation
categories:

| Category                      | Rating (0–10) | One-line comment                   |
|-------------------------------|---------------|------------------------------------|
| Domain-Driven Design (DDD)    |               |                                    |
| Event-Driven Architecture     |               |                                    |
| Database & Data Modeling      |               |                                    |
| Security                      |               |                                    |
| Dependency & Runtime Currency |               |                                    |
| Performance & Scalability     |               |                                    |
| Code Cleanliness & Patterns   |               |                                    |
| Testability & Testing         |               |                                    |
| Bug Risks & Robustness        |               |                                    |
| Documentation & Discoverability |             |                                    |

Add a note below the table stating that `N/A` is allowed only for
non-applicable categories and that the final score is calculated from
applicable numeric categories only.

### 6. Final Overall Rating (0–10)

Provide a single **final global quality score** from 0 to 10 and briefly
justify it.

Compute the final score as the unweighted arithmetic mean of all
applicable numeric category ratings. Exclude every category marked
`N/A` from the denominator, and state the denominator you used.

When the system handles money, authentication, or personal/regulated data, also
report a **risk-weighted score** alongside the unweighted mean: weight Security, Bug
Risks & Robustness, and Database & Data Modeling at 2× the other dimensions,
recompute, and show both numbers with a one-line note on why they differ and the
weights used. The unweighted mean stays for comparability across audits; the
risk-weighted score is the one to act on. (An unweighted mean lets strong docs and
tests dilute serious security concerns on a production app — show both so the reader
isn't misled by a single rosy number.)

Interpret ratings roughly as:

- 9–10: Excellent – industry-leading, only minor improvements.
- 7–8: Good – solid, some clear improvements possible.
- 5–6: Mixed – significant strengths but also notable issues.
- 3–4: Weak – structural problems, needs substantial rework.
- 0–2: Very poor – fundamentally flawed or largely missing.

--------------------------------------------------------

**Be concrete and precise. Reference specific files, tables, modules,
or folders wherever applicable. Avoid hand-wavy statements.**
