# Kodus on GitHub: queries and shapes

Verified 2026-09-30 against public Kodus-reviewed PRs.

**Bot login:** it depends on the installation. Kodus cloud posts as `kody-ai[bot]`
(GraphQL: `kody-ai`). A self-hosted install posts under its own GitHub App, for
example `kodus-27b[bot]`. The check run is always named `Kody Code Review`, so take
the login from that check run's `app.slug` (§1): REST login `<slug>[bot]`, GraphQL
login `<slug>`. Before any Kody check run exists, use `kody-ai`.

Setup used by every snippet:

```bash
PR=<number>
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER=${REPO%/*}; NAME=${REPO#*/}
HEAD_SHA=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
KODY_SLUG=kody-ai   # replace with app.slug from §1 once a Kody check run exists
```

## §0 Is Kodus installed?

Sets `KODY_SLUG` to the bot's app slug, or empty when successful reads find no Kody
check on this PR's head or the last 20 PR heads. API errors stay visible and stop
the Bash snippet with failure. Handle that error before continuing the workflow.

```bash
RECENT_HEADS=$(gh pr list -R "$REPO" --state all --limit 20 --json headRefOid -q '.[].headRefOid') || {
  printf '%s\n' 'Kody history listing failed; fix the reported error and retry.' >&2
  exit 1
}
KODY_SLUG=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  KODY_SLUG=$(gh api "repos/$REPO/commits/$sha/check-runs?check_name=Kody%20Code%20Review" \
    --jq '.check_runs[0].app.slug // empty') || {
    printf '%s\n' 'Kody check lookup failed; fix the reported error and retry.' >&2
    exit 1
  }
  if [ -n "$KODY_SLUG" ]; then break; fi
done <<EOF
${HEAD_SHA:-}
$RECENT_HEADS
EOF
```

GitHub does not let a normal `gh` login list a repository's app installations
(`repos/<repo>/installation` needs an app JWT; `orgs/<org>/installations` needs the
`admin:org` scope). The check-run history is the evidence this skill uses.

## §1 Newest Kody check run on the head commit

```bash
gh api "repos/$REPO/commits/$HEAD_SHA/check-runs?check_name=Kody%20Code%20Review" \
  --jq '.check_runs | max_by(.id) // empty | "\(.id)\t\(.app.slug)\t\(.status)\t\(.conclusion)\t\(.output.title)\t\(.output.summary)"'
```

Empty output means no Kody check run exists on this commit yet. Seen outcomes:

| status | conclusion | output.title | output.summary (example) |
| ------ | ---------- | ------------ | ------------------------ |
| `completed` | `success` | Code Review Complete | Review finished successfully. Suggestions (if any) were posted as PR/file comments. |
| `completed` | `skipped` | Code Review Skipped | No New Commits (No changes detected since last review) |
| `completed` | `skipped` | Code Review Skipped | Automated Review is disabled — Enable 'Automated Code Review' in General Settings |
| `completed` | `failure` | Code Review Failed | - Rate limit reached on the provider (...). Try again in a few minutes. (Kody also posts a "Code Review Could Not Complete" PR comment.) |

`max_by(.id)` picks the newest run when a commit has more than one. Keep its `id`:
after a re-trigger, only a run with a higher `id` is the new review.

## §2 Unresolved Kody threads and rebuttals

```bash
gh api graphql --paginate -F owner="$OWNER" -F repo="$NAME" -F pr="$PR" -f query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{id isResolved isOutdated path line originalLine
        comments(first:50){nodes{databaseId author{login} body}}}}}}}' \
  | jq --arg bot "$KODY_SLUG" '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.comments.nodes[0].author.login==$bot)
    | (.comments.nodes | length > 1 and last.author.login==$bot) as $rebuttal
    | select((.isResolved|not) or $rebuttal)
    | {id, isResolved, isOutdated, rebuttal: $rebuttal, path, line: (.line // .originalLine),
       commentId: .comments.nodes[0].databaseId,
       lastReplyId: (if $rebuttal then .comments.nodes[-1].databaseId else null end),
       lastReply: (if $rebuttal then .comments.nodes[-1].body[0:2000] else null end),
       severity: (.comments.nodes[0].body | capture("severity_level-(?<s>[a-z]+)").s // "unknown")}'
```

`rebuttal: true` means Kody replied last in a thread it started, after someone else
replied. Kody does not reopen a resolved thread when it replies, so `isResolved`
alone misses it. The reply is not always a rebuttal: on a re-review Kody often
confirms the fix, and the thread keeps `rebuttal: true` because Kody stays last.
Decide from `lastReply` and track `lastReplyId` as handled. Threads with more than
50 comments are cut off; that does not happen in practice.

The REST endpoint `pulls/<PR>/comments` has no resolution state. Use GraphQL
`isResolved` to decide what is unresolved.

## §3 Inline comment format

A Kody inline comment body starts with shields.io badges, then the finding:

```
![kody code-review](...) ![Bug](https://img.shields.io/badge/Bug-B71C1C) ![high](https://img.shields.io/badge/severity_level-high-6B6B92)

<explanation and suggested fix, often with a code block>

<details><summary>Prompt for LLM</summary> ... File <path>: Line X to Y: ... </details>
```

- Severity: `severity_level-<low|medium|high|critical>`.
- Category: the second badge (`Bug`, `Security`, `Performance`, and others the repo
  enables).
- `Prompt for LLM` restates the file, line range, and fix. Use it as a hint. Read
  the real code before you change anything.

## §4 Kody PR-level comments

Kody edits its PR comments in place (a status comment's `updated_at` moves on later
reviews), so use two separate filters.

Suggestions (carry the `kody code-review` badge; status comments do not):

```bash
gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  | jq -s --arg bot "${KODY_SLUG}[bot]" 'add[] | select(.user.login==$bot)
    | select(.body | test("badge/kody-code--review"))
    | select(.body | test("Code Review Complete|Kody Review Complete|Could Not Complete") | not)
    | {id, updated_at, body: .body[0:2000]}'
```

Failure reason (newest status comment by `updated_at`):

```bash
gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  | jq -rs --arg bot "${KODY_SLUG}[bot]" '[add[] | select(.user.login==$bot)
    | select(.body | test("Could Not Complete"))] | max_by(.updated_at) // empty
    | .body | capture("\\*\\*Reason:\\*\\* (?<r>[^\\n]*)").r'
```

Kody also appends a collapsible "Kody Guide" block to its comments; ignore it.

## §5 Reply to and resolve a thread

Reply (use `commentId` from §2):

```bash
gh api "repos/$REPO/pulls/$PR/comments/<commentId>/replies" -f body="<reason>"
```

Resolve (use thread `id` from §2; one alias per thread):

```bash
gh api graphql -f query='mutation{
  t1: resolveReviewThread(input:{threadId:"<id1>"}){thread{isResolved}}
  t2: resolveReviewThread(input:{threadId:"<id2>"}){thread{isResolved}}
}'
```

## §6 Trigger a review

Before you post, look for a pending trigger (for example, after an interrupted run).
Reuse your newest `@kody start-review` only when Kody has not reacted to it yet and
it is under 5 minutes old. The commit date is not the push time, so it cannot prove
a trigger belongs to this head. A trigger Kody already answered, or one it ignored
for 5 minutes, is not reused; post a new one.

```bash
ME=$(gh api user --jq .login)
SINCE=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
CAND=$(gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  | jq -rs --arg me "$ME" --arg since "$SINCE" \
    '[add[] | select(.user.login==$me and (.body|startswith("@kody start-review")) and .created_at > $since)]
     | max_by(.created_at) // empty | .id')
if [ -n "$CAND" ] && [ "$(gh api "repos/$REPO/issues/comments/$CAND/reactions" \
     --jq "map(select(.user.login==\"${KODY_SLUG}[bot]\")) | length")" = 0 ]; then
  TRIGGER_ID=$CAND
fi
```

Otherwise post the trigger and keep its id:

```bash
TRIGGER_ID=$(gh api "repos/$REPO/issues/$PR/comments" -f body="@kody start-review" --jq .id)
```

Kody reacts on that comment. Observed: 🚀 `rocket` within 30 s while the review
runs, replaced by 🎉 `hooray` when it finishes. The docs also list 👀 `eyes`
(skipped), 😕 `confused` (error), and 👎 `-1` (no license). Use reactions as a
secondary signal; the check run is the primary one.

```bash
gh api "repos/$REPO/issues/comments/$TRIGGER_ID/reactions" \
  | jq -r --arg bot "${KODY_SLUG}[bot]" '.[] | select(.user.login==$bot) | .content'
```

Optional focus: `@kody start-review focus on <area>`. A focus is a priority, not a
filter. `@kody review --force` re-runs a skipped review. Use it only when the user
asks.

## §7 Closeout: every Kody thread with its class

For a merged or closed PR. `ME` is the user that posts the loop's replies. GraphQL
uses plain logins, without `[bot]`.

```bash
ME=$(gh api user --jq .login)
gh api graphql --paginate -F owner="$OWNER" -F repo="$NAME" -F pr="$PR" -f query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{id isResolved path line originalLine
        comments(first:50){nodes{databaseId author{login} body}}}}}}}' \
  | jq --arg bot "$KODY_SLUG" --arg me "$ME" '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.comments.nodes[0].author.login==$bot)
    | .comments.nodes as $c
    | ([$c[] | select(.author.login==$me)]) as $mine
    | ([$mine[] | select(.body | startswith("@kody Yes,"))]) as $closeout
    | ($mine[-1].body // "") as $latest
    | ($latest | test("^(Fixed|Addressed) in ")) as $fixed
    | {id, isResolved, path, line: (.line // .originalLine),
       commentId: $c[0].databaseId,
       sha: (if $fixed then ($latest | capture("^(Fixed|Addressed) in `?(?<s>[0-9a-f]{7,40})").s // null) else null end),
       class: (if ($closeout|length) > 0 then "done"
               elif $fixed then "fixed"
               elif ($latest | startswith("Declined:")) then "declined"
               elif ($mine|length) > 0 or .isResolved then "needs-triage"
               else "unanswered" end)}'
```

These classes are candidates, not permission to change issue status. Read the
full thread before posting. A later dispute or retraction needs triage. A resolved
thread without a reply also needs triage: resolution does not tell you whether a
finding was fixed or declined. Unmarked explanations and questions never imply
a decline. The latest reply supplies the decision and SHA, not the oldest fix.

Kody answers replies in its own threads, with or without a mention. The `@kody`
prefix keeps the instruction explicit. Kody changes an issue only when your latest
message tells it to, so phrase the reply as an instruction, not a question.

## §8 Kody's answer to your newest reply

For every Kody thread you replied in: your newest reply, how many replies you
posted in this run, and Kody's newest answer after it (`null` until Kody answers).
Uses the same setup and `ME` as §7. `RUN_STARTED_AT` must be the UTC timestamp saved
at invocation start, before any replies. Keep it unchanged across passes.

```bash
gh api graphql --paginate -F owner="$OWNER" -F repo="$NAME" -F pr="$PR" -f query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{id isResolved path line originalLine
        comments(first:50){nodes{databaseId author{login} body createdAt}}}}}}}' \
  | jq --arg bot "$KODY_SLUG" --arg me "$ME" --arg runStartedAt "${RUN_STARTED_AT:?Set RUN_STARTED_AT at invocation start}" '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.comments.nodes[0].author.login==$bot)
    | .comments.nodes as $c
    | ([$c | to_entries[] | select(.value.author.login==$me) | .key]) as $mine
    | select($mine | length > 0)
    | ([$c[($mine[-1]+1):][] | select(.author.login==$bot)] | last) as $answer
    | {id, isResolved, path, line: (.line // .originalLine),
       myReplies: ([$mine[] | $c[.] | select(.createdAt >= $runStartedAt)] | length),
       myLastReply: $c[$mine[-1]].body[0:300],
       answerId: $answer.databaseId,
       answer: ($answer.body // null | if . then .[0:2000] else null end)}'
```

Poll until every thread you just replied in has an `answerId` that is not on your
handled list, or 5 minutes pass. `myReplies` counts toward the 3-reply limit.
