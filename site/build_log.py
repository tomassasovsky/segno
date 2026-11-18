#!/usr/bin/env python3
"""Build the devlog from the Markdown entries in site/log.

Each entry is site/log/YYYY-MM-DD-slug.md and starts with front matter:

    ---
    title: What changed this week
    date: 2026-11-17
    summary: One or two sentences for the list, the feed and link previews.
    ---

The script writes, under site/public:

    log/<slug>/index.html   one page per entry
    log/index.html          every entry, newest first
    feed.xml                RSS 2.0, absolute URLs on https://segno.aquiles.dev
    sitemap.xml             the home page, the list and every entry

and removes the page of an entry that no longer exists. The output is
committed, so the site keeps serving plain files.

    python3 site/build_log.py           write the output
    python3 site/build_log.py --check   exit 1 if the output is out of date (CI)

Asset references in the output carry ?v=<hash> from stamp.py. The header's
links and the footer are copied from index.html.
"""

import datetime
import email.utils
import html
import pathlib
import re
import shutil
import sys

from stamp import stamp

SITE = pathlib.Path(__file__).resolve().parent
LOG = SITE / "log"
PUBLIC = SITE / "public"
BASE = "https://segno.aquiles.dev"
FEED_TITLE = "Segno devlog"
FEED_DESCRIPTION = (
    "Progress notes on Segno, an open-source live looping appliance: "
    "the console, the audio engine, the firmware and the Flutter interface."
)
ENTRY_FILE = re.compile(r"(?P<date>\d{4}-\d{2}-\d{2})-(?P<slug>[a-z0-9]+(?:-[a-z0-9]+)*)\.md")
REQUIRED = ("title", "date", "summary")


class EntryError(Exception):
    pass


# Markdown ------------------------------------------------------------------
#
# A small subset, enough for a progress note: paragraphs, ## to #### headings,
# lists, block quotes, fenced code, images on a line of their own, and inline
# code, links, <autolinks>, **bold** and *emphasis*. Raw HTML is escaped, not
# passed through. "# " is refused because the title is the page's only h1.

INLINE_CODE = re.compile(r"(`+)(.+?)\1")
LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
AUTOLINK = re.compile(r"&lt;(https?://[^\s&]+)&gt;")
BOLD = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
EM = re.compile(r"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])")
IMAGE = re.compile(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)')
HEADING = re.compile(r"(#{1,6})\s+(.*)")
BULLET = re.compile(r"[-*]\s+(.*)")
NUMBER = re.compile(r"\d+\.\s+(.*)")


def inline(text: str) -> str:
    # Code spans become placeholders first, so their contents are left alone
    # and a link's text can still be code: [`site/log/`](url).
    codes = []

    def hold(m: re.Match) -> str:
        codes.append(f"<code>{html.escape(m[2].strip(), quote=False)}</code>")
        return f"\0{len(codes) - 1}\0"

    text = html.escape(INLINE_CODE.sub(hold, text), quote=False)
    text = LINK.sub(lambda m: f'<a href="{m[2].replace(chr(34), "%22")}">{m[1]}</a>', text)
    text = AUTOLINK.sub(lambda m: f'<a href="{m[1]}">{m[1]}</a>', text)
    text = BOLD.sub(r"<strong>\1</strong>", text)
    text = EM.sub(r"<em>\1</em>", text)
    return re.sub(r"\0(\d+)\0", lambda m: codes[int(m[1])], text)


def markdown(source: str, where: str) -> str:
    lines = source.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        if stripped.startswith("```"):
            lang = stripped[3:].strip()
            body = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                body.append(lines[i])
                i += 1
            if i == len(lines):
                raise EntryError(f"{where}: a code block is not closed")
            i += 1
            cls = f' class="language-{html.escape(lang)}"' if lang else ""
            code = html.escape("\n".join(body), quote=False)
            blocks.append(f"<pre><code{cls}>{code}</code></pre>")
            continue
        if m := HEADING.fullmatch(stripped):
            level = len(m[1])
            if level == 1:
                raise EntryError(f"{where}: use ## for headings; the title is the page's h1")
            if level > 4:
                raise EntryError(f"{where}: headings go down to ####")
            blocks.append(f"<h{level}>{inline(m[2])}</h{level}>")
            i += 1
            continue
        if m := IMAGE.fullmatch(stripped):
            alt, src, caption = m[1], m[2], m[3]
            if not alt:
                raise EntryError(f"{where}: image {src} needs alt text")
            img = f'<img src="{html.escape(src)}" alt="{html.escape(alt)}" loading="lazy">'
            cap = f"<figcaption>{inline(caption)}</figcaption>" if caption else ""
            blocks.append(f"<figure>{img}{cap}</figure>")
            i += 1
            continue
        if stripped.startswith(">"):
            quoted = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quoted.append(lines[i].strip()[1:].removeprefix(" "))
                i += 1
            blocks.append(f"<blockquote>\n{markdown(chr(10).join(quoted), where)}\n</blockquote>")
            continue
        for pattern, tag in ((BULLET, "ul"), (NUMBER, "ol")):
            if pattern.fullmatch(stripped):
                items = []
                while i < len(lines):
                    s = lines[i].strip()
                    if m := pattern.fullmatch(s):
                        items.append([m[1]])
                    elif s and lines[i][:1].isspace() and items:
                        items[-1].append(s)
                    else:
                        break
                    i += 1
                lis = "\n".join(f"<li>{inline(' '.join(item))}</li>" for item in items)
                blocks.append(f"<{tag}>\n{lis}\n</{tag}>")
                break
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not _starts_block(lines[i].strip()):
                para.append(lines[i].strip())
                i += 1
            blocks.append(f"<p>{inline(' '.join(para))}</p>")
    return "\n".join(blocks)


def _starts_block(s: str) -> bool:
    return bool(
        s.startswith(("```", ">"))
        or HEADING.fullmatch(s)
        or IMAGE.fullmatch(s)
        or BULLET.fullmatch(s)
        or NUMBER.fullmatch(s)
    )


# Entries -------------------------------------------------------------------


def read_entry(path: pathlib.Path) -> dict:
    where = f"site/log/{path.name}"
    name = ENTRY_FILE.fullmatch(path.name)
    if not name:
        raise EntryError(f"{where}: name it YYYY-MM-DD-slug.md, slug in lowercase words and hyphens")
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise EntryError(f"{where}: start with front matter between --- lines")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise EntryError(f"{where}: the front matter is not closed with ---")
    meta = {}
    for line in text[4:end].splitlines():
        if not line.strip():
            continue
        key, sep, value = line.partition(":")
        if not sep:
            raise EntryError(f"{where}: front matter line {line!r} is not key: value")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        meta[key.strip()] = value
    missing = [k for k in REQUIRED if not meta.get(k)]
    if missing:
        raise EntryError(f"{where}: front matter needs {', '.join(missing)}")
    unknown = sorted(set(meta) - set(REQUIRED))
    if unknown:
        raise EntryError(f"{where}: unknown front matter {', '.join(unknown)}")
    try:
        date = datetime.date.fromisoformat(meta["date"])
    except ValueError:
        raise EntryError(f"{where}: date {meta['date']!r} is not YYYY-MM-DD") from None
    if meta["date"] != name["date"]:
        raise EntryError(f"{where}: the date {meta['date']} does not match the file name")
    return {
        "slug": name["slug"],
        "title": meta["title"],
        "date": date,
        "summary": meta["summary"],
        "body": markdown(text[end + 5:], where),
    }


def read_entries() -> list:
    entries = [read_entry(p) for p in sorted(LOG.glob("*.md"))] if LOG.is_dir() else []
    seen = {}
    for e in entries:
        if e["slug"] in seen:
            raise EntryError(f"two entries use the slug {e['slug']!r}; slugs must be unique")
        seen[e["slug"]] = e
    return sorted(entries, key=lambda e: (e["date"], e["slug"]), reverse=True)


# Pages ---------------------------------------------------------------------


def from_index(pattern: str) -> str:
    index = (PUBLIC / "index.html").read_text(encoding="utf-8")
    m = re.search(pattern, index, re.S)
    if not m:
        raise EntryError(f"index.html has no match for {pattern!r}")
    return m[0]


def nav() -> str:
    # The home page's links are relative to /; make them work from any path.
    links = from_index(r'<nav class="nav".*?</nav>\s*<a class="nav-source".*?</a>')
    links = re.sub(r'href="(?!https?:|/)', 'href="/', links)
    return links.replace('href="/log/"', 'href="/log/" aria-current="page"')


def human(date: datetime.date) -> str:
    return f"{date.day} {date:%B %Y}"


def page(*, title: str, description: str, path: str, og_type: str, main: str, extra_head: str = "") -> str:
    url = BASE + path
    t, d = html.escape(title), html.escape(description)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{t}</title>
<meta name="description" content="{d}">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#0b0b0c" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#f6f6f4" media="(prefers-color-scheme: light)">
<link rel="canonical" href="{url}">
<link rel="alternate" type="application/rss+xml" title="{FEED_TITLE}" href="/feed.xml">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta property="og:type" content="{og_type}">
<meta property="og:site_name" content="Segno">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{BASE}/img/og.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Render of the Segno floor console.">
<meta name="twitter:card" content="summary_large_image">
{extra_head}<link rel="preload" href="/fonts/Inter-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/fonts/Inter-SemiBold.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
{from_index(r'<svg class="sprite".*?</svg>')}

<header class="bar">
  <div class="wrap bar-inner">
    <a class="brand" href="/" aria-label="Segno home page">
      <svg class="brand-glyph" aria-hidden="true"><use href="#glyph"/></svg>
      <span class="brand-word">segno</span>
    </a>
    {nav()}
  </div>
</header>

<main id="main" tabindex="-1">
{main}
</main>

{from_index(r'<footer class="foot">.*?</footer>')}
</body>
</html>
"""


def entry_page(e: dict) -> str:
    iso = e["date"].isoformat()
    main = f"""  <article class="post wrap">
    <p class="eyebrow"><a href="/log/">Devlog</a> &middot; <time datetime="{iso}">{human(e['date'])}</time></p>
    <h1>{html.escape(e['title'])}</h1>
    <p class="lede">{html.escape(e['summary'])}</p>
    <div class="prose">
{e['body']}
    </div>
    <p class="post-foot"><a href="/log/">All entries</a> &middot; <a href="/feed.xml">RSS feed</a></p>
  </article>"""
    return page(
        title=f"{e['title']} · Segno devlog",
        description=e["summary"],
        path=f"/log/{e['slug']}/",
        og_type="article",
        main=main,
        extra_head=f'<meta property="article:published_time" content="{iso}">\n',
    )


def list_page(entries: list) -> str:
    if entries:
        items = "\n".join(
            f"""      <li>
        <time datetime="{e['date'].isoformat()}">{human(e['date'])}</time>
        <h2><a href="/log/{e['slug']}/">{html.escape(e['title'])}</a></h2>
        <p>{html.escape(e['summary'])}</p>
      </li>"""
            for e in entries
        )
        listing = f'    <ol class="entries" reversed>\n{items}\n    </ol>'
    else:
        listing = '    <p class="entries-empty">No entries yet.</p>'
    main = f"""  <section class="post wrap">
    <p class="eyebrow">Devlog</p>
    <h1>What changed in Segno</h1>
    <p class="lede">Progress notes on the console, the audio engine, the firmware and the interface, written from the work that merged. Follow along with the <a href="/feed.xml">RSS feed</a>.</p>
{listing}
  </section>"""
    return page(title=FEED_TITLE, description=FEED_DESCRIPTION, path="/log/", og_type="website", main=main)


# Feed and sitemap ----------------------------------------------------------


def absolute(fragment: str) -> str:
    return re.sub(r'(href|src)="/(?!/)', rf'\1="{BASE}/', fragment)


def rfc822(date: datetime.date) -> str:
    moment = datetime.datetime(date.year, date.month, date.day, tzinfo=datetime.timezone.utc)
    return email.utils.format_datetime(moment)


def feed(entries: list) -> str:
    x = lambda s: html.escape(s, quote=False)  # noqa: E731
    items = []
    for e in entries:
        url = f"{BASE}/log/{e['slug']}/"
        body = absolute(e["body"]).replace("]]>", "]]]]><![CDATA[>")
        items.append(
            f"""    <item>
      <title>{x(e['title'])}</title>
      <link>{url}</link>
      <guid isPermaLink="true">{url}</guid>
      <pubDate>{rfc822(e['date'])}</pubDate>
      <description>{x(e['summary'])}</description>
      <content:encoded><![CDATA[{body}]]></content:encoded>
    </item>"""
        )
    built = f"\n    <lastBuildDate>{rfc822(entries[0]['date'])}</lastBuildDate>" if entries else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>{FEED_TITLE}</title>
    <link>{BASE}/log/</link>
    <description>{x(FEED_DESCRIPTION)}</description>
    <language>en</language>{built}
    <atom:link href="{BASE}/feed.xml" rel="self" type="application/rss+xml"/>
{chr(10).join(items)}
  </channel>
</rss>
""".replace("\n\n  </channel>", "\n  </channel>")


def sitemap(entries: list) -> str:
    urls = [f"  <url>\n    <loc>{BASE}/</loc>\n  </url>"]
    newest = f"\n    <lastmod>{entries[0]['date'].isoformat()}</lastmod>" if entries else ""
    urls.append(f"  <url>\n    <loc>{BASE}/log/</loc>{newest}\n  </url>")
    urls += [
        f"  <url>\n    <loc>{BASE}/log/{e['slug']}/</loc>\n    <lastmod>{e['date'].isoformat()}</lastmod>\n  </url>"
        for e in entries
    ]
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(urls)
        + "\n</urlset>\n"
    )


# Main ----------------------------------------------------------------------


def outputs(entries: list) -> dict:
    files = {f"log/{e['slug']}/index.html": stamp(entry_page(e)) for e in entries}
    files["log/index.html"] = stamp(list_page(entries))
    files["feed.xml"] = stamp(feed(entries))
    files["sitemap.xml"] = sitemap(entries)
    return files


def main() -> int:
    check = "--check" in sys.argv[1:]
    try:
        files = outputs(read_entries())
    except EntryError as err:
        print(err)
        return 1
    stale = [n for n, text in files.items() if not (PUBLIC / n).is_file() or (PUBLIC / n).read_text(encoding="utf-8") != text]
    built = PUBLIC / "log"
    orphans = sorted(
        d for d in built.iterdir() if d.is_dir() and f"log/{d.name}/index.html" not in files
    ) if built.is_dir() else []
    if check:
        if stale or orphans:
            names = stale + [f"log/{d.name}/" for d in orphans]
            print(f"devlog output out of date: {', '.join(names)}; run python3 site/build_log.py")
            return 1
        return 0
    for name in stale:
        (PUBLIC / name).parent.mkdir(parents=True, exist_ok=True)
        (PUBLIC / name).write_text(files[name], encoding="utf-8")
    for d in orphans:
        shutil.rmtree(d)
    changed = stale + [f"removed log/{d.name}/" for d in orphans]
    print(f"built {', '.join(changed) or 'nothing (already current)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
