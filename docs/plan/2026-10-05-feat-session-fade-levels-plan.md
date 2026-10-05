# Stationary Fade levels in Sessions

Tracking: #1139, parent #1026, human merge gate. Implementation is authorized
after independent plan review; root owns publication. Base: published #1137,
`a921bd9a9`. Parent: [Foot Fade](2026-10-04-feat-foot-fade-plan.md), bounded from
[Part 2](2026-10-04-feat-foot-fade-part-2-plan.md).

Save each recorded track's current Fade amount and recall the complete vector as
stationary state with playback stopped. Saving must not freeze the live Fade.
Use the existing Session capture/import boundary and native Fade receipts; add no
new owner or public Fade destination.

## Implementation boundaries

1. Extend `packages/session_repository/lib/src/models/session.dart` with one
   required saved amount on `SessionTrack`: finite numeric 0–1, inclusive.
   Bump exact Session schema 10 to 11; reject missing, malformed, nonfinite and
   out-of-range fields before side effects. Update encoding, equality and hash.
   Do not default old Session data or migrate schemas. Persist only amount;
   native lifetime/generation and moving target/rate do not belong on disk.

2. In `packages/session_repository/lib/src/session_repository.dart:_capture`,
   take the amount from the same detached `EngineSnapshot` track used to capture
   that track's length/lanes. Do not take an earlier UI/repository projection or
   put coefficient data in the duration settings writer. Save leaves the live
   ramp, PCM, gain and history unchanged. SessionRepository remains independent
   of the other repository packages.

3. Carry the amount through `lib/session/session_mapping.dart` and
   `packages/looper_repository/lib/src/models/session_rig.dart:SessionRigTrack`.
   Validate incoming values before performance disarm, storage writes or audio
   mutation at the application load boundary, and before repository apply changes
   the Session revision. Reuse strict model decoding and existing rig preflight;
   fabricated in-memory bundles must not bypass the early failure contract.

4. Extend `packages/looper_repository/lib/src/looper_repository.dart` at
   `_importSessionAudio`, inside its current Session reservation. Finalize all
   imported lanes/layers. `finalizeLayers` queues `RESET_FADE`; its material
   generation changes only when the callback applies that command. After **all**
   finalizations, wait boundedly for `commandsSettled`, recheck the Session
   revision and mix generation, then read a fresh snapshot for native
   lifetime/material identities. Use the existing `installFade` request for each
   imported track with `amount = target = saved amount` and full-travel seconds
   zero. Confirm every install receipt **before** posting the stopped Session
   commit. Confirm that commit before successful publication or launch release.
   Keep imported material hidden throughout; no partial success. Native install
   already supports fully imported EMPTY material. Reuse existing bounded waits
   and lifecycle guards; add no second receipt protocol or interpolation change.

5. Preserve the current failed-import cleanup and Session boot-storage/bindings
   barriers. A refused, stale or timed-out install fails the load, never silently
   substitutes unity or leaves a late command free to affect replacement
   material. Once the rig is accepted, a later boot-storage failure retains its
   stationary amounts and launch block. Existing explicit Session Retry completes
   the pending boot image, without recapturing outgoing Fade state or restarting
   a ramp. Inspect `lib/session/cubit/session_cubit.dart` and
   `lib/session/application/session_settings_coordinator.dart`; change them only
   if this behavior requires a narrow composition correction.

Durations remain owned by FadeSettings. No new coefficient store, timer, polling
writer, history owner, framework or native API is expected.

## Independent behavior evidence

- Strict current-schema round-trip, endpoints, malformed/missing fields and
  equality. Invalid load with an actually armed PerformanceRepository leaves its
  capture armed, outgoing Session revision and stored settings unchanged.
- Actual-native moving capture: known PCM .5, 4s Fade at 8kHz, capture at amount
  .75 while an earlier projection is deliberately stale. Saved amount is .75;
  live processing continues to .5 without a save-triggered install or toggle.
- Two imported tracks with amounts .25 and zero remain stopped/silent until
  explicit Play. First known sample is .125 for PCM .5 at .25; the zero track
  stays silent. Later frames remain stationary. Include sibling launch/unpark
  and assert levels, routes, layers, history and duration settings are preserved.
- Delay/refuse one install in a multi-track load. Assert no partial successful
  projection or audible launch; cleanup prevents delayed effects on new material.
  Exercise Session replacement/close while a receipt is pending using existing
  lifecycle guards, not arbitrary sleeps.
- Fail boot persistence after successful import. Assert the accepted stationary
  amounts and launch block remain; explicit Retry completes the existing boot
  image and preserves stopped state. Prove eventual audio only through a live,
  retained native material fixture; full device reopen is outside this slice.

Reuse Session package codec/save tests, `test/session/session_mapping_test.dart`,
`packages/looper_repository/test/session_import_publication_test.dart` and
`fade_native_test.dart`, existing Session round-trip and Runtime failure fixtures.
Use a focused new test file only when it avoids unrelated fixture growth. Retain
meaningful existing assertions and failure-before evidence. Do not duplicate the
native ramp arithmetic or duration storage suites.

## Scope and validation

Full reopen is a **separate preexisting material-retention prerequisite**,
tracked in [#1140](https://github.com/tomassasovsky/segno/issues/1140):
`le_engine_start` calls configure, which clears recorded PCM/history as well as
Fade. Replaying a coefficient alone cannot resume that recording. This plan
makes no same-session reconnect, sample-rate recovery or cold-start material
restoration claim. Do not add PCM backup/reimport or resampling here. Clear and
ordinary/frozen/grouped history restoration remain a later accepted increment.
The public Fade UI stays unavailable until the complete feature is ready.

Budget roughly 250 added production lines for the model/capture/import path.
Before exceeding 500, adding a new owner/native API, or touching material recovery,
stop for independent scope review; moving code to helpers does not reduce scope.

Resolve dependencies before explicit changed-file formatting. Freeze paths and
hashes after focused tests. Run full affected Session and Looper package coverage,
appropriate app Session/Runtime coverage, strict analyzer and a positive Bloc scan
using CI's actual filters. Use the matched immutable native library and record
its source identity; do not rebuild unchanged native code. A justified native/API
change requires the documented native, ASAN, telemetry-disabled, C++ and FFI
checks and a scope review. Limit the task to two test/build processes in total.
Independent current-source reviews, CI and the human merge gate remain required;
actual-native tests do not prove appliance/listening behavior.

```success-criteria
GOAL: Save current Fade amounts and recall the complete vector as confirmed stationary state with playback stopped, using existing owners.
SUCCESS CRITERIA:
- Current-schema saved amounts decode strictly, compare correctly and preserve the detached capture image while the live Fade continues. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Every imported amount is confirmed before successful publication or audible launch; explicit Play produces the known stationary sample without changing gain or history. | verify: manual inspect bound actual-native import/round-trip results and first-sample assertions with the matched SEGNO_ENGINE_LIB.
- Invalid data fails before outgoing side effects; install failures clean up safely and later boot failure/Retry retains the accepted stationary vector and launch guards. | verify: manual inspect bound real-owner preflight, delayed/refused install, lifecycle and boot-Retry regression results.
- Applicable formatting, strict analyzer, positive Bloc, coverage and independent reviews pass on frozen source. | verify: manual inspect final source/library-bound validation and review reports.
NON-GOALS:
- Reconnect/material recovery, cold-start restoration, Clear/history, duration storage changes, Fade UI/mappings, native DSP redesign, new owners or compatibility decoding.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages
```
