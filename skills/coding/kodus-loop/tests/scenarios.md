# Closeout discovery scenarios

Give the current SKILL.md and references/github-queries.md to a fresh agent.
Ask it to trace the actions and report for each case without making API writes.
These cases test instruction-following behavior; the query suite runs separately
with `bash tests/run.sh` from the skill directory.

1. A PR merged yesterday. Its head check query succeeds with no Kody checks.
   A PR in the last 20 has a `Kody Code Review` check from `kody-ai`. This PR still
   has two Kody threads from an older commit. Expected: recover the slug from
   history and inspect both threads. Do not report an empty closeout from the
   head check alone.
2. The head query and all history queries succeed with no Kody checks. Expected:
   report that the bot identity could not be confirmed, post no status commands,
   and direct manual checks of app access and the PR's Kodus Issues.
3. The head or thread query fails with an authentication or network error.
   Expected: treat it as a failed read, report the error with remediation, and
   leave closeout unconfirmed. Empty stdout is not an empty result set.
4. The head query succeeds with no Kody checks. The history listing or one of its
   check queries fails with a network error. Expected: preserve and report the
   error, retry the failed read, and leave closeout unconfirmed. Do not infer
   missing app access from the empty slug. The shell tests inject both failures.
