# Foot Mixer performance

Issue #1123; parent #1026; `autonomy:merge-gate`. Base `5704e2fed795274368ff5bad2fcbba22c8d73d6e` (track-mute durability #1129), branch `codex/foot-mixer-performance`. Implementation is authorized; technical review precedes code changes.

## Delivery boundaries

Independent scope, VGV and simplicity reviews split this into working-product
changes, each with its own checks and human merge gate:

1. [Shared input gain](2026-10-04-fix-live-input-gain-part-1-plan.md), issue #1124:
   correct existing controls and saved-data admission without exposing a new mode.
2. [Complete Foot Mixer](2026-10-04-feat-foot-mixer-performance-part-2-plan.md),
   issue #1123: deliver Tracks and Inputs together after the dependency is ready.

The prerequisite probes and repairs are published separately: shared input gain
#1126, monitor mute #1128, and track-mute durability #1129. Part 2 reuses those
corrected owners. The mute prerequisites have clean reviews; older Claude reviews and the human
merge gates remain open.
No unused foundation or partial destination will be published.

## Goal and scope

Complete the accepted single-channel Tracks/Inputs foot Mixer using existing native mixing, transport, Control gestures and persistence. Do not implement Reverse, Fade, Speed, Click pan, backing or instruments. Do not redesign the faceplate, introduce a second controller interpreter, or generalize a performance framework. Click pan remains an explicit unfinished M3 slice requiring a separate native/output-law plan.

The accepted saved Pen section `U9iU1` contains: Tracks `PQJIq`, Inputs `Fbk22`, eighteen inputs `L8Z37W`, Auto `f8I7b`. Use these existing frames: ten-pedal Layout A with two raised controls, compact chosen-channel/bar readout at right and Tracks/Inputs switch. No new layout is proposed.

No new DSP is needed: track and monitor gains/mutes already reach the engine; live monitoring is separate from capture; `LE_MAX_MONITORED_INPUTS` is now 32, so eighteen-input paging needs no capacity expansion. Actual availability comes from the current device/input inventory, not the constant.

## Self-contained accepted product contract

The September 7 owner-accepted Mixer journey uses the existing ten-pedal A layout. Clear and Bank remain above the front row. Enter from a saved Mixer assignment using the same catalogue on Custom, External and MIDI. Entry is a function, not a new direct volume target. Mixer begins on the current recorded track, otherwise the first track containing recorded audio. If none exists, show the empty Tracks state; Inputs remain reachable.

| Control | Short action | Hold |
| --- | --- | --- |
| Four channel pedals | Select one visible channel; repeat keeps it selected | Toggle that channel's mute |
| Undo | Decrease selected volume by five percentage points | Reset selected volume to 100% |
| Clear | Increase selected volume by five percentage points | Reset selected volume to 100% |
| Bank | Page to next four channels, wrapping | Switch Tracks/Inputs |
| Mode | Exit directly to normal Tracks | No additional action |
| Record/Play | Current transport track's recording sequence | No additional action in this flow |
| Stop | Stop all recorded tracks | No additional action in this flow |

Adjustments with a Hold alternative commit short action on release; the existing default hold threshold is 800 ms. Hold consumes release, and no action auto-repeats. Keep the existing shared configured threshold rather than invent another timer. Transport remains immediate as already accepted. Mode exits on contact. Entry by a held Custom gesture must consume that contact's later release.

A pending channel hold follows the newly visible channel if Bank changes **before** the hold fires. Once committed it acts once. Changing Tracks/Inputs or exiting cancels pending flow gestures. A release in a replacement view/device/session cannot act on a different source. Resetting gain never unmutes. Mute does not change level, Auto/On/Off policy, recording trim, recorded audio or transport. Track gain controls recorded playback; Input gain/mute controls only live monitoring. Input status exposes Muted, Auto · Live off or Hear live off truthfully.

Paging is local to Mixer and never changes the normal track/FX bank or transport cursor. Entering a new page selects its first available channel; changing domain selects its first available channel. The last page of eighteen inputs says Inputs 17–18 with the remaining two positions unavailable. Empty recorded tracks are unavailable. The selection LED means selected-for-adjustment; muted state gets its own label/subdued bar. Bars are gain settings, not fabricated audio meters. Touch and encoder can reach the same selection/source choices and actions. Exit, save/reload and restart retain gains/mutes; local selection/page and Mixer mode do not persist.

Accepted foot ranges: Tracks 0–200%; Inputs 0–100%; unity 100%. Each step is exactly 0.05 linear gain and an out-of-range step has no effect. The monitor-only shared-range correction below is a dependency of this journey.

## Resolved contract correction: shared input gain range

The latest owner prototype is decisive evidence of an inconsistency, not a reason for a compatibility branch:

- `fx-ux-prototype.html:704` scales expression level by 2 only for recorded track names. Live-input level uses scale 1; default input unity is normalized 1.
- The same file at line 793 supplies that very same input gain to Foot Mixer.
- `mixer-performance-study.js:11` and the owner-accepted document both cap Inputs at 100%, Tracks at 200%.
- Current production `MonitorVolumeTarget` uses the shared log-fader conversion to gain 2; `MixSettingsCoordinator.setMonitorVolume` also permits 2.
- Later **implementation** plan `docs/plan/2026-10-01-shared-mixer-controls.md:16–20` explicitly states live-monitor logarithmic travel to 2 and its tests prove that implementation. This is a later plan, but this investigation found no separate owner design decision authorizing input 200%. Native capacity alone does not establish UX acceptance.

The current accepted design resolves the implementation direction: correct shared input controls to 0–100%, preserving Tracks 0–200%, and remove the wrongly shared monitor conversion instead of adding a special foot-only ceiling or out-of-range fallback. The accepted prototype uses linear normalized live-input gain: 0 is silence, .5 is 50%, 1 is unity. Adopt that monitor-only descriptor with literal tests; keep recorded-track/lane conversions untouched. The October 1 production plan conflict is recorded, not treated as later owner acceptance. No new user decision is needed absent actual contrary acceptance evidence. Do not clamp existing live state merely on entering a page, add migration/aliases, or introduce old/new target versions. Existing invalid-data/recovery policy must govern unsupported stored values, including Session/startup values; review the exact rejection boundary without building a compatibility layer.

## Ownership and simplicity

1. **ControlCubit remains the only gesture interpreter and holder ledger.** Reuse `_HoldGesture`, `_pressedButtons`, token invalidation and existing transport admission. Add one typed `FootMixerSelection` value containing domain, page and selected channel to ControlState. Keep `cursor` and `activeBank` untouched. A pure read-model helper derives channels, levels, muted/available status and pedal roles from that local selection plus current repository facts. This is local navigation intent, not another persisted mix. Keep semantic navigation, selection and operation policy in a focused stateless Foot Mixer component. Control admits contacts, uses its existing hold interpreter, delegates semantic actions and emits returned selection. The component has no timers, streams or second mutable mix. This bounds growth of the existing interpreter without hiding it in a part file.
2. **MixSettingsCoordinator remains the gain writer.** Calls from the foot flow are ordinary edits so its existing `onOrdinaryValues` supersedes held mapping contributions, including same-value unity reset. Step inside its queued candidate calculation (a bounded track/monitor relative-edit operation) rather than calculating `snapshot + .05` twice outside the owner: three or more rapid taps must preserve every step while storage is delayed. The existing replace-by-target pending map is not sufficient for relative edits; use bounded ordered composition and prove endpoint reversals and absolute reset interleaving. Reuse its transaction/recovery/session-generation machinery. Do not store shadow gains in ControlState.
3. **Track mute reuses repository intent and Session capture**, just like ordinary Mute. Existing restart persistence uses lane-mute settings; reconcile this confirmed ownership gap before claiming restart retention. Reuse those keys rather than add a second mute envelope or force mutes into the native mix vector. `trackMuted` reads synchronous intended whole-track mute to avoid stale-poll double-toggle loss. Keep mute independent from park/resume behavior: Foot Mixer never invokes the Mute mode's all-muted transport consequences.
4. **Input mute reuses the existing confirmed monitor-envelope save owner.** `FxChainPersistence.saveConfirmed(input address)` already saves current input mode/output/mute plus Released FX; MonitorCubit delegates to it today. Extract only the reusable mute operation into a small non-Cubit `InputMonitorMuteControl` application adapter if needed, injecting repository, FxChainPersistence and SettingsRepository. Both MonitorCubit and Control use that same operation; it does not own another map, timer, save queue or settings format. Check current input/session identity, report engine refusal, then join the existing save. MonitorCubit stays a repository-observing presentation adapter. Do not pass MonitorCubit to Control or expose its method as a disguised Cubit callback.
5. AppRuntime constructs/injects the narrow operation adapter. App only provides dependencies; views render and forward intents. No flow logic in App, view setState, or a second persistence callback chain. Existing SessionSettingsCoordinator and runtime flush barriers continue to own save/shutdown ordering.

Input mute currently updates repository intent before native admission returns, and whole-track mute applies per lane. Do not promise atomic rollback that these APIs do not provide. Add explicit queue-refusal/error observations to the regression matrix and make a bounded repository correction: current setMonitorMute publishes intent before reporting native rejection, so the existing flow can claim success after rejection; present that delta separately at review. A generic transaction rewrite or native DSP change is not part of this plan.

## Concrete file plan and dependency order

1. Implement the accepted monitor-only gain-law correction; update `lib/control/binding/control_value_target.dart` and `mix_value_scale.dart` only to the reviewed boundary, along with actual input editor constraints and relevant descriptor tests. Extend the existing application admission and saved-input validation boundary to reject values above unity instead of relying on native capacity 2; trace Settings/Session import paths without adding migration. Native gain capability can remain unchanged. Do not alter recorded-track/lane/Click domains by incidental shared-helper edits.
2. Model and route the journey in `lib/looper/model/interaction_mode.dart`, `lib/control/binding/control_action.dart` and action labels/pickers, `lib/control/cubit/control_state.dart`, `control_cubit.dart`. Add pure `lib/control/model/foot_mixer_selection.dart` and `lib/control/foot_mixer_projection.dart` only if they keep data/projection out of the interpreter. Add the narrow queued relative gain operations to `lib/app/mix_settings_coordinator.dart`. Build and test the intent path before exposing the function.
3. Reuse/extract input mute operation at `lib/audio_setup/application/input_monitor_mute_control.dart`; inject through `lib/app/application/app_runtime.dart`, `lib/app/view/app.dart` (composition only), `lib/audio_setup/cubit/monitor_cubit.dart`, Control constructor. Existing monitor snapshot/save machinery remains in `lib/app/fx_chain_persistence.dart`; avoid changes unless a reproduced admission/lifetime gap requires them.
4. Present `lib/looper/view/foot_mixer_view.dart` from `tracks_view.dart`, with existing typography, status/notice and encoder controls. Reuse `lib/control/view/pedal_setup/pedal_hardware_face.dart` and the existing `lib/pedal/view/pedal_plate.dart` simulator instead of duplicating the ten-pedal layout. Contextual captions/roles must come from the same typed read model as dispatch. Audit all InteractionMode switches, `lib/control/control_projection.dart`, `lib/control/invariants.dart`, action labels and `tracks_commands.dart`.
5. Keep the current protocol. The wire frame only has eight track LED slots and an A/B bank; do **not** encode Mixer input page 4 as an illegal normal track bank. Project selected visible physical slot/active-button mask using a documented existing wire mode (Custom is the candidate) while keeping local input page only in app readout. Confirm physical firmware consumes the existing mask before freezing this choice. If it requires a wire change, stop and replan with mandatory firmware checks rather than faking page identity.
6. Session/save/restart and teardown integration should primarily be tests of existing owners. Extend production only where required by new adapter admission/flush; no new session schema or storage format is anticipated. New mode is not a boot default. Keep device-loss/session replacement selections safe and invalidate pending flow gestures before reassignment.

## Observable regression matrix

- Enter by Custom press and held action, External and MIDI; entry release does nothing extra; Exit returns normal Tracks and prior bank/cursor unchanged.
- Current empty track falls back to first recorded one; all empty Tracks remains honest while Inputs works; pages A/B and Inputs 1–4 through17–18 are complete and unused positions inert.
- Select one, repeat select, page first-available, domain first-available; flow selection never retargets Record/Play's transport track.
- Tap ±5%, three rapid taps during delayed save yield ±15%, including reversals at endpoints and reset interleaving; min/max no-op; hold reset exactly unity and no trailing step; live >range/invalid state follows the adjudicated contract without a compatibility branch.
- Track hold and input hold toggle only committed channel, preserve gain; hold across Bank follows newly visible slot before threshold; domain/Exit/session/device change invalidates it. Bounce/repeat/release fires once.
- Track mute never parks a playing track. Monitor mute/volume does not change capture trim, capture PCM, input mode/FX, track playback or transport; Auto closed input remains Auto closed after mute/reset/unmute.
- Input/track gains share ordinary controller priority: Foot reset while Held is unity supersedes prior Released cleanup; source disable/loss later cannot restore stale gain. External/MIDI changes update foot readout via repository truth.
- Slow/failing storage, rejected enqueue, engine/device/session replacement, shutdown while a step/mute is admitted: show actual outcome, no uncaught errors or false durable success; save/recall gets accepted values and existing Released projection.
- Save/reload/restart retains gain/mute but not local mode/selection/page. Multi-lane track mute operates every lane. Eighteen input identities never bind by label or swap due to pairing/name changes.
- Real TracksView render contains the complete flow, contextual physical controls, readable selected level/status, empty view, last input page and error notice above overlay siblings. Touch/encoder invokes the same intent methods; no master gain change by an incorrectly routed flow encoder action.

## Tests and gates

New focused files: `test/control/foot_mixer_dispatch_test.dart` and `test/looper/view/foot_mixer_view_test.dart`, plus `packages/looper_repository/test/foot_mixer_monitor_isolation_test.dart` for literal native samples. Extend existing `test/control/control_projection_test.dart`, `invariants_test.dart`, `binding/control_action_test.dart`, descriptor/resolver tests, `test/app/mix_settings_coordinator_test.dart`, `test/audio_setup/cubit/monitor_cubit_test.dart`, `test/pedal/view/pedal_plate_test.dart`, `test/looper/view/tracks_view_test.dart`, `test/app/application/app_runtime_test.dart`, and a real Session save/recall test. Add actual-native tests in the existing LooperRepository suite for unchanged monitor/capture separation if the current bound evidence does not cover exactly the exercised mute/volume path. Do not manufacture tests that match source text.

Use the configured Flutter CLI and source-bound native library for relevant tests, max two coordinated processes. Root owns aggregate application/package coverage, analyzer/explicit-path format/Bloc lint, final diff review and publication. Verify static tools scan intended worktree files. Native DSP suites may reuse exact hashes only if no native source changes. Any pedal codec/firmware change requires `bash firmware/test/run_tests.sh`; none is intended. Read accepted Pen frames through Pen tools before UI implementation and compare actual rendered TracksView after author freeze; no blanket golden regeneration.

## Success Criteria

```success-criteria
GOAL: Perform and retain one recorded-track or live-input volume/mute adjustment entirely by foot, with one shared runtime and no effect on recording or unrelated transport.

SUCCESS CRITERIA:
- Every accepted pedal, bank, held-release and shared-controller priority sequence has the stated observable effect. | verify: flutter test test/control/foot_mixer_dispatch_test.dart test/control/control_projection_test.dart test/control/invariants_test.dart
- Fast steps, mute/save failures, Session/restart and owner disposal preserve confirmed intent or expose recovery. | verify: flutter test test/app/mix_settings_coordinator_test.dart test/audio_setup/cubit/monitor_cubit_test.dart test/app/application/app_runtime_test.dart
- The actual Tracks hierarchy provides selection, all input pages, unity/mute/status and visible failures through the same intent path. | verify: flutter test test/looper/view/foot_mixer_view_test.dart test/looper/view/tracks_view_test.dart test/pedal/view/pedal_plate_test.dart
- Native input gain/mute leave recorded PCM and transport unchanged. | verify: flutter test packages/looper_repository/test/foot_mixer_monitor_isolation_test.dart
- Physical ten-pedal hold/release, LEDs, eighteen-input paging and recorded/live sound separation match the accepted flow. | verify: manual perform the frozen matrix on the appliance, including Bank during hold and Exit while held; preserve evidence separately from desktop checks

NON-GOALS:
- New DSP operations, Click pan, backing/instruments, new firmware protocol, generic performance framework, obsolete-target compatibility or migration, auto-merge/deployment/flash.

VERIFICATION COMMAND: flutter test test/control/foot_mixer_dispatch_test.dart test/control/control_projection_test.dart test/control/invariants_test.dart test/app/mix_settings_coordinator_test.dart test/audio_setup/cubit/monitor_cubit_test.dart test/app/application/app_runtime_test.dart test/looper/view/foot_mixer_view_test.dart test/looper/view/tracks_view_test.dart test/pedal/view/pedal_plate_test.dart packages/looper_repository/test/foot_mixer_monitor_isolation_test.dart
```

The commands describe required evidence, not checks already run. Final focused matrix must add the exact Session and native cases, source hashes and normal repository CI commands before implementation freeze. The prerequisite corrections are published as #1126, #1128 and #1129; the existing wire mask has been verified against the firmware consumer. The second part can now build on those owners. Human merge, physical verification and independent review gates remain unchanged.
