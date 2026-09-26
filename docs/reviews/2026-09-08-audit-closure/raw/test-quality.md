# Test quality review

Scope: the approved September 8 design closure pass only. Reviewed the new D1/D2 controls, preset/media helpers and source-owned repair paths against their focused model/browser suites and the existing FX/media regression suites. Native/audio quality, production Flutter/Bloc tests, hardware and Pen are separate gates; their absence is not a defect in this bounded prototype pass.

Role: `workflow-agents/references/test-quality-review-agent.md`, with the common review-agent output instructions. The relevant design tests use Node's `node:test`/`node:assert`, `vm` to run actual study modules with injected host callbacks, and Playwright Chrome/Firefox for integrated UI journeys. They use the established prototype framework, rather than applying Dart mocking conventions to JavaScript.

## Coverage summary

Fresh executions:

- `node --test docs/design/media-closure-study.test.cjs docs/design/pedal-closure.test.cjs docs/design/fx-parity.test.cjs docs/design/media-parity-study.test.cjs`: **48 passed, 0 failed**.
- `node --test --experimental-test-coverage docs/design/media-closure-study.test.cjs docs/design/pedal-closure.test.cjs`: **20 passed, 0 failed**; Node reported 61.09% lines / 59.41% branches / 62.00% functions over only three attributed files. This is **not complete implementation coverage**: much of the study code executes as VM scripts and is absent from that file report. No design-prototype percentage threshold is configured, and this report does not present that number as a feature-completion percentage.
- `python3 docs/research/segno-looper-x-comparison/2026-09-08-recheck/verify_closure.py`: passed, explicitly reporting “inventory validation only.” It verifies 183 unique audit records, preserved baseline, legal gates and evidence paths; it does not exercise 183 features.

The three browser suites were inspected for dispatch, waits, state assertions, persistence paths, error capture and teardown. Their fresh executions are owned by the coordinator/authors; this independent role does not claim it ran those browsers or promote screenshots to CI/audio/device proof.

## Feature-to-test mapping

| New/changed seam | Evidence reviewed | Assessment |
|---|---|---|
| Track heading rename, fallback name and context | `verify_closure_design.cjs` enters bank B, changes/cancels names, commits and checks unchanged playback. | Real integrated UI path and saved owner assertions. |
| Backing/click in Mixer | Same suite edits shared values, performs encoder rollback/reset and verifies a value after normal-URL reload. | Tests the shared owner, not only control presence. |
| Solo in FX and fine BPM | Same suite toggles Solo from overview/rack, returns to Mixer, checks playback unchanged; edits hundredths BPM with encoder cancellation and touch. | Bounded state/UI proof; it is not proof of D3 clock inference or native tempo scheduling. |
| Transpose bypass | `pedal-closure.test.cjs` checks stored/effective pitches, global enable, selection, reset independence and refused writes; `verify_pedal_closure.cjs` tests real holds, canceled holds, assignment dispatch, reload and storage rejection. | Meaningful behavior assertions and hold-consumption protection. |
| Clear custom assignments | Model and browser suites exercise both banks, fixed MODE/BANK, LED/settings preservation, modal Cancel, draft/save/restore and failed Save. | Covers affected state and recovery, not only text/counts. |
| Five mode shortcuts | Real catalogue/dispatcher/Loop study in model tests; real custom chooser and foot confirmation in browser suite; incompatible/capture/queued guards and late capture recheck. | Tests existing guard reuse and unchanged recorded content; does not claim unresolved automatic Sync/Band close behavior. |
| Preset interchange | `media-closure-study.test.cjs`, `fx-parity.test.cjs`, `verify_media_closure.cjs`: both locations, explicit import review, duplicates, malformed/changed packages, cancel, USB generation/hotplug, capacity, failed writes, retry and reload. | Tests actual helpers and integrated owner handoffs. Media bytes remain simulated. |
| Repair dialog and source drafts | Model tests cover stale mapping/target, failed Apply, inverted range, no target audition, Save/Cancel for expression, switch and MIDI; browser suite uses actual owner callbacks and an injected Storage exception for expression Save. | The combined source-transaction failure/retry case is now covered in the integrated browser suite. |
| Remaining recording time | Pure formula tests cover reserve, format, channels, simultaneous streams, low space and invalid/unknown input; model integration follows changing format and free-space state; the browser suite changes the applied sample rate, proves an uncommitted draft has no effect, and checks known/unknown capacity plus normal/low-space layout. | Formula/state evidence is accurately separated from real storage measurements. |

Every scoped new helper/control has a corresponding focused test path. No new untested production package or repository was introduced.

## Combined source Save regression verified

The focused regression gap is resolved in `verify_media_closure.cjs:34`. The integrated test repairs the missing CTRL2 switch parameter, stages a `rack-1` activation rule, rejects `Storage.prototype.setItem`, and checks both the saved parameter and rack rule remain unchanged while one binding patch remains pending. It restores storage, retries, verifies the exact repaired parameter target, external rack assignment and cleared pending queue, and retains the parameter's condition and inverted/active endpoint values. This exercises the actual host transaction rather than only a mocked writer. The media author reports the revised suite passed Chrome and Firefox; this role inspected its assertions and does not claim a separate browser execution.

No remaining actionable test-quality finding in the bounded pass. The original expression failure reproduction and the corrected transaction are recorded in the architecture report.

## Test quality assessment

No tautological assertions, tests with no assertions or mocking of the units under test were found in the scoped suites. Injected state, clock and storage callbacks are appropriate host seams. Model helpers use real modules, deterministic timers and before/after state comparisons; browser suites wait for simulated completion, collect page errors and close browsers in `finally`.

The tests intentionally assert normalized source values and preserve unknown FX-scale status. Catalogue/key counts support inventory retention only. The old and current correction records explicitly keep DSP, factory-audio usability, D3 timing, complete backup, optional scope and hardware proof open. Nothing in the reviewed evidence supports saying all 183 rows are verified or all design decisions are closed.

## Reviewed hashes

These SHA-256 values identify the reviewed test/source revision. Later changes require a focused recheck.

| File | SHA-256 |
|---|---|
| `docs/design/verify_closure_design.cjs` | `0b37d85d761b7b010e134b387f9959945102fb80a979fbd72c57034447a9597f` |
| `docs/design/verify_pedal_closure.cjs` | `58918144a03858f4d4ad055d107cd2c4ce4ee830194dd6e2da56c59e0965a7cc` |
| `docs/design/verify_media_closure.cjs` | `c84dddbe9449f80e30653d747d18a0be3f8fd8e484116fddaf1479dfc4c119fa` |
| `docs/design/media-closure-study.test.cjs` | `549cecc2d1a294df191aeef125798f44404e58596d430c5873a7cc6ebb749576` |
| `docs/design/pedal-closure.test.cjs` | `d69a55006ec983e595613c279e0e300f280c1a92ccdedc48a9f885eb77e4df0c` |
| `docs/design/fx-parity.test.cjs` | `be025c2f34d07fccd08939d5f0d18f82d04dcf04f8d9cc64fd87bdc02f83bf3b` |
| `docs/design/media-parity-study.test.cjs` | `d8cfe409da2f6737a42fc4423f17f03054454c4db2821e1e6ac238bee082dd10` |
| `docs/design/media-closure-study.js` | `8549c4a9ba927e7762cd91e71e694aa4c1c3c378a97e35bcfaff68e75c7c19fc` |
| `docs/design/expression-ux-study.js` | `1c42c77205dfd4f7ff5d4aef9a96617c71e7624afe9dd97b1bc010fd4940d70a` |
| `docs/design/external-switch-study.js` | `d35628ee5a4a98c802806a27f5661b2816b659a8379f00c33f8ad51d78c97dcc` |
| `docs/design/fx-ux-prototype.html` | `f5fafd5e2f3f760e4d57ce6d591861cf9c549213eeb2f046ace7a69414a931b6` |
| `docs/design/stage-display-study.js` | `d10a5cf8a593aea0f37a6fa55ebfa51a7527f765de40b56d412d507f38e91fbc` |
| `docs/design/loop-ux-study.js` | `a41dbad688e34c064da757b384a39c08b83b9beabf39a046730166d5b0f8ce20` |
| `docs/design/transpose-performance-study.js` | `74639a419241100a3c836014391eca194809c432c9864e096f925254b9290f17` |
| `docs/design/pedal-ux-study.js` | `c26fafabc851089c3a055fd387804c344f5b9da9b40698fe683a98177d02ead9` |

## Verdict

48 model tests pass at the recorded model revision. The combined transaction regression is now included and author-reported green in Chrome/Firefox; no remaining actionable test-quality finding. Scoped evidence supports the stated prototype behavior, with the 183-row inventory and future proof gates kept distinct.
