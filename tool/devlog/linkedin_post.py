#!/usr/bin/env python3
"""Post a devlog entry's LinkedIn text to Tomás's own profile.

Run by .github/workflows/devlog-linkedin.yaml after a merge to the trunk.
It posts once for each site/log/<entry>.linkedin.txt the push added, after
the entry's page is live, with the entry as the link preview.

    python3 tool/devlog/linkedin_post.py --before SHA --after SHA
    python3 tool/devlog/linkedin_post.py --file site/log/<entry>.linkedin.txt --dry-run

Environment: LINKEDIN_ACCESS_TOKEN and LINKEDIN_PERSON_URN (repository
secrets, written by tool/devlog/setup_linkedin.py), optional
LINKEDIN_API_VERSION, and optional TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID to
report the result.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.parse

import devlog_common as dc

POSTS_URL = "https://api.linkedin.com/rest/posts"


def added_texts(before: str, after: str) -> list:
    out = subprocess.run(
        ["git", "diff", "--diff-filter=A", "--name-only", before, after, "--", "site/log"],
        cwd=dc.REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [dc.REPO_ROOT / p for p in out.split() if dc.LINKEDIN_FILE.match(p)]


def payload(path: pathlib.Path, author: str) -> tuple:
    entry = dc.entry_for(path)
    url = dc.entry_url(entry)
    body = {
        "author": author,
        "commentary": dc.little_text(dc.read_post_text(path)),
        "visibility": "PUBLIC",
        "distribution": {
            "feedDistribution": "MAIN_FEED",
            "targetEntities": [],
            "thirdPartyDistributionChannels": [],
        },
        "content": {
            "article": {
                "source": url,
                "title": entry["title"],
                "description": entry["summary"],
            }
        },
        "lifecycleState": "PUBLISHED",
        "isReshareDisabledByAuthor": False,
    }
    return entry, url, body


def wait_until_live(url: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while True:
        status, _, _ = dc.http("GET", url, timeout=20)
        if status == 200:
            return
        if time.monotonic() > deadline:
            raise dc.ToolError(f"{url} still answers {status} after {timeout} s; not posting a dead link")
        time.sleep(30)


def post(body: dict, token: str, version: str) -> str:
    status, headers, raw = dc.http(
        "POST",
        POSTS_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "LinkedIn-Version": version,
            "X-Restli-Protocol-Version": "2.0.0",
            "Content-Type": "application/json",
        },
        body=json.dumps(body).encode(),
    )
    if status != 201:
        detail = raw.decode("utf-8", "replace")[:300]
        if status == 401:
            detail = "the access token is expired or revoked; run tool/devlog/setup_linkedin.py again. " + detail
        raise dc.ToolError(f"LinkedIn answered {status}: {detail}")
    urn = {k.lower(): v for k, v in headers.items()}.get("x-restli-id", "")
    return f"https://www.linkedin.com/feed/update/{urllib.parse.quote(urn, safe=':')}/" if urn else ""


def telegram_from_env():
    token, chat = os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID")
    return dc.Telegram(token, chat) if token and chat else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--before")
    ap.add_argument("--after")
    ap.add_argument("--file", action="append", default=[], help="a site/log/*.linkedin.txt to post")
    ap.add_argument("--dry-run", action="store_true", help="print the request body and post nothing")
    ap.add_argument("--wait", type=int, default=1200, help="seconds to wait for the entry's page to go live")
    args = ap.parse_args()

    paths = [dc.REPO_ROOT / f for f in args.file]
    if args.before and args.after:
        paths += added_texts(args.before, args.after)
    if not paths:
        print("No new LinkedIn text in this push; nothing to post.")
        return 0

    telegram = None if args.dry_run else telegram_from_env()
    failed = False
    for path in paths:
        try:
            if args.dry_run:
                _, url, body = payload(path, "urn:li:person:DRY-RUN")
                print(json.dumps(body, indent=2, ensure_ascii=False))
                continue
            env = dc.require_env(os.environ, "LINKEDIN_ACCESS_TOKEN", "LINKEDIN_PERSON_URN")
            entry, url, body = payload(path, env["LINKEDIN_PERSON_URN"])
            wait_until_live(url, args.wait)
            version = os.environ.get("LINKEDIN_API_VERSION") or dc.linkedin_version()
            link = post(body, env["LINKEDIN_ACCESS_TOKEN"], version)
            message = f"Posted to LinkedIn: {entry['title']}\n{link or '(LinkedIn returned no post id)'}"
            print(message)
            if telegram:
                telegram.send(message)
        except dc.ToolError as e:
            failed = True
            message = f"LinkedIn post failed for {path.name}: {e}"
            print(message, file=sys.stderr)
            if telegram:
                try:
                    telegram.send(message)
                except dc.ToolError as te:
                    print(te, file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
