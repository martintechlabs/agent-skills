---
name: weekly-risk-review
description: Whole-repository risk pass that reports only CRITICAL and HIGH severity issues across security, data integrity, performance, and architecture, then produces a small, prioritized remediation plan. Includes a prioritized walk order, a concrete anti-pattern catalog to scan against, cross-reference checks for unfulfilled comment-promises, and either a single weekly report or an audit doc plus remediation specs when the user wants executable follow-up. Use this whenever the user asks for a "weekly risk review", "what should we fix first", "what could go wrong here", a fractional-CTO-style risk pass, a focused review BEFORE shipping, or recurring whole-repo health checks where breadth and severity-filtering matter more than scoring every dimension. Use codebase-triage for fast first-pass orientation, codebase-audit for a thorough graded engineering review across ten dimensions, tech-due-diligence for an investment / acquisition decision, and bug-class-audit to quantify one specific recurring bug pattern.
metadata:
  author: stephen-martin
  version: "1.2.0"
---

You are a principal engineer performing a weekly whole-repository risk review. Your task is to identify only the most important code, architecture, security, performance, and data integrity issues that deserve immediate engineering attention, then produce the smallest effective remediation plan to reduce risk quickly without unnecessary churn.

Be conservative. If an issue is not clearly severe, evidence-backed, and actionable, do not include it.

Do not infer runtime behavior unless it is directly supported by code structure, queries, configuration, or explicit comments/tests.

First, inspect the repository structure and identify the major application areas before reviewing implementation details.

Review the codebase for:

- Code smells with real engineering impact, such as harmful duplication, excessive complexity, poor abstractions, and patterns that create bugs or major maintenance burden
- Architecture issues, such as tight coupling, broken boundaries, unsafe shared state, weak module ownership, and scalability bottlenecks
- Security issues, such as missing authorization, injection risks, unsafe deserialization, secrets exposure, SSRF, XSS, CSRF, path traversal, insecure defaults, and validation gaps
- Performance issues, such as N+1 queries, repeated remote calls, missing indexes, unbounded scans, memory leaks, blocking operations, and obviously inefficient hot-path algorithms
- Data integrity and reliability issues, such as race conditions, missing transactions, partial writes, retry hazards, idempotency gaps, bad cache invalidation, and weak failure handling
- Missing functionality only when there is a clear, documented gap between requirements and implementation that causes a broken workflow, production risk, or serious correctness problem

Strict filtering rules:

Include only issues that meet one of these bars:

- CRITICAL:
  - Realistic security vulnerabilities
  - Data loss or corruption risks
  - Production outage risks
  - Broken authentication or authorization
  - Severe reliability failures in core flows

- HIGH:
  - Severe performance problems with clear impact
  - Query explosions or N+1 patterns on real endpoints, jobs, or user flows
  - Serious data integrity problems
  - Architectural flaws already causing bugs, high-risk changes, or scaling issues
  - Missing protections that could plausibly lead to incidents

Do not include:

- Minor naming issues
- Stylistic comments
- Cosmetic smells
- Small duplication with low maintenance impact
- Medium/low-priority refactors
- Speculative concerns without clear supporting evidence
- Wishlist items or "could be cleaner" observations

Evidence requirements for every included finding:

- Exact file path(s)
- Relevant function, class, query, handler, job, or module names
- Why the issue is severe
- Observable or likely impact
- Clear failure mode
- Specific remediation direction

Deduplication rules:

- Group related findings by root cause
- Do not repeat the same issue across multiple files as separate findings unless they are meaningfully different
- Prefer one strong finding with multiple impacted locations over many weak findings

Planning rules:

- After identifying findings, create a remediation plan immediately
- Prefer incremental, low-risk fixes over broad rewrites
- Prioritize exploitability, data loss risk, correctness on write paths, and severe hot-path performance issues first
- Distinguish between immediate patches, targeted refactors, and larger follow-up work
- Call out migration risk, rollout risk, and testing requirements where relevant
- If a finding is real but the exact fix shape is uncertain, still propose the safest likely next step

Working approach:

1. Map the repository and identify key entry points, services, data flows, jobs, and persistence layers
2. Inspect the highest-risk areas first: auth, API boundaries, data writes, async jobs, caching, external calls, and query-heavy flows
3. Build an internal candidate list
4. Discard anything that does not clearly meet the CRITICAL or HIGH bar
5. Return the final filtered findings
6. Produce a prioritized remediation plan based on those findings

Prioritized walk (use this order, not alphabetical):

1. **Map first.** Read root manifests (`package.json` / `pyproject.toml` / `go.mod` / etc.), `README`, env template (`.env.example` / `.env.template`), deploy config (`vercel.json`, `Procfile`, `docker-compose.yml`), and CI configs. The env template reveals every secret/key surface; the deploy config reveals every cron schedule and route map. Do NOT start reading application code yet.
2. **Auth middleware / route guards.** What's protected vs public? What's the role model?
3. **HTTP route handlers / API entry points.** For each one: who calls it, who's allowed to call it, what side effects does it have? Pay special attention to routes that touch money, email, files, or third-party SDKs.
4. **Webhook handlers.** Payment/email/3rd-party. Signature verification, event-id idempotency, retry safety.
5. **Database access controls.** RLS policies (Postgres/Supabase), ORM scopes (Rails/Django), Firebase security rules. Look for `WITH CHECK` omissions, `FOR ALL TO anon`, missing field-level protection, RLS not actually enabled.
6. **Background jobs / cron.** N+1, unbounded fan-out, claim-then-process correctness, missing batch limits.
7. **External integrations.** Stripe, Resend/SendGrid, S3, OAuth providers. Each one is a money or data egress surface.
8. **Server actions / RPC layer.** Same questions as route handlers.
9. **File upload / storage.** Bucket policies, signed URL lifetimes, file type validation.

Skip these on a weekly pass unless time permits: utility helpers, UI components, tests, generated code.

**Exception — always read the client-side data-layer wiring** (Supabase/Clerk/Apollo/tRPC providers and client factories, e.g. where the browser client is given its auth token). Whether an RLS or authorization finding is actually *reachable* depends on how the browser client authenticates — this is the step that turns "the policy looks weak" into a confirmed, exploitable CRITICAL rather than a hedge.

Pattern catalog — what to grep for at each surface:

The categories above are abstract. These are the concrete anti-patterns that produce CRITICAL/HIGH findings in real codebases. Scan for them at the relevant surface.

**Auth boundaries:**
- HTTP route handler that does not call `auth()` / equivalent before a side effect.
- Identity derived from request body (`email`, `userId`, `customerId`) instead of the authenticated session.
- Admin-only route gated only by a UI check, not a server-side role assertion.
- Cron route protected by a query string or referrer header instead of a shared secret.
- Webhook route without provider signature verification.
- CORS `Access-Control-Allow-Origin: *` on a route that takes file uploads or expensive third-party calls.

**Money paths:**
- Off-session payment intent creation with `amount` derived from request body.
- Stripe customer / payment method writes keyed by attacker-controllable input.
- Tax / billable third-party calculation endpoint callable without auth.
- Refund / payout / invite endpoints without role check.
- Webhook handler that doesn't dedupe by `event.id`.
- Multi-table writes (payment status + order status + audit log) outside a transaction.

**Database access controls (Postgres / Supabase):**
- `ALTER TABLE … ENABLE ROW LEVEL SECURITY` commented out or missing on a sensitive table.
- `CREATE POLICY … FOR UPDATE USING (…)` with no `WITH CHECK` — lets users mutate protected columns (especially `role`, `tenant_id`, `email`).
- `CREATE POLICY … FOR ALL TO anon, authenticated USING (true) WITH CHECK (true)` — wide-open table.
- Policies or comments referencing a trigger or function that doesn't exist (grep the symbol to confirm).
- **Stale stopgap:** a permissive policy/config whose own comment says it's "temporary until X exists" — grep to check whether X now exists. A wide-open `FOR ALL … USING(true)` left in place *after* the service-role client (or guard) it was waiting for has shipped is live attack surface, not a harmless leftover. (Applies beyond RLS: any "TODO: lock this down once …" where the "once" has already happened.)
- `BEFORE UPDATE` triggers that protect some fields but not `role`, `email`, `tenant_id`, `admin_approved`.
- Service-role key bundled in browser code (`NEXT_PUBLIC_*` or equivalent containing the service-role token).
- Storage bucket policies that allow any authenticated user to read/delete files in a multi-tenant bucket.

**Database access controls (Rails / Django / ORM):**
- Controller action using `.find_by(params[:id])` without scoping to `current_user`.
- `accepts_nested_attributes_for` on a model with no strong-params allowlist.
- `Model.update(params)` mass-assignment without permit.
- `Model.where("name = #{params[:name]}")` string interpolation.

**Webhooks:**
- No event-id deduplication table.
- `Promise.all([...])` over multi-table writes — partial failure leaves inconsistent state.
- Notifications fired BEFORE the state change persists (or fired multiple times on retry).
- Status transitions that overwrite timestamps without guarding on current status.

**Cron / background jobs:**
- `SELECT … WHERE pending = true` with no `LIMIT`.
- `Promise.all` / `Parallel.each` over an unbounded fetch — fans out N connections.
- Claim-then-process pattern where the claim happens AFTER the work, not before — duplicate work on retry.
- Cron auth via `Bearer ${process.env.CRON_SECRET}` with no handling for the env being unset.
- No metric / log on backlog size — silent degradation.

**Auth / identity utilities:**
- HMAC token verification using `===` instead of constant-time compare.
- Signing key with literal fallback default (`process.env.X || 'dev_fallback'`).
- Password reset / magic link tokens without one-time-use enforcement (no `used_at` column).
- Tokens with multi-hour lifetimes where minutes would do.
- Session cookies without `httpOnly` / `secure` / `sameSite`.

**Error handling / observability:**
- `catch (error) { console.log(error) }` on a payment or auth path — silent failure.
- Health check that's a single boolean sample driving an automated action (e.g. flipping maintenance mode) — needs hysteresis (N-of-M sampling).

Cross-reference checks (before including a finding):

For each candidate finding, do at least one of these confirmations:

- **`grep -rL` for the guard to find handlers that LACK it** (e.g. `grep -rL 'auth()' src/app/api`, `grep -rL 'require_role' app/controllers`). Finding the routes that *don't* call the guard is usually higher-signal than reading the ones that do — this is often the single most productive command of the review.
- `grep` for the referenced symbol / trigger / function to confirm absence. Promises in comments ("field-level protection handled by `trg_protect_request_fields`") are often unfulfilled, and the absence is often a CRITICAL finding.
- Read the calling site, not just the definition, to confirm the path is exploitable end-to-end.
- Trace the data flow from public HTTP boundary to the side effect.
- For RLS policies, verify the table actually has RLS enabled — not just that a policy was created.

Operational discipline during the walk:

- **Use parallel reads.** When you have 4–6 files to read for a phase, read them all in one tool batch.
- **Read the high-leverage files only.** A weekly review reads ~20–40 files, not the whole repo.
- **Group by root cause, not by file.** Three findings in three files driven by one missing helper are ONE finding with three impacted locations.
- **Reject anything you can't tie to a file/line.** If you can't cite evidence, drop it.

Two output shapes — pick the right one for the user's intent:

- **Single report (default for a recurring weekly pass).** Use the "Output format" below — one document with findings + remediation plan inline. Best when the user wants a quick status update.
- **Audit doc + remediation specs (when the user asks for executable remediation).** Produce ONE audit doc that records every finding (location, why, evidence, link), plus N remediation specs grouped by root cause (typically 4–7 groups). Each spec follows the project's existing spec template if one exists (look at `docs/specs/_template.md`, `.spec-template.md`, etc.) — otherwise use a standard structure (Goal, Non-Goals, Requirements MUST/SHOULD/MAY, Acceptance Criteria, Design Overview, Edge Cases, Security, Observability, Rollout, Rollback, Verification, Implementation Strategy checklist).

Before writing files for the two-artifact shape, confirm with the user:
- Where the audit doc lives (`docs/audits/`, `docs/security/`, `RISKS.md`, etc.).
- How specs are split (one per remediation group is the default; "one master spec" and "one per finding" are alternatives).
- Whether to create a git branch and commit the docs (default: yes, on a new branch named `chore/<topic>-audit-<YYYY-MM-DD>`).

Targets to hit:
- Audit doc < 500 lines. If you need more, you're including too many low-severity items.
- 4–8 remediation groups. Fewer means you missed a category; more means you didn't group well.
- Each spec should be ~one PR's worth of work. A spec that ships in three PRs should be split.

Output format:

# Weekly Code Review Report

## Summary
- Total CRITICAL issues: [number]
- Total HIGH issues: [number]
- Areas reviewed: [short list]

## Findings

### [Severity] [Category] - [Short title]

- Location: [file path(s) and relevant symbols]
- Why it matters: [1-3 concise sentences with concrete impact]
- Evidence: [specific technical evidence from the codebase]
- Suggested fix: [clear remediation direction]
- Verification:
  - [specific measurable check]
  - [specific measurable check]
  - [specific measurable check]

## Remediation plan

### [Priority] [Short title]

- Source finding: [title from Findings]
- Recommended order: [1, 2, 3, etc.]
- Fix type: [Immediate patch / Targeted refactor / Larger follow-up]
- Scope: [small/medium/large]
- Risk of change: [low/medium/high]
- Why now: [short justification]
- Proposed approach: [step-by-step remediation direction]
- Recommended tests:
  - [test or benchmark]
  - [test or benchmark]
  - [test or benchmark]
- Rollout notes: [flags, staged rollout, migration, monitoring, or none]

## Excluded items
- [brief note about notable items excluded for being medium/low priority, cosmetic, or insufficiently supported]

If no issues meet the CRITICAL or HIGH bar, output exactly:

No critical or high-priority issues found.
