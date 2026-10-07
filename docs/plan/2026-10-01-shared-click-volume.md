# Shared Click volume control

Issue #1026. M3.11 follows the shared Mixer catalogue. This plan covers one
vertical slice: Click volume through the existing touch controls, External
buttons/expression and MIDI Remote. Product implementation starts after M3.10
finishes its local gates and publication; its remote CI may finish in parallel.
This document is separate from that change.

## Behavior and scope

Click volume has physical linear gain 0–2, with unity at 1. Controller endpoints
remain normalized 0–1: gain is twice the endpoint, and unity is endpoint 0.5.
Relative input moves 0.01 normalized per step, or 0.02 physical gain. This is
the existing Click slider law; it does not use the Mixer logarithmic fader law.

Use an immutable `ClickVolumeTarget` with exact canonical identity
`{"ctl":"clickVolume"}`. It belongs to `ControlValueTarget`, outside
`MixValueTarget`. Reject extra fields, aliases and malformed identities. Offer
one stable `click` destination under the existing Outputs navigation band,
independent of audio bus count. Both editors show the existing percent-of-unity
readout: endpoint 0.5 displays 100%, and endpoint 1 displays 200%. Accessible
values use the same units during editing, commit and cancellation.

External button parameters initialize both endpoints from the current accepted
Click value: unity starts at 0.5/0.5. Expression and MIDI retain their existing
full 0/1 range defaults. Add and Save alone never write audio, and repairing a
target preserves its authored endpoints. Do not create a Click-specific constant
range for expression or MIDI. An absent owner makes the target unavailable and
repairable with Change control/Remove; zero volume is a valid available value.
A stopped device still accepts a durable deferred intent. It does not provide
an audible confirmation. Reconnection requires fresh controller input and never
replays a held value or logical latch.

Click mode, count-in, BPM, loop fields, backing and instrument targets are
outside this slice. It adds no MIDI format, native API, settings migration,
compatibility target or independent controller interpreter.

## Architecture and interfaces

TempoCubit remains the sole owner of Click user intent. Both touch routes keep
calling `setClickVolume(double volume)`; the same method returns a typed
`Future<ClickVolumeOutcome>` instead of an uninformative completion. Existing
awaited or fire-and-forget callers remain viable on that path. The outcome has
`applied`, `rejected`, `superseded` and `recoveryRequired` statuses, an optional
engine result/error, and an explicit deferred flag for stopped acceptance.

Place the shared `kMaxClickGain` and small Click-specific boundary types in
`lib/looper/model/click_volume.dart`. TempoCubit implements a narrow
`ClickVolumeControl` interface exposing:

- Accepted physical `clickVolume`, nullable only when the owner is unavailable.
- `durableClickVolume`, the authored Released projection or accepted ordinary
  or non-held value.
- A lifetime containing the existing repository session revision and mix
  generation.
- A stream of accepted ordinary Click volume changes.
- `setControllerClickVolume(double volume, {double? releasedVolume,
  required ClickVolumeLifetime lifetime})` returning the typed outcome.

The app injects the same eager TempoCubit instance through that interface into
ControlCubit. ControlCubit does not import another Cubit or construct another
Click owner. Tempo additionally exposes `flushClickVolume`,
`runClickVolumeExclusive<T>`, `recoverClickVolume` and a failure stream for app
integration. These operations share one owner queue.

The existing repository extension resolver receives an optional physical
`clickVolume` argument for availability, enumeration and read methods; the
catalogue builder receives the same value. Only its Click branch uses it.
Every Click-capable editor/runtime call site supplies the owner value. There is
no fallback to `sessionTransport.clickVolume` and no label-based resolution.
The nullable port remains unavailable until startup Click restoration or another
confirmed initialization settles; TempoSettings' provisional unity must not
seed new button endpoints while a saved value is still loading. An accepted
ordinary edit or session replacement can establish the owner first and fences
the older startup read. While a running write is pending, the owner retains its
last accepted setting; immediate repository emissions must not advertise a
proposed value as accepted.

## Native publication and the confirmed cache

`LooperRepository.setClickVolume` currently acknowledges command enqueue and
updates a reapply cache. That is insufficient for controller acceptance. Keep
its low-level admission signature, add one pending Click receipt and
`settleClickVolume`, and update the cache only after callback confirmation.
Expose `clickVolumeSettled` for bounded integration checks.

Reuse `AudioEngine.commandsSettled`. Its native implementation acquires the
command publication count, which the callback releases after snapshot stores.
After that fence, read a fresh native snapshot and compare its click gain with
the requested float32 value using an explicit absolute tolerance of 1e-6 over
the supported range. No callback telemetry, frame-count heuristic, FFI symbol
or generated binding change is required. The existing Mixer settlement code is
the local implementation pattern.

A same-value request still observes the publication fence; an older queued
write must not apply after an apparent idempotent success. Reject another
low-level Click admission while one is pending; Tempo serializes its callers.
Settlement must work without a UI subscriber. Use a bounded poll, initially
10 ms for at most 50 attempts, with test injection for deterministic delays.

Stop, reconfigure and session replacement cancel the exact pending receipt.
Engine startup replays the last confirmed deferred Click gain and settles it
before publishing the new audible value. Session application also awaits Click
settlement before reporting success. Other tempo/count-in behavior is unchanged.

## Durable transaction and recovery

Keep the existing `tempo.click_volume` scalar in SettingsRepository. Add
`readClickVolumeCheckpoint(): Future<double?>` and
`restoreClickVolumeCheckpoint(double?): Future<void>`. Serialize its existing
save method, checkpoint reads and restoration through the repository writer,
with readback verification. Null means absent; rollback removes the key rather
than replacing absence with explicit unity. Unreadable data is not silently
replaced. The default of 1 belongs to normal load, after checkpoint reading.

For each ordinary or controller write, the owner:

1. Captures the accepted live value, prior durable projection, exact stored
   scalar and session/device lifetime; rejects invalid or non-finite gain.
2. Saves the candidate durable value: authored Released for a held contribution,
   otherwise the candidate itself. A storage refusal sends no audio command.
3. Rechecks lifetime, admits the repository command and awaits native publication.
4. Commits accepted state/projection and reports ordinary intent only after both
   persistence and the engine receipt succeed.

An enqueue refusal restores the checkpoint and preserves the prior accepted
state. A timeout takes the deterministic stop boundary: block Click recovery
and engine start, stop processing, cancel uncertain pending work and report
recoveryRequired. Do not accept a corrective old value merely because an old
snapshot already equals it. Failed checkpoint restoration also enters recovery.

Use a separate Click recovery start flag alongside the existing Mixer flag;
repairing Mixer persistence must not clear a Click failure. Explicit recovery
restores the scalar checkpoint and the prior durable runtime value as stopped
deferred intent, then clears only the Click block. These are separate values:
a recalled session can differ from the startup preference. Expired held highs
must not be replayed. Recovery does not automatically start audio.

Superseded work must never restore its gain or stop a replacement session or
device. Restore its preference checkpoint only while the owner queue excludes
newer preference writes. Check pending identity/lifetime before timeout action
as well as before admission. Closing the owner refuses new work, awaits its
queue and recovery boundary, cancels subscriptions and prevents late emits.

## Shared held and ordinary ownership

Use ControlCubit's current source queue, parameter-holder ledger, acceptance
order, survivor resolution and MIDI prepare/settle protocol. Add Click target
arms to that path. Generalize the existing External Released-value map only
as needed to hold both Mixer and Click targets; keep the native Mixer batch
typed and send Click through its own authoritative owner.

A held press supplies its authored Released endpoint. Cleanup supplies the
newest surviving held contribution's Released value. A new non-held write
supplies no old Released override: its accepted value becomes durable. Accepted
ordinary edits, including equal-valued explicit edits, publish an ordinary
ledger contribution. An accepted new controller write retires older ordinary
or retained baseline markers only after receipt.

Refused writes do not advance pickup, toggles, holder priority or accepted MIDI
indices. Refused release remains owed; accepted repress replaces its own older
cleanup ticket. Missing Click must not reject valid sibling targets. Source,
session and device lifetime checks fence queued work and cleanup. The target
uses the same disable/disconnect/reconnect rules as existing controls.

## Session, shutdown and lock order

The fixed lock order is **Mixer exclusive, then Click exclusive**. Click writes
must not await the Mixer lock while holding the Click lock. Controller writes
to separate owners settle each owner in sequence without nesting these locks.
Never await a Click flush from inside its own exclusive callback.

Give SessionCubit required narrow callbacks for `runClickVolumeExclusive` and
`currentDurableClickVolume`, following its existing composition pattern. Save
and Save As acquire both locks, reject unresolved recovery and capture the
accepted durable Click value after earlier writes drain. Add a required
`clickVolume` argument to `settingsFromLooper`; serialize that value into the
existing session field rather than reading the live/reapply cache. A save while
held therefore records Released while the audible held high stays live.
Performance/audio capture continues observing live audio.

Load uses the same lock order and the existing repository session apply path,
including its new Click receipt. Session recall does not overwrite startup
Click preferences. Preserve the existing session revision and user-edit checks
around startup restoration so delayed load cannot undo newer intent. Any stale
queued controller write is rejected after replacement.

Power off explicitly awaits the Click flush after controller work, including
ordinary touch writes outside the controller queue. A failure or recovery
outcome must keep halt pending with a visible retry; logging and continuing is
not sufficient. Dispose the control owner after its cleanup and before closing
the Click owner; the latter still waits for its own transaction queue.

## Implementation order and ownership

| Step | Paths and owner | Completion evidence |
| --- | --- | --- |
| 1. Confirmed scalar and callback receipt | Runtime: `packages/settings_repository/lib/src/settings_repository.dart`, `packages/looper_repository/lib/src/looper_repository.dart`, focused package tests | Delayed callback is not accepted early; exact absent/present rollback; timeout cancels late application |
| 2. Authoritative owner | Runtime: `lib/looper/cubit/tempo_cubit.dart`, shared `lib/looper/model/click_volume.dart`, `test/looper/cubit/tempo_cubit_test.dart` | Ordinary/controller serialization, stopped deferred intent, recovery and close/load fences |
| 3. Target and editors | Model/UI: `lib/control/binding/{control_value_target,control_value_resolver,expression_catalogue,binding_labels}.dart`, `lib/control/view/control_value_readout.dart`, existing MIDI/External endpoint views and tests; existing Click sliders import the shared scale | Strict identity, one Click destination, no-jump defaults, percent semantics and real Save/Cancel behavior |
| 4. Shared dispatch | Runtime: `lib/control/cubit/{control_cubit,control_midi}.dart`, new `test/control/click_dispatch_test.dart` | Both sources, full range, refusal, ordering, fresh-input and cleanup behavior through the real owner |
| 5. App/session/halt integration | Root: `lib/app/view/app.dart`, `lib/looper/view/looper_page.dart`, `lib/session/cubit/session_cubit.dart`, `lib/session/session_mapping.dart`, new `test/session/click_persistence_test.dart`, power-off integration tests | Released session snapshot, fenced recall, pending touch/controller writes delay halt, visible recovery |
| 6. Complete gate | Root and independent reviewers | Frozen intended-file hashes, aggregate tests/coverage/static, adversarial boundary tests, design reconciliation and current-head CI |

Steps 1–2 establish the owner before dispatch can be admitted. Model/UI may
prepare typed targets and editors against the agreed interface; the feature is
not complete while a selectable target lacks a confirmed owner. Root owns the
app/session/halt files to avoid concurrent edits. The shared model module has
one designated writer agreed before authoring.

## Success Criteria

Use the working Flutter SDK and native pump library described in
`docs/PROGRESS.md`. A missing native library must fail the native verification
command rather than silently skip it. The named new test files are part of the
implementation deliverable; these commands are planned gates, not results.

```success-criteria
GOAL: Performers control Click volume from touch, External pedals and MIDI with one confirmed owner, correct units and durable Released values.

SUCCESS CRITERIA:
- Exact Click identity round-trips; unity reads 0.5; both editors offer one Click destination, show 100% at unity, retain surface-specific endpoint defaults, and preserve draft Save/Cancel without an audible write. | verify: flutter test test/control/binding/control_value_target_test.dart test/control/binding/control_value_resolver_test.dart test/control/binding/expression_catalogue_test.dart test/control/mixer_catalogue_ui_test.dart
- Storage preserves an absent scalar and exact prior values on refusal; callback delay, stale same-value readback, timeout and lifetime replacement cannot produce false acceptance or a late gain change. | verify: (cd packages/settings_repository && flutter test test/settings_repository_test.dart) && (cd packages/looper_repository && flutter test test/looper_repository_test.dart) && flutter test test/looper/cubit/tempo_cubit_test.dart
- Real callback-backed MIDI and External writes span gain 0..2; authored Released values, newer ordinary/non-held writes, refused cleanup and reconnect obey the shared ownership contract. | verify: test -n "$SEGNO_ENGINE_LIB" && flutter test test/control/click_dispatch_test.dart
- Saving while held records Released without changing live high; session replacement rejects stale writes; pending ordinary and controller Click work delays halt and exposes recovery instead of silently continuing. | verify: test -n "$SEGNO_ENGINE_LIB" && flutter test test/session/click_persistence_test.dart test/appliance/power_off/power_off_gate_test.dart
- Click target selection, endpoint units and recovery notices fit the accepted design and accessible keyboard flow. | verify: manual 1. Review both mapping editors and existing Click controls against the saved design. 2. Exercise keyboard preview, Escape, Enter and Save. 3. Trigger a bounded failure and inspect retry behavior. 4. Save any intentional design departure and verify the on-disk design.

NON-GOALS:
- Click mode, tempo, count-in, loop defaults/per-track fields, backing and instruments.
- New native APIs, storage blobs, compatibility aliases or controller interpreters.
- Claiming physical device verification from desktop tests or CI.

VERIFICATION COMMAND: flutter test test/control/binding/control_value_target_test.dart test/control/binding/control_value_resolver_test.dart test/control/binding/expression_catalogue_test.dart test/control/mixer_catalogue_ui_test.dart && (cd packages/settings_repository && flutter test test/settings_repository_test.dart) && (cd packages/looper_repository && flutter test test/looper_repository_test.dart) && flutter test test/looper/cubit/tempo_cubit_test.dart && test -n "$SEGNO_ENGINE_LIB" && flutter test test/control/click_dispatch_test.dart test/session/click_persistence_test.dart test/appliance/power_off/power_off_gate_test.dart
```

After focused behavior passes, run the applicable complete application and
package suites, required coverage, explicit-path formatting, strict analyzer
and Bloc lint with a positive intended-file count. Review the frozen revision
independently, including refusal and timeout paths; rebind any later delta.
Published-head CI and the existing issue's autonomy/merge gate remain separate.

## Risks and references

The main risks are mistaking desired cache for native publication, accepting a
stale same-value snapshot, losing key absence during rollback, replaying held
high after a stop, and reversing the two-owner lock order. The tests above must
exercise those boundaries with delayed callbacks and a failing store. Existing
invocation-only mocks are insufficient evidence of admission.

References: `docs/handoff/segno-app/accepted-behavior.md` §4.6–11;
`docs/plan/2026-10-01-shared-mixer-controls.md`; current Click controls in
`lib/audio_setup/view/click_volume_section.dart` and
`lib/audio_setup/view/console/audio_routing_card.dart`; native command
publication in `packages/segno_engine/src/core/engine.c` and
`engine_process.c`; confirmed transaction pattern in
`lib/app/mix_settings_coordinator.dart`. The known preexisting live-owner
session publication issue remains tracked separately for M5; this slice must
not claim that broader transition is repaired by Click-specific fencing.
