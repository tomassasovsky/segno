<!-- cspell:words magick pyftsubset unicodes liga calt tnum healthz -->

# Segno website

The one-page site at <https://segno.aquiles.dev>. It is plain HTML and CSS with
no build step and no JavaScript.

```
public/index.html   the page
public/404.html     the not-found page
public/styles.css   light and dark palettes, phone layout
public/robots.txt   and sitemap.xml
public/img/         console renders, UI captures, the board view (WebP)
public/fonts/       Inter and JetBrains Mono, subset to Latin-1 (OFL)
nginx.conf          the server block inside the image
Dockerfile          nginx:alpine with public/ baked in
stamp.py            versions asset references by content hash
```

## Asset versions

Every reference to a local asset carries `?v=<hash>`, and nginx caches assets
for a year. After changing any file under `public/`, run:

```bash
python3 site/stamp.py
```

The Site workflow runs `python3 site/stamp.py --check` and fails on a stale
version.

## Preview

```bash
python3 -m http.server 8766 --directory site/public
```

## Pictures

Label every picture for what it is. The console renders come from the Fusion
model, the board view from KiCad, and the interface images from the app's UI
tests (the `screenshots` artifact of a CI run). None of them is a photo, and
the page says so. Do not use generated art.

Crop renders so the console sits in the middle of the frame: centre the crop
on the console's bounding box (the pixels brighter than the black background),
not on the original frame. To add a render, convert it to WebP at 1200 and
2000 pixels wide:

```bash
magick render.png -resize 1200x -strip -quality 80 site/public/img/name-1200.webp
magick render.png -resize 2000x -strip -quality 80 site/public/img/name-2000.webp
```

## Fonts

The fonts are subset from `assets/fonts` to keep the page small. Regenerate
them after adding characters outside Latin-1:

```bash
pyftsubset assets/fonts/Inter-Regular.ttf --flavor=woff2 \
  --unicodes="U+0020-007E,U+00A0-00FF,U+2013,U+2014,U+2018,U+2019,U+201C,U+201D,U+2026,U+2192,U+00D7" \
  --layout-features='kern,liga,calt,tnum' --output-file=site/public/fonts/Inter-Regular.woff2
```

WOFF2 output needs the `brotli` Python package next to `fonttools`.

## Deploy

`segno.aquiles.dev` is also the appliance update mirror
([`tomassasovsky/segno-updates`](https://github.com/tomassasovsky/segno-updates)),
behind Nginx Proxy Manager on the home server. Appliances poll
`/updates/appliance/<channel>/manifest.json` and CI posts to `/hooks/sync`, so
the site takes over `/` only:

1. A push to `site/` on the trunk or `master` runs `.github/workflows/site.yaml`,
   which publishes `ghcr.io/tomassasovsky/segno-site:latest`.
2. The `segno-updates` stack runs that image as `segno-site`. Its nginx proxies
   `/` to `segno-site:80` and keeps `/updates/`, `/hooks/sync` and `/healthz`.
3. The watchtower container on the same host pulls a new `latest` within five
   minutes. Nothing else needs a redeploy.

Check a deploy:

```bash
curl -sI https://segno.aquiles.dev/ | grep -i content-type
curl -s https://segno.aquiles.dev/healthz
curl -s https://segno.aquiles.dev/updates/appliance/experimental/manifest.json
```

The first prints `text/html`, the second `ok`, and the third the current
manifest.
