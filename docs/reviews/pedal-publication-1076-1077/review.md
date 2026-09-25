# Cumulative current-console publication review

Base: `bedcecf2733dbde1cdddf96530e5c1749a72b710` (origin/master).
Reviewed implementation head: `4ab1f91e38e551d7d96fe7b79659b11aeba57d2c`.
Scope: the complete accumulated diff for PR #1079, including originally
untracked sketches/tests, final documentation and standalone simulations.
This report is added in a documentation-only follow-up; its commit does not
change the reviewed implementation. Current-head continuity is checked before
applying the PR review label.

## Result

No unresolved actionable findings. All requested review angles completed;
no missing or failed reviewer. This is a source-review result, not physical
hardware acceptance or an assertion of hosted CI success on a later head.

## Independent coverage

The [independent native/firmware report](raw/native-firmware-review.md) records
line-by-line review of all native, firmware, protocol and generated-binding
changes, removed guards, caller/callee tracing, lifecycle cancellation,
callback ownership, bounds, reuse, simplification, maintained-library buffer
semantics and both firmware build paths. Its hashed source content is unchanged
at the final implementation head.

The coordinating reviewer inspected every changed Dart control, repository,
snapshot and protocol hunk, related callers and state ownership, test additions
and removed behavior. Queue state remains engine-owned across the C/FFI,
repository, control and wire boundaries. Projection and equality carry both
fields; frame validation rejects invalid targets, out-of-range bytes and orphan
progress. Song semantics bypass Multi membership without crossing the
presentation/repository boundary.

The same reviewer independently inspected the Stop correction implemented by
the reproducing agent, including the native stop handler's count-in effect,
recording exclusions, resume intent and the real-engine regressions. No new
engine API, compatibility path or callback work was introduced by that fix.

The standalone simulation animation fragments are unchanged from the approved
previews. Their wrapper/styles were inspected in a browser; handoff, cancel,
requeue, pause and pixel-view controls worked. They load no external libraries
and are explicitly illustrative, not production timing or optical verification.
Documentation distinguishes historical trials from current publication and
corrections awaiting deployment. Only intended source, tests and records are included.

## Resolved findings

1. The newly published bench diagnostic cleared 24 ring LEDs while the current
   strip has 40. It now clears all 40; a seeded-colour output regression covers
   the complete transmitted frame. The normal console firmware was correct.
2. Song Stop could miss a handoff or start between polls. Two real-engine cases
   reproduced continued playback after Stop. The correction addresses every
   possible stopped-content playback section as well as the polled running set,
   preserving defining recordings/count-in and non-Song behavior. All 197
   control/integration tests pass, including three added race cases and the
   existing seeded control sequences. Analysis, format and Bloc lint pass.

## Validation and limits

Both Pico 2 sketches compile and all four firmware suites pass with 49 shared
protocol fixtures. The first published implementation passed every hosted CI
check; the later Stop correction and documentation require CI on their own head.
The unchanged application/native baseline also has the complete recorded native,
sanitizer, telemetry-off, FFI, package coverage and analysis evidence linked in
the [publication record](verification.md).

All ten normal-use pills and BANK brightness were physically accepted. Final
queued fill/audio handoff, diffuser appearance and the new Stop correction's
deployment remain separate checks. Keep autonomy:blocked-verify. No merge,
firmware reflash, PCB order or appliance release is authorized by this review.
