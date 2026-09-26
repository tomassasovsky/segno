# Test Quality Review

## Scope and reviewed revision

September 8, 2026. Independent review of the new saved-session target repair under issue 919 and [the approved plan](../../../plan/2026-09-08-session-target-repair-plan.md). Scope is the local JavaScript design prototype: the new pure model and tests, plus the intended host/Library/CSS delta. The surrounding dirty tree, prior unchanged ownership implementation authored by this reviewer, Flutter/native code and Pen artifacts are excluded. Existing ownership and connection seams were traced as dependencies without claiming a fresh independent review of their whole implementation.

The intended integration delta was compared with `/tmp/segno-session-target-before`. Baseline SHA-256 values: main HTML `c745de666af7687569f823d95bf92949f7a8b02b9792f5625651a946297af3b8`; Library JS `4af02ea38e908b1f44575d8452b8ebe820ad1ad4bdd628f1f23e9456518873e9`; Library CSS `425905c502838a59d29eae8b24bedebcd21c7a18d547ea4ce2a18b8644438446`.

| File under `docs/design/` | Reviewed SHA-256 |
| --- | --- |
| `fx-ux-prototype.html` | `b176f4f3708def1fa64b6584cd0204a8a6f66738150f224863583ebed88a611a` |
| `session-library-study.js` | `829c7062da23519fec9e0bd7cf51ea704b257e3367c87968bb3f2be5a71c5a43` |
| `session-library-study.css` | `4b221b9e76499237d48fb3b39cde4f638f0388f7723c5bd90babab78a4eb58e6` |
| `session-target-repair.js` | `c417dee328fd047076c5bd1011f91b29611efbf43d94c7d16959c0b9fbd27ebe` |
| `verify_session_target_repair.cjs` | `c55b296347f4f60311564ca964fd1f79b0e056415911e1c1af5e4056981afac9` |
| `verify_session_target_repair_browser.cjs` | `0614158bb8908b923c43d42245346e8fe76b7a3d8a2072e333f8f09d1770041d` |

Final fixture reconciliation: the host SHA above includes the one-condition correction in `sessionOwnershipReview`, limiting the wrong-type fixture to `session-ownership-missing` and `session-connection*`. Reversing only that condition in memory reproduces the prior reviewed host SHA-256 `a98d6b45bcd8fe6fb94d0a7c0c07f88592437c0493505b06c1fbae69fabeec6d`, proving no other host delta. The full normal-storage browser runs recorded below exercised that prior hash. No full suite was repeated for this fixture-only edit.

On the final host, an independent Playwright smoke passed Chrome and Firefox for `session-target-missing`, `session-target-destinations`, `session-target-controls`, `session-target-review`, `session-target-ready`, `session-ownership-missing`, `session-connection-missing` and `session-connection`. All five target scenes retain current CTRL 1 as expression; the first four show only `control-target`, and ready has no remaining issue and one staged repair. The old ownership/connection missing scenes still show `control-type` with current CTRL 1 dual. Expected picker/review state, visible heading/actions bounds and absence of page errors were also asserted. No Pen or native-device validation is claimed here.

Hashes were rechecked after the final fixture smoke. This is local revision evidence, not a commit, CI, merge, native-audio or appliance certification.

## Coverage summary

- Focused model tests: 21 passed.
- Combined target, connection, ownership, media and recovery regression: 93 passed.
- New `session-target-repair.js` coverage: 100% lines, 92.77% branches, 100% functions.
- New model: 1/1 new implementation module has a focused test file.
- Host/Library integration: dedicated normal-host browser suite, plus unchanged connection-repair browser regression.
- Browser result: target, connection and final ownership suites passed Chrome and Firefox independently.
- No new JavaScript design-study percentage threshold is defined. The model coverage result does not claim complete branch coverage or coverage of the whole main prototype.

The initial reviewer attempt accidentally included the browser-only `verify_session_recovery.cjs` in a Node-test invocation without the Playwright environment; it failed during module loading. The corrected six-file pure suite above passed 93 tests. This was an invocation error, not a source failure.

## Model test quality

`verify_session_target_repair.cjs` meaningfully checks:

- every exact missing-key occurrence across expression, external held/on buttons and continuous/momentary/toggle/program MIDI;
- source identities, conditions, channels, disabled state, curves, hardware and unrelated session state preserved by repair;
- reversed normalized ranges and destination-coerced, formatted endpoint values;
- Program's active Value endpoint without rewriting its unused low field;
- collisions in each affected source group, duplicates of the missing key and valid reuse in unrelated groups;
- disappearance or identity change after preview; restored original targets; disabled candidates; malformed sources, descriptors and endpoints;
- throwing or invalid coercion/formatting without partial repair;
- frozen inputs and independent outputs;
- real FX descriptor integration, including module-enable switches and unresolved Source-number parameters;
- equivalent CommonJS/browser exports with no DOM or storage dependency.

The descriptor stubs deliberately throw from get/set/persist, so an accidental live mutation fails. This is a targeted boundary test, not replacement of the model under test.

## Browser test quality

`verify_session_target_repair_browser.cjs` uses real host/Library code on a normal storage URL. It seeds distinct incoming/outgoing module identities and track names, verifies the incoming catalogue, and compares the current rig plus serialized storage before Use/Apply, Cancel and failure.

Five affected mappings force range pagination. Touch, encoder and foot journeys exercise the same choices and both review pages. Geometry checks cover picker text containment and visible dialog actions. Held Use, destination and control contacts are invalidated across Back/reentry, changed target, Cancel/reopen and page changes.

The composed path repairs backing media, then a CTRL connection, then a target in the same pending session. A forced Storage writer exception preserves all pending choices and original live/storage state; retry publishes the expected state and reload retains it. Collision refusal and missing-module/missing-parameter paths have separate cases.

The unchanged connection suite independently preserves coverage for incompatible/occupied/disconnected/calibration choices, exact MIDI source movement, overlap refusal, final connection revalidation, failed writes, reset, cancellation and its prior held-contact regressions.

## Anti-patterns found

None requiring action. Tests use deterministic state assertions and failure injection. They do not infer native audio correctness from screenshots or count source-text matches as behavioral proof.

The browser and Node fixtures simulate controller/media inventories and symbolic audio. The browser harness does not independently certify physical pedal timing, plugin loading, audio rendering or appliance storage. The new target test covers the prototype's incoming serialized target catalogue, not native installed-effect availability.

## Commands and observed results

```sh
node --test --experimental-test-coverage docs/design/verify_session_target_repair.cjs
node --test docs/design/verify_session_target_repair.cjs docs/design/verify_session_connection_repair.cjs docs/design/verify_session_field_ownership.cjs docs/design/session-recovery-model.test.cjs docs/design/session-recovery-study.test.cjs docs/design/media-parity-study.test.cjs
node docs/design/verify_session_target_repair_browser.cjs
node docs/design/verify_session_connection_repair_browser.cjs
```

The browser commands used the configured Playwright runtime and Chrome executable, with the normal local HTTP host at `http://127.0.0.1:8768/fx-ux-prototype.html`; the journeys assert that the URL has no `review` parameter. Both scripts passed Chrome and Firefox independently in this review. The unchanged connection browser suite was `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd`.

## Resolved quality concern

The first target-review draft had a long scroll-only endpoint list. It was changed before final review to explicit pages, and the browser fixture was expanded to prove navigation and review of all five affected mappings. The final assertions also verify real source-behavior endpoint names, saved track labels and the absence of live-only FX choices.

The existing ownership browser initially expected raw `missing-rack` text where the approved UI now shows a friendly label. Its first correction used `issue.type`; the final correction checks `issue.kind`, the unchanged exact target ID, the friendly label and visible Replace. The reviewer independently reran `node docs/design/verify_session_field_ownership_browser.cjs` with the same browser runtime: Chrome and Firefox both passed. Final test SHA-256: `d44b51cf922ddb5c6a959087cec3020f067ba9310d5c602b16241fd3096f3ece`. That assertion correction changed no host/model behavior; the later fixture-only host edit is reconciled above.

## Verdict

All reviewed tests pass the quality bar for the approved prototype scope. Critical: 0. Important: 0. Suggestions: 0. No unresolved regression assertion remains.
