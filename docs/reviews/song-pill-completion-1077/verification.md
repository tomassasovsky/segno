# Song queue completion on the current console — #1077

> Historical implementation and device-check record. The final combined source
> is documented in [the publication record](../pedal-publication-1076-1077/verification.md).

The owner selected the existing v2 board. Firmware 1.10 extends the working
1.9 ten-pill implementation and retains its wiring. The ring is a continuous
40-pixel WS2812B GRB strip bent into a ring, with data out disconnected. The
separate new v3 console and ring-controller firmware are not this target.

## Behavior

In Song/Mute mode, selecting a stopped section queues it for the current
section's next loop boundary. Its eight-pixel pill fills left to right over
remaining loop time. The current pill stays green until the native engine
actually commits the transition; then it goes dark and the new pill is steady
green. Repeating the target or the playing source cancels; choosing a different
target replaces. Stop, clear, capture and lifecycle changes invalidate stale
queues. REC/PLAY leaves a running or queued Song section alone and resumes one
section after a stop.

The native snapshot publishes target and progress together. Protocol 7 uses
21 STATE bytes, with target + 1 at byte 19 (zero means none) and completion
0..254 at byte 20. The board renders received progress and never infers an audio
handoff from a local timer. Old protocol-5 frames are not accepted as new state.
The app, native engine and firmware must be installed together.

The existing GP12 ring, GP13/14/15 encoder and GP18 pill outputs remain. Forty
ring pixels use brightness 96/255; the approved 80-pill-pixel centre curve,
191 peak and 6000-channel shared budget remain. The conservative combined
current model is 1.634 A against the old board's approximate 1.65 A trace
planning budget. These are estimates and software ceilings, not measurements.

## Local validation

- All native suites pass normally, with AddressSanitizer, and with callback
  telemetry disabled. C++ atomics inclusion passes. All eight final native
  files in this target are byte-identical to those validated source files.
  Native cases check actual audio samples across both channel-order handoffs,
  remaining-time progress, cancellation/replacement, lifecycle invalidation,
  One Shot and exact performance-event logging.
- The real native-library control corpus passes all 25 tests. Its new Song
  case crosses C FFI, repository polling, pedal gestures and encoded/decoded
  wire frames. It checks a queue placed 64 frames into a 256-frame source,
  half progress after 96 more frames, REC/PLAY preservation, cancel/requeue,
  the final pre-boundary sample and committed old-off/new-green state.
  This test exposed and fixed two fields omitted by the device-free snapshot
  adapter. Production snapshot decoding already carried both.
- Normal application tests: 2257 passed, 35 skipped. Coverage after the existing
  CI glue exclusions: 93.56% (90% requirement). The earlier unfiltered run in
  the preparation checkout had 52 author-only screenshot pixel mismatches;
  those goldens were not regenerated. The normal run excludes `screenshots`.
- Pedal repository: 209 passed, 97.62% coverage (96% requirement).
  Looper repository: 390 passed, 11 skipped, 97.47% (95% requirement).
  Engine Dart tests with the real native library: 274 passed, no skips.
- Analysis reports no issues; formatting checks are clean. Bloc lint scans
  601 files with zero issues, using a visible path so hidden-worktree ignore
  rules cannot produce a false no-op. Whitespace checks pass.
- All four old-board firmware suites pass with 49 Dart/C protocol fixtures.
  Tests exercise the actual sketch/parser, pill direction and partial fill,
  both banks, mode/cancellation, stale link, all 40 ring outputs and the
  existing current limit. Pico 2 compile passes at 66,132 bytes program and
  10,668 bytes RAM.
- Matching ARM64 debug and release application builds pass using the local
  appliance build recipe. All 146 Dart-looked-up native symbols are exported.
  Generated snapshot bindings match the compiled native header.

The firmware ELF SHA-256 is
`63d20797d41ccdcdc2f44b23b6fe645fe10e788a845027fa93ccaa03b1bd552c`.
The UF2 SHA-256 is
`f1f402ad7107569964f4a76c29592b7f4c7477a8e35af1bcca0ad5b360f5e794`.

## Review and installation

Five independent roles reviewed the final target: [VGV](raw/vgv-review.md),
[architecture](raw/architecture-review.md), [test quality](raw/test-quality-review.md),
[simplicity](raw/simplicity-review.md) and [readiness](raw/readiness-review.md).
The resolved test-adapter and analyzer-comment findings are documented there.
Hosted CI and a PR-head merge review have not run.

The matched app/firmware update was installed with independent recovery armed. Recovery must send the verified 21-byte goodbye while 1.10 is still
running to clear all 40 ring pixels before restoring 1.9, which only addresses
24. Physical pill appearance and audible Song handoff require observation on
the instrument; automated checks do not establish them.


## Existing recording-recovery fault

The first device trial programmed and verified firmware 1.10, started audio and
connected the matching app. The generic startup-error check then restored the
old app and firmware because boot recovery tries to allocate 38,381,030,944 bytes
for an unfinished recording. The same allocation error and both complete stacks
were independently verified in the historical accepted 1.9 startup and in the
freshly restored original app. Original app and firmware hashes were verified
after restoration, and all 120 pixels were blanked before downgrade.

This existing issue is tracked separately as [#1078](https://github.com/tomassasovsky/segno/issues/1078).
No recordings were moved, deleted or changed. The deployment verifier now
recognizes only that single exact historical exception block, with its baseline
hash pinned; changed allocation, stack, duplicate or additional errors still
fail. It also requires successful audio startup, the expected firmware, the
same active invocation and zero restarts. The focused verifier tests and
independent review pass. This distinction does not claim the recovery fault is
fixed or that startup is free of all errors.


## Installed state

The second attempt completed successfully: the controller was programmed and
verified, emitted HELLO protocol 7 / firmware 1.10, and the fresh app invocation
logged both successful audio startup and the firmware 1.10 connection. The
installed whole-app file manifest, ELF hash and startup version marker match
the verified package. The app remains active with zero restarts and recovery
is disarmed. The original matched app, 1.9 ELF and version marker are retained.

The existing recovery error above remains; no new startup failures were observed.
A physical Song queue/fill/handoff check has been requested from the owner and
has not yet been confirmed. No commit, PR, hosted release or PCB change was made.
