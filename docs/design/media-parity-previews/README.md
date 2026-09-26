# Media correction browser evidence

Saved September 8, 2026 from fresh headless Chrome and Firefox contexts. These are silent UX-study images, not appliance or audio evidence. The [correction record](../2026-09-08-media-parity-correction.md) records outcomes and production limits.

| Journey | Chrome | Firefox |
|---|---|---|
| Session management | [View](chromium-session-manage.png) | [View](firefox-session-manage.png) |
| Fixed bottom keyboard | [View](chromium-session-keyboard.png) | [View](firefox-session-keyboard.png) |
| Session folder | [View](chromium-session-folder.png) | [View](firefox-session-folder.png) |
| Missing tempo | [View](chromium-import-unknown.png) | [View](firefox-import-unknown.png) |
| Adapt with file tempo | [View](chromium-import-adapt.png) | [View](firefox-import-adapt.png) |
| Shared backing mix | [View](chromium-backing-mix.png) | [View](firefox-backing-mix.png) |
| Backing performance | [View](chromium-backing-performance.png) | [View](firefox-backing-performance.png) |
| Independent USB restore | [View](chromium-session-restored.png) | [View](firefox-session-restored.png) |

Reproduce with `node ../media-parity-browser.test.cjs` after starting the design preview server. Resolve Playwright through `NODE_PATH`; optional `CHROME_EXECUTABLE` selects an installed Chrome. Set `MEDIA_TEST_FIREFOX=1` to run both engines and `MEDIA_PREVIEW_OUTPUT` to save the images. `SEGNO_PREVIEW_URL` can override the default local preview URL. The script creates isolated browser contexts and never resets the user's saved preview.
