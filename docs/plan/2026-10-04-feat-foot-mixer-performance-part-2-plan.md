# Complete the foot-operated Mixer

Part 2 of [Foot Mixer](2026-10-04-feat-foot-mixer-performance-plan.md),
issue #1123, human merge gate. Depends on the shared input-gain correction in
[part 1](2026-10-04-fix-live-input-gain-part-1-plan.md), published as #1126,
and monitor-mute admission #1125 (published as #1128). Track-mute restart
persistence #1127 is published as #1129. This implementation starts from that
head; it does not imply those prerequisites have merged.

## Contract and owners

Implement the complete Tracks and Inputs journey in the parent plan. Retain its
accepted ten-pedal layout, single selection, four-channel pages, independent
transport cursor, mute semantics, live/capture separation and transient mode.
Do not expose an assignment until the whole journey works.

Control remains the sole contact/hold interpreter and mapping holder ledger.
A focused stateless Foot Mixer operation component owns semantic selection,
paging and dispatch against existing mix/mute owners. It accepts typed local
selection and current facts; it does not introduce another timer, stream,
persisted mix, controller parser or save queue. Control only admits gestures,
delegates their semantic actions and publishes returned selection. The view
renders state and sends intents. The existing mix owner continues to serialize
all gain writes; monitor muting joins the confirmed monitor-envelope save path.

Relative volume steps must compose at the owner boundary, including three or
more rapid taps while a prior save is blocked. The current replace-by-target
pending map cannot silently discard an intermediate step. Preserve order between
relative steps and absolute unity reset without creating a second unbounded
command queue. A full five-point step that would cross a bound is a no-op,
including an off-grid value: Input 98% plus stays 98%, and 2% minus stays 2%.
Do not clamp those to the endpoints or quantize values from other controllers. Ordinary accepted edits, even equal-valued resets, retain shared
holder priority semantics.

## Tasks

1. Add the typed local Tracks/Inputs selection and minimal semantic operations.
   Reuse Control's existing 800 ms hold path and lifetime invalidation. Reuse
   repository facts; do not shadow gains or mutes.
2. Add bounded queued relative gain operations to MixSettingsCoordinator.
   Extract the input-mute operation only if both existing Monitor and new flow
   use it immediately. Prove engine refusal cannot be reported as durable success.
3. Wire the existing assignment catalogue, runtime composition and actual
   TracksView. Reuse the hardware-shaped pedal widget and theme tokens from the
   accepted Pen frames. All captions and LED roles derive from the same semantic
   projection used by dispatch. App remains composition only.
4. Preserve the wire protocol. Input pages are local UI state, not an invalid
   A/B track-bank value. Verify the selected physical-slot mask is consumed by
   existing firmware before fixing the representation. If a protocol change is
   necessary, replan it explicitly with the firmware test gate.
5. Add focused behavioral, actual-native and rendered tests, then independent
   quality/adversarial reviews. Keep hardware proof separate from desktop proof.

## Existing wire projection

The console firmware already renders each physical pill from
`active_button_mask` and `pedal_colors`, independently of legacy track LEDs and
bank fields. Its existing console pill tests cover every physical button under
both valid banks. Reuse Custom wire mode and that mask for Mixer selection;
keep input page only in local state. The application must test the new projection
and normal bank/cursor preservation. No protocol change is required by this flow.
Physical appliance verification remains separate.

## Verification and risks

The parent regression matrix applies in full. Add three-plus-tap delayed-save
and mixed relative/reset ordering cases. A hold consumed on entry cannot fire
again in Mixer; page changes before a channel hold fires follow the newly
visible channel, while domain changes and Exit cancel the pending gesture.
Selection and pages must never retarget Record/Play or leak into the normal bank.

Admission/refusal fixes substantially larger than a small shared mute operation
become an independently usable correction of the existing Monitor flow first.
Current inspection has identified native-refused monitor mute being published
before admission, and whole-track mute lacking the lane-settings write used at
app restart. Prove these paths and correct their existing ownership before
claiming durable mute. Read the visible page when a channel hold fires; capturing
the channel at press time contradicts the accepted Bank-during-hold behavior.
Do not hide a generic state-owner rewrite inside this feature. No new DSP,
firmware, settings format or Session schema is planned.

## Success Criteria

```success-criteria
GOAL: Adjust one recorded track or live input by foot through the accepted complete Mixer flow without changing capture or unrelated transport.

SUCCESS CRITERIA:
- Entry, selection, paging, hold/release, Exit and shared control priority obey the accepted flow. | verify: flutter test test/control/foot_mixer_dispatch_test.dart test/control/control_projection_test.dart test/control/invariants_test.dart
- Every rapid relative step survives delayed storage; reset and mute remain independent with truthful failures. | verify: flutter test test/app/mix_settings_coordinator_test.dart test/audio_setup/cubit/monitor_cubit_test.dart
- The actual Tracks hierarchy exposes the complete flow with all eighteen inputs and visible failures. | verify: flutter test test/looper/view/foot_mixer_view_test.dart test/looper/view/tracks_view_test.dart test/pedal/view/pedal_plate_test.dart
- Live-input gain/mute leave capture PCM and transport unchanged. | verify: flutter test packages/looper_repository/test/foot_mixer_monitor_isolation_test.dart
- Physical gestures, LEDs, sound isolation and save/restart match the accepted behavior. | verify: manual perform the frozen matrix on the appliance and retain separate evidence

NON-GOALS:
- New DSP, other performance functions, another gesture interpreter, compatibility, new firmware protocol, auto-merge or deployment.

VERIFICATION COMMAND: flutter test test/control/foot_mixer_dispatch_test.dart test/control/control_projection_test.dart test/control/invariants_test.dart test/app/mix_settings_coordinator_test.dart test/audio_setup/cubit/monitor_cubit_test.dart test/looper/view/foot_mixer_view_test.dart test/looper/view/tracks_view_test.dart test/pedal/view/pedal_plate_test.dart packages/looper_repository/test/foot_mixer_monitor_isolation_test.dart
```

The report must record exact save/recall/native test cases, affected package and
application coverage, strict analysis, explicit formatting, positively scanned
Bloc lint, author renders and source-bound review. These are future obligations;
this plan alone certifies none of them.
