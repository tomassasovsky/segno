# Correct shared live-input gain

Issue #1124, a prerequisite of the Foot Mixer journey in #1123, human merge
gate. Base: the published Count-in mappings. This correction improves existing
controls and restoration before adding a new performance mode.

## Accepted behavior

Live-input volume ranges from silence to unity (0–100%), independently of
capture trim. A normalized mapping position of 0, 0.5 or 1 means exactly
0%, 50% or 100% live gain. Tracks and recorded lanes retain their existing
0–200% logarithmic fader conversion. This corrects the October 1 implementation
plan's inclusion of live inputs in the recorded-track gain law: the current
accepted prototype and September 7 Mixer decision both specify input unity as
the ceiling. It does not introduce a separate Foot Mixer range.

## Implementation

1. Separate `MonitorVolumeTarget` in
   `lib/control/binding/control_value_target.dart` from recorded gain conversion.
   Update the scope comment in `mix_value_scale.dart`; keep its recorded law.
   Retain existing mapping identity and the existing source interpreter.
2. Correct ordinary gain admission in `lib/app/mix_settings_coordinator.dart`
   and the repository's monitor-gain boundary. Constrain any actual input gain
   editor to the same range. Input percent readout must report the resulting
   gain. Do not change track/lane dB readouts or capture trim.
3. Trace monitor levels through `MixSettingsSnapshot`, Settings restore,
   `MonitorCubit` and Session decoding/restoration. Unsupported saved gain must
   follow an explicit existing invalid-data/error path before any partial rig
   mutation. Settings decoding rejects bad data with FormatException during
   the all-input read phase; writing uses its ordinary invalid-value outcome.
   Observe Monitor startup load failures so the startup future cannot leak an error.
   Validate SessionMonitor decoding and direct SessionRig application before
   mutation. Session load reads and validates its candidate before disarming
   an active performance recording. Do not silently migrate, clamp old state
   on page entry, or retain an obsolete interpretation. Keep native engine
   capacity unchanged.
4. Update focused tests with literal expected monitor values. Existing scenarios
   that intentionally relied on >100% monitor gain are changed explicitly to
   legal scenario values; tests protecting other gain domains remain intact.

No new owners, timers, persistence queues, target versions, feature destinations,
packages or native DSP changes belong in this part. The existing application
remains fully usable after this correction without the new Mixer mode.

## Verification

Test forward/reversed endpoints, absolute/relative sources, simultaneous held
sources, ordinary edits at unity, durable Released projection, unavailable
inputs, failed writes and save/reload. Reject non-finite/out-of-range stored
monitor values without affecting accepted track/lane gains or the active session.
Add narrow existing-suite cases for every changed admission boundary. Compare
actual native monitoring and capture samples where existing bound evidence does
not already cover the exact path. Root runs the affected package suites and
application aggregate once the source is frozen, then analysis, explicit-path
formatting and positively scanned Bloc lint. Independent review covers the final
source; actual Claude review and current-head CI remain required before readiness.

## Success Criteria

```success-criteria
GOAL: Every existing live-input volume path uses the accepted 0–100% range without changing recorded-track gain or capture audio.

SUCCESS CRITERIA:
- Monitor mappings produce literal silence, half gain and unity; track and lane laws remain unchanged. | verify: flutter test test/control/binding/control_value_target_test.dart
- Ordinary edits, holders and persistence use the same accepted input range. | verify: flutter test test/app/mix_settings_coordinator_test.dart test/audio_setup/cubit/monitor_cubit_test.dart
- Invalid saved monitor gains are rejected before partial restoration; valid Session and Settings values round-trip. | verify: flutter test test/session
- Changed app and package code passes strict analysis and Bloc lint. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages

NON-GOALS:
- Foot Mixer navigation, gesture changes, native gain-capacity changes, migration/compatibility, deployment or merging.

VERIFICATION COMMAND: flutter test test/control/binding/control_value_target_test.dart test/app/mix_settings_coordinator_test.dart test/audio_setup/cubit/monitor_cubit_test.dart test/session && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

Commands are obligations, not evidence of execution. The final report records
all affected package/native checks and actual results, including skips and
hardware limits. Use the repository's documented SDK and worktree lint wrapper.
