"""Tests for the devlog's LinkedIn and Telegram tools.

    python3 -m unittest discover -s tool/devlog
"""

from __future__ import annotations

import datetime
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import devlog_common as dc  # noqa: E402
import linkedin_post  # noqa: E402
import telegram_approve  # noqa: E402
import telegram_notify  # noqa: E402

CHAT = "123456"
NOW = 1_800_000_000


def devlog_pr(**overrides) -> dict:
    pr = {
        "number": 1830,
        "title": "docs(site): devlog entry on the pixel ratio",
        "url": "https://github.com/tomassasovsky/segno/pull/1830",
        "state": "OPEN",
        "isDraft": False,
        "baseRefName": dc.TRUNK,
        "headRefName": "claude/devlog-2026-11-22-1829",
        "mergeable": "MERGEABLE",
        "files": [
            {"path": "site/log/2026-11-22-pixel-ratio.md"},
            {"path": "site/log/2026-11-22-pixel-ratio.linkedin.txt"},
            {"path": "site/public/feed.xml"},
        ],
        "statusCheckRollup": [
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED"},
        ],
    }
    pr.update(overrides)
    return pr


def message(text: str, *, chat_id: str = CHAT, sender: str = CHAT, kind: str = "private", age: int = 60) -> dict:
    return {
        "text": text,
        "date": NOW - age,
        "chat": {"id": int(chat_id), "type": kind},
        "from": {"id": int(sender)},
    }


class LittleTextTest(unittest.TestCase):
    def test_reserved_characters_are_escaped(self):
        self.assertEqual(dc.little_text("a (b) [c] <d> *e* _f_ ~g~ @h |i| {j} \\k"),
                         "a \\(b\\) \\[c\\] \\<d\\> \\*e\\* \\_f\\_ \\~g\\~ \\@h \\|i\\| \\{j\\} \\\\k")

    def test_hashtags_become_hashtag_templates(self):
        self.assertEqual(dc.little_text("Done. #Flutter #EmbeddedLinux"),
                         "Done. {hashtag|\\#|Flutter} {hashtag|\\#|EmbeddedLinux}")

    def test_a_hash_that_is_not_a_hashtag_is_escaped(self):
        self.assertEqual(dc.little_text("PR #859 and C#"), "PR \\#859 and C\\#")

    def test_urls_keep_their_text(self):
        self.assertEqual(dc.little_text("https://github.com/x/pull/859"), "https://github.com/x/pull/859")


class ApprovalParsingTest(unittest.TestCase):
    def test_accepted_forms(self):
        for text, want in (
            ("publish 1830", ("publish", 1830)),
            ("Publish #1830", ("publish", 1830)),
            ("/publish 1830", ("publish", 1830)),
            ("  skip 12 ", ("skip", 12)),
        ):
            self.assertEqual(dc.parse_approval(text), want, text)

    def test_rejected_forms(self):
        for text in ("publish", "publish it", "yes", "publish 1830 now", "please publish 1830", "", None):
            self.assertIsNone(dc.parse_approval(text), text)


class PullRequestGateTest(unittest.TestCase):
    def test_a_devlog_pr_passes(self):
        self.assertEqual(dc.devlog_pr_problems(devlog_pr()), [])

    def test_each_rule_is_enforced(self):
        cases = {
            "merged": devlog_pr(state="MERGED"),
            "draft": devlog_pr(isDraft=True),
            "targets": devlog_pr(baseRefName="master"),
            "branch": devlog_pr(headRefName="claude/engine-1234"),
            "outside site/": devlog_pr(files=devlog_pr()["files"] + [{"path": ".github/workflows/main.yaml"}]),
            "no site/log": devlog_pr(files=[{"path": "site/log/2026-11-22-pixel-ratio.md"}]),
        }
        for want, pr in cases.items():
            problems = " ".join(dc.devlog_pr_problems(pr))
            self.assertIn(want, problems, want)

    def test_checks_state(self):
        self.assertEqual(dc.checks_state(devlog_pr()["statusCheckRollup"]), "green")
        self.assertEqual(dc.checks_state([{"__typename": "CheckRun", "status": "IN_PROGRESS"}]), "pending")
        self.assertEqual(
            dc.checks_state([{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"}]), "red"
        )
        self.assertEqual(dc.checks_state([{"__typename": "StatusContext", "state": "PENDING"}]), "pending")
        self.assertEqual(dc.checks_state([{"__typename": "StatusContext", "state": "FAILURE"}]), "red")
        self.assertEqual(dc.checks_state([]), "green")


class ApproveHandlerTest(unittest.TestCase):
    def setUp(self):
        self.gh = mock.patch.object(telegram_approve, "gh", return_value="").start()
        self.view = mock.patch.object(telegram_approve, "view", return_value=devlog_pr()).start()
        self.addCleanup(mock.patch.stopall)

    def test_publish_merges_a_green_devlog_pr(self):
        reply = telegram_approve.handle(message("publish 1830"), CHAT, NOW)
        self.assertIn("Merged #1830", reply)
        self.gh.assert_called_once_with("pr", "merge", "1830", "-R", dc.REPO, "--merge", "--delete-branch")

    def test_messages_from_anyone_else_are_ignored(self):
        for msg in (
            message("publish 1830", chat_id="999", sender="999"),
            message("publish 1830", sender="999"),
            message("publish 1830", kind="group"),
            message("publish 1830", age=4 * 24 * 3600),
        ):
            self.assertIsNone(telegram_approve.handle(msg, CHAT, NOW))
        self.gh.assert_not_called()

    def test_pending_or_red_checks_do_not_merge(self):
        self.view.return_value = devlog_pr(statusCheckRollup=[{"__typename": "CheckRun", "status": "QUEUED"}])
        self.assertIn("still running", telegram_approve.handle(message("publish 1830"), CHAT, NOW))
        self.view.return_value = devlog_pr(
            statusCheckRollup=[{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"}]
        )
        self.assertIn("a check failed", telegram_approve.handle(message("publish 1830"), CHAT, NOW))
        self.gh.assert_not_called()

    def test_a_pr_that_is_not_a_devlog_pr_is_refused(self):
        self.view.return_value = devlog_pr(headRefName="claude/engine-1234")
        self.assertIn("Not merging", telegram_approve.handle(message("publish 1830"), CHAT, NOW))
        self.assertIn("Not closing", telegram_approve.handle(message("skip 1830"), CHAT, NOW))
        self.gh.assert_not_called()

    def test_skip_closes(self):
        self.assertIn("Closed #1830", telegram_approve.handle(message("skip 1830"), CHAT, NOW))
        self.assertEqual(self.gh.call_args.args[:3], ("pr", "close", "1830"))

    def test_other_text_gets_the_help_line(self):
        self.assertEqual(telegram_approve.handle(message("hi"), CHAT, NOW), telegram_approve.HELP)
        self.gh.assert_not_called()


class EntryFilesTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name)
        self.log = self.root / "site" / "log"
        self.log.mkdir(parents=True)
        (self.log / "2026-11-22-pixel-ratio.md").write_text(
            "---\ntitle: The pixel ratio\ndate: 2026-11-22\nsummary: Why the readout was too small.\n---\n\nBody.\n",
            encoding="utf-8",
        )
        self.text = self.log / "2026-11-22-pixel-ratio.linkedin.txt"
        self.text.write_text("Fixed the readout's pixel ratio (PR #859). #Flutter\n", encoding="utf-8")

    def test_payload_links_the_entry(self):
        entry, url, body = linkedin_post.payload(self.text, "urn:li:person:abc")
        self.assertEqual(url, "https://segno.aquiles.dev/log/pixel-ratio/")
        self.assertEqual(body["author"], "urn:li:person:abc")
        self.assertEqual(body["content"]["article"]["source"], url)
        self.assertEqual(body["content"]["article"]["title"], "The pixel ratio")
        self.assertEqual(body["commentary"], "Fixed the readout's pixel ratio \\(PR \\#859\\). {hashtag|\\#|Flutter}")

    def test_a_text_without_its_entry_fails(self):
        orphan = self.log / "2026-11-23-orphan.linkedin.txt"
        orphan.write_text("text", encoding="utf-8")
        with self.assertRaises(dc.ToolError):
            dc.entry_for(orphan)

    def test_too_long_text_fails(self):
        self.text.write_text("x" * (dc.LINKEDIN_MAX_CHARS + 1), encoding="utf-8")
        with self.assertRaises(dc.ToolError):
            dc.read_post_text(self.text)

    def test_notify_message_names_the_reply(self):
        pr = devlog_pr(files=[{"path": "site/log/2026-11-22-pixel-ratio.linkedin.txt"}])
        with mock.patch.object(dc, "REPO_ROOT", self.root):
            text = telegram_notify.message(pr, None)
        self.assertIn('Reply "publish 1830"', text)
        self.assertIn("Fixed the readout's pixel ratio (PR #859). #Flutter", text)
        self.assertIn("https://segno.aquiles.dev/log/pixel-ratio/", text)


class SmallHelpersTest(unittest.TestCase):
    def test_linkedin_version_is_last_month(self):
        self.assertEqual(dc.linkedin_version(datetime.date(2026, 11, 17)), "202610")
        self.assertEqual(dc.linkedin_version(datetime.date(2027, 1, 5)), "202612")

    def test_expiry_warning(self):
        today = datetime.date(2026, 11, 17)
        self.assertEqual(telegram_notify.expiry_warning("2027-01-16", today), "")
        self.assertIn("expires in 10 days", telegram_notify.expiry_warning("2026-11-27", today))
        self.assertIn("expired", telegram_notify.expiry_warning("2026-11-01", today))
        self.assertEqual(telegram_notify.expiry_warning(None, today), "")


if __name__ == "__main__":
    unittest.main()
