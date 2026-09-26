# Architecture Review

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

## Layer separation

Violations found: 0.

- `session-target-repair.js` owns reference discovery, validation, collision refusal, endpoint projection and copied output. It has no imports of UI, storage or physical-device clients.
- `session-library-study.js` owns the existing pending request and navigation through destination, control and review pages. It invokes injected describe/options/preview/repair adapters.
- `fx-ux-prototype.html` builds incoming-session descriptors and owns final storage/publication through the established commit boundary.
- CSS remains scoped to the Library target options and review presentation.

No new package or circular dependency was introduced. The plain JavaScript study architecture is the relevant standard for this scope; production Flutter restructuring is not required by this local proposal.

## State ownership and lifecycle

Assessment: correct for the reviewed prototype.

The archive remains the source of truth until Apply and open. The pending dialog retains an original archive copy, a base snapshot and an optional repaired snapshot. Exact archive equality is checked before target choice, Use control and final Apply. Back retires the appropriate picker level, while Cancel/Library exit retire the request. Reset returns controller/target choices to the existing base, preserving media repair already incorporated into that base.

The pure model scans every exact-key occurrence, including disabled MIDI assignments and dormant control mappings. Duplicate missing-key entries within one source context and replacement collisions are refused before any copied mapping is updated. Reuse across independent source groups is retained. MIDI action controls and rack activation rules are not accidentally rewritten as parameter targets.

Incoming FX identities are preserved. The host runs the descriptor builder on a disposable clone and filters out newly generated identities unless capturing an outgoing session. Target enumeration and review do not call descriptor get/set/persist. The repaired snapshot changes only mapping target metadata and the endpoint values explicitly produced by the target coercer.

The existing host writes the complete projected candidate before releasing live contacts and swapping musical state. A writer failure leaves the current rig, archive and pending composed repair intact. Existing physical type/calibration, connection configuration, aliases and global catalogues retain their established ownership.

## Dependency direction

Direction violations: 0.

Library → injected host adapters → pure target/ownership models and descriptor catalogue. The model does not reach back into the Library or own publication. Available controls are derived from the incoming snapshot, while controller/media facts come from their existing current inventories.

This availability contract proves that a serialized target exists in the incoming prototype session. It does not prove a corresponding native plugin is installed. Source-number FX descriptors are intentionally unresolved; the proposal claims explicit normalized endpoint conversion, not physical equivalence with the missing control.

## Contact and review navigation

The exact pressed action is captured together with request token, revision, connection, choice and page. Every new target navigation action advances the revision, and the context includes `targetDestination`, `targetChoice` and `targetPage`. A held Use or picker contact cannot be repurposed after Back/reentry, another choice, Cancel/reopen or pagination.

The initial range navigation concern is resolved by three-assignment review pages and wheel routing. Five affected assignments are exercised through touch, encoder and foot controls. Page navigation does not publish mappings.

## Verification

Independent focused model and combined regression results: 21/21 and 93/93 passed. The target and existing connection browser suites both passed Chrome and Firefox before the fixture-only reconciliation described above. The browser tests verify failed storage, composed media/controller/target repair, cancellation, reload, incoming-only target identity and held-contact retirement.

```sh
node --test --experimental-test-coverage docs/design/verify_session_target_repair.cjs
node --test docs/design/verify_session_target_repair.cjs docs/design/verify_session_connection_repair.cjs docs/design/verify_session_field_ownership.cjs docs/design/session-recovery-model.test.cjs docs/design/session-recovery-study.test.cjs docs/design/media-parity-study.test.cjs
node docs/design/verify_session_target_repair_browser.cjs
node docs/design/verify_session_connection_repair_browser.cjs
```

The browser commands used the configured Playwright runtime and Chrome executable, with the normal local HTTP host at `http://127.0.0.1:8768/fx-ux-prototype.html`; the journeys assert that the URL has no `review` parameter. Both scripts passed Chrome and Firefox independently in this review. The unchanged connection browser suite was `1bb5c330ac09bfc3b9b7c8319192157b05b19c9eb5bf3b949e03707b12b3a8dd`.

## Verdict

The existing ownership browser also passed independently in Chrome and Firefox after its assertion was adapted to the friendly label while retaining the exact target issue ID and Replace check. Command: `node docs/design/verify_session_field_ownership_browser.cjs`, using the same browser runtime. Its final SHA-256 is `d44b51cf922ddb5c6a959087cec3020f067ba9310d5c602b16241fd3096f3ece`; that assertion correction changed no implementation behavior; the later fixture-only host edit is reconciled above.

Architecture is clean for this bounded local prototype. No unresolved actionable architecture findings. Native audio, hardware, installed-plugin inventory and appliance storage guarantees are not certified.
