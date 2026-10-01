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
| `completed` | `failure` | Code Review Failed | - Rate limit reached on the provider (...). Try again in a few minutes. (Kody also posts a "Code Review Could Not Complete" PR comment.) |

`max_by(.id)` picks the newest run when a commit has more than one. Keep its `id`:
after a re-trigger, only a run with a higher `id` is the new review.

## §2 Unresolved Kody review threads

```bash
gh api graphql --paginate -F owner="$OWNER" -F repo="$NAME" -F pr="$PR" -f query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{id isResolved isOutdated path line originalLine
        comments(first:1){nodes{databaseId author{login} body}}}}}}}' \
  | jq --arg bot "$KODY_SLUG" '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved|not)
    | select(.comments.nodes[0].author.login==$bot)
    | {id, isOutdated, path, line: (.line // .originalLine), commentId: .comments.nodes[0].databaseId,
       severity: (.comments.nodes[0].body | capture("severity_level-(?<s>[a-z]+)").s // "unknown")}'
```

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

Before you post, look for a trigger you already posted for this head (for example,
after an interrupted run). Reuse it if it is newer than the head commit and Kody has
not finished it:

```bash
HEAD_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq .commit.committer.date)
ME=$(gh api user --jq .login)
gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  | jq -rs --arg me "$ME" --arg since "$HEAD_DATE" \
    'add[] | select(.user.login==$me and (.body|startswith("@kody start-review")) and .created_at > $since) | .id'
```

Otherwise post the trigger and keep its id:

```bash
TRIGGER_ID=$(gh api "repos/$REPO/issues/$PR/comments" -f body="@kody start-review" --jq .id)
```

Kody reacts on that comment. Observed: 🎉 `hooray` when the review finishes. The docs
also list 🚀 `rocket` (running), 👀 `eyes` (skipped), 😕 `confused` (error), and
👎 `-1` (no license), but 🚀 was not seen on real triggers. Use reactions as a
secondary signal; the check run is the primary one.

```bash
gh api "repos/$REPO/issues/comments/$TRIGGER_ID/reactions" \
  | jq -r --arg bot "${KODY_SLUG}[bot]" '.[] | select(.user.login==$bot) | .content'
```

Optional focus: `@kody start-review focus on <area>`. A focus is a priority, not a
filter. `@kody review --force` re-runs a skipped review. Use it only when the user
asks.
