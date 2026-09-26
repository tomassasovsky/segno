# VGV Code Review

## Summary

No unresolved actionable findings in this bounded prototype revision. Exact-key repair is isolated in a pure module; Library stages a returned snapshot and the existing host publishes it. The former range-review navigation gap is resolved with explicit pages reachable through touch, encoder and foot controls. The existing ownership browser assertion now checks the friendly label and preserved exact issue ID, and its final rerun passes.

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

## Critical — must fix

None.

## Important — should fix

None.

## Suggestions

None.

## Architecture and conventions

The repository's production stack is Flutter/Dart with Bloc, but this authorized slice is an existing browser design study. It follows the study's injected host adapters and plain JavaScript modules. No production layer, package, SDK, dependency or compatibility path was introduced.

`session-target-repair.js` contains exact reference collection, source-context collision checks, normalized coercion and immutable repair. The UI only chooses destinations/controls, renders model output and changes its pending dialog. The host supplies descriptors from a clone of the incoming snapshot, including saved musical labels and current appliance aliases.

A removed module or parameter is represented as an unavailable assignment target. Repair changes mappings; it never installs or replaces a processor, calls descriptor setters, or infers native units. Existing unresolved FX descriptors retain Source-number formatting and an explicit unverified-scale note.

Cancellation, Back, Reset and failed publication preserve live and archived state. Final Apply rechecks the original archive and ownership dependencies. Held contacts retain the exact action and request context, including target choice, page and monotonic revision.

## Simplicity assessment

The pure module has one responsibility and no DOM, storage or live audio dependency. It uses the existing descriptor API and existing Library pending state, rather than adding another repair browser or compatibility abstraction. No justified deletion or speculative abstraction was identified. The repeated target-options build in destination rendering was removed before this final review.

## Testing assessment

Independent results: 21 focused tests passed; 93 focused and existing regression tests passed. New model coverage was 100% lines, 92.77% branches and 100% functions. Normal-host target and connection journeys passed Chrome and Firefox.

The tests verify all exact references across expression, external buttons and MIDI; typed/reversed ranges; disabled and dormant assignments; source-context collisions; immutable inputs; malformed endpoints; changed candidates; writer failure; combined repairs; reload; full input-method journeys; and stale held contacts. They assert source and persisted state, rather than only checking rendered labels.

```sh
node --test --experimental-test-coverage docs/design/verify_session_target_repair.cjs
node --test docs/design/verify_session_target_repair.cjs docs/design/verify_session_connection_repair.cjs docs/design/verify_session_field_ownership.cjs docs/design/session-recovery-model.test.cjs docs/design/session-recovery-study.test.cjs docs/design/media-parity-study.test.cjs
node docs/design/verify_session_target_repair_browser.cjs
node docs/design/verify_session_connection_repair_browser.cjs
```

The browser commands used the configured Playwright runtime and Chrome executable, with the normal local HTTP host at `http://127.0.0.1:8768/fx-ux-prototype.html`; the journeys assert that the URL has no `review` parameter. Both scripts passed Chrome and Firefox independently in this review. The unchanged connection browser suite was `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd`.

## Resolved review observations

- New endpoint review originally required scrolling without a foot/encoder route. It now renders three assignments per page with explicit Previous/Next actions; the five-assignment browser fixture exercises both pages through all input methods.
- Destination names and descriptor notes now survive the pure options projection. The browser verifies the saved track name and absence of outgoing-only processor IDs.
- Scoped picker rows now contain their two-line labels; the browser geometry assertion passes. This was also raised by the independent browser author.
- The old ownership browser's raw-ID text expectation was updated to check the friendly label, `issue.kind` plus the exact original target ID, and Replace. Independent Chrome/Firefox reruns pass on test SHA-256 `d44b51cf922ddb5c6a959087cec3020f067ba9310d5c602b16241fd3096f3ece`, using `node docs/design/verify_session_field_ownership_browser.cjs` with the same browser runtime. That assertion correction changed no host/model behavior; the later fixture-only host edit is reconciled above.

## Verdict

The reviewed local design delta meets the VGV review bar. Critical: 0. Important: 0. Suggestions: 0. Missing native-plugin inventory, physical parameter translators, real audio behavior and appliance persistence remain outside this proposal.
