#!/usr/bin/env python3
"""Authorize the devlog to post to your LinkedIn profile. Run locally.

Once, on https://www.linkedin.com/developers/apps:
  - create an app linked to a LinkedIn Page,
  - add the products "Share on LinkedIn" and "Sign In with LinkedIn using
    OpenID Connect",
  - under Auth, add the redirect URL http://localhost:8765/callback.

Then, now and every 60 days (the token's lifetime):
    python3 tool/devlog/setup_linkedin.py

It asks for the app's Client ID and Client Secret (the secret is not echoed),
opens LinkedIn's consent page, and stores LINKEDIN_ACCESS_TOKEN and
LINKEDIN_PERSON_URN as repository secrets and LINKEDIN_TOKEN_EXPIRES_AT as a
repository variable. It prints no token.
"""

from __future__ import annotations

import datetime
import getpass
import http.server
import json
import secrets
import subprocess
import sys
import urllib.parse
import webbrowser

import devlog_common as dc

PORT = 8765
REDIRECT = f"http://localhost:{PORT}/callback"
SCOPES = "openid profile w_member_social"


def wait_for_code(state: str) -> str:
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if query.get("state", [""])[0] != state:
                result["error"] = "the state did not match; start again"
            elif "error" in query:
                result["error"] = query.get("error_description", query["error"])[0]
            else:
                result["code"] = query.get("code", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Done. You can close this tab and go back to the terminal.")

        def log_message(self, *args):
            pass

    with http.server.HTTPServer(("localhost", PORT), Handler) as server:
        while not result:
            server.handle_request()
    if "error" in result:
        raise dc.ToolError(f"LinkedIn did not authorize: {result['error']}")
    return result["code"]


def exchange(code: str, client_id: str, client_secret: str) -> dict:
    status, _, body = dc.http(
        "POST",
        "https://www.linkedin.com/oauth/v2/accessToken",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        body=urllib.parse.urlencode(
            {
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": REDIRECT,
                "client_id": client_id,
                "client_secret": client_secret,
            }
        ).encode(),
    )
    data = json.loads(body or b"{}")
    if status != 200 or "access_token" not in data:
        raise dc.ToolError(f"token exchange failed ({status}): {data.get('error_description', data.get('error', ''))}")
    return data


def person_urn(token: str) -> str:
    status, _, body = dc.http(
        "GET", "https://api.linkedin.com/v2/userinfo", headers={"Authorization": f"Bearer {token}"}
    )
    data = json.loads(body or b"{}")
    if status != 200 or "sub" not in data:
        raise dc.ToolError(f"could not read your LinkedIn member id ({status})")
    return f"urn:li:person:{data['sub']}"


def main() -> int:
    client_id = input("LinkedIn app Client ID: ").strip()
    client_secret = getpass.getpass("LinkedIn app Client Secret (not shown): ").strip()
    if not client_id or not client_secret:
        print("Both are needed.")
        return 1
    state = secrets.token_urlsafe(24)
    url = "https://www.linkedin.com/oauth/v2/authorization?" + urllib.parse.urlencode(
        {"response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT, "state": state, "scope": SCOPES}
    )
    print("Opening LinkedIn's consent page. If no browser opens, visit:\n" + url)
    webbrowser.open(url)
    token = exchange(wait_for_code(state), client_id, client_secret)
    urn = person_urn(token["access_token"])
    expires = datetime.date.today() + datetime.timedelta(seconds=int(token.get("expires_in", 0)))
    for name, value in (("LINKEDIN_ACCESS_TOKEN", token["access_token"]), ("LINKEDIN_PERSON_URN", urn)):
        subprocess.run(["gh", "secret", "set", name, "-R", dc.REPO], input=value, text=True, check=True)
    subprocess.run(
        ["gh", "variable", "set", "LINKEDIN_TOKEN_EXPIRES_AT", "-R", dc.REPO, "--body", expires.isoformat()],
        check=True,
    )
    print(f"Saved. The token expires on {expires.isoformat()}; the Telegram bot warns two weeks before.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (dc.ToolError, subprocess.CalledProcessError) as e:
        print(e, file=sys.stderr)
        sys.exit(1)
