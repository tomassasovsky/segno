# Foot Fade performance

Status: technical, simplicity and split-plan reviews complete; implementation pending.
Tracking: existing #1026, `autonomy:merge-gate`. Implementation is already authorized
by the delivery task; merging and device deployment remain separately gated. Source baseline: `5bad07820dd7209c70f345f7162a09e9f87de44a`.

## Overview and motivation

Deliver the accepted complete Fade journey: independent recorded-track fades,
shared/default duration editing, Custom/CTRL/MIDI actions and the banked foot
surface. Existing Mixer gain is an immediate saved scalar; changing it repeatedly
would overwrite the player's mix and make timing depend on Dart scheduling.
Fade therefore needs one separate callback-owned playback coefficient per track.
It is independent of unfinished Reverse, tempo arbitration and METRIC-01.

## Accepted behavior and engineering choices

- Tap a recorded track on release to alternate fade out/in. Retrigger reverses
  from the current amount without a jump; several tracks fade independently.
- Use a linear coefficient from 0 to 1 at the **existing track-gain boundary**,
  multiplied by saved Mixer gain. Four seconds describes a full traversal:
  reversing from .5 with that duration takes two seconds. Editing duration only
  affects the next gesture, including retrigger; no quantization to loop/beat.
- Advance by processed samples, including when loop playback is stopped. Fade
  never starts transport or changes capture, overdub, mute, input level, FX,
  speed, pitch or direction. Empty tracks are unavailable. Stop retains the
  envelope; Exit leaves admitted fades running and returns to normal Tracks.
- Preserve existing signal topology: lane Post precedes track gain; track Post,
  all-track and output processing follow it. Fade attenuates upstream lane tails
  normally. Do not borrow Stop semantics or promise every Post tail escapes Fade.
- Default duration is 4s, range .5–30s in .5s steps. Entry selects Default.
  Track hold selects its duration without fading. Editing inherited time creates
  an override; hold Undo/Clear removes it, or resets Default to 4s. Tap Undo/Clear
  shortens/lengthens. Tap Bank changes A/B; hold Bank selects Default.
- Use the existing shared hold timing (accepted prototype: 800ms), one activation
  and consumed release. Pending track holds follow bank changes until activation;
  completed gestures retain identity. Exit/session/device retirement cancels
  unfinished contacts. Record/Play retains the normal transport cursor.
- Show all eight effective times, selected Default/Custom/Uses default, progress
  and truthful LEDs (fading/attenuated, not audibility). Normal Mixer retains its
  saved gain and separately shows Fading/Faded out. Reuse accepted Pen layout.
- While the device is unavailable, freeze the last coherent observed coefficient.
  On same-session reopen, resume its target at its original full-travel rate from
  that amount; no wall-clock catch-up. Duration edits do not change the active fade rate.
- Session capture stores a stationary current coefficient; reopening restores it
  with playback stopped. Cold startup restores the last committed image, not
  elapsed wall time. New Loop/removed material clears obsolete envelopes to unity;
  retain duration setup. Fade/time edits are not audio-history steps and cannot
  discard Redo. Undo/Redo that empties/refills a track must not resurrect a stale
  running fade. Clear/Clear All recovery restores the affected pre-clear Fade
  amount as stationary musical state when the clear changed it, without undoing
  later independent edits. Preserve the existing per-track/grouped history and
  its ordering; do not add Fade gestures as new audio-history entries.

These choices fit the accepted native target and later Session behavior. Browser
normal-URL reload advances simulated wall time, explicitly described as a silent
prototype; it is not a device-reopen requirement. No explicit acceptance conflict
was found. Curve/clock/replay choices passed the plan review. Implementation still
needs independent code review and listening verification.

## Architecture and concrete work, in dependency order

### 1. Native envelope and observable admission

Edit `packages/segno_engine/src/core/engine_private.h`, `engine.c`,
`engine_commands.c`, `engine_process.c`, `engine_snapshot.c` and
`segno_engine_api.h`. Add checked command-ring admission for target + full-travel
duration, per-track amount/target/rate runtime and bounded coherent readback with
revision. Resolve Toggle from the callback's current target at application, never
from a delayed UI snapshot. Rapid same-track commands and independent tracks need
identifiable applied/refused outcomes; do not copy the timing owner's single
pending-setting exclusion or infer success from a coincidentally matching target.
Add one checked internal image-install operation: Session installs amount=target
with zero progression; reconnect installs coherent amount/target/full-travel rate
in seconds. Validate finite/ranged values and the content/session lifetime, apply
the complete tuple before audibility, and reject without partial publication. Retrigger samples amount on the callback, not from a delayed Dart poll.
Reuse the existing record-timing sequence/tuple publication pattern; ordinary
meter atomics permit mixed frames and cannot certify an envelope tuple.
Advance the envelope before transport gating, without allocations, locks or I/O.
Use the same coefficient for no-chain, lane-cache and whole-track-print paths.
Initialize/reset to unity explicitly: zero-initialized memory means silence.

Extend `packages/segno_engine/lib/src/audio_engine.dart`,
`native_audio_engine.dart`, `mock_audio_engine.dart`, `engine_snapshot.dart` and
regenerate `generated/segno_engine_bindings.dart`. Keep `AudioEngine` the seam.
Extend native `perf_log_ring`/`perf_drain` encoding only where the concrete command
requires it; implement initial image and sample-timed replay in `perf_render.c`.
Performance output must contain Fade while recorded lane PCM remains unchanged.
No separate ramp queue, generic transform graph or periodic Dart gain writer.

### 2. Repository, duration ownership and saved images

Extend `packages/looper_repository/lib/src/looper_repository.dart`, its Track
projection and `models/session_rig.dart`. Expose confirmed amount/target/moving
and one checked action; use existing engine/session generations to reject stale
completion. Reuse the existing pending-command observation machinery. No second
UI gain cache and no routing through MixSettingsCoordinator.setTrackVolume.

Add a small typed duration snapshot/default+override model and immediately used
Fade settings owner. It owns only strict duration setup and ordered durable
writes, existing mapping precedence and Session exclusion. Do not clone the
playback owner's engine receipts, rollback, reconnect image or runtime envelope.
Pass effective duration with each musical gesture; ordinary duration edits make
no native request and never change the rate of an admitted ramp. A failed storage write keeps
its last durable value authoritative and exposes existing explicit retry.
Place the owner in `lib/looper/application/fade_settings.dart`, compose it in
`lib/app/application/app_runtime.dart`, and add strict persistence to
`packages/settings_repository/lib/src/settings_repository.dart`. Reuse existing
scalar admission, recovery, Held/Released and ordinary-edit priority conventions;
one owner writes duration data. Do not generalize unrelated owners for this slice.

Extend `packages/session_repository/lib/src/models/session.dart`,
`session_repository.dart`, `lib/session/application/session_settings_coordinator.dart`
and the existing Session capture/apply adapters. Capture waits admitted edits,
then detaches current Fade amounts from **the same engine image used by
SessionRepository._capture**; its later snapshot must not disagree with an earlier
UI/duration-owner read. Saving freezes only the saved image, not the live ramp.
Use existing Session replacement/boot persistence/retry barriers; malformed Fade
fields fail preflight before disarm or mutation. No fallback/migration format.

Reconnect currently raw-stops, retires waiters and configures a fresh engine.
Before discarding that lifetime, retain one coherent observed amount/target/rate
image; replay it together for the same session. A command accepted before loss
cannot be treated as applied without its readback. Reopen failure keeps explicit
recovery, not unity/default publication. Sample-rate change preserves seconds.
Clear, undo-to-empty, redo/new capture, import and New Loop must retire obsolete
runtime state at accepted material transitions. Detach pre-Clear amount at the
actual callback Clear boundary, before unity reset, into the existing generation-
bound ordinary/frozen Clear report. Restore it stationary through both history
paths; do not sample a stale Dart projection or add another history owner.
Session load installs its own
stationary image rather than the outgoing reconnect image. No disk writes per
sample/poll; existing save/checkpoint/shutdown capture owns committed images.

### 3. Complete shared controls and accepted surface

Add Fade to `lib/looper/model/interaction_mode.dart`, the shared ControlAction
catalogue/labels and `lib/control/binding/control_value_target.dart`, resolver and
external/MIDI writers. Support mode entry and selected/fixed/all Fade actions,
plus normalized default/fixed-track duration targets from the accepted catalogue.
Do not expose these until the engine and persistence paths above work.

Use a small `lib/control/model/foot_fade.dart` role/projection and
`lib/control/foot_fade_actions.dart` semantic adapter. Extend existing Control
state/gesture dispatch: one contact ledger, source ownership and hold interpreter.
Selection is temporary Control state; audio state comes from repository readback.
Keep failure observation and actionable retry on the existing notice seams.
No new widget timer, gain owner, Cubit-to-Cubit dependency or view setState policy.

Extract the existing private `_MixerPedal` contact/presentation shell only with
its immediate Mixer and Fade consumers. Keep one typed role table for labels and
dispatch; do not introduce a generic performance-screen builder.
Compose `lib/looper/view/foot_fade_view.dart` from that shared contact widget;
update TracksView, pedal projection, assignment pickers and `mixer_column.dart`
attenuation cue. Add English/Spanish strings using existing localization tools.
Reuse custom physical active masks; no new firmware protocol is expected. Check
all enum/picker/export switches and real Custom/CTRL/MIDI entry/release paths.

## Tests and acceptance

Add native Fade cases to `packages/segno_engine/src/test/test_engine_core.c` and the
existing performance-render suite: literal samples at44.1/48kHz and varying block
sizes; full/midpoint/retrigger/duration-edit timing; concurrent tracks; stopped
transport; Mixer independence; downstream tails and raw/cache/print parity.
Include two toggles before a poll, independent-track admission, refused complete-
image install and its first audible sample; delayed ordinary/frozen Clear capture.
Include malformed commands, queue refusal, coherent readback under interleaving,
reconfigure/sample-rate change, removal and performance-render parity.

Add `packages/looper_repository/test/fade_test.dart` with actual-native coverage
for confirmation, capture isolation, clear/refill and device/session lifetimes;
Settings/Session package tests for strict decode, stationary capture/recall and
failed-write/load recovery. Add `test/looper/application/fade_settings_test.dart`,
`test/control/cubit/control_fade_test.dart` and
`test/looper/view/foot_fade_view_test.dart`. Use existing fixtures, deterministic
barriers and real shared ingress; no source-text assertions or duplicated matrix.
Test inherited/explicit/default reset, old held-release priority, bank-following
hold, physical/screen overlap, stale release, normal cursor, Exit and Power.

## Success Criteria

```success-criteria
GOAL: Perform and recall independent track fades without altering saved Mixer levels, recorded audio or transport intent.

SUCCESS CRITERIA:
- Native output follows full-travel linear timing, continuous retrigger and stopped-playback progression across cache paths, with unchanged capture PCM and correct performance replay. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Repository and saved images confirm admission, freeze on device loss, preserve seconds on reopen, recall stationary Session amounts and reject malformed data before mutation. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Shared duration/mapping and actual foot gestures obey inheritance, lifetime and release ownership; Exit preserves fades and Mixer labels attenuation separately. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static checks and callback configurations remain clean without compatibility machinery. | verify: dart analyze --fatal-infos && bloc lint lib test packages && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Accepted layout, audible continuity/tails and physical timing work on the appliance. | verify: manual 1. Compare accepted Fade Pen frames and Mixer cue. 2. Listen while retriggering and stopping cached/live tracks. 3. Exercise physical hold/bank/Exit and device unplug/replug without stale actions.

NON-GOALS:
- Reverse, Speed, tempo-law repair, input fades, audio-history redesign, generic automation framework, compatibility migrations or unrelated factory assignments.

VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

## Review, risks and references

Measure success by the observable assertions above, not test count. Before build,
independently review snapshot/capture coherence, accepted-versus-applied loss,
current-value resume, history retirement, layer boundaries and realistic scope.
No user-visible half-feature: dependency commits may be reviewed separately, but
publish the whole journey only after the earlier layers work. Use the three
linked dependency plans below; split further only when the actual diff justifies it. Follow PROGRESS
for the working SDK, explicit edited-path format, FFI regeneration/C++ checks and
CI coverage; firmware suite is required if codec/firmware changes prove necessary.
Final-head code/VGV/simplicity/test reviews, CI and human merge gate remain separate
from author screenshots and physical/listening proof. No checks were run for this plan.

Sources: `docs/design/2026-09-07-fade-performance-ux.md`,
`fade-performance-study.js`, `pedal-action-catalogue.js`,
`mapping-parameter-targets.js`, `2026-09-07-session-library-ux.md`,
`session-field-ownership.js`, `fx-ux-prototype.html` Session capture/fresh paths;
`docs/brainstorm/2026-09-07-undo-redo-brainstorm-doc.md`;
`docs/handoff/segno-app/accepted-behavior.md` §§3/6. Looper X Fade reference is
already documented in the accepted Fade source; its timing law is not Segno's.

## Reviewed delivery partitions

Independent splitting, simplicity and VGV roles were completed. Consolidation
keeps three coherent contracts; a seven-layer scaffold would defer composition
and duplicate fixtures. No production/test line estimate is an approved budget.

1. [Native capability and real engine seam](2026-10-04-feat-foot-fade-part-1-plan.md):
   complete command, readback, literal audio and performance reconstruction.
2. [Durability and lifetime composition](2026-10-04-feat-foot-fade-part-2-plan.md):
   duration setup, actual capture/recall, reconnect and existing history metadata.
3. [Complete controls and accepted surface](2026-10-04-feat-foot-fade-part-3-plan.md):
   one contact/role path and immediate UI/mapping consumers.

Part 1/2 preserve current public app behavior with unity defaults and no advertised
Fade actions. Part 3 exposes only the completed journey. Each part is independently
testable and reviewed; none alone is advertised as the accepted feature finished.
Assign sample/rate oracles once to native tests, lifecycle races to repositories,
strict data to persistence, contact identity to Control, and real visibility to UI.
No repeated unchanged broad runs or source-shaped tests.
