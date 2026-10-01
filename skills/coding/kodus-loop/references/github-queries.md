# Kodus on GitHub: queries and shapes

Verified 2026-09-30 against public Kodus-reviewed PRs.

**Bot login:** REST returns `kody-ai[bot]`. GraphQL returns `kody-ai`. Match the
right spelling for the API you call.

Setup used by every snippet:

```bash
PR=<number>
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER=${REPO%/*}; NAME=${REPO#*/}
HEAD_SHA=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
```

## §1 Newest Kody check run on the head commit

```bash
gh api "repos/$REPO/commits/$HEAD_SHA/check-runs?check_name=Kody%20Code%20Review" \
  --jq '.check_runs | max_by(.id) // empty | "\(.status)\t\(.conclusion)\t\(.output.title)\t\(.output.summary)"'
```

Empty output means no Kody check run exists on this commit yet. Seen outcomes:

| status | conclusion | output.title | output.summary (example) |
| ------ | ---------- | ------------ | ------------------------ |
| `completed` | `success` | Code Review Complete | Review finished successfully. Suggestions (if any) were posted as PR/file comments. |
| `completed` | `skipped` | Code Review Skipped | No New Commits (No changes detected since last review) |
| `completed` | `failure` | Code Review Failed | - Rate limit reached on the provider (...). Try again in a few minutes. (Kody also posts a "Code Review Could Not Complete" PR comment.) |

`max_by(.id)` picks the newest run when a commit has more than one.

## §2 Unresolved Kody review threads

```bash
gh api graphql --paginate -F owner="$OWNER" -F repo="$NAME" -F pr="$PR" -f query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:100,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{id isResolved isOutdated path line originalLine
        comments(first:1){nodes{databaseId author{login} body}}}}}}}' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved|not)
    | select(.comments.nodes[0].author.login=="kody-ai")
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
  --jq '.[] | select(.user.login=="kody-ai[bot]")
    | select(.body | test("badge/kody-code--review"))
    | select(.body | test("Code Review Complete|Kody Review Complete|Could Not Complete") | not)
    | {id, updated_at, body: .body[0:2000]}'
```

Failure reason (newest status comment by `updated_at`):

```bash
gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  --jq '[.[] | select(.user.login=="kody-ai[bot]")
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

```bash
gh pr comment "$PR" --body "@kody start-review"
```

Optional focus: `@kody start-review focus on <area>`. A focus is a priority, not a
filter. `@kody review --force` re-runs a skipped review. Use it only when the user
asks.
