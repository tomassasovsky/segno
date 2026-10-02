<!-- cspell:ignore readset -->
# M3.12 — shared Decay, defaults and fixed Tracks 1–8

Issue #1026. Approved implementation contract for M3.12, following shared Click volume PR #1094. This plan covers default and fixed-track decay only. The existing full campaign authorization and human merge gate remain. No implementation result is claimed by this plan.

## Product contract

Offer Overdub decay in the shared MIDI, External button and expression catalogue for Loop defaults and fixed Tracks 1–8. A mapping stores the fixed channel, never the current selection or a display name. Normalized endpoints remain 0..1; physical decay is integer `round(100 * normalized)` percent; relative step is .01 normalized, one percentage point. Read/pickup uses the accepted effective percent divided by 100. Literal 0/.5/1 means decay 0/50/100, native feedback 1/.5/0. Display 0 as “Off · Keep layers” where space allows and nonzero values as percent decay, using existing decay language.

Default and per-track decay operate in every mode, including during overdub. Ordinary playback remains unchanged. Native ramping and layer recovery remain the existing engine behavior. This is decay of previous audio during overdub, not a volume fader.

An explicit track value of 0 remains Custom even when the default is 0. An inherited track has no map entry. A numeric controller endpoint always authors an explicit override, including a Released endpoint of 0. It does not restore the pre-press inheritance marker. “Use default” remains a separate ordinary edit which removes only that track's decay override; it is not a numeric endpoint or new mapped action. A later accepted Use default wins over older held cleanup.

Keep surface defaults: a newly added External button starts both endpoints at the current accepted effective value; expression/MIDI retain their existing full 0..1 ranges. Add/Save alone changes no audio. Repairs retain authored endpoints until reviewed. No compatibility keys, migration, selected-track fallback or UI-only target.

## Verified current authority

- Accepted behavior §2.2 and §2.5 requires independent field inheritance, explicit equal values staying Custom, `1 − decay/100`, replacement including silence at 100%, no decay on ordinary playback, and preserved layer recovery. §4.11 requires shared stable targets and repairable missing assignments. The prototype's default and fixed-track decay rows use integer percent with a one-percent step (accepted prototype parameter catalogue).
- `lib/looper/cubit/playback_options_cubit.dart:99–105` currently applies the default through the repository, publishes state, then saves one scalar. There is no controller result or durable temporary projection.
- `lib/looper/bloc/looper_bloc.dart:749–758` currently owns per-track application and starts its scalar save without awaiting it. This must join the same decay owner; it must not remain a second persistence path.
- `lib/looper/view/loop_settings/loop_playback_page.dart:86–96` sends default edits to PlaybackOptionsCubit and fixed-track edits to LooperBloc. Existing preview/commit/Escape and fixed-scope protections should remain. Retain the event, but route its handler to the shared owner.
- Repository setters at `packages/looper_repository/lib/src/looper_repository.dart:4546–4570,6390–6397` call native while running, then update remembered integer default/override maps and publish the snapshot. While stopped they retain deferred intent. Null per-track input removes the override; zero inserts it. `feedbackOfDecay` already provides the physical conversion.
- `packages/segno_engine/lib/src/native_audio_engine.dart:1521–1554` calls the existing C functions and encodes inherited feedback as -1. `engine_commands.c:2714–2739` validates engine/channel, stores atomic feedback, then logs the control change. This is immediate control-side publication, not command-ring admission. There is no feedback readback field in the existing snapshot; repository maps are application-owned intent. Do not label them callback receipts or add artificial command-settlement waits.
- `engine_process.c:5734–5737` reads default feedback each block; `:5208–5226` resolves track override/inherit and ramps the coefficient; `:5387–5391` applies it only while overdubbing before summing new input. Existing native tests cover decay, override/inherit and mid-pass ramping (`test_engine_core.c:3908,6933,6980`). No native API/FFI change is required by this slice.
- `SettingsRepository` keys are `looper.overdub_decay` and `track_overdub_decay.<channel>` (`:1742–1763`). Existing saves are direct and unverified; absent default differs from stored 0 for exact rollback, and absent track differs from explicit 0 for behavior.
- `session_mapping.dart:114,118` currently captures live default/map, so it would leak a temporary held value. Session schema and `SessionRig` already store both fields; no format revision is needed.
- `audio_bootstrap.dart:228–230,321–324` restores decay before the app owner exists. Repository restart at `:1970,2038–2043` replays current live caches and ignores decay replay results. Merely adding session projection would leave reconnect able to replay a held high.

## Settled interface for parallel writers

Use the existing PlaybackOptionsCubit as the application-owned Decay transaction owner. Do not create another generic settings coordinator or move Once/timing into this slice. Publish one small pure port in `lib/looper/model/overdub_decay.dart` before consumers compile. Agreed API:

```dart
// Value equality; defaults has no channel, track channels are 0..7.
final class DecayAddress {
  const DecayAddress.defaults();
  const DecayAddress.track(int channel);
  int? get channel;
}
typedef DecayLifetime = ({int sessionRevision, int mixGeneration});
final class DecaySnapshot {
  final int defaultPercent;
  final Map<int, int> trackOverrides; // immutable; membership is meaningful
  int effectivePercent(DecayAddress address);
}
enum DecayStatus { applied, rejected, superseded, recoveryRequired }
// DecayOutcome carries status, deferred, optional EngineResult/error; isOk.
abstract interface class DecayControl {
  DecaySnapshot? get decaySnapshot; // null only before initialized/unavailable
  DecaySnapshot get durableDecaySnapshot;
  DecayLifetime get decayLifetime;
  Stream<({DecayAddress address, int? percent})> get ordinaryDecayChanges;
  Future<DecayOutcome> setControllerDecay(
    DecayAddress address,
    int percent, {
    required DecayLifetime lifetime,
    int? releasedPercent,
  });
}
```

`releasedPercent: null` means no temporary projection; it does not mean inherit. Controller writes never carry an inherited endpoint. Ordinary track reset uses the owner's existing-domain method `setTrackOverdubDecay({required int channel, required int? percent})`. Change `setOverdubDecay(int percent)` to return `Future<DecayOutcome>` without renaming it; existing callers can continue awaiting/ignoring its returned outcome. LooperBloc receives the required `DecayControl`/owner ordinary-write seam and awaits the track owner call instead of applying/saving directly. Add the ordinary method to the narrow port if LooperBloc receives that port; do not inject a concrete cubit into another bloc merely for this call.

PlaybackOptionsCubit additionally supplies:

```dart
Future<DecayOutcome> flushDecay();
Future<DecayOutcome> recoverDecay();
Future<T> runDecayExclusive<T>(Future<T> Function() operation);
Stream<DecayOutcome> get decayFailures;
```

Retain accepted readout during recoverable failure while refusing new acquisitions; changing it to null must not cause Control to drop an owed release. A `decayReady` field and confirmed override map in PlaybackOptions state give UI an observable initialization/track-change transition, even when the default remains 0. Once fields and behavior remain intact. Owner close is idempotent and awaits its pending writes; application disposal closes Control before PlaybackOptions.

Single-target transactions are sufficient: a mapping's distinct targets already have independent admission and missing-sibling handling. Do not introduce a cross-domain atomic batch requirement. The owner queue serializes targets and session capture; Control commits each target's holder only after its own accepted outcome.

## Transaction and persistence rules

1. Validate integer domain/address and availability before any mutation. Capture the source/device/session lifetime before Control queues work; validate it again inside the owner. Loading must finish before entering the owner queue, avoiding a startup self-wait.
2. Read the exact nullable scalar checkpoint through SettingsRepository's existing serialized writer. Save and read back the intended durable value: the authored Released percent for a temporary hold, otherwise the requested percent. Update only this address's key.
3. After the storage await, check lifetime/closing again. If still owned, call the repository setter synchronously. Its successful atomic publication (or stopped deferred cache acceptance) is the decay receipt. There is no callback wait or timeout. Publish the confirmed live value, durable projection and ordinary event only after success. Do not insert another asynchronous boundary between native success and owner commit.
4. If storage rejects/mutates then throws, or native rejects, restore and verify the exact checkpoint (including absence), retaining the previous accepted value/projection and older cleanup obligations. No priority is granted to refused input. A failed rollback records recovery owed and blocks further decay mutation/session capture/halt until explicit Retry. Scalar recovery must repair only the scalar it owns, not replace the whole settings store.
5. Introduce narrow SettingsRepository APIs `readDecayCheckpoint({required int? channel})` and `restoreDecayCheckpoint({required int? channel, required int? percent})`; null channel denotes default, null percent denotes absent scalar. Upgrade existing `saveOverdubDecay`/`saveTrackOverdubDecay` to serialized, verified writes and make loads wait the writer. These lower-layer methods use primitive domain values, never app mapping types.
6. Keep the old transaction's lifetime with a recovery record. An old failure must never restore old feedback into, stop, or relabel itself as the current replacement rig. Explicit recovery may repair its exact scalar checkpoint, then retire the obsolete obligation and adopt the replacement's accepted decay state. Recheck lifetime after every recovery await. Do not copy the former Click stale-recovery bug.
7. `flushDecay` waits admitted ordinary/controller writes and returns unresolved failure; `recoverDecay` explicitly confirms a coherent accepted owner when no repair remains, instead of returning a sticky historical rejection forever. Session/halt callers must not receive a fictitious success while startup is incomplete.

### Restart and initialization are part of the slice

Repository needs distinct durable restart decay state, using a small existing-domain value (default integer plus explicit override map); keep it separate from live held values. On accepted controller hold, update restart intent to authored Released; on accepted non-held/ordinary edit, update only that target to its accepted durable value. Failed edits never move restart intent. Add one narrow repository setter for this projection and a getter/snapshot for adoption; no control-target imports. Apply/session replacement must set both live and restart state from the recalled rig. While stopped, controller accepted holds may remain live deferred intent, but a later engine start uses durable Released and invalidates the old source lifetime.

On reconnect, replay the durable default and explicit overrides, including explicit 0, and publish the completed coherent projection. Check the existing atomic native return values; if decay replay fails, `startEngine` returns refusal/stops that failed start and the owner surfaces unavailable/recovery rather than advertising accepted replay. No queued command receipt, native recovery flag, feedback getter or speculative native API is needed. Recovering a failed start uses normal engine-start ownership; stale owner work must not stop a newer start.

Bootstrap remains a pre-owner initialization phase, not a second runtime writer. Preserve its requirement that saved defaults/overrides reach the first overdub. Reuse verified scalar reads and check decay native outcomes; restore all fixed slots without relying on a recorded take. PlaybackOptions initialization must restore/adopt default plus all eight override memberships, fenced against session replacement/user intent. Avoid applying defaults after a session has already replaced startup values. Startup failure must remain visible and block successful flush.

## Shared Control and catalogue integration

Proposed canonical targets are `DefaultDecayTarget` → `{"ctl":"overdubDecay"}` and `TrackDecayTarget(channel)` → `{"ctl":"trackOverdubDecay","index":channel}`. Parse only exact supported shape/integer coordinates; do not alias prototype paths. Both share percent conversion and .01 relative step through a decay-target family, separate from MixValueTarget and ClickVolumeTarget. Fixed identity is channel 0..7. Empty tracks remain valid settings destinations; labels can change without identity changing. A genuinely missing live owner remains unavailable/repairable and is never silently retargeted.

Extend resolver/catalogue to receive the same nullable accepted `DecaySnapshot` supplied by the application-owned PlaybackOptionsCubit. All MIDI/External authoring paths must use it, including zero. A track read resolves `override ?? default` while keeping membership in the owner snapshot for persistence. Pickup and relative deltas use the same quantized normalized law; tiny inputs rounding to the same percent must not flood storage, but an accepted explicit equal-value intent must still retire older ownership and create its override.

Reuse the current MIDI/External value ledger for default and track keys. Extend ordinary-event handling, origin capture, admission result and Released projection to Decay. No second interpreter, mapping store, timer or hidden global projection registry. Latest accepted non-held intent becomes durable even when older sources remain physically held or later retire. Default intent only supersedes the default target; it does not clear explicit track ownership. Track Use default is an ordinary intent for that track, removes its projection/holder priority on acceptance, and later inherited effective reads follow the current default. Refused reset leaves older obligations intact.

Catalogue placement: default Decay needs a genuine Loop controls destination; fixed-track Decay belongs in its existing recorded-track destination under Playback. The current expression picker reuses the FX-only three-kind enum. Introduce an expression-catalogue kind with the three existing groups plus Loop controls, with an explicit conversion for FX destinations; update only shared parameter picker consumers. Do not add a non-FX case to the global FX editor's enum or disguise the default as All tracks Mixer gain. Preserve existing IDs/order and add the one default destination, then one Decay row per fixed track. This is the only new picker grouping in the slice and needs design-source review.

## Composition, session and shutdown

- App creates one PlaybackOptionsCubit before Control/LooperBloc and provides it by value, as with the existing Tempo owner. Remove the old second provider construction. Subscribe its failures to the existing visible settings-recovery flow with explicit Retry; avoid duplicate notices.
- SessionCubit gets required `runDecayExclusive` and `currentDurableDecay` callbacks. Extend the one lock order to **Mixer → Click → Decay**. No owner calls an outer lock. All save/load/new-session paths use it; entering the gate waits startup before enqueuing work. Capture `settingsFromLooper(..., required DecaySnapshot decay)` from the durable owner, replacing only default/track decay reads. Both fields must come from the same immutable snapshot. Audio/performance capture still observes actual live audio.
- App shutdown synchronously cuts off new controls as today, awaits retirement, then on explicit Retry recovers owners and retries owed retirement. Include `flushDecay` before goodbye/halt. Failure shows Retry/Keep playing and cannot halt; Keep playing permits fresh input without replaying old contacts. Shutdown during a pending scalar write waits it. Disposal awaits Control cleanup, then PlaybackOptions/Tempo before their repositories are disposed.
- Session schema, export formats, native FFI and generated bindings stay unchanged. Existing session-load live-track intermediate-state defect documented in M3.10 is not claimed fixed here; a persistence test must not conceal it as a Decay success.

## Disjoint writer partitions and dependency order

1. Runtime writer: first create `lib/looper/model/overdub_decay.dart` and announce stable signatures. Own `lib/looper/cubit/playback_options_cubit.dart`, `lib/control/cubit/{control_cubit,control_midi}.dart`, `packages/looper_repository/lib/src/looper_repository.dart`, `packages/settings_repository/lib/src/settings_repository.dart`; narrowly associated transaction/repository/scalar/Control tests. Repository restart projection belongs here. Do not modify Click or Mixer behavior beyond the required exhaustive target cases/injection.
2. Model/UI writer after port agreement: own `lib/control/binding/{control_value_target,control_value_resolver,expression_catalogue,binding_labels}.dart`, `lib/control/view/control_value_readout.dart`, shared `expression_target_picker.dart`, External/MIDI page and endpoint consumers, their model/widget tests. Root assigns locale files to this writer or retains them explicitly; no simultaneous generated-localization writes. Keep loop-playback ordinary UI behavior intact.
3. Root integration writer after one writer slot is free: own `lib/app/{audio_bootstrap,app_toasts}.dart`, `lib/app/view/app.dart`, `lib/looper/bloc/looper_bloc.dart` and event forwarding, `lib/looper/view/looper_page.dart`, `lib/session/{session_mapping,cubit/session_cubit}.dart`, relevant composition/bootstrap/session/shutdown fixtures, docs and `segno-ui.pen`. Coordinate all constructor fixture edits before touching another writer's tests. Root also owns any loop-playback page caller adjustment needed by the finalized port.
4. Independent oracle: freeze literal vectors and inheritance/lifetime expectations before author tests; execute after product hashes freeze. Review cross-author source plus whole integration, then aggregate/static/native gates. Freeze source again after each repair; retain red attempts and sensitivity evidence. At most the authorized process slots, no aggregate while writers mutate its inputs.

## Observable acceptance and verification order

1. Model: exact canonical key round-trip; invalid coordinates/shapes refused; default versus Track 1–8 distinct; rename/selection does not retarget. Literal normalized0/.5/1 yields percent0/50/100; .005 rounds to1%; relative+.01 moves one percent. Non-finite input is rejected before a store/native call.
2. Owner/scalar: default absence and explicit0 checkpoints round-trip exactly; track null/0 remain different; saved mutation-then-throw, readback mismatch, failed rollback and explicit retry produce honest outcomes. Pending storage cannot publish acceptance. Native refusal cannot create a holder or destroy older projection. Startup0 emits ready; session replacement during load wins. No receipt-timeout wait is invented for atomic setters.
3. Inheritance: with default40, inherited Track1 reads40; assigning Track1=0 makes it Custom and remains0 after default80 and reload. Use default returns80 and affects no other field. HeldTrack1 high75/Released0 beginning from inherit finishes as explicit0. Ordinary Use default during that hold wins over later release. Default held and track-held combinations save their correct independent memberships.
4. Sources: test MIDI continuous/relative/pickup/momentary/toggle and External expression/button through real Control dispatch. Two-source orderings, ordinary-before and ordinary-during hold, same-value intent, refused release, non-held takeover plus source retirement, missing sibling, fresh reconnect input, and target lifetime invalidation retain established ledger semantics. Confirm no mapping Add/Save mutates audio.
5. Native: existing C feedback/override/ramp tests stay green; an independent real-engine application harness verifies mapped0/50/100 reaches actual overdub samples, including silence replacement, playback unchanged and undo/layer recovery. Fakes prove failure ordering only; they do not prove audio DSP. Stop/restart while held uses Released state without replaying the hold. Session recall overrides old recovery payload.
6. Session/halt: save while held stores Released default/override membership, reload faithfully; performance capture stays live. Load/new session cannot race an admitted scalar write or receive an old release. Actual App halt waits a blocked decay write; refusal prevents goodbye/halt; Retry repairs and then retires owed cleanup; Keep playing allows a fresh press. New ingress after cutoff cannot begin another write.
7. UI: default and all eight fixed destinations available with one Decay row each, no duplicates; unavailable owner handled without accepting provisional0; all endpoints display decay percent and restore actual parent drafts on Escape; defaults per surface and repair preservation tested. Author-only screenshots/design source are separately identified from ordinary CI.

## Success Criteria

```success-criteria
GOAL: MIDI and External controls can change real default and fixed-track overdub decay with correct inheritance, durable Released values, and lifetime-safe failure recovery.

SUCCESS CRITERIA:
- Literal conversion, shared catalogue, owner transactions and real source dispatch preserve the rules above. | verify: flutter test test/control/binding/control_value_target_test.dart test/control/binding/control_value_resolver_test.dart test/control/binding/expression_catalogue_test.dart test/looper/cubit/decay_transaction_test.dart test/control/decay_dispatch_test.dart
- Session saves preserve explicit overrides and Released values; application shutdown waits/refuses/retries decay persistence safely. | verify: flutter test test/session/decay_persistence_test.dart test/app/view/app_test.dart
- Existing native decay DSP, inheritance and ramp behavior remains valid. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Labels, unavailable states, endpoint editing and the Loop controls destination match the reviewed design. | verify: manual inspect saved author renders and segno-ui.pen; verify fixed identity, 0/50/100 labels and repair endpoints

NON-GOALS:
- Loop/Once, record length/timing, Tempo/Hear click/Count-in, Fade, Follow/Pitch, Click pan, backing and instruments.
- A new session format, native feedback API, global settings framework or UI-only control.

VERIFICATION COMMAND: flutter test test/control/binding/control_value_target_test.dart test/control/binding/control_value_resolver_test.dart test/control/binding/expression_catalogue_test.dart test/looper/cubit/decay_transaction_test.dart test/control/decay_dispatch_test.dart && flutter test test/session/decay_persistence_test.dart test/app/view/app_test.dart && bash packages/segno_engine/src/test/run_native_tests.sh
```

Commands name planned new test files and are prospective, not executed. Before publication root must additionally run relevant package tests/coverage, the ordinary app aggregate and required coverage, explicit-file formatter, strict analyzer, actual-scope Bloc lint and whitespace checks per CI. Native sanitizer/telemetry variants apply if native code changes; this plan requires none. Independent oracle and complete current-head source review remain mandatory. A push invalidates the old head binding; remote CI must pass before readiness. Physical appliance audio/MIDI validation remains distinct from desktop/native test evidence.

## Remaining controls, separately tracked

Next numeric/discrete slices: Playback Loop/Once; record length with existing settlement; record timing with coherent gate/division; Tempo/Hear click/Count-in with proper native admission and coupled Sound/count-in persistence. Defer Follow/Pitch and Fade until actual playback/performance owners, Click pan until a real click-source stereo contract, backing until its session/audio owner, instruments until their voice owner. None is exposed speculatively by this slice.

## Decisions and limitations

No unknown native symbol, FFI change or missing decay DSP blocks this slice. The coordinator has settled the port/key names and ExpressionDestinationKind with the existing three bands plus loopControls, leaving the FX enum unchanged. Add the ordinary track setter to DecayControl exactly as specified. The correction below is required before implementation. The remaining engineering risk is transactional inheritance across restart/session replacement and exact scalar rollback, not the percent conversion. The source readset is recorded in `m312-decay-plan-readset.json`; source was not frozen by this planning task. This plan uses established in-repository atomic-control, serialized-store and shared-owner patterns rather than researching unrelated products or adding dependencies.


## Required inheritance and startup correction after technical review



`ControlCubit._onOrdinaryFxWrite` (`control_midi.dart:903–917`) records a numeric `(#ordinary, target)` holder. MIDI ending work and External release work choose the latest surviving numeric holder and call the target setter. If Track 1 Use default is translated to its effective default value, an old release will call `setControllerDecay(track1, effectivePercent)` and recreate a permanent explicit override. The audible value can look correct until the default changes. Comparing values cannot detect this: explicit 0 and inherited default 0 sound equal but are different accepted intent.

Therefore the accepted ordinary change stream must retain the proposed nullable `percent`. Never replace null with an effective numeric value on that stream.

## Minimal concrete algorithm

1. Track Use default enters the same Decay owner queue as numeric writes. It saves/removes and verifies exactly that track scalar, then applies repository `setTrackOverdubDecay(channel: n, percent: null)`. Only after acceptance does it remove the track from live, durable and restart override maps. Refusal preserves the prior maps and all prior source obligations.
2. At that commit point, increment a per-address ordinary/reset revision, then synchronously publish `(address: trackN, percent: null)` before completing the Future. Publish even if the map was already absent or the effective value remains 0. No global default change is emitted on behalf of the track.
3. Control handles this null event as **supersession of that target's older claims**, with no repository write and no numeric ordinary marker:
   - Drop its MIDI holder keys, target/released entries and queued cleanup memberships using the existing `_dropMidiHolder` path.
   - Remove its `_parameterHolders` entry, including old ordinary/retained numeric markers.
   - For each External input, remove this target from `_externalMixReleased` and `_externalNumericReleases`, and mark its old release invalidated in the existing target set. Extend the release-filter and accepted-acquisition branches to Decay. Keep the physical contact/gesture and unrelated controls intact.
   - In MidiMappingEngine, clear only matching parameter rows' `held`, `contributing` and `releasePending` claims. Preserve `contacts`, `latched`, other rows, and unrelated source decoding. The real release then updates the physical contact but emits no stale parameter cleanup. Remove retired mapping state only when it has no remaining claims.
4. Do not reuse `_invalidateValueTargets` unchanged: its tail resets all MIDI decoders and clears all expression raw samples, and its call to `invalidateTargets` deletes complete MIDI row state, including the logical toggle latch. A small `supersedeParameterClaims(Set<String> keys)` on the pure MIDI engine plus a target-local Control helper expresses exactly the accepted ordinary supersession. Keep topology invalidation behavior separate; do not change it for this slice. No second interpreter or new contact registry is needed.
5. A fresh accepted controller acquisition can create an explicit override again, clearing the External invalidation marker through the existing accepted-record path. A still-down momentary contact does not synthesize another press: it must release and press again. Preserve toggle logical state on ordinary supersession, so its next real press retains the existing toggle semantics. Expression movement remains a new explicit numeric intent; Add/Save and a default change do not synthesize movement.

## Fence already queued work and late acceptance

Clearing current maps alone does not cover an immutable proposal already prepared, nor an owner result whose Control continuation has not recorded its holder yet. Use one per-target owner revision, not a global ordinary generation that cancels unrelated controls.

Small addition to the approved port:

```dart
int decayRevision(DecayAddress address);
// Add to setControllerDecay's named arguments:
required int revision;
```

This revision is distinct from session/device `DecayLifetime`. It advances on accepted ordinary intent for that address (including same-value Use default). Capturing it for each target at source ingress/queue submission and passing it to the owner makes the supersession boundary explicit. Advancing on all accepted ordinary Decay edits is consistent and keeps the rule simple; source/controller writes do not advance it, so simultaneous held sources can still arbitrate normally.

- Owner checks `(lifetime, address revision)` before checkpoint/storage and after every asynchronous boundary. A queued old release rejected here does no new scalar/native write. If an already-started transaction was superseded after an await, use its existing rollback/superseded rules; ordinary owner writes serialize on the same queue.
- After an accepted owner result, Control checks the captured address revision again before `recordAccepted`, holder bookkeeping, and `MidiMappingEngine.settle` for that row. This prevents an earlier successful native write's delayed continuation from reinstalling a holder after Use default committed.
- Apply the check **per Decay row**, not as an early cancellation of an entire mixed-target proposal. A Track 1 reset must not discard a valid sibling Track 2/FX/Click action or release.
- Ordinary reset publication is synchronous. Thus the ordering is either controller accepted/recorded before reset and then retired, or reset wins the revision and the stale Control continuation cannot reinsert its claim. The owner serial queue ensures final live/durable/native state follows that same accepted order.

The revision lives in the owner because a Control-only counter cannot guard a request already waiting inside the owner queue before its storage mutation. The owner revision is a bounded nine-address map; no general generation framework or additional native flag is required.

## Inheritance after cleanup

With default 0 and Track 1 held at 75/Released 0:

1. Accepted Use default removes Track 1 membership and retires old target claims, even though the new effective value is 0.
2. A later default change to 40 changes inherited Track 1 to 40; it does not create a track ordinary numeric marker.
3. Releasing or retiring the old MIDI/External source performs no Track 1 setter and cannot restore 0 or insert a map entry. Durable session and boot settings still have no Track 1 key.
4. A new accepted press can create explicit 75, with authored durable Released 0; its later release leaves explicit 0. This is intentional and distinct from Use default.

The same sequence must work with two previously held sources, a refused old cleanup pending Retry, zero/default-equal values, a queued release behind a blocked owner write, and a delayed Control acceptance continuation. Unrelated targets and source contacts stay unchanged. A refused Use default must do none of the retirement/revision steps and the old accepted Released obligation remains retryable.

## Required narrow regressions

- MIDI and External: default0 → held75/Released0 → accepted Use default → default40 → old release/device retirement. Assert map absence and scalar absence throughout, effective/native feedback .6 at the end, no old release storage/native write.
- Repeat with explicit track0 before reset and with a reset whose effective numeric value is unchanged; membership, not value equality, determines the result.
- Two older held sources plus a refused cleanup: reset wins both, later cleanup retry cannot recreate either endpoint; fresh press still works.
- Stall a source request before owner admission, commit ordinary reset, resume: old request performs zero scalar writes. Separately delay Control's post-acceptance continuation across reset: it cannot recreate a holder or settle stale MIDI effects.
- Track1 reset in a mapping with Track2/Click sibling: only Track1 is superseded.
- Refuse the reset: no revision advance, no claims dropped; eventual old release still applies its authored endpoint.
- Preserve MIDI/External toggle state and physical contact edges; no decoder reset, phantom press or unrelated pickup reset is introduced.

This is a necessary refinement of the plan's generic ordinary-change paragraph, not an expansion into other inherited settings. The same rule may later be reused for other inherited fields only when those fields are implemented.


Initialization must validate all stored decay values before applying them, preserve explicit zero and absence for all eight fixed slots, and expose read/native refusal without reporting successful flush. Decay readiness is independent of unrelated Once initialization. The existing atomic setter success is the receipt; do not add callback polling. Stage internal freezes, but publish one complete vertical slice.
