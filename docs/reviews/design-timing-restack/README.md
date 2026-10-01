# Timing reconstruction validation

Issue #1061, recording-timing slice of #1012 and epic #1009. Reviewed October 1,
2026 against parent `cf16b6b794c76ac097347c4e5ffc3912a24623f7`, preserving
the incoming timing history at `42c4d07928326487e1dba2513fd8486e25392494`.

## Result

No unresolved actionable finding remains in the reviewed implementation.
The independent conventions, architecture, test-quality, simplicity and
readiness reviews cover the reconstructed timing slice. Authored portions were
excluded from each author's verdict and checked by another reviewer. The final
native repair received a fresh adversarial review and an independent public-API
probe; the repository repair received an independent caller review.

The candidate preserves per-track default inheritance, Once playback and
relaunch, exact session timing, empty-track settings, stale-read protection,
command settlement and the preceding recovery semantics. Hardware timing,
physical controls and listening quality remain separate verification gates.

## Closed findings from the final pass

| ID | Rule | Finding | Resolution and independent evidence |
| --- | --- | --- | --- |
| FINDING-01 | `timing/remembered-grid` | Choosing Immediately discarded the previously selected musical division. | Immediate now closes the gate without replacing the division. Running and offline regressions failed before repair, then passed; restart clears the fake's retained value before asserting replay. |
| FINDING-02 | `native/record-start-refusal` | A full command queue could enable Sound start alongside Count-in or corrupt a pending arm despite refusing the change. | Each setting is one queued command. Refusal leaves control state untouched; callback cancellation and publication happen together. Native queue-capacity and arm-identity regressions, plus independent interleaved-setting probes, pass. |

A separate proposed gate/division failure was discarded after tracing the real
native setter: it cannot queue-refuse a valid engine. No speculative API was
added to satisfy a fake-only failure.

## Verification

The final native source was unchanged across normal, address-sanitized and
telemetry-disabled runs. Each passed all five suites, with 679 named tests.
The thread-sanitized race run passed all three dedicated cases. The documented
non-Clang C++ shim compiled. Plugin scan and slot tests are not sanitizer-
instrumented, and the shim emulates the alternate compiler path on macOS.

Generated bindings were regenerated and formatted. All 155 generated function
lookups resolve in a complete macOS engine library, including MIDI. This parity
harness uses the production CMake source list, disables optional plugins and
explicitly links CoreAudio. Linux bundle export validation remains a CI check.

The repaired library passed 2,291 app tests, 477 looper repository tests, 292
engine package tests and 95 session repository tests. The other 17 package
results are reused from the same source/dependency set before the repair;
those packages were not edited by this repair. Native-dependent tests used the
real engine library rather than their missing-library skip path.

Analyzer and Bloc lint pass; Bloc lint scanned 603 files. Explicit formatting
checks pass. Generated test-tooling exclusions were removed from eleven
analysis configurations; each returned byte-for-byte to the parent revision.
All configured coverage floors pass: app 93.8% (floor 90), looper 97.7% (95),
session 98.5% (89), performance 100% (99), pedal 97.7% (96), controller 90.2%
(82), and audio export 100% (100). App, looper and session coverage was refreshed
after the repairs; other unchanged packages reuse the complete earlier run.

Six pre-existing app tests remain skipped: three update notifications, waveform
window failure, single-display notification and the missing-device recovery
notification. Their earlier overlay conversion predates this slice. Recovery
state tests run, but these app-level notification visuals are not certified.

The final test-library SHA-256 is
`66ebc19e0d0d73165e33b98939ed2fb3223ae75a7a563d67be26ccb65b595e38`.
The generated-bindings SHA-256 is
`488651342a3111d12317578c5a833bcea21495d63882c59fd354e3549b0fb8ff`.
Full command logs, coverage summaries, source manifests and role reports are
retained in the delivery evidence archive. Tests are reused only where source,
dependencies and relevant native-library identity match their recorded scope.

Local validation does not waive CI on the published PR head or the existing
human merge gate. Linux builds, hardware proof and deployment are distinct.
