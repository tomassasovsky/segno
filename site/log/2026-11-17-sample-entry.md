---
title: "Sample entry: how the devlog is built"
date: 2026-11-17
summary: A sample entry for reviewing the devlog. It shows every piece of Markdown the generator supports, and it is deleted before the pull request merges.
---

**This is a sample entry.** It exists so the pull request that adds the devlog has something to show. Delete `site/log/2026-11-17-sample-entry.md` and run `python3 site/build_log.py` before merging.

## Where entries come from

Each entry is a Markdown file in [`site/log/`](https://github.com/tomassasovsky/segno/tree/master/site/log), named by date and slug. A short Python script turns the files into:

- one page per entry, under `/log/<slug>/`
- the list of entries at `/log/`, newest first
- an RSS feed at `/feed.xml`, and the sitemap

The generated pages are committed, so the server still serves plain files and the site keeps its rule of no JavaScript.

## Adding an entry

1. Write `site/log/YYYY-MM-DD-slug.md` with a title, a date and a summary.
2. Run the script.
3. Commit the Markdown and the output together.

```bash
python3 site/build_log.py
python3 site/build_log.py --check
```

### Pictures

A picture goes on a line of its own, with alt text and an optional caption. Label it for what it is, as the rest of the site does.

![The Segno console seen from above at an angle, with ten footswitches and two screens.](/img/console-iso-1200.webp "Render of the console design from Autodesk Fusion. This is not a photo.")

> A quote goes in a block like this one, and *emphasis* and links such as <https://segno.aquiles.dev> work inside it.
