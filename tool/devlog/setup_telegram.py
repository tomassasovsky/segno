#!/usr/bin/env python3
"""Connect the devlog's Telegram bot to this repository. Run once, locally.

1. In Telegram, talk to @BotFather, send /newbot and copy the token it gives.
2. Run: python3 tool/devlog/setup_telegram.py
3. Paste the token (it is not echoed), then send any message to your bot.

The script stores TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID as repository
secrets with `gh secret set` and prints neither. Only the chat that sends the
first message is trusted to approve devlog PRs, so send it from your own
account.
"""

from __future__ import annotations

import getpass
import subprocess
import sys
import time

import devlog_common as dc


def set_secret(name: str, value: str) -> None:
    subprocess.run(["gh", "secret", "set", name, "-R", dc.REPO], input=value, text=True, check=True)


def main() -> int:
    token = getpass.getpass("Bot token from @BotFather (not shown): ").strip()
    if not token:
        print("No token given.")
        return 1
    bot = dc.Telegram(token, "")
    me = bot.call("getMe")
    print(f"Bot found: @{me['username']}. Send it any message from your own Telegram account now.")
    deadline = time.monotonic() + 300
    offset = None
    chat_id = None
    while chat_id is None and time.monotonic() < deadline:
        params = {"timeout": 30, "allowed_updates": ["message"]}
        if offset is not None:
            params["offset"] = offset
        for update in bot.call("getUpdates", **params):
            offset = update["update_id"] + 1
            chat = update.get("message", {}).get("chat", {})
            if chat.get("type") == "private":
                chat_id = str(chat["id"])
    if chat_id is None:
        print("No private message arrived within five minutes. Run the script again.")
        return 1
    if offset is not None:
        bot.call("getUpdates", offset=offset, limit=1, timeout=0)
    set_secret("TELEGRAM_BOT_TOKEN", token)
    set_secret("TELEGRAM_CHAT_ID", chat_id)
    dc.Telegram(token, chat_id).send(
        "This chat now approves Segno's devlog PRs. Reply \"publish <PR>\" or \"skip <PR>\" when one arrives."
    )
    print(f"Saved TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID to {dc.REPO}. A confirmation is in your Telegram chat.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (dc.ToolError, subprocess.CalledProcessError) as e:
        print(e, file=sys.stderr)
        sys.exit(1)
