# The Segno website as a static nginx image, published to
# ghcr.io/tomassasovsky/segno-site by .github/workflows/site.yaml.
FROM nginx:1.30-alpine
LABEL org.opencontainers.image.source="https://github.com/tomassasovsky/segno"
LABEL org.opencontainers.image.description="The Segno website (segno.aquiles.dev)"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
