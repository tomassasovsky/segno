#!/usr/bin/env python3
"""Act on Tomás's Telegram replies to devlog PRs.

Run every 10 minutes by .github/workflows/devlog-telegram.yaml. It reads the
bot's new messages and acts only on these, sent from Tomás's own private chat
(TELEGRAM_CHAT_ID) within the last three days:

    publish <PR>   merge the devlog PR; the merge deploys the site and posts
                   the LinkedIn text (devlog-linkedin.yaml)
    skip <PR>      close the devlog PR and delete its branch

Only an open claude/devlog-* PR into the trunk that changes nothing outside
site/ and carries a site/log/*.linkedin.txt qualifies, and publish also needs
green checks. Every other message gets a short answer or is ignored.

Environment: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, and GH_TOKEN set to the
merge token (a merge with the workflow's own token would not start the deploy
and post workflows).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

import devlog_common as dc

MAX_AGE_S = 3 * 24 * 3600
HELP = 'I only act on "publish <PR number>" or "skip <PR number>".'


def gh(*args: str) -> str:
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise dc.ToolError(f"gh {args[0]} {args[1]} failed: {r.stderr.strip()[:300]}")
    return r.stdout


def view(number: int) -> dict:
    return json.loads(
        gh(
            "pr", "view", str(number), "-R", dc.REPO, "--json",
            "number,title,url,state,isDraft,baseRefName,headRefName,files,statusCheckRollup,mergeable",
        )
    )


def publish(number: int) -> str:
    pr = view(number)
    problems = dc.devlog_pr_problems(pr)
    if problems:
        return f"Not merging #{number}: " + "; ".join(problems) + "."
    if pr.get("mergeable") == "CONFLICTING":
        return f"Not merging #{number}: it has conflicts with {dc.TRUNK}."
    checks = dc.checks_state(pr.get("statusCheckRollup"))
    if checks == "pending":
        return f"#{number}'s checks are still running. Send \"publish {number}\" again once they finish."
    if checks == "red":
        return f"Not merging #{number}: a check failed. {pr['url']}/checks"
    gh("pr", "merge", str(number), "-R", dc.REPO, "--merge", "--delete-branch")
    return (
        f"Merged #{number}: {pr['title']}\n"
        "The site deploys within about five minutes, then the LinkedIn post goes out. I'll send its link here."
    )


def skip(number: int) -> str:
    pr = view(number)
    if pr.get("state") != "OPEN" or not str(pr.get("headRefName", "")).startswith(dc.DEVLOG_BRANCH_PREFIX):
        return f"Not closing #{number}: only an open {dc.DEVLOG_BRANCH_PREFIX}* PR can be skipped."
    gh("pr", "close", str(number), "-R", dc.REPO, "--delete-branch", "--comment", "Skipped from Telegram.")
    return f"Closed #{number} without publishing."


def from_owner(msg: dict, chat_id: str) -> bool:
    chat, sender = msg.get("chat", {}), msg.get("from", {})
    return chat.get("type") == "private" and str(chat.get("id")) == chat_id and str(sender.get("id")) == chat_id


def handle(msg: dict, chat_id: str, now: float) -> str | None:
    """The reply to one message, or None to ignore it."""
    if not from_owner(msg, chat_id) or now - msg.get("date", 0) > MAX_AGE_S:
        return None
    command = dc.parse_approval(msg.get("text", ""))
    if command is None:
        return HELP
    action, number = command
    try:
        return publish(number) if action == "publish" else skip(number)
    except dc.ToolError as e:
        return f"{action} {number} failed: {e}"


def main() -> int:
    try:
        env = dc.require_env(os.environ, "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "GH_TOKEN")
    except dc.ToolError as e:
        print(f"Telegram approvals {e}; nothing to do.")
        return 0
    telegram = dc.Telegram(env["TELEGRAM_BOT_TOKEN"], env["TELEGRAM_CHAT_ID"])
    updates = telegram.call("getUpdates", timeout=0, allowed_updates=["message"])
    if not updates:
        print("No new messages.")
        return 0
    try:
        now = time.time()
        for update in updates:
            msg = update.get("message")
            if not msg:
                continue
            reply = handle(msg, telegram.chat_id, now)
            if reply:
                print(reply)
                telegram.send(reply)
    finally:
        # Mark everything read, so a message is acted on once.
        telegram.call("getUpdates", offset=updates[-1]["update_id"] + 1, limit=1, timeout=0)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except dc.ToolError as e:
        print(e, file=sys.stderr)
        sys.exit(1)
