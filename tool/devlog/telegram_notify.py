#!/usr/bin/env python3
"""Ask Tomás on Telegram whether to publish a devlog PR.

Run by .github/workflows/devlog-telegram.yaml when a claude/devlog-* PR
opens. The message carries the entry's title and summary, the exact LinkedIn
text, the PR link and the reply that publishes it.

    python3 tool/devlog/telegram_notify.py --pr 1830

Environment: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GH_TOKEN (to read the PR),
optional LINKEDIN_TOKEN_EXPIRES_AT (YYYY-MM-DD) for an expiry warning.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys

import devlog_common as dc

WARN_DAYS = 14


def pr_info(number: int) -> dict:
    out = subprocess.run(
        ["gh", "pr", "view", str(number), "-R", dc.REPO, "--json", "number,title,url,files"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)


def expiry_warning(expires_at: str | None, today: datetime.date | None = None) -> str:
    if not expires_at:
        return ""
    try:
        expires = datetime.date.fromisoformat(expires_at)
    except ValueError:
        return ""
    days = (expires - (today or datetime.date.today())).days
    if days > WARN_DAYS:
        return ""
    if days < 0:
        return "\n\nThe LinkedIn token expired. Run tool/devlog/setup_linkedin.py before publishing."
    return f"\n\nThe LinkedIn token expires in {days} days. Run tool/devlog/setup_linkedin.py to renew it."


def message(pr: dict, expires_at: str | None) -> str:
    texts = [f["path"] for f in pr["files"] if dc.LINKEDIN_FILE.match(f["path"])]
    if not texts:
        raise dc.ToolError(f"PR #{pr['number']} has no site/log/*.linkedin.txt")
    path = dc.REPO_ROOT / texts[0]
    entry = dc.entry_for(path)
    n = pr["number"]
    return (
        f"New devlog entry: {entry['title']}\n"
        f"{entry['summary']}\n\n"
        f"LinkedIn post:\n"
        f"----------\n"
        f"{dc.read_post_text(path)}\n"
        f"----------\n\n"
        f"Entry (live after merge): {dc.entry_url(entry)}\n"
        f"PR: {pr['url']}\n\n"
        f"Reply \"publish {n}\" to merge it and post to LinkedIn, or \"skip {n}\" to close it."
        f"{expiry_warning(expires_at)}"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pr", type=int, required=True)
    args = ap.parse_args()
    try:
        env = dc.require_env(os.environ, "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID")
    except dc.ToolError as e:
        print(f"Telegram {e}; skipping the notification.")
        return 0
    try:
        text = message(pr_info(args.pr), os.environ.get("LINKEDIN_TOKEN_EXPIRES_AT"))
        dc.Telegram(env["TELEGRAM_BOT_TOKEN"], env["TELEGRAM_CHAT_ID"]).send(text)
    except dc.ToolError as e:
        print(e, file=sys.stderr)
        return 1
    print(f"Asked on Telegram about PR #{args.pr}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
