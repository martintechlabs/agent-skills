# Common Bug Classes — Starter Criteria

Ready-to-adapt inclusion/exclusion criteria for the bug classes that most often turn out to be systemic when audited. Each class includes a one-sentence definition, what the fix typically looks like, and concrete inclusion/exclusion bullets you can paste into a subagent brief.

These are starting points, not final criteria. The "typical fix shape" examples span several stacks to stay illustrative — keep the ones that match the codebase under audit, drop the rest, and always tighten against real recent PRs before delegating the per-PR loop.

## 1. Stale client state after server-side writes

**Definition.** The server-side mutation succeeded, but the client or a cache didn't refresh, so the view shows pre-write data until something forces a reload.

**Typical fix shape.** Adding a re-read or cache-invalidation after the write. Across stacks this shows up as: a refetch / cache-key invalidation / path revalidation / forced re-render in a frontend; a manual re-read of the record after writing; busting a server-side or CDN cache entry; a freshly added subscription, poll, or focus/visibility refresh to pick up the change.

**Count when.**
- Bug is "stale data shown" or "doesn't react to a server change"
- The server write itself succeeded
- The fix is one of the patterns above

**Exclude when.**
- Data-layer bugs (wrong query, missing join, broken access policy)
- Wrong data returned by the server (re-reading wouldn't help)
- Client/local state that was always wrong (e.g. a mis-computed filter)
- Concurrency races between actors (different bug class)

**Common red herrings.** A fix that *adds* a refetch but the root cause is actually a missing field on the server response — exclude.

## 2. Silent error swallowing

**Definition.** An error path exists in the code that absorbs failures without logging, alerting, or surfacing to the user, so problems compound or go undetected for long stretches.

**Typical fix shape.** Replacing an empty/no-op catch with one that logs and rethrows, adding an error-tracking capture where there was none, replacing a fire-and-forget concurrent call with one whose failures are observed, replacing dev-only output (e.g. a stdout print invisible in prod) with structured logging, adding context to a generic "something went wrong" message.

**Count when.**
- The PR adds error logging, captures, or rethrows where there was none
- Or replaces a generic "Something went wrong" with a contextualized message
- Or upgrades a swallowed error path from no-op to observed

**Exclude when.**
- The error was already logged; PR just changes log content
- Pure refactor of error handling without behavioral change
- The fix is for an error that never actually happened in prod

## 3. Authorization drift

**Definition.** Access-control rules — database-level policies, middleware/guard checks, or app-level permission logic — fall out of sync with the application's intended visibility rules, so users see too much or too little.

**Typical fix shape.** Adding or altering an access-control policy (e.g. a database row-level-security policy), adding a permission check in middleware or a service layer that was missing, adding an ownership or tenant scope to a previously-unscoped query (a `WHERE owner_id = ...` / tenant filter), introducing a new authorization helper (`can_view(...)`, `is_member(...)`).

**Count when.**
- Fix changes an access-control policy or adds/strengthens a permission check
- Fix adds an authorization predicate to a previously-unscoped query
- Symptom is "user X could see Y they shouldn't" or "user X couldn't see Y they should"

**Exclude when.**
- Fix is purely UI (hide a button) without underlying data scoping
- Fix is about a feature flag, not visibility
- The "permission" check is really a business rule, not auth

## 4. Validation bypass / contract drift

**Definition.** A field added to a form/schema/API isn't enforced in all the paths the data flows through, so invalid data slips through one entry point.

**Typical fix shape.** Adding schema/input validation to a request handler or endpoint that lacked it, adding a server-side check that previously existed only on the client, tightening a type or contract and fixing the downstream call sites, adding required-field enforcement to a previously-loose form.

**Count when.**
- The fix adds validation to one path where it was missing
- The fix tightens a type/contract and fixes resulting errors
- Symptom is "we got bad data in the store" or "field X was supposed to be required"

**Exclude when.**
- Fix changes the validation rule (X must be > 0 instead of > -1)
- Fix is about copy/UX for the error, not the rule
- New schema added for a wholly new feature

## 5. N+1 queries / fetch waterfalls

**Definition.** The application fetches data in a loop or sequentially when it could batch, producing one query per item where one query would do.

**Typical fix shape.** Replacing per-item fetches in a loop with a single batched/bulk query, adding a join or eager-loading (e.g. an ORM `include` / `select_related` / `prefetch`) where the code previously made one trip per row, introducing a batch loader, hoisting a fetch out of a render or iteration loop.

**Count when.**
- Fix replaces per-item fetches with a batched query
- Fix collapses a waterfall (A → then B → then C) into parallel/joined fetches
- Symptom is "page/endpoint slow" specifically tied to fetch count

**Exclude when.**
- Slow query that's a single query (index/plan bug — different class)
- Frontend perf bug unrelated to fetches (re-render storms, etc.)
- Caching addition without underlying query change

## 6. Race conditions / order-of-operation bugs

**Definition.** Two async operations depend on each other's effects but no synchronization enforces the order, so the outcome depends on timing.

**Typical fix shape.** Adding an `await`/synchronization where there was none, serializing concurrent calls into sequential ones, adding a "stale request" guard (a sequence token or cancellation/abort), fixing a missing effect/callback dependency, adding a lock or mutex.

**Count when.**
- Fix changes parallel/concurrent code to sequential
- Fix adds stale-response detection
- Symptom is "works sometimes, fails sometimes" tied to ordering

**Exclude when.**
- Genuine cross-actor race between users/processes (concurrency class — different)
- DB-level race that needs a transaction (data integrity class — different)

## 7. External-service sync drift

**Definition.** Outbound calls to third-party services (CRM, payment processor, email, search index, analytics) silently miss fields, fail on retry, or get out of sync with the local store.

**Typical fix shape.** Adding fields to a payload that maps to an external API, fixing key-name or casing mismatches between the two systems, adding idempotency keys, adding a retry or queue, adding webhook signature verification, adding a missing sync call after a local write.

**Count when.**
- Fix touches a third-party integration
- Symptom is "their system shows X but ours shows Y"
- Fix is about syncing one specific field that was missing

**Exclude when.**
- Pure local store bug that doesn't touch the external service
- New integration / feature (not a fix of existing sync)

## 8. Migration / schema-caller drift

**Definition.** A schema change (column rename, table split, type change) shipped, but at least one caller of the old shape still references the old structure, surfacing weeks or months later when that path runs.

**Typical fix shape.** Updating a caller to read from a renamed/moved column or table, fixing a query or join path that no longer resolves, restoring a reference that was renamed but not updated everywhere, fixing a backfill that missed a case.

**Count when.**
- Fix updates a caller to the new schema shape
- Symptom is "this feature broke and the schema change was N weeks ago"
- The bug surfaced only because a specific user/path hit the stale caller

**Exclude when.**
- Fix is itself a schema change with no caller-side work
- Backfill bug (data integrity, not schema drift)

## 9. Null / undefined / nil dereference

**Definition.** Code accesses a property, index, or method on a value that can be null/undefined/nil, so the path crashes or produces a silently-wrong result when that value is absent.

**Typical fix shape.** Adding a guard clause or early return, safe navigation / optional chaining, a presence check before use, a default-before-use (coalescing) that resolves the crash, or making a previously-optional value required upstream so it can't arrive empty.

**Count when.**
- Fix adds a null/undefined/nil check, guard, safe-navigation, or coalescing default before a use that *was actually crashing or misbehaving*
- Symptom is a null-pointer / "undefined is not a ..." / `NoneType` crash, or a wrong value from a silently-missing field
- The absent value was optional or merely missing at runtime — a real crash was prevented, so count it even though the value wasn't required

**Exclude when.**
- The value was *required* and the old code silently masked its absence with a default — that's "invented defaults" (#14); the fix there replaces the default with a loud error, not a guard
- A speculative guard added with no actual crash/defect behind it (hardening, not a fix)
- The real fix is upstream data that should never have been empty (data-integrity bug) — count only if the fix is the defensive check itself
- Pure type-annotation change with no runtime guard

**#9 vs #14.** Both touch defaults for absent values; the split is *what the absence did and what the fix does*. Absent **optional** value caused a crash, fix adds a guard/default to tolerate it → **#9, counted**. Absent **required** value was silently tolerated by a default and produced wrong behavior, fix replaces that default with a loud error → **#14**. Same `?? x` edit can be either — read the direction.

## 10. Off-by-one / boundary errors

**Definition.** A loop bound, index, slice, or range is off by one, so the code drops, double-counts, or over-reads the edge element.

**Typical fix shape.** Changing `<` to `<=` (or back), adjusting a start/end index, fixing inclusive-vs-exclusive bounds in pagination or slicing, fixing a fencepost in a range, page, or chunk calculation.

**Count when.**
- Fix adjusts an index, bound, or inclusive/exclusive range by one
- Symptom is "first/last item missing", "duplicated edge row", "page N drops a record", "reads one past the end"

**Exclude when.**
- The bound was conceptually wrong, not off-by-one (e.g. the wrong variable entirely)
- Pagination bug rooted in an unstable sort, not boundary math

## 11. Timezone / date-time handling

**Definition.** Date or time logic assumes the wrong zone, mishandles DST, or does naive arithmetic, so values shift by hours or land on the wrong day.

**Typical fix shape.** Normalizing to UTC at the boundary, replacing naive timestamps with zone-aware ones, fixing day-boundary math (start/end of day in the right zone), switching to a proper date type/library instead of string or epoch arithmetic, fixing DST-unsafe add/subtract.

**Count when.**
- Fix changes how a timestamp is parsed, stored, or compared with respect to zone/offset/DST
- Symptom is "off by N hours", "wrong day near midnight", "breaks during DST", "differs by user location"

**Exclude when.**
- Pure display/formatting change over a correct underlying value
- Locale number/currency formatting unrelated to time

## 12. Money / numeric precision

**Definition.** Monetary or high-precision values use floating point (or lose precision in conversion), so sums drift, rounding is inconsistent, or totals fail to reconcile.

**Typical fix shape.** Moving to integer minor units (cents) or a decimal/bignum type, fixing a rounding mode or rounding at the wrong step, removing float arithmetic from a money path, fixing a unit/scale mismatch (dollars vs cents).

**Count when.**
- Fix changes a money/precision-sensitive value from float to integer/decimal, or fixes rounding or scale
- Symptom is "total off by a cent", "rounding inconsistent", "amounts don't reconcile"

**Exclude when.**
- Business-rule change to how a price is computed (not a precision bug)
- Display rounding over a correct stored value

## 13. Resource leaks

**Definition.** A resource (file handle, socket, DB connection, lock, subscription, timer) is acquired but not reliably released, so the process exhausts a pool, leaks memory, or holds a lock.

**Typical fix shape.** Adding a close/dispose in a `finally` or scope-guard (`with` / `using` / `defer`), returning a connection to the pool, unsubscribing or removing a listener on teardown, clearing a timer/interval, fixing an early return that skipped cleanup.

**Count when.**
- Fix adds or relocates a release/close/dispose/unsubscribe so the resource is freed on all paths
- Symptom is "pool exhausted", "too many open files", "memory grows over time", "handler fires after teardown"

**Exclude when.**
- Pool-size tuning with no actual leak
- An unbounded cache (capacity/eviction bug — adjacent, not a leak)

## 14. Invented defaults / hidden fallbacks

**Definition.** When required config or data is missing, the code silently substitutes a default or guessed value instead of failing, so misconfiguration is masked until it causes a subtler problem downstream.

**Typical fix shape.** Replacing a silent default with an explicit error that names the missing key and its remediation, removing a `?? <guess>` / `|| <fallback>` on a required value, failing fast at config-load/startup instead of deep in a code path, turning an optional parameter back into a required one.

**Count when.**
- Fix replaces a silent default/fallback for a *required* value with a loud failure
- Symptom is "ran with the wrong value", "used a placeholder/stale config", "no error but wrong behavior because X was unset"

**Exclude when.**
- The default is a genuinely valid optional default (the value isn't required)
- Adding a default to *prevent a crash* — that's likely a null-deref fix (#9), not a masked-requirement fix

## 15. Incomplete refactor / orphaned call sites

**Definition.** A symbol was renamed, a signature changed, or an interface moved, but not every caller was updated, so a stale reference lingers in a path the change missed. The code-interface cousin of schema-caller drift (#8).

**Typical fix shape.** Updating the missed call sites to the new name or signature, fixing an argument order/count that drifted, finishing a rename across the remaining references, reconciling two copies of a constant/value that were supposed to move together.

**Count when.**
- Fix updates one or more callers left behind by an earlier rename / signature / interface change
- Symptom is "this one path still called the old shape", "worked everywhere except X", "wrong arg after the signature changed"

**Exclude when.**
- The change is a *data*-schema/column drift (use #8)
- A genuinely new caller, not one missed during a refactor

## 16. Type-checker / lint suppression

**Definition.** A type or lint error was silenced rather than fixed, so the escape hatch hides a real defect that later surfaces at runtime.

**Typical fix shape.** Removing a suppression (an `any`/`unknown` cast, `@ts-ignore` / `@ts-expect-error`, `# type: ignore`, `eslint-disable`, a non-null assertion `!`, an `unwrap()` / unchecked `as`) and handling the case it was masking, narrowing a type that was widened to quiet the checker, adding the missing branch a suppressed exhaustiveness check was hiding.

**Count when.**
- Fix removes a type/lint suppression and the underlying defect it concealed surfaces
- Symptom is "crashed on the case the cast promised couldn't happen", "the ignore hid a real null/None"

**Exclude when.**
- Suppression removed in a pure cleanup with no behavior change and no bug
- The suppression was legitimately correct and the real fix is elsewhere

## 17. Assertion-free / mock-only tests

**Definition.** A test exists but can't fail — it asserts nothing, only exercises a mock and checks the mock, or rubber-stamps a snapshot — so it reports coverage without verifying behavior, and the real defect ships green.

**Typical fix shape.** Adding a real assertion against actual output or state, replacing an assertion on a mock's return value with one on the system under test, removing over-mocking so the test exercises real code, regenerating or tightening a snapshot that had baked in the buggy output, asserting on an error path that was only smoke-tested.

**Count when.**
- Fix turns a passing-but-meaningless test into one that can actually fail (adds/strengthens an assertion, de-mocks the unit under test, fixes a rubber-stamped snapshot)
- Symptom is "we had a test for this and it still broke", "coverage was green but the behavior was wrong"

**Exclude when.**
- New test added for previously-untested code (a coverage gap, not a hollow test)
- Test was already meaningful; the fix only adjusts a correct assertion's expected value
- Flaky-test fix where the assertion was real but timing/order was the problem (use #6)

## 18. Duplicated logic / divergent copies

**Definition.** The same rule or behavior is implemented in several places instead of shared, so a change has to be made in every copy. One copy gets missed or the copies drift apart, and the same bug has to be fixed more than once or two paths quietly disagree.

**Typical fix shape.** Applying the *same* fix to several near-identical sites in one PR (the tell that they should have been one), extracting the duplicated logic into a single shared function/module and pointing the call sites at it, fixing the one copy that drifted from its siblings, reconciling two implementations of the same rule that had diverged.

**Count when.**
- Fix changes the same logic in multiple near-identical places at once, or consolidates duplicated logic into a single source
- Symptom is "we already fixed this bug, it came back somewhere else", "two screens/endpoints compute the same thing differently", "the rule was updated in one place but not the others"

**Exclude when.**
- A rename / signature / interface change with missed callers — that's one definition with scattered references, use #15 (not duplicated *logic*)
- Coincidental similarity that isn't actually the same rule (false DRY)
- Pure refactor extracting duplication with no bug behind it (code smell, not a fix)

## 19. Injection / unsanitized input

**Definition.** Untrusted input is interpolated into a query, command, markup, path, or template without parameterization or escaping, so malformed or hostile input can alter the interpreted structure — SQL injection, cross-site scripting, command injection, path traversal.

**Typical fix shape.** Switching string-built SQL to parameterized queries / prepared statements or an ORM binding, escaping or encoding output for the right context (HTML / attribute / URL), replacing shell string interpolation with an argument array or a safe API, validating a path against an allowlist or canonicalizing to block `../`, adding a strict allowlist or format check on a value used in a sensitive sink.

**Count when.**
- Fix parameterizes, escapes, or allowlists untrusted input flowing into a query / command / markup / path / template
- Symptom is an injection / XSS / traversal report, or "special characters in the input broke or altered the query"

**Exclude when.**
- Validation added for data-quality reasons with no injection sink (use #4)
- Authorization / visibility bug (use #3)
- A dependency CVE bump with no change to a code path (dependency update, not this class)

## 20. Non-atomic multi-step writes / missing transaction

**Definition.** A sequence of writes that must all succeed or all fail isn't atomic, so a failure or crash partway through leaves the data inconsistent — a debit without its credit, a parent row without its children, a status flipped without the side effect that should accompany it.

**Typical fix shape.** Wrapping the steps in a single transaction (commit / rollback), adding a compensating action or saga for cross-service steps that can't share a transaction, reordering so the durable write happens last, adding a uniqueness constraint so a partial retry can't duplicate.

**Count when.**
- Fix makes a multi-step write atomic (a transaction) or adds compensation/cleanup for partial failure
- Symptom is "record A exists but related B doesn't", "money moved one way only", "left half-updated after an error"

**Exclude when.**
- Timing / order race between concurrent operations (use #6)
- Single-statement write that just needed a constraint or validation (use #4)
- Idempotency of an outbound sync call (closer to #7)

## 21. Control-flow / branch-precedence logic errors

**Definition.** Conditional logic evaluates branches in the wrong order, uses the wrong boolean operator, or has overlapping/mismatched predicates, so an input lands in the wrong branch — or no branch — producing a misclassification, a mis-bucketed item, or a case that silently falls through.

**Typical fix shape.** Reordering guards so the more specific case is checked before a broader one, fixing an inverted or wrong boolean operator (`&&`/`||`, a dropped negation, a De Morgan slip), tightening or widening a predicate so cases stop overlapping or falling through, adding the branch/case a condition skipped.

**Count when.**
- Fix reorders conditions, flips a boolean operator, or corrects a predicate so an input is routed to the right branch
- Symptom is "shows in the wrong category / bucket / state", "fell through to the default", "counted in neither (or both)", or a plainly inverted condition

**Exclude when.**
- The defect was an index or range off by one (use #10)
- The condition was correct but the data feeding it was wrong (classify by that root cause)
- The same routing logic is duplicated across copies and one drifted (use #18 — that's about divergence, this is one site's logic being wrong)
- The fix tightens an enforcement rule on input rather than routing it (use #4)

## 22. Environment / config-contract drift

**Definition.** Code depends on a value whose shape, key, or presence differs across environments or external providers — environment variables, auth-token claims, provider config, feature flags — so it works in one environment and breaks in another with no change to the application logic itself.

**Typical fix shape.** Reading a value in a way that tolerates both shapes or sources (e.g. accepting a claim under either of two keys), removing or updating a stale reference to renamed/removed provider config, normalizing an environment or provider difference at the boundary, correcting which variable is read in which environment.

**Count when.**
- Fix reconciles a value that differs by environment or provider (claim shape, env var, provider template/config, flag) so behavior is consistent everywhere
- Symptom is "works on staging, breaks on prod", "NULL/empty only in one environment", "stopped working after a provider/config change" with no app-logic change behind it

**Exclude when.**
- A database schema/column rename with stale callers — that's code-vs-data drift, use #8 (this is code-vs-environment/provider)
- A missing field on an outbound third-party payload (use #7)
- A *required* value simply absent and silently defaulted (use #14) — #22 is when the value exists but its shape/key/source differs by environment, not when it's missing

---

## How to use this catalog

1. The user names a class loosely. Find the closest match here.
2. Copy the inclusion/exclusion bullets into the subagent brief verbatim.
3. **Tighten them** for the specific codebase: keep only the "typical fix shape" examples that match this stack, and add 2–3 concrete examples drawn from recent PRs or from the user's stated intuition. Without examples, the per-PR judge drifts.
4. If no class matches, the user's hypothesis may be too fuzzy. Either narrow it (ask: "what specifically is the failure mode?") or expand the catalog by drafting fresh criteria following the same template.

**Two flavors of class.** Classes 1–13 describe a *root cause* (what was wrong). Classes 14–16 describe *how the bug got introduced* — silent fallbacks, half-finished refactors, silenced checks — patterns common to both rushed human work and agent-generated code. A single `fix:` PR can match one of each (e.g. a race condition introduced by an incomplete refactor). Pick whichever flavor answers the user's actual question: audit a root-cause class to size a *kind of defect*, an introduction class to size a *way defects keep entering* — the latter is the sharper lens when the question is "are our AI-assisted changes shipping a recognizable pattern?"

## When the catalog is wrong

These criteria are starting points, not gospel. Codebase-specific signals override them. Examples of the kind of override to expect:

- A codebase whose "stale client state" fixes mostly route through one framework mechanism (a cache invalidation API, a revalidation call) — fold that specific mechanism into the inclusion bullets.
- A codebase with custom logging conventions — "silent error swallowing" fixes might match a specific dev-output → structured-logger transition.
- A multi-service codebase — "authorization drift" might really be cross-service contract drift; rewrite the criteria accordingly.

Tighten before delegating. The criteria are the audit's load-bearing artifact.
