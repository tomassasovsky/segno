# Audit closure final validation

September 8, 2026. Author-side verification of the current design prototype.
All requested regression suites passed in Chrome and Firefox. The new pedal
and media model suites passed 20 tests. This record covers browser behavior
and simulated state; production, native audio, Flutter CI, and physical
appliance verification are outside this validation task.

## Environment and commands

Commands ran from the repository root with bundled Node v24.19.0 and
Playwright 1.62.1. `SEGNO_VALIDATION_NODE` and `SEGNO_VALIDATION_MODULES`
resolved to the configured bundled runtime; `SEGNO_VALIDATION_CHROME`
resolved to the installed Chrome executable. Machine-specific paths are
deliberately kept out of the repository. The prototype server was
`http://127.0.0.1:8768`. Each browser suite used fresh isolated contexts.

The harnesses offered no screenshot-skip option, so their built-in preview
captures ran. No code fixes were made by this validation task.

| Suite | Result | Process exit | Output |
|---|---|---:|---|
| Mixer reference | Chrome and Firefox passed. | 0 | [mixer-reference.log](mixer-reference.log) |
| Mapping browser | Chrome and Firefox passed. | 0 | [mapping.log](mapping.log) |
| Stage display | Chrome and Firefox passed. | 0 | [stage-display.log](stage-display.log) |
| Wave performance | Chrome and Firefox passed. | 0 | [wave.log](wave.log) |
| Loop journeys, Chrome | Passed, including seventeen preview captures. | 0 | [loop-chrome.log](loop-chrome.log) |
| Loop journeys, Firefox | Passed, including seventeen preview captures. | 0 | [loop-firefox.log](loop-firefox.log) |
| D1 and fine BPM | Chrome and Firefox passed. | 0 | [d1.log](d1.log) |
| D2 pedal closure | Chrome and Firefox passed. | 0 | [d2.log](d2.log) |
| Media closure | Chrome and Firefox passed; final CSS rerun recorded below. | 0 | [media.log](media.log) |
| D2 and media model suites | 20 passed; 0 failed, skipped or canceled | 0 | [new-model-suites.log](new-model-suites.log) |

The following command lines were executed exactly with the runtime variables
resolved as described above:

```sh
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_mixer_reference.cjs > docs/reviews/2026-09-08-audit-closure/mixer-reference.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_mapping_parity_browser.cjs > docs/reviews/2026-09-08-audit-closure/mapping.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_stage_display.cjs > docs/reviews/2026-09-08-audit-closure/stage-display.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_wave_performance.cjs > docs/reviews/2026-09-08-audit-closure/wave.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" FX_BROWSER=chrome "$SEGNO_VALIDATION_NODE" docs/design/verify_loop_journeys.cjs > docs/reviews/2026-09-08-audit-closure/loop-chrome.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" FX_BROWSER=firefox "$SEGNO_VALIDATION_NODE" docs/design/verify_loop_journeys.cjs > docs/reviews/2026-09-08-audit-closure/loop-firefox.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_closure_design.cjs > docs/reviews/2026-09-08-audit-closure/d1.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_pedal_closure.cjs > docs/reviews/2026-09-08-audit-closure/d2.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_media_closure.cjs > docs/reviews/2026-09-08-audit-closure/media.log 2>&1
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" --test docs/design/pedal-closure.test.cjs docs/design/media-closure-study.test.cjs > docs/reviews/2026-09-08-audit-closure/new-model-suites.log 2>&1
```

## What passed

- Mixer reference: stereo/gain, multiple Solo tracks, bank persistence, manual mute, encoder commit/cancel/reset, FX entry/return, whole-mix reset and reload.
- Mapping browser: Learn, Omni, global enable, shared parameter targets, direct transforms, grouped Clear recovery, selection versus pedal activation, and Custom/external assignment.
- Stage display and Wave: Track/Wave/Mixer selection and mix, bank retention, selected waveform, capture/empty states, settings/FX return, foot entry, phrase growth, closed-loop fit and shared playheads.
- Loop journeys: recording choices, direct tempo and cancellation, signatures, click/count-in, mode compatibility, MIDI ownership, recording locks, length/timing, per-field inheritance, reset, and persistence.
- D1: heading rename/cancel, shared backing/click controls, encoder rollback/default, Solo in track FX and return, and fine BPM.
- D2: all five mode shortcuts, safe refusal/cancel/save paths, Custom assignment clearing, Transpose bypass preservation, and Solo LED state.
- Media: Internal/USB import/export, fixed bottom keyboard, import review, cancel/hotplug/write failure, persistence, expression/switch/MIDI repair, source Save/Cancel, atomic parameter-plus-binding rollback/retry, and applied-rate/free-space/unknown recording estimates.

## Source identity

The working prototype is identified by SHA-256 manifests rather than a Git
commit. [The before manifest](source-hashes-before.sha256) covers 91 prototype
HTML, JavaScript, CSS, supporting data, and selected harness files.

The affected surface changed during the validation window: the
reviewer adjusted only `.mediafx-name` in `media-closure-study.css` to give
the export package-name button the normal appliance theme and control size.
The exercised prototype HTML, JavaScript, data and test sources stayed
unchanged. The affected
media browser suite is rerun against the final CSS; other requested suites
do not display this package-name control.

The targeted rerun passed in Chrome and Firefox with exit 0. See
[media-final-css.log](media-final-css.log). Its exact command was:

```sh
env NODE_PATH="$SEGNO_VALIDATION_MODULES" ATLAS_CHROME="$SEGNO_VALIDATION_CHROME" "$SEGNO_VALIDATION_NODE" docs/design/verify_media_closure.cjs > docs/reviews/2026-09-08-audit-closure/media-final-css.log 2>&1
```

The enclosing task also changed `parity-review.html`, the review index. None
of the requested harnesses loads that index; it is outside the browser
behavior evidence in this record. [The final manifest](source-hashes-final.sha256)
contains the full final hash set, including that index. Comparing the manifests
confirms exactly these two deltas:

| Source | Before SHA-256 | Final SHA-256 | Evidence |
|---|---|---|---|
| `media-closure-study.css` | `a725fb5d81319159e3afd1e4938eb1f06e023e041b563486259763032c53db17` | `8f92aeb422f869a3c7bc4cd5f2377fc8e539b7715fe75f470356c2b254482a02` | Media suite rerun passed Chrome and Firefox. |
| `parity-review.html` | `3276c9f087290494e46f3bafd2d965dead5f7c1e58ca51e9f430ca24b8f672da` | `fe107c3c5c604906324920f35d525ab2e192b287850158081d2f1fc0f3b4f385` | Review index; not loaded by requested suites. |

The principal final source hashes are:

| Source | SHA-256 |
|---|---|
| `fx-ux-prototype.html` | `f5fafd5e2f3f760e4d57ce6d591861cf9c549213eeb2f046ace7a69414a931b6` |
| `stage-two-screen-preview.html` | `fdcb8128d1b47d56946448047a9d2c81971b3d7fb376b9e456e207f15380238e` |
| `stage-display-study.js` | `d10a5cf8a593aea0f37a6fa55ebfa51a7527f765de40b56d412d507f38e91fbc` |
| `pedal-performance-study.js` | `84beb3dc8dec284a475c51f202043a0ad7e1327752469cdba4bb7793f49eeb3c` |
| `loop-ux-study.js` | `a41dbad688e34c064da757b384a39c08b83b9beabf39a046730166d5b0f8ce20` |
| `media-closure-study.js` | `8549c4a9ba927e7762cd91e71e694aa4c1c3c378a97e35bcfaff68e75c7c19fc` |
| `media-closure-study.css` | `8f92aeb422f869a3c7bc4cd5f2377fc8e539b7715fe75f470356c2b254482a02` |
| `fx-preset-library.js` | `049cd20c658262a90ec5852bfd06c666e1933ae62ddd82884c7ef83f70c8e233` |
| `storage-study.js` | `c53fcf0ab6ebe18c3af9e05d8732972b1cdb83f35738e81a07b58cbcbb6b97ea` |
| `expression-ux-study.js` | `1c42c77205dfd4f7ff5d4aef9a96617c71e7624afe9dd97b1bc010fd4940d70a` |
| `external-switch-study.js` | `d35628ee5a4a98c802806a27f5661b2816b659a8379f00c33f8ad51d78c97dcc` |
| `midi-controls-study.js` | `59099849f5cc0156442639af5fd14171c823a8a4bc45f1943a2c218f87e5042b` |

No actionable behavior regressions were found in the requested suites. Pen
reconciliation and physical/production verification remain separate evidence.

