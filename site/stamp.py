#!/usr/bin/env python3
"""Version every local asset reference in the site by content hash.

Each reference to a file under site/public (styles.css, favicon.svg, img/...,
fonts/...) gets `?v=<first 8 hex of its sha256>`, so nginx can cache assets
for a year and a changed file still reaches visitors at once.

    python3 site/stamp.py           rewrite the references in place
    python3 site/stamp.py --check   exit 1 if any reference is stale (CI)

styles.css is stamped before the pages because its own hash covers the
font references inside it.
"""

import hashlib
import pathlib
import re
import sys

PUBLIC = pathlib.Path(__file__).resolve().parent / "public"
# styles.css first: the pages reference it, so its hash must be final.
FILES = ["styles.css", "index.html", "404.html"]
ASSET = re.compile(
    r"(?<![\w.-])(?P<path>(?:img|fonts)/[\w.-]+\.(?:webp|jpg|png|svg|woff2)"
    r"|styles\.css|favicon\.svg)(?:\?v=[0-9a-f]*)?"
)


def version(path: str) -> str:
    return hashlib.sha256((PUBLIC / path).read_bytes()).hexdigest()[:8]


def stamp(text: str) -> str:
    return ASSET.sub(lambda m: f"{m['path']}?v={version(m['path'])}", text)


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for name in FILES:
        file = PUBLIC / name
        before = file.read_text(encoding="utf-8")
        after = stamp(before)
        if after != before:
            stale.append(name)
            if not check:
                file.write_text(after, encoding="utf-8")
    if check and stale:
        print(f"stale asset versions in {', '.join(stale)}; run python3 site/stamp.py")
        return 1
    if not check:
        print(f"stamped {', '.join(stale) or 'nothing (already current)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
