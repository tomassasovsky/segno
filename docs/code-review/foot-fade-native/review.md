# Native track Fade review

Issue #1131, parent #1026. Human merge gate.

## Revision and scope

Reviewed candidate: the 28 source/test files in the native Fade v3 freeze,
SHA-256 `1df3059908e2ba1f1ba2d7285aeaefb71f684f9e4f01a42ddaa42cd95d7f1c16`.
Publication base: `6bf1ef006026b23b65d88f8b65322627d6f232d9`
(`codex/foot-mixer-performance`). The candidate was first frozen on the prior
Mixer base; fast-forwarding preserved every frozen source byte. Documentation
added for publication does not change the tested source.

This part adds the native envelope, confirmed command seam, coherent snapshot,
and performance-log/render behavior. Existing playback remains at full Fade
level until explicitly controlled. Session persistence, reconnect/history
composition and the user-facing controls belong to Parts 2 and 3.

## Review result

Independent native and Dart reviewers found no remaining actionable defect in
the frozen scope. Their complementary reviews cover every changed source/test
hunk, the new files, caller/lifecycle boundaries, removed invariants, API/FFI
parity, callback safety, architecture, meaningful test oracles and simplicity.
These are two independent reviewers with several review angles, not five
independent people. The additional conventions and PR-readiness passes found no actionable issues;
their role coverage is recorded without counting the same reviewer twice.
The root review found and repaired a receipt-retirement leak: Session replacement
can retain the configured engine, so abandoned requests must still be consumed.
A real-native regression exceeds receipt capacity across repeated replacements.

A configure-failure ordering concern did not establish a wrong result under the
single-producer FIFO and publication-ticket contract; no speculative rewrite was
added. Native allocation, locks and blocking I/O are absent from the new callback
path. The shared envelope helper serves both live processing and offline render.
Generated FFI changes are limited to the new API and snapshot fields.

Actual Claude adversarial review remains pending after its session quota was
exhausted. Remote CI and human merge approval are separate gates. This report
therefore does not mark the PR ready to merge.

## Observed verification

- Native suite, AddressSanitizer and callback-telemetry-disabled suite pass.
- C++17 atomics shim compiles; the matched library exports all 187 generated
  symbol lookups.
- App: 3,137 passed, 49 conditional skips; 92.634% coverage (90% required).
- Ordinary Looper: 714 passed, 35 conditional skips; 95.136% coverage (95%
  required). Four additional actual-native Fade repository tests pass.
- Matched Engine, Session and Performance suites: 597 passed, no skips.
  Separate Session coverage is 95.771% (89% required); Performance is 99.330%
  (99% required).
- Strict analyzer, explicit-file formatter and diff checks pass. Bloc lint
  positively scanned 806 files with zero issues.

The tested library has SHA-256
`3d03c63d25c0f7c30b290bd6aa8d7b6d3460d7cfdffa3a9d38b8dfcfef05f550`.
Native sample assertions cover linear timing, retrigger, independent tracks,
original PCM and monitor isolation, ordered same-frame events, and the first
sample after installing a saved Fade image. Live/render parity supplements those
literal oracles. Native-only results are not counted as ordinary-suite coverage.

No appliance listening, physical-controller or deployment validation is claimed.
