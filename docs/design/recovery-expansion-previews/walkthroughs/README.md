# Recorded walkthrough

[Watch with chapters](../walkthrough.html) or play `all-flows.mp4` directly.
The six chapter files can also be played independently.

This is a silent recording of real browser UI interactions. Captions and a
visible pointer are recording overlays, not product UI. Simulated time is
explicitly labeled in the long-recording example. No native audio capture,
physical storage copying or appliance restart is demonstrated.

With the prototype server running, Playwright available to Node, and ffmpeg on
PATH:

```sh
node docs/design/record_recovery_walkthrough.cjs --dry-run
node docs/design/record_recovery_walkthrough.cjs
node docs/design/package_recovery_walkthrough.cjs
```

`ATLAS_CHROME` can select a Chrome executable. `FX_PROTOTYPE_URL` can select
another served prototype. `--only=02-audio-connections` records one chapter;
repackage afterward. Recording runs use isolated browser contexts.

All six recorded paths assert the demonstrated results. Packaging preserves
their playback speed and generates the chapter JSON, VTT and poster.
