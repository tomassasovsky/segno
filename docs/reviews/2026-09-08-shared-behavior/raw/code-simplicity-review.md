# Simplification Analysis

Final verdict: no actionable simplification findings in the bounded scope.

## Scope and independence

September 8, 2026. These are uncommitted JavaScript design prototypes, not Flutter,
native audio, a PR head or an appliance build. This reviewer did not author the
processing or ownership implementation or their tests. The reviewer authored the
separate timing tests; those tests and timing code are excluded from these roles.
Test Quality and Simplicity were performed as separate passes by this same
independent reviewer while all team slots were occupied.

Reviewed the whole new processing model/preview and ownership model, plus their
three verification files. Host review is bounded to sessionTargets,
sessionCurrentRig, sessionProjection, sessionCapture, sessionFresh, commitSession,
Library context and script wiring, and STOP/MODE ownership of dependency dialogs.
The host comparison uses the supplied pre-pass file (SHA-256
`38e60242e40451630bda5bdf56ac36c2610e4217965e53fadd0c5223fb62a58c`).
No exact Library baseline was supplied: that module is bounded to ownership
checks, dependency dialog/actions/lifecycle, the commit-kind argument and review
fixtures. Its CSS review covers only the dependency list rule. The media-parity
fixture's new ownership callback is included. The existing expression module was
read as the cancelSwitches consumer; no persistReleased method is present there.
Released external values are materialized in the new host sessionCapture seam.
Other existing modules and the large unrelated dirty tree are excluded.

No implementation or reviewed test file was changed by this reviewer. Isolated
mutation copies and reviewer browser images were written outside the repository.

## Core purpose

The processing model lets a reviewer observe routing and symbolic tail behavior
without pretending to render audio. The ownership model separates musical
session fields from current appliance configuration, reports exact unresolved
dependencies, and hands one candidate to the existing host publication path.
The two previews make those proposals concrete without introducing production
engine state or another persistence system.

## Reviewed complexity

- The processing model uses immutable plain objects and a single effect-chain
  reducer. Its buffer map is required to distinguish retained tails from fresh
  input; the source/frame split supports observable tests without a second model.
- Capture, selected-render and performance-frame recipes express different
  user decisions. Their functions are short and retain their distinct output
  contracts; merging them would add conditional options and obscure scope.
- Selected-render duration uses the common cycle only for supported integer
  material and requires an explicit duration for independent-time, Once or
  fractional sources. This avoids a hidden policy fallback.
- Ownership uses a fixed musical allowlist and three small nested-field lists.
  Starting from current state and replacing only these fields directly expresses
  the requirement that new catalogues and physical setup survive recall.
- The requirements record carries evidence about an assignment's original
  physical source. It is necessary because capture intentionally omits current
  calibration/type settings; it is not a second device configuration.
- Projection returns candidate, issues and readiness without dispatching host
  actions. The existing host owns saving and releasing contacts. That separation
  prevents a broad state-management abstraction or duplicated save path.
- Candidate parameter descriptors reuse the existing FX and mapping target
  providers. Known-ID filtering prevents descriptor generation from silently
  repairing a missing saved identity; the capture path deliberately enables IDs.
- The small dependency dialog is integrated into the existing Library lifecycle
  and media-recovery flow. Retry rechecks exact archived state and availability;
  Cancel/Back/navigation clear the request. STOP/MODE uses the existing pedal
  interception mechanism and retains ownership after a blocked Retry.
- Library and host both check recall dependencies. The former creates reviewable
  repair UI; the latter guards final publication. Removing either would remove
  a necessary responsibility, not merely duplicate validation.
- Metadata writes and New Loop intentionally bypass saved-session dependency
  rejection. They operate on the current setup and must remain available while
  a currently missing controller is being repaired.

## Unnecessary complexity, code to remove and YAGNI

No verified unnecessary abstraction, obsolete compatibility layer, redundant
state machine or speculative implementation was found. No deletion is proposed;
therefore estimated avoidable code is **0 lines (0%)**. The compact host and
Library style predates this bounded change; reformatting their full files would
expand the unrelated dirty scope without improving this proposal's behavior.

The `createIds` distinction, captured requirements and final readiness guard each
preserve an observed caller invariant. Replacing them with implicit fallback or
merging them into a generic migration layer would conflict with repository rules.
The two unresolved performance capture alternatives remain explicit comparison
inputs; no hidden default has been introduced.

## Validation considered

Independently read the focused Node and browser tests and observed their passing
runs, including real failed storage publication and held-contact release. The
Test Quality role separately verified and closed the missing live-input action
coverage using a no-op mutation. No implementation changes were necessary for
that finding. Current source/test hashes are recorded below.

## Final assessment

Complexity is low in the pure modules and moderate at the existing host/Library
integration boundary. The integration work is proportionate to dependency
repair and atomic recall. Already minimal within the proposal scope; no source
changes are recommended. This is not an assessment of the entire host or of a
production audio architecture.

## Checked hashes

Paths are relative to `docs/design/`. The host, Library and existing dependencies
are scoped to the seams listed above, not their entire files.

| File | SHA-256 |
|---|---|
| `processing-behavior-study.js` | `69947ccab8e8474bc7ccc70a5b6bc32b2e66985c8e2f29da8738ca2fbd6c8193` |
| `processing-behavior-preview.html` | `526d364467fcd6b5aaccde1c2fbd9900735ef90752e4ed8784a46b41c09fd917` |
| `verify_processing_behavior.cjs` | `f133fa3088bc80321ecde133ee535c3e7bc43c994c6dc6fe1a37f8d63be435db` |
| `session-field-ownership.js` | `d89e7d1d7d6f83075e4da2f838c4512548e2f07288c42fb4e6971bc9192f1932` |
| `verify_session_field_ownership.cjs` | `74705dbd128afd4c2d59d30e40a56fcb87b6f2060aa3df03fdc1d9084ac972b4` |
| `verify_session_field_ownership_browser.cjs` | `d0974567e41e905da7b8eaed7b3ecea099f05eaae0ac454224348f72c326d132` |
| `session-library-study.js` | `5b29dac1756d6ade5d0d0537d9e05e1eccdcc78e5fc81c61d5ac0a2ec07cdf37` |
| `session-library-study.css` | `675a3d3ba039fa9b61ad4cce3a255b8bda1a2c85c2e8b3c56d9e34de9ffa1b9c` |
| `fx-ux-prototype.html` | `4419343fd04a62b457678e46706b0163a750fa0b39c54eb511dedeef9480b28a` |
| `expression-ux-study.js` | `1c42c77205dfd4f7ff5d4aef9a96617c71e7624afe9dd97b1bc010fd4940d70a` |
| `media-parity-study.test.cjs` | `9698374d0b22375c12c464c3b8b5acd34f43b84c5b6a6c1d1d6371efc35f2cd2` |
