# M3.16: shared Hear click

2026-10-03. Issue #1026, stacked after M3.15 / PR #1098 at `3025840dd212a86ee1b23c21b6980f0ac4866e20`. The coordinator approved this implementation direction after separate technical review resolved both findings. Implementation remains subject to the independent behavioral oracle and all existing human merge gates.

## Scope and accepted behavior

One global Hear click target, proposed strict key `{"ctl":"clickMode"}`, label Hear click, in the existing Loop controls destination (the accepted catalogue leaves this target's destination at Loop). Do not move it to the Click source destination merely because Click volume lives there. User order is `[Off, First recording, Recording, Play & record]`; native codes are `[0,2,1,3]`. Conversion is `choices[round(clamp(n,0,1)*3)]`; reject non-finite input before conversion. Reverse conversion uses the table index/3, and relative step is 1/3. Use named choices in endpoint UI, preserving authored raw endpoints until an actual committed edit.

Missing `tempo.click_mode` means First recording. This is established by owner catalogue line26 and prototype loopSettings seed line676, not a new decision. Explicit stored native code0 and an explicit session Off remain Off. Keep a fresh native engine's zero-initialized Off safety state; direct reconfigure preserves its existing actual mode while resetting transient receipt and reservation state. Application startup stages First and waits for its receipt. No migration, compatibility key, forced write on reading absence, or route-mask change.

Lock actual recording/overdubbing; armed/count-in alone does not acquire this lock. The accepted prototype also locks its frozen-capture recovery state (`frozenCapturePending`, a recovery list, not every armed start). The current native runtime has no failed take-finalization journal state capable of producing that prototype condition; the precise trace and retained integration obligation are specified below. Do not substitute device recovery, ordinary undo history, layer-tail drainage or every armed start for it. Multi and external clock add no Hear click restriction. Do not cancel/reschedule arms or alter count-in, tempo, volume, routing or DSP.

Existing native gate semantics are retained: Off silences click including count-in; every non-Off mode sounds during count-in; First sounds only during the defining first recording while no master loop length exists; Recording sounds in recording/overdub; Play & record also sounds in playback. A loaded existing loop followed by another first layer is not a new defining first recording.

## Required corrections to the draft

1. A callback refusal leaves the actual mode unchanged **but publishes a new completion revision and refused result**. Keeping the receipt unchanged makes same-value capture refusal indistinguishable from a stuck request.
2. Separate mode initialization/readiness from volume and the miscellaneous Tempo restore. Current `_restore` reads all settings serially, maps malformed mode to Off and publishes after enqueue; it cannot remain the mode authority. A volume or count-in read failure must not falsely initialize mode or permanently prevent its independent Retry.
3. Use the existing Tempo Click serial queue for both owned Click fields and one session gate. Rename `runClickVolumeExclusive` to `runClickExclusive` at all callers, with no compatibility alias. Do not introduce a second nested Click queue or call load/flush/queued setters inside an already-held gate.
4. Structural target identity survives unavailable owner/recovery. New acquisitions refuse; ending operations keep their matching-lifetime owed release. A healthy compensated ordinary rejection must not poison owner flush, while retained controller cleanup must block Control's retiring flush (`ControlCleanupPending`). These are the final M3.15 F1/F3 lessons, not optional optimizations.

## Narrow interface agreement

Create `lib/looper/model/click_mode.dart`, using the existing repository `ClickMode` enum rather than a duplicate enum:

```dart
typedef ClickModeLifetime = ({int sessionRevision, int mixGeneration});
// Equatable immutable snapshot: mode and captureLocked, with canEdit.
final class ClickModeSnapshot { /* ClickMode mode; bool captureLocked; */ }
enum ClickModeStatus { applied, rejected, superseded, recoveryRequired }
// Same small outcome shape as neighboring ports: status, deferred,
// EngineResult?, Object?, isOk; no generic transaction hierarchy.
abstract interface class ClickModeControl {
  ClickModeSnapshot? get clickModeSnapshot;
  ClickMode get durableClickMode;
  ClickModeLifetime get clickModeLifetime;
  int get clickModeRevision;
  Stream<ClickMode> get ordinaryClickModeChanges;
  Future<ClickModeOutcome> setClickMode(ClickMode mode);
  Future<ClickModeOutcome> setControllerClickMode(
    ClickMode mode, {
    required ClickModeLifetime lifetime,
    required int revision,
    ClickMode? releasedMode,
  });
}
```

TempoCubit implements this and its existing ClickVolumeControl. Add `clickModeReady` to TempoSettings equality/copyWith; retain the last accepted mode field while unavailable, but nullable snapshot and presentation readiness must not advertise editable state. Mode readiness must visibly transition even when accepted value is Off. Keep volume's existing `clickReady` meaning; no unrelated rename needed. Required ControlCubit injection `clickModeControl`, no production ownerless fallback.

Tempo-specific APIs: `loadClickMode()`, `flushClickMode()`, `recoverClickMode()`, `Stream<ClickModeOutcome> clickModeFailures`, and `runClickExclusive<T>(Future<T> Function())`. `load()` starts/awaits independently guarded mode and volume/remaining restoration; public mode edits await only mode initialization **before** entering the shared queue. Session gate awaits initialization outside the queue and verifies both Click fields inside it. Close waits the shared queue then closes both ordinary/failure streams. App continues awaiting Control close before Tempo close.

Settings keeps the existing scalar key, with `Future<int?> readClickModeCheckpoint()` and `Future<void> restoreClickModeCheckpoint(int? code)`. Read strict nullable integer0..3; preserve absence and malformed source. Write/remove plus readback verification follows current serialized scalar helpers. Retain normal `loadClickMode`/`saveClickMode` only if real callers need their distinct convenience semantics; route them through strict helpers and First default, otherwise remove unused APIs. Never decode persisted invalid input with permissive `ClickMode.fromCode`.

Repository retains `EngineResult setClickMode(ClickMode mode, {ClickMode? releasedMode})`, plus `settleClickMode({Duration pollInterval=10ms,int attempts=50})`, `clickModeSettled`, `clickModeRecoveryRequired`, `clickModeCaptureLocked`, `clickModeRestartIntent`, `clickModeFailures`, `recoverClickMode()`. Naming parallels existing scalar receipt seams; do not create a generic settings dispatcher. Stopped acceptance is explicit deferred intent; running acceptance requires callback proof. Separate confirmed live, durable restart, and pending/recovery intent; `sessionTransport.clickMode` is accepted live, not the candidate queued mode.

## Native receipt: scalar, not another vector

Current native `a_click_mode` is actual callback-owned atomic readback (`engine_snapshot.c:383`), but `LE_CMD_SET_CLICK_MODE` has no revision/result and clamps in callback. Keep existing exported setter and enum mapping. Extend its command payload with the mode plus request revision; reject invalid raw command values as well as wrapper arguments. Enforce one in-flight mode request. Queue-full must release its admission reservation without altering actual mode or accepted receipt.

Producer performs an early capture check; callback checks recording/overdub immediately before mutation. Click-before-Record may apply; Record-before-Click must refuse. Same-mode requests still pass through callback and acquire a new completion receipt. Do not add a Record admission fence or plugin preparation change for this family: unlike Record timing, Hear click does not change capture classification.

Add `click_mode_revision` and `click_mode_result` to native snapshot and corresponding Dart fields. Publish result and completed revision at the callback publication boundary before `a_commands_published` release, following the existing command-boundary pattern. The repository must acquire `commandsSettled` BEFORE synchronously calling `snapshot()`, with no await, callback into application code, stream emission, timer scheduling or next mode admission between the check and tuple read. It then compares exact expected revision, result and actual mode before clearing its pending record. Raw `le_engine_post_command(...LE_CMD_SET_CLICK_MODE...)` is explicitly rejected with LE_ERR_INVALID; it must not enqueue a competing request without a revision. All native mode writes use the typed setter and its one-in-flight reservation on the existing sole control-thread producer. After callback publication, the repository still holds its pending record through the synchronous sample; only then can the shared Tempo queue admit another mode edit. Therefore mode/result are stable after that acquired boundary until the next allowed request. This avoids a new multi-field sequence-lock cache for a scalar: neither the UI nor repository treats an arbitrary mid-callback snapshot as an accepted mode. Document this precondition and test withheld publication and raw-post rejection. The SPSC engine contract already excludes arbitrary concurrent command producers; do not claim this makes unsupported multi-producer access safe. Restart and applySession must use the same repository pending/settle path, never direct engine setters or a cleared pending record before sampling. A standalone raw snapshot may show actual scalar progress before completion; owner readiness must not.

Known callback refusal + exact prior actual mode restores exact Settings checkpoint and returns rejected, without stopping audio or changing priority. Missing/wrong receipt is uncertainty, not proof of rejection. Start an autonomous bounded repository deadline for replay as well as user writes (same10ms/50 policy, deterministic test seam). Surface recovery without needing a later owner call. Recovery never stops an actual capture or a replacement lifetime; block new mode admissions and unsafe Save/halt, retain desired Released/restart mode, retry only when safe. For uncertainty while idle, existing bounded owner recovery may stop the same generation and restore prior durable intent. No callback allocation, I/O, locks or unbounded spin; no new capture DSP.

C/API modifications: `segno_engine_api.h` command payload/snapshot docs, `engine_private.h` request/receipt state, `engine_commands.c`, `engine_process.c`, `engine_snapshot.c`, configure reset in `engine.c`; AudioEngine/native/mock/snapshot types and fakes; regenerate ffigen/bindings. Include snapshot equality/hash and human-paced field whitelist. Zero-sized callback still completes receipt. Test revision wrap and queue-full reservation recovery. Produce a new immutable library after standard/ASAN/telemetry-off/C++ shim gates; never overwrite M3.15's frozen library.

## Transaction, lifetime and integration ordering

Initialization stages strict mode checkpoint before changing mode. Null maps to First intent without persisting2. Ordinary/controller edits serialize store checkpoint → verified durable candidate (Released when held) → native enqueue → receipt → accepted state/ledger. On known refusal restore exact prior scalar/absence. Storage rollback uncertainty blocks admissions even if no local recovery object could be constructed. Old completion cannot emit failure or restore old native mode into a newer session/device; global scalar repair uncertainty remains visible but never adopts old payload into the replacement. Generation-only replacement during initial reads retries current initialization; authoritative session replacement wins over old settings reads.

Bootstrap adds strict mode read before start, stages mode while stopped, checks it, and awaits post-start mode receipt. Remove the raw restart cascade's unchecked `..setClickMode` and replace with the pending replay path, without intermediate ready publication. Repository `applySession` sets the final explicit session mode once and awaits settlement before reporting success; no default-then-final mode writes. The default change applies only to absence in startup settings, not to a valid session Off. Session schema/wire format need not change.

Session ordering stays Mixer → Click → Playback → Record length → Record timing. `SessionCubit` replaces gate name with `runClickExclusive` and receives `currentDurableClickMode`; `settingsFromLooper` takes required `ClickMode clickMode` and writes it instead of `transport.clickMode`. Save/Save As while a healthy Held is audible records Released. No live performance audio capture projection: rendered/performance audio uses live mode. Pending/recovery blocks capture of an unconfirmed settings image. Do not await outgoing Control cleanup that reacquires Click while holding Click; replacement lifecycle fencing retires old claims.

Control routes both MIDI and External through the same owner and accepted-only ledger. Capture lifetime + ordinary revision before queuing; verify again in owner and after acceptance before bookkeeping. Accepted ordinary same-value writes supersede old claims; refused writes do not. Relative/pickup use the normalized choice table, never native enum integers. New button endpoints use accepted current/current; new MIDI/expression ranges stay0/1; Add/Save alone sends no mode write. Repair/Cancel/Escape preserves raw endpoints. Unknown/stale saved target remains repairable.

Capture-time release or source retirement remains owed with durable Released intent retained; do not update live mode, drop holder, auto-Stop or report cleanup success. Extend the existing eligibility tuple to this owner's ready/settled/capture state. On capture→idle transition, enqueue one bounded MIDI/External cleanup retry; after a failure await a new eligibility transition or explicit flush/Retry, not every meter tick. Unrelated mapping contacts/latches remain intact.

Shutdown keeps synchronous Control ingress retirement first, awaits both input queues and owed-cleanup result, then owner flushes. Explicit Retry may recover mode then must perform the existing second retiring Control flush; reaching goodbye requires no owed cleanup. Keep Playing reopens admission without replaying old holds. Healthy exact compensated ordinary refusal does not poison mode flush; uninitialized owner, genuine pending/recovery, or Control debt still blocks halt. Do not let a Click-volume-only toast Retry accidentally flush/recover unrelated fields.

## Five input routes and observable proof

- Touch Loop Tempo choice and keyboard/encoder activation share `TempoCubit.setClickMode`; show last accepted selection, readiness and capture/recovery reason. Preserve existing choice order/geometry. No optimistic selection on enqueue.
- MIDI, External button, External expression each prove a real owner write with literal enum result; saved mapping construction alone proves zero engine commands. All three use one typed target, resolver and existing endpoint controls.
- Literal mapping vectors0,1/3,2/3,1 → native0,2,1,3; nearest boundaries around1/6,1/2,5/6; two-way relative single choice; malformed key/extra fields/non-finite input refuse.
- Null checkpoint→confirmed First, explicit0→Off, invalid4/wrong type preserved with persistent Retry; delayed initialization, independent volume failure and default-value readiness emission. Exact absent rollback after mutating-and-throwing store.
- Queue-full, callback Record-before-mode capture refusal, same-value refusal, mode-before-Record accepted, held-release capture refusal and safe-idle retry, native wrong/missing receipt, autonomous restart timeout, generation/session replacement at each await. No native stop on capture refusal, no stale replacement stop or old replay.
- Held mode live with Released in Settings, actual Save/Save As file and restart; newer ordinary value survives older release; rejected ordinary preserves obligation. Explicit Off session round trip. Real App shutdown initial owed failure, Retry cleanup, Keep Playing and post-flush ingress cutoff.
- Routed native PCM with explicit output mask, known tempo and enough frames: each mode's literal audibility/silence in empty idle, count-in, defining recording, existing-loop recording, overdub, playback and stopped states. No-output default stays silent. Count-in remains non-Off override. No desktop result is hardware acoustic proof.

## Exclusive file ownership and gate sequence

Runtime/native writer: pure click_mode port; TempoCubit; ControlCubit/control_midi (required port and shared-ledger dispatch); LooperRepository; SettingsRepository; native/API/FFI/engine seams above; focused owner/dispatch/receipt/checkpoint/native tests and directly affected fakes. Model/UI writer after port freeze: control target/resolver/catalogue/labels/readout/endpoints, Loop Tempo choice readiness and dedicated fixtures/goldens. Root composition after a writer slot transfers: App/bootstrap, SessionCubit/session_mapping, locale messages, required constructor fixtures, actual App/Session/startup tests and workflow bindings. Explicitly coordinate shared helpers, do not bulk-edit another writer's fixtures.

Before edits root approves interface/native direction and adversary freezes independent oracle. Then pure port → native receipt+real readback red/green → immutable library → repository/owner+Control → surface/root composition. Writer source freeze precedes independent execution and aggregate. Keep first failures; final gates include native variants/shim, package/app coverage, strict analyzer/format/positive Bloc, real-native CI route, independent adversary and cross-author review, intentional Pen save/binding where UI changes. No native parser fallback, broad refactor or other control family ships in this slice.

## Decisions/blockers

No unresolved user-facing product decision was found. First absent default, choice order, capture lock and destination follow accepted executable sources; count-in remains a separate follow-on. Root must approve the engineering choices above (port/key names, shared Click gate and scalar receipt boundary) before writers. A potential earlier-draft contradiction is resolved: refusal advances completion but not mode. Existing raw snapshot support is sufficient for actual scalar value, **not** for command acceptance without the new revision/result. This is a complete vertical slice; target-only shipping would be incomplete.


## v2 resolution: receipt single-writer proof

Source `lockfree_ring.h:4–5` defines one control-thread producer; `engine.c:1301–1306` acquires `a_commands_published`. Callback releases that field after snapshot publication in `engine_process.c:6318`. Current raw entry `engine.c:1257–1278` bypasses typed Click mode admission, so v2 explicitly adds its rejection, before generic `le_push_cmd`. Keep defensive callback enum validation even though production raw admission is closed. No compatibility alias or second exported mutation path.

Implement `_trySettleClickMode` as one synchronous repository operation: locate current pending request → if commandsSettled is false return pending → snapshot now → check lifetime plus expected completion revision/result/actual mode → settle or classify recovery → only afterward clear pending and publish accepted state. Checking settlement after reading, checking twice around the read without reservation, or emitting before sampling are all insufficient. A later await can occur only once the read and classification are complete. Configure/session replacement is control-thread-owned and cannot interleave this synchronous step; its generation must still be checked for async work outside it.

Required red probes: pause callback after mode/result mutation but before completion publication; settlement remains pending and owner shows prior accepted state. Finish callback, then exact receipt confirms. Attempt raw Click-mode post both during and after a typed request; both return invalid, produce no queued command, and leave receipt/mode unchanged. Typed request while the first is outstanding refuses; the next request after settlement succeeds. Same-mode Record-before-mode refuses with a fresh refused receipt, not an apparent successful equality. A test hook may trigger a competing attempt but cannot grant an unsupported second control-thread producer.

## v2 resolution: frozen capture reachability and owner boundary

The prototype's exact state is not generic stopped audio. `stage-transport-study.js:30–35` catches a failed `editState.publish(changes,journal,clock)`. `finish` at146–152 can fail this publication or compatibility checks without deleting its take. The scheduled event loop at172 and `clockLost` at195 call `freezeTake` on that failure. `freezeTake` at192 sets `take.frozenAt`, removes the pending action, publishes capture idle and retains the take for Stop-to-retry or Undo. `snapshot` at284 reports only these retained takes as `frozenRecoveries`. `fx-ux-prototype.html:772` tests that list, and lines678/681 add it to the capture lock. This is accepted future behavior, not an optional UI convention.

There is currently no matching producer or predicate in the engine/repository/session runtime:

- Native `finalize_master` (`engine_process.c:787`) and `finalize_new_track` (`:1221`, final state publication `:1323`) finalize existing memory and publish track state; neither calls SessionRepository or a fallible file/journal publisher. Admission/preparation can refuse before a take begins, but that does not create a stopped retained failed-finalization take. Native configure's memory reservation and existing finalization behavior do not implement the prototype's durable journal transaction.
- `SessionRepository.save` (`session_repository.dart:439–483`) first waits commands/layers, detaches already-settled audio, then writes WAV/manifest files. A failure goes to SessionCubit's action failure envelope (`session_cubit.dart:430–458`); it does not convert a recording into a retained frozen take or own a Stop-to-finalize retry. `SessionRepository._capture` (`:626–638`) excludes actual recording/overdub tracks.
- `AudioRecoveryCubit` (`audio_recovery_cubit.dart:9–20,78–106`) watches for a never-connected pinned device. Repository reconnect is another device lifecycle. Neither represents failed capture finalization. Blocking Hear click on these would wrongly forbid ordinary deferred settings while stopped.
- `LaneSnapshot.recoverable` (`engine_snapshot.dart:475–482`) means ordinary live/undo/redo content, so it cannot be the lock: doing so would disable Hear click whenever recorded audio exists.
- `a_layer_in_flight`/`TrackSnapshot.layerInFlight` cover normal overdub fade/drain and delayed history retirement (`engine_process.c:1469–1570`, `engine_snapshot.c:86`). Event-ring pressure can temporarily retain a shadow and continue writing/merge passes; later punch-out drainage is already bounded and retried by the engine, not a failed journal retained for explicit Stop/Undo. It is correctly a Session stable-export guard (`session_repository.dart:825–838`), not the prototype frozen-capture flag. Likewise clearRestorePending is a clear/undo history transition, not an unsuccessful save of the active take.
- The prototype clock-loss trigger cannot provide a hidden route today: current `le_engine_set_clock_mode` (`engine_commands.c:2582`) rejects Receive, whose follower is not implemented. Do not add clock-loss/follower behavior in this slice.

Consequently the exact current `LooperRepository.clickModeCaptureLocked` implementation is the real snapshot recording/overdub predicate, owned by the repository, checked at owner admission and native callback. Mode storage/native uncertainty remains a separate explicit unready/recovery gate. The UI consumes the owner snapshot; it must never manufacture a frozen flag or derive authority from visible banners. Armed/count-in remains eligible. Existing Session save failure, stopped retained undo content and ordinary device absence remain eligible if mode initialization itself is coherent.

This is a scoped reachability conclusion, not a waiver of the accepted frozen-capture lock or a claim that journal recovery is implemented. When the capture/journal owner gains the accepted stopped pending-finalization state, that owner must expose it authoritatively and extend this predicate plus the corresponding engine admission guard before that new path ships. No placeholder callback, always-false interface or UI-only fake state belongs in M3.16. Root must retain this dependency in the later capture/journal delivery ledger; if a hidden native failed-finalization producer is discovered before freeze, it must be mapped here rather than ignored.

Observable M3.16 distinctions: real recording and overdub refuse; a genuinely armed/count-in track permits mode; a stopped track with ordinary undo content permits it; a Session file-save failure does not impersonate frozen capture; mode's own uncertainty still blocks. The frozen-capture-specific oracle is explicitly deferred with its absent producer, not claimed as a testable implemented state. The existing accepted prototype remains the future producer's behavioral oracle.


## Approval and delivery dependency

The coordinator accepts the narrow scalar receipt protocol, shared Click owner gate and four-choice mapping. The separate technical recheck found no remaining blocker in this direction. This is plan approval, not implementation or hardware proof.

The later capture/journal milestone must expose its stopped failed-finalization obligation to shared-control admission, including Hear click, before that new capture path ships. This obligation is retained in the delivery checkpoint. M3.16 must not invent an always-false recovery seam or claim that absent producer is implemented.
