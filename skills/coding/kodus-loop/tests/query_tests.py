"""Run the documented jq filters against GitHub-shaped review threads."""

import json
import re
import subprocess
import unittest
from pathlib import Path


REFERENCE = (Path(__file__).resolve().parents[1] / "references/github-queries.md").read_text()
RUN_STARTED_AT = "2026-10-03T22:00:00Z"


def comment(comment_id, author, body, created_at="2026-10-01T12:00:00Z"):
    return {"databaseId": comment_id, "author": {"login": author},
            "body": body, "createdAt": created_at}


def thread(replies=(), resolved=False, author="kody-ai"):
    return {"id": "thread-1", "isResolved": resolved, "path": "src/example.py",
            "line": None, "originalLine": 12,
            "comments": {"nodes": [comment(1, author, "Check the nullable caller."), *replies]}}


def page(threads):
    return {"data": {"repository": {"pullRequest": {"reviewThreads": {
        "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": threads}}}}}


def query(section, pages):
    content = REFERENCE.split(f"## §{section} ", 1)[1].split("\n## ", 1)[0]
    jq_filter = re.search(r"\| jq .*? '(.*?)'\n```", content, re.S).group(1)
    result = subprocess.run(
        ["jq", "-c", "--arg", "bot", "kody-ai", "--arg", "me", "developer",
         "--arg", "runStartedAt", RUN_STARTED_AT, jq_filter],
        input="\n".join(json.dumps(value) for value in pages), text=True,
        capture_output=True, check=True,
    )
    return [json.loads(line) for line in result.stdout.splitlines()]


class CloseoutQueries(unittest.TestCase):
    def classify(self, replies=(), resolved=False):
        return query(7, [page([thread(replies, resolved)])])[0]

    def test_clarification_is_not_a_decline(self):
        result = self.classify([comment(2, "developer", "Which caller can pass null?")])
        self.assertEqual(result["class"], "needs-triage")

    def test_latest_disposition_replaces_an_earlier_fix(self):
        result = self.classify([
            comment(2, "developer", "Fixed in abcdef1. Added a guard."),
            comment(3, "kody-ai", "The guard does not fix the caller."),
            comment(4, "developer", "Declined: The caller guarantees a value."),
        ])
        self.assertEqual(result["class"], "declined")
        self.assertIsNone(result["sha"])

    def test_latest_fix_sha_is_used(self):
        result = self.classify([
            comment(2, "developer", "Fixed in abcdef1. Initial guard."),
            comment(3, "developer", "Fixed in `123abcd`. Corrected the caller."),
        ])
        self.assertEqual(result["class"], "fixed")
        self.assertEqual(result["sha"], "123abcd")

    def test_resolution_alone_is_not_fix_evidence(self):
        self.assertEqual(self.classify(resolved=True)["class"], "needs-triage")

    def test_unanswered_and_missing_sha_rows_survive(self):
        result = self.classify()
        self.assertEqual(result["class"], "unanswered")
        self.assertIsNone(result["sha"])
        self.assertEqual(result["line"], 12)

    def test_existing_closeout_resumes_after_evidence_reply(self):
        result = self.classify([
            comment(2, "developer", "@kody Yes, dismiss the Kody issue for this finding now."),
            comment(3, "kody-ai", "Which caller?"),
            comment(4, "developer", "The caller is src/example.py:12."),
        ])
        self.assertEqual(result["class"], "done")

    def test_human_threads_are_excluded_across_pages(self):
        result = query(7, [page([thread(author="human")]), page([thread()])])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["commentId"], 1)


class ReplyQueries(unittest.TestCase):
    def replies(self, replies):
        return query(8, [page([thread(replies)])])[0]

    def test_reply_limit_counts_only_this_run(self):
        result = self.replies([
            comment(2, "developer", "Fixed in abcdef1."),
            comment(3, "developer", "See the caller."),
            comment(4, "developer", "See the test."),
            comment(5, "kody-ai", "Agreed."),
            comment(6, "developer", "@kody Yes, mark it resolved now.", RUN_STARTED_AT),
            comment(7, "kody-ai", "I can do that. Say the word.", "2026-10-03T22:01:00Z"),
        ])
        self.assertEqual(result["myReplies"], 1)
        self.assertEqual(result["answerId"], 7)

    def test_old_answer_does_not_answer_new_reply(self):
        result = self.replies([
            comment(2, "developer", "Fixed in abcdef1."),
            comment(3, "kody-ai", "Please check the caller."),
            comment(4, "developer", "Fixed in 123abcd.", RUN_STARTED_AT),
        ])
        self.assertIsNone(result["answerId"])
        self.assertIsNone(result["answer"])

    def test_latest_historical_answer_is_available_on_resume(self):
        result = self.replies([
            comment(2, "developer", "@kody Yes, dismiss the Kody issue for this finding now."),
            comment(3, "kody-ai", "I can do that."),
            comment(4, "kody-ai", "Please confirm the instruction."),
        ])
        self.assertEqual(result["myReplies"], 0)
        self.assertEqual(result["answerId"], 4)

    def test_threads_without_my_reply_are_excluded(self):
        self.assertEqual(query(8, [page([thread()])]), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
