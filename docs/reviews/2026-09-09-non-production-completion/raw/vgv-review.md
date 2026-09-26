# VGV Code Review

## Summary

The bounded local prototype has no unresolved actionable findings in the reviewed code. The render-channel, obsolete-preview-caller, frozen-capture lifecycle and persistent-recovery-cue findings were fixed and independently reproduced successfully. This is a review of the non-production completion plan for issue 919, not a production, CI, hardware or merge approval.

## Scope and independence

Reviewed the coordinator's recording, selected-render and illustrative-sound changes against `/tmp/segno-completion-baseline`, Carson's timing changes against `/tmp/segno-timing-completion-before`, their focused tests, and the new Audio Library drive-identity changes and regression by Dewey. The host review covers those adapters, lifecycle guards, publication and navigation, rather than unrelated dirty sections of the large prototype HTML file.

The repository's application uses Flutter, Bloc and Very Good Analysis. These changes are isolated browser JavaScript design studies. Reviewed the established pure-model, context-adapter and rendering boundaries for this stack; no application-layer, native callback, FFI, dependency or firmware changes are claimed. No implementation edits were made during this review.

I authored the optional-control/MIDI modules and tests in this pass and exclude them from the independent verdict. I also authored the older `processing-behavior-study.js`; its unchanged behavior is excluded. I independently reviewed Dewey's newly authorized removal of its duplicated render function and traced callers. I ran an additional isolated browser reproduction independently for frozen capture; it is not counted as independently reviewing my optional-controls test suite.

## Critical — unresolved

None.

## Important — unresolved

None.

## Suggestions

None. No style-only churn requested.

## Resolved findings and verified consequences

- **Held capture lost by session lifecycle:** failed Cut publication left a take only in the transport's frozen recovery map, but New loop/session replacement previously observed idle capture state and reset transport. Host `frozenCapturePending()` now composes relevant session, mode, device, power, backup and restore blockers; `commitSession` also rechecks before publication. The independent normal-host reproduction holds exactly 0.63 seconds across New loop, session next and a failed Restart, with current session identity and saved bytes unchanged. Physical Stop then saves those exact seconds as stopped audio.
- **Held capture became invisible after a transient notice:** Stage now keeps a Save held take control and a persistent recovery instruction while frozen audio exists. Verified visibility after ten seconds and successful physical Stop retry in both browsers.
- **USB copies retained the wrong storage identity:** inspected Dewey's new destination descriptor, per-drive catalogue/collision selection, captured drive identity and final revalidation. The dedicated suite independently proves USB A → Internal → USB B, identical multipart take/part identity, stale conflict refusal, copy/import/render races, preview stopping after a drive switch, failed-write retention and reload.

- **Rack channel processing omitted from render recipes:** the normal-host reproduction originally changed rack input/output/pan on Track 1 and All tracks without changing the recipe. The host now builds `renderRack` descriptors with effective placement and copied channel settings for selected Post and chosen shared FX. The dedicated browser test passes in Chrome and Firefox: printed Pre is excluded from runnable FX, Post appears once, channel choices are preserved, reading a recipe does not mutate the source, and changing channel settings changes the recipe used by Save's existing final revalidation.
- **Deleted API left a live preview caller:** removal of the duplicated `selectedRecipe` initially broke `processing-behavior-preview.html` with `P.selectedRecipe is not a function`. The page now imports and calls the common `SegnoSelectedRender.recipe`. A subsequent overflow caused by longer choice copy was also corrected. Its existing full browser checks pass in both browsers, including initial render, tabs, keyboard focus, tails, output comparison and bounds at 1920×1080 and 1280×1024. No bounds assertion was weakened.

- **Imported Follow-off length recheck:** independently inspected the new original-span/current-span ratio and ran the real import/Multiply/Divide/Save/reload journey. A 24-second imported source renders as 48 seconds after Multiply, then 24 and 12 seconds after Divide, while the original file/timing descriptor remains unchanged. The final saved and reloaded render is exactly 12 seconds. This correction is authored by Dewey and is included in this independent review.

## Architecture, conventions and simplicity

The shared render policy removes the separate Bounce duration calculation. Recorder checkpoint allocation remains a pure model, with storage accounting and publication supplied by the host. The illustrative sound generator has deterministic sample arrays and explicitly identifies itself as an example, and its UI stops examples on action changes, completion and leaving the page. Timing retains captured seconds separately from musical beat regions; the new musical cycle is independent of audible speed, reverse, Once and Follow. Publication failures preserve recoverable content and history. Cut all sound intentionally stops audible players despite write failure and retains the held take; it does not claim an atomic storage operation.

No speculative architecture or new runtime package was introduced in the reviewed slice. Existing prototype host size is not treated as a new finding. No independently justified abstraction removal is requested. Complexity is proportionate to the accepted recovery and processing behaviors.

## Independent validation

Commands ran from the repository root with the configured bundled Node runtime; browser commands also used the configured Playwright `NODE_PATH` and `ATLAS_CHROME` executable.

| Command | Observed result |
| --- | --- |
| `node --test docs/design/verify_processing_behavior.cjs docs/design/verify_selected_render_policy.cjs docs/design/verify_timing_completion.cjs` | 50/50 pass: 17 historical processing, 8 selected-render/sound and 25 timing tests. The historical processing tests are my authored regression suite, not an independent test-quality verdict. |
| `SKIP_SCREENSHOTS=1 TIMING_COMPLETION_OUTPUT=/tmp/segno-timing-independent-final node docs/design/verify_timing_completion_browser.cjs` | Chrome and Firefox pass, including held take, New loop/session refusal and failed Restart. |
| `node docs/design/verify_recording_completion_browser.cjs` | Chrome and Firefox pass: destination/tap persistence, drive loss, finalize race, slow writes, low/unknown space, settings recovery, selected render and example lifecycle. |
| `node docs/design/verify_audio_drive_identity_browser.cjs` | Chrome and Firefox pass: per-drive copies, exact multipart identity, replacement review, races, failed writes and reload. |
| `node /tmp/segno-review-frozen-lifecycle.cjs` | Chrome and Firefox pass with the exact 0.63-second take and unchanged current/stored data. |
| `node docs/design/verify_render_rack_processing_browser.cjs` | Chrome and Firefox pass: Post once, printed Pre excluded, channel metadata, read-only recipe and changed-channel detection. |
| `SEGNO_PROCESSING_BROWSER=1 node docs/design/verify_processing_behavior.cjs` | 19/19 pass: 17 model and both browser cases; original responsive bounds preserved. |
| `node docs/design/verify_imported_render_length_browser.cjs` | Chrome and Firefox pass: 24 → 48 → 24 → 12 seconds, immutable imported source, Save and reload. |
| `vm.Script` parsing of 21 reviewed modules/test scripts and the main/standalone inline scripts | Pass. |
| `git diff --check --` reviewed existing source paths | Pass. |

Tests exercise public model/context APIs and real browser actions on normal persisted routes; the illustrative rendering comparison alone uses a dedicated review scene. None of these checks proves real USB throughput, device timing, DSP processing, filesystem transactions or native audio quality. Pen and walkthrough validation belong to the coordinator and are outside this independent code report. No CI or production checks were substituted with prototype results.

## Reviewed source fingerprints

The source hashes below bind the final reviewed files. The coordinator remains responsible for Pen and video reconciliation and the consolidated gate.

| File under `docs/design` | SHA256 |
| --- | --- |
| `fx-ux-prototype.html` | `483ac9fe67deb2eec9384487b3440e0c74019ec23b2507b3d0ffc57dad04997d` |
| `selected-render-policy.js` | `0c9dd6be59b07b31d467b470b12dc4a091a0bedf68bd94c925cb2e894b0e507b` |
| `selected-render-policy.css` | `9fee2f48a23fbe55562b5ee4a6c456675d9180cd0ede903aeaadcbfb64a84f82` |
| `sound-behavior-audio.js` | `f801e7883fe004e6dbc780dcd3cb7ae4847fa21ad87887faab7df1f8af75e678` |
| `sound-behavior-study.js` | `a66d8a314b93cdaf2ff09b29d25513cef462c27573b8091ccdbf1861d5cee969` |
| `sound-behavior-study.css` | `3164c6112edea4f6a0fb218c9624ff03a7ad8fc3c31a7c02a5b1e53c62139445` |
| `performance-recording-model.js` | `e57e0694d46a70fd11ec50446541f3ddeef42ee5954f34914129139119a85856` |
| `performance-recording-study.js` | `602952defaa2785fd9525b0b1f55332ade59bef7faef28e49926919958a380d6` |
| `bounce-performance-study.js` | `d9ad2d4382d6f2b47028021cfb0fe8d18c0ebf504031745f770f0851041bcbbb` |
| `audio-library-study.js` | `c95a6e09ce50a02cdde226c6488c4f29ee234de280c475fafdc4b291f0dd770b` |
| `storage-study.js` | `ecbd437d64ba0858007bce7ff0fcd3857e76123f7c7cb5f61a59627d176122f2` |
| `stage-transport-study.js` | `513969b1a57d8f25d4e221956a8ad800abb494542965c5b116754615c9c063a0` |
| `primary-track-study.js` | `31096f736462c22565b4b0d4eefc1a01cb8693bbc0fad03edf38efa9421e6349` |
| `midi-sync-study.js` | `3ed47aaee2328eb2aff1ebdb5869981c9e2530ed3a1546d090db478ac3bf039f` |
| `recording-timing-scenes.js` | `a5e783935ee42d69748b6d4b62b1f7ea77a3581b05aa16714a28d00a588d582a` |
| `processing-behavior-study.js` | `6163f11216a171f1b737a13bc599406133a52a6bc425fb73427349bf73fdf501` |
| `processing-behavior-preview.html` | `7be1d5845837864b455bacb447ac5302d70b8e0ec82486766bb8919d5f798734` |
| `verify_processing_behavior.cjs` | `dfa2238a37fc8e08b8ecf9f53cb298bd9ba84107d88714287bee3e30118df506` |
| `verify_selected_render_policy.cjs` | `5c247ce8b578ebca0c67e34fd5ada1b50c250b4ea4972bc765e0363892390f74` |
| `verify_timing_completion.cjs` | `1a32c97ac68913d2eff70117800bea4e32a72cd87f5ad6bdb632b7f41aa1a021` |
| `verify_timing_completion_browser.cjs` | `609f1a2a9d9a1cf1d6941779dd8616771ef6514caf78a240e32a5c75eb31ae4b` |
| `verify_recording_completion_browser.cjs` | `0f56e01f5d4830414d2009046bb62eec8a8c798d1cef58466dfd444416563cfe` |
| `verify_audio_drive_identity_browser.cjs` | `8d0f77e4de512c15967afd59b6fc29b5cf854efe51925c94b9de9262b68c7c88` |
| `verify_render_rack_processing_browser.cjs` | `42b156c9d19fcec561fbad8956949353fc73e9c6eae9557124c00e3f6209f07f` |
| `verify_imported_render_length_browser.cjs` | `a22679798e7948ec41f22bdbaba2b62e05fd02cf1d585a14175d0e80e44bf0fb` |
