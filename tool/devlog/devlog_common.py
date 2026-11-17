"""Shared helpers for the devlog's LinkedIn and Telegram tools.

Standard library only, like site/build_log.py, so the workflows need no
installs. Nothing here prints a token.
"""

from __future__ import annotations

import datetime
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = REPO_ROOT / "site"
LOG = SITE / "log"
BASE_URL = "https://segno.aquiles.dev"
REPO = "tomassasovsky/segno"
TRUNK = "claude/segno-integration"
DEVLOG_BRANCH_PREFIX = "claude/devlog-"

# A LinkedIn post's text sits next to its entry: site/log/<entry>.linkedin.txt
LINKEDIN_SUFFIX = ".linkedin.txt"
LINKEDIN_FILE = re.compile(
    r"^site/log/(?P<stem>\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*)\.linkedin\.txt$"
)
LINKEDIN_MAX_CHARS = 3000

sys.path.insert(0, str(SITE))
import build_log  # noqa: E402  (site/build_log.py reads the entry format)


class ToolError(Exception):
    """A failure to report and stop on, with no secret in the message."""


def entry_for(linkedin_path: pathlib.Path) -> dict:
    """The devlog entry a LinkedIn text belongs to, read by build_log."""
    name = linkedin_path.name
    if not name.endswith(LINKEDIN_SUFFIX):
        raise ToolError(f"{name}: a LinkedIn text is named <entry>{LINKEDIN_SUFFIX}")
    md = linkedin_path.with_name(name[: -len(LINKEDIN_SUFFIX)] + ".md")
    if not md.is_file():
        raise ToolError(f"{name}: no entry {md.name} next to it")
    try:
        return build_log.read_entry(md)
    except build_log.EntryError as e:
        raise ToolError(str(e)) from None


def entry_url(entry: dict) -> str:
    return f"{BASE_URL}/log/{entry['slug']}/"


# LinkedIn's "little text" format reserves these characters in commentary.
# Unescaped, they can cut the post short or vanish.
_RESERVED = set("\\|{}@[]()<>#*_~")
_HASHTAG = re.compile(r"(?<![\w#])#([A-Za-z][A-Za-z0-9_]*)")


def little_text(text: str) -> str:
    """Escape text for a post's commentary, keeping #Words as hashtags."""
    out = []
    pos = 0
    for m in _HASHTAG.finditer(text):
        out.append(_escape(text[pos : m.start()]))
        out.append("{hashtag|\\#|" + m.group(1) + "}")
        pos = m.end()
    out.append(_escape(text[pos:]))
    return "".join(out)


def _escape(s: str) -> str:
    return "".join("\\" + c if c in _RESERVED else c for c in s)


def read_post_text(linkedin_path: pathlib.Path) -> str:
    text = linkedin_path.read_text(encoding="utf-8").strip()
    if not text:
        raise ToolError(f"{linkedin_path.name} is empty")
    if len(text) > LINKEDIN_MAX_CHARS:
        raise ToolError(f"{linkedin_path.name} is {len(text)} characters; LinkedIn allows {LINKEDIN_MAX_CHARS}")
    return text


def http(method: str, url: str, *, headers: dict | None = None, body: bytes | None = None, timeout: int = 30):
    """Returns (status, headers, body bytes). Error bodies are returned, not raised."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


class Telegram:
    def __init__(self, token: str, chat_id: str):
        self._base = f"https://api.telegram.org/bot{token}/"
        self.chat_id = str(chat_id)

    def call(self, method: str, **params):
        status, _, body = http(
            "POST",
            self._base + method,
            headers={"Content-Type": "application/json"},
            body=json.dumps(params).encode(),
        )
        try:
            data = json.loads(body)
        except ValueError:
            data = {}
        if status != 200 or not data.get("ok"):
            # The URL holds the token, so only the method and Telegram's own
            # description are reported.
            raise ToolError(f"Telegram {method} failed ({status}): {data.get('description', 'no description')}")
        return data["result"]

    def send(self, text: str) -> None:
        if len(text) > 4000:
            text = text[:3990] + "\n[...]"
        self.call("sendMessage", chat_id=self.chat_id, text=text, disable_web_page_preview=True)


def linkedin_version(now: datetime.date | None = None) -> str:
    """LinkedIn-Version header: last month, the newest version surely live."""
    now = now or datetime.date.today()
    year, month = (now.year, now.month - 1) if now.month > 1 else (now.year - 1, 12)
    return f"{year}{month:02d}"


APPROVAL = re.compile(r"^\s*/?(publish|skip)\s+#?(\d+)\s*$", re.IGNORECASE)


def parse_approval(text: str):
    """('publish'|'skip', PR number) for an approval message, else None."""
    m = APPROVAL.match(text or "")
    if not m:
        return None
    return m.group(1).lower(), int(m.group(2))


def devlog_pr_problems(pr: dict) -> list:
    """Why a PR may not be merged from Telegram. Empty means it may."""
    problems = []
    if pr.get("state") != "OPEN":
        problems.append(f"it is {str(pr.get('state', 'unknown')).lower()}")
    if pr.get("isDraft"):
        problems.append("it is a draft")
    if pr.get("baseRefName") != TRUNK:
        problems.append(f"it targets {pr.get('baseRefName')}, not {TRUNK}")
    if not str(pr.get("headRefName", "")).startswith(DEVLOG_BRANCH_PREFIX):
        problems.append(f"its branch {pr.get('headRefName')} is not a {DEVLOG_BRANCH_PREFIX}* branch")
    outside = [f["path"] for f in pr.get("files", []) if not f["path"].startswith("site/")]
    if outside:
        problems.append("it changes files outside site/: " + ", ".join(outside[:5]))
    if not any(LINKEDIN_FILE.match(f["path"]) for f in pr.get("files", [])):
        problems.append("it has no site/log/*.linkedin.txt")
    return problems


def checks_state(rollup: list) -> str:
    """'green', 'pending' or 'red' for a PR's statusCheckRollup."""
    ok = {"SUCCESS", "SKIPPED", "NEUTRAL"}
    pending = False
    for c in rollup or []:
        if c.get("__typename") == "StatusContext":
            state = c.get("state")
            if state in ("PENDING", "EXPECTED"):
                pending = True
            elif state != "SUCCESS":
                return "red"
            continue
        if c.get("status") != "COMPLETED":
            pending = True
        elif c.get("conclusion") not in ok:
            return "red"
    return "pending" if pending else "green"


def require_env(environ, *names: str) -> dict:
    missing = [n for n in names if not environ.get(n)]
    if missing:
        raise ToolError("not set up yet, missing: " + ", ".join(missing))
    return {n: environ[n] for n in names}
