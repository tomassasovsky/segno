# FX placement integration code review

Base: `a0a54e57ed371c316b9eabcc64379c2c431150cc`.
Original placement parent: `be987759def149f986e4ec176daeff88bc42d0ee`.
Reviewed candidate: 90 implementation and test paths, fingerprint
`36017c3018207351a8635451d991bd8c92dc88072bcd5c4c4204a9e92fc81c67`.
The integration commit preserves both parents. Committed-blob verification
binds this source review to the published head; a later source change requires
review of that delta. Remote CI is a separate current-head gate.

## Result

Independent review is complete with no unresolved actionable findings.
Line-by-line, removed-invariant, cross-file, reuse, simplification, efficiency,
fix-depth and repository-convention checks cover the complete intended native,
FFI, domain, app and test diff, including new files and repair deltas.
Architecture excludes its reviewer's native/engine/export implementation and
initial gain wiring; a separate reviewer covers those paths independently.
Five quality roles share those two reviewers, with root owning integration.

Closed findings cover combined Pre processing and independent track gain,
recorded-only bus routing, resource retirement, immutable recipes, source-copy
admission, callback-boundary capture, channel refusal, saved gain, exact
acknowledgment before durable writes, history/restart ordering, absent-target
session reset and completed missing-plugin scans. Original failing probes and
fixed expected samples are retained. Later replay results do not erase earlier
failures. No callback allocation, blocking I/O or locks were introduced.

Tests assert audio samples and observable behavior, including delayed callback
application and refusal, rather than mirroring implementation. Fixture changes
retain their original sound/history, order, identity and error assertions.
Session round-trip tests keep every sample boundary and all 24 seeded histories;
a retained subscription and deterministic publication ticks repair fixture
lifecycle without changing production code. Full-envelope save assertions and
recipe-aware no-reset guards avoid passing against obsolete granular calls.

Normal, AddressSanitizer and telemetry-disabled native suites each pass 744
named tests. ThreadSanitizer, the C++ header check and all 186 FFI symbols pass.
All seven relevant Dart suites and configured coverage floors pass; the app
retains six existing skips. Strict analysis, formatting and the real 640-file
Bloc scan pass. Two later test-only amendments have complete affected-file
passes and independent review; unchanged aggregate results are reused with
source/dependency hashes, not described as fresh full runs. The Mac app build
and actual Tracks/Mixer/effects navigation pass. See the
[verification record](../../reviews/design-fx-placement-restack/README.md).

## Limits

The platform plugin-host suite is not itself instrumented by the core ASAN
runner. The main Mac window worked despite a recorded multi-window startup
warning. Desktop navigation is not a listening or physical-appliance test.
Already-started platform storage writes across session replacement remain M7
work; this review does not claim those writes can be cancelled. FX screens,
complete offline rendering and exact effect-definition/DSP parity have explicit
later owners. Existing human merge and deployment boundaries remain in force.
