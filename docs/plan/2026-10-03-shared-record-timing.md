# Shared Record timing (M3.15)

Issue #1026. Builds on shared Record length, PR #1097 at
`8749688c51912f808c3f36d4eb5bca665ede3ade`. Native Codex execution is authorized;
merge/deployment remain human-gated. Two writers and two test processes maximum.

## Product boundary and settled behavior

Nine targets: Loop defaults plus fixed Tracks 1–8. Choices, in accepted order: Immediately, Loop start, bar, half, quarter, eighth, sixteenth. Finite normalized values choose `round(6 * clamp(v,0,1))`; relative step1/6. Existing RecordTiming enum supplies those values. Explicit Immediately remains Custom; only null resets a track to inheritance. All modes, including Multi, keep independent track timing. Only capture (recording/overdubbing) disables the accepted timing edit; do not copy the Multi length lock or invent a permanent armed-state lock.

Use default affects only timing, invalidates prior claims for that address, and retains source contact/latch/siblings. Default changes affect inheritors; Custom tracks retain their settings. Quantized waiting requests remain owned by their original tracks. Updating a musical division reschedules the affected pending request on the existing grid. Choosing effective Immediately cancels the affected quantized request, not unrelated Sound or Band-section requests. Stop/repeating the corresponding request retains the accepted cancellation behavior. The first defining recording has no existing grid and keeps its current immediate/count-in/Sound policy. Existing recorded seconds, sample content, loop spans and history do not change.

These requirements come from accepted-behavior §2.2/2.4 and the accepted executable mapping catalogue. The dated recording-timing proposal is historical context; its explicitly superseded primary-speed limitations are not reintroduced. Tempo, Hear click, Count-in, signature, defaultMultiple, Follow/Pitch and Fade stay outside this slice.

The new target keys are `defaultRecordTiming` and `trackRecordTiming` index0..7. Freeze these and the pure port together before the model writer starts. Endpoints show choice labels, not normalized percentages. External button new endpoints=current/current; expression/MIDI=0/1. Add/Save emits no audio command. Repair and Escape preserve authored endpoints exactly.

## Chosen native design: one bounded timing-vector command

Replace the four split low-level setters with one typed native operation. Existing splitting is insufficient: global gate is mutated on the control thread, division is queued, snapshot division is a control mirror, and gate-off cancellation discards a failed DISARM enqueue. Reversing an enum after a failure cannot recreate a canceled request.

Proposed C input (fixed POD, copied by value into the existing command union):

```c
typedef struct le_record_timing_settings {
  int32_t default_timing;       /* RecordTiming code 0..6 */
  int32_t remembered_division; /* GridDivision code 0..5 */
  int32_t track_timing[LE_MAX_TRACKS]; /* -1 inherit, else 0..6 */
  uint32_t edit_mask; /* bit0 default; bit1..8 addressed track intentions */
} le_record_timing_settings;
int32_t le_engine_set_record_timing_settings(
    le_engine* engine, const le_record_timing_settings* settings);
```

The vector is necessary for one startup/session restore and default/inheritor consistency; the edit mask describes which ordinary/controller addresses own the intentional change, including a same-value write. It is not a generic parameter framework. Regular requests cannot change a value outside that mask. Full startup/session replay uses all nine bits. Derive the affected native-track mask from explicit addressed tracks plus tracks inheriting an addressed default; preserve Custom siblings. Any global remembered-division change is part of the default bit. Reject malformed vectors, extra mask bits, and a non-Immediately default whose remembered division disagrees with that choice. Track Immediately maps to explicit gate-off/division-off; inherit maps both to inherit.

### Producer admission

1. Validate handle/configuration, every scalar and mask, and one vector already pending. Check effective native capture state before posting, using the existing effective-state/queued-intent conventions. A captured track anywhere refuses the edit. Waiting quantized/Sound/Band requests alone do not refuse it.
2. Post exactly one command with one ring admission. A full ring changes no timing state, control arm ownership, or pending callback image. Do not call `le_cancel_arm` or post a separate DISARM as part of this transaction.
3. Keep the current applied state intact until callback acceptance. Record the command's existing posted sequence as the timing pending-publication fence, in the same spirit as `lane_growth_command` (commands.c:1343 and `le_prepare_routing`). No new lock, sleep, unbounded scan, or callback allocation.

### Callback acceptance

1. Process the vector in FIFO order. Validate all fields and **callback-owned** capture state again before any field or arm mutation. A preceding Record that actually starts recording/overdubbing, or a previously armed capture that fired in an earlier callback, makes the vector refuse unchanged. A preceding Record that only arms a waiting action remains allowed: the timing vector may reschedule or cancel that affected quantized arm. This closes the awaited-storage/admission race.
2. Apply all default/track timing fields together within this single command. Move the native applied gate ownership to atomic published fields (or derive gates from atomic timing enum codes) so the control producer only reads accepted state; it must not continue to write a desired plain gate.
3. For each affected track, if the new effective gate is off and that track's callback pending request is quantized trigger0, perform the existing DISARM callback cleanup inline: clear its pending image revision, pending capture shadow, pending_record, pending_trigger, and published pending flag. No fallible extra queue operation exists. Leave trigger1 Sound and trigger2 section requests intact, and leave unaffected tracks untouched. Do not write the producer-owned `armed[]` from the callback. Its existing spent-arm synchronization reads the cleared pending flag before the next corresponding action; test that path explicitly.
4. Publish the vector's success or refusal receipt as described below. Changing a division only updates the future boundary calculation; it does not finalize a take or resize content. Capture is never stopped by an ordinary/refused edit.

### Record admission while the vector is pending

A new native Record/Overdub acquisition must not compute its gate against the old applied vector while an earlier timing command is queued. Use the timing command's existing end-of-block publication fence to return `LE_ERR_NOT_READY` for **new acquisition/preparation** until publication. This is a bounded internal admission guard, like the existing lane-growth guard, not a new player setting or an input replay queue. Do not prepare layers/history before this check. Preserve active-capture finish/punch-out and the existing same-owner repeated-request cancellation path; Stop and explicit cancel are always available. Put shared classification/admission at both public Record entrypoints, before image FX preparation, as specified in the v2 mechanics below. Keep final execution checks and cleanup for a state change after preflight. Root/native technical review must verify all control-side record entrypoints reach this check. Do not solve ordering by silently accepting an input and replaying it later.

This guard is the smallest local consequence of making timing truly callback-applied. Changing all recording to callback-side allocation/decision logic would be a much larger and unacceptable redesign.

## True readback and receipt

Existing `EngineSnapshot.quantizeDiv` comes from `engine->quantize_div` (engine_snapshot.c:342–345), and the gate/track gate come from plain producer fields. Those are desired mirrors today. Change these existing snapshot fields to reflect the applied callback-owned atomics; keep their public domain meaning, remove the stale mirror comments/fields and audit each caller. Track division must likewise reflect the callback-applied vector. `RecordTiming` can continue to be reconstructed from these raw fields; the application has no reason to read native private state.

Add only a narrow timing receipt to the native/public snapshot:

- monotonically wrapping even committed `record_timing_revision` (zero is the coherent initialization; odd values are private in-progress publication);
- `record_timing_result` (`LE_OK` or the typed refusal result) for that revision.

Assign the next even revision when the single producer successfully admits the command, carry it in the named payload, and use the bounded coherent publication protocol below to publish its result with the actual vector after command processing. A rejected command advances the receipt revision while retaining prior applied values. The repository permits only one timing transaction in flight, captures the preceding revision/lifetime, and waits for this request's next revision plus the existing `commandsSettled` end-of-block boundary. It then compares the exact accepted vector to the candidate on success or prior vector on refusal. Do not infer success from drained queue, from old mirror equality, or from equal candidate/prior values.

The receipt makes same-value capture refusal observable without speculative timing heuristics. If capture starts later in the same block **after** an accepted timing edit, the successful receipt still describes a valid edit before capture; do not retrospectively misreport it as refused. If capture preceded the command, the receipt is a refusal. An impossible success/readback mismatch is uncertainty, not a normal validation refusal.

The native pending guard uses command publication, not this result field. The repository result wait is bounded and autonomous for startup/reconnect as well as explicit edits. Reset receipt counters with engine generation; pair them with the repository lifetime. There is no global receipt/event framework or new polling API.

## V2 mechanics: close the independent review gaps

This section corrects two assumptions: independent timing atomics alone do not guarantee a coherent snapshot, and guarding only `le_record_impl` does not precede all preparation. It incorporates the independent technical review without changing the accepted player behavior.

### Shared early acquisition classification

Current `le_engine_record_with_image` prepares FX recipes at engine_commands.c:1577, then enters `le_record_impl`. Therefore a guard inside that implementation is too late.

Extract one narrow internal preflight used by **both** public Record entrypoints. It validates the handle/configuration/channel/image, performs the same required event drain before reading effective state, and classifies the requested action from current effective track state plus the existing arm owner/trigger and current accepted recording policy. The classification is `new acquisition`, `active finish/punch-out`, `owned repeated-request cancellation`, or refusal. It must preserve the existing Sound-versus-quantized precedence and foreign-trigger rejection; do not simplify any armed flag into permission to cancel somebody else's action. Classification itself does not prepare/admit FX, write arm state, allocate capture/history/shadows, or enqueue commands.

If the timing publication fence is outstanding, refuse **new acquisition** before `le_fx_prepare_capture`, `record_fx_prepared`, recipe admission, layer/shadow allocation, history edits or arm mutation. Allowed finish/cancel operations still proceed. Then use the existing image preparation/execution pipeline. Recheck the required effective-state conditions at execution because callback state can change after preflight; retain `le_fx_recipe_abandon` for failures after legitimately admitted preparation. Do not claim that early classification freezes the callback or remove the current execution validations. Factor the decision used by both paths so the image and plain entrypoints cannot disagree; no new general action framework is needed.

The setter's callback capture rule distinguishes these FIFO cases explicitly:

- Record/ARM posted before timing but still waiting: allow the vector; reschedule or scoped-cancel the trigger0 arm as requested.
- Record actually starts capture before timing executes: refuse the vector without timing/arm mutation.
- A waiting arm fires in a preceding callback while the owner awaited storage: refuse at callback when the vector arrives.
- Timing admitted before a new Record attempt: the new acquisition gets NOT_READY until publication; no preparation or delayed input replay. Existing Stop/owned cancel/active finish remain available.

### One timing tuple with bounded publication/read

A coherent tuple comprises default timing code, remembered division, all8 explicit timing codes (including -1 inherit), and timing result/revision. All timing snapshot fields must be derived from one such tuple. The old pattern of reading each track then the global gate/division independently is removed for this family.

Use the proposed receipt revision itself as a **bounded sequence protocol**, not another generic lock or reader loop. Initialize an even revision0 and a coherent native control-thread cached tuple when the engine is configured. Each admitted timing command is assigned the next even revision (+2, wrapping, reserving odd for publication). Permit only one timing vector in flight, as already required. At callback mutation/publication start, mark the sequence odd; apply or refuse the vector, record its result, then publish the assigned even sequence at the callback's end-of-block publication boundary. Refusal still publishes a complete prior vector with a new result/revision. An active callback may use the newly applied timing for that block; the control snapshot sees the old completed tuple until publication completes.

The control snapshot helper makes **one attempt**:

1. Read the timing sequence.
2. If it is even, copy the entire fixed timing tuple into a local candidate, then read the sequence again.
3. Accept/update the control-thread cache only when both sequence reads are equal and even. Otherwise use the previous complete cached tuple, including its previous receipt revision/result.
4. Copy that one chosen tuple to the public snapshot. No loop, sleeping, callback wait, mutex, dynamic allocation or unbounded retry exists. The existing next poll is the retry.

For a simple provable C memory-order contract, use sequentially consistent atomic stores/loads for the sequence **and the published timing tuple fields** in this narrow path. A reader cannot then observe a new field in the SC order bracketed by equal old sequence reads. Do not substitute plain fields or relaxed tuple loads merely because the sequence itself is acquire/release; that requires a separate memory-model proof. The bounded <=8-track field cost occurs on timing edits and render-rate snapshot reads, not per audio sample. Existing DSP reads may retain their normal atomic load policy; all timing writes participating in publication follow this contract. Configure/reset seeds the cache only while quiescent and resets its lifetime.

The cache is native control-thread owned under the existing sole control-thread API contract. It holds last **applied and coherently observed** state; it is not a desired-value mirror or a success fallback. Returning its old receipt keeps an outstanding owner transaction pending, including timeout behavior. Owner readiness/acceptance does not advance until the expected new even revision and matching vector/result arrive through the ordinary publication barrier. Initialization creates a valid known initial tuple, not a last-known value from a previous engine generation. Expose neither an odd revision nor fields from an interrupted copy as confirmed.

Have both `le_engine_get_snapshot` and standalone `le_engine_get_track` use this family-specific coherent read helper. Full snapshots use a single chosen tuple to populate every track timing field plus global fields/result, rather than calling the helper once per track. Standalone track calls may observe a different complete revision on separate invocations, which is fine for standalone consumers; combining those calls into one application timing snapshot is not fine.

### Close the Dart multi-call snapshot gap

`NativeAudioEngine.snapshot()` currently calls `le_engine_get_snapshot`, then `le_engine_get_track` for every track because this FFI path does not index a native struct array. Therefore even individually coherent C entrypoints could still produce mixed revisions in one Dart EngineSnapshot.

Append `int32_t record_timing_overrides[LE_MAX_TRACKS]` to the **full** public `le_snapshot`, populated from its one chosen tuple alongside global timing fields and receipt. A primitive integer array is already used/read successfully elsewhere in this FFI surface. This is the minimal bridge; no extra query function or second snapshot fetch is needed. Dart captures these codes from that same `_snapshotPtr` and uses them to supply/replace each TrackSnapshot's timing override fields, deriving gate/division from each exact code. It must not take timing from the subsequent per-track `_trackPtr` reads. Global timing and receipt likewise come from the original full snapshot. Keep unrelated track/lane reads unchanged. Audit `EngineSnapshot.fromNative` and `TrackSnapshot.fromNative` docs/callers to make the one-tuple guarantee explicit rather than assuming the constructor's later track list is timing-coherent.

### Required discriminating red cases

- Pending timing vector then `le_engine_record_with_image`: a deterministic native test hook/counter demonstrates zero FX preparation/admission, unchanged history/layers/shadows, no new arm, and NOT_READY. The plain entrypoint must behave the same. Deliberately moving the guard back inside `le_record_impl` must fail this test.
- An owned pending-arm second request can still cancel while timing publication is pending; a foreign trigger cannot. An existing capture can finish. Preserve rejected prepared-recipe cleanup if effective state changes after the early preflight.
- Queue only ARM before the vector and prove allowed reschedule/cancel. Queue actual RECORD before the vector and prove capture refusal with exact prior vector/arm metadata. These are separate tests, not one broad “earlier Record refuses” expectation.
- Pause a test-instrumented writer after marking odd and after changing the first track/default field, then call the snapshot helper: it must return the complete cached old tuple and old receipt. After even publication, it must return the complete new tuple/result. Also pause a reader between its field copy and second revision read: the candidate must be discarded if the writer committed meanwhile. No mixed fields may be reported under either old or new even revision.
- Force timing to commit between full `get_snapshot` and the first/later `get_track` inside the Dart snapshot fixture. The returned EngineSnapshot's entire timing vector must still equal the original full tuple. Without the flat-array override, this test must fail. An independent native/concurrent stress probe supplements these deterministic event orderings; it does not replace them.
- Initialization/reconfigure has no prior-generation cached tuple; refused/same-vector commits still advance to a coherent even receipt; malformed or interrupted copy cannot produce false readiness. Test wrap with equality semantics and only one in-flight vector.

Native test hooks are compile-time test instrumentation like the existing `le_test_record_image_staged` hook, not production flags or a new public API. Preserve existing `a_commands_published` end-of-block release/`commandsSettled` acquire, named POD payloads and C++ shim discipline. The new sequence protocol is limited to this vector and is not a replacement for whole-engine snapshot architecture.

## Required C/FFI surface, explicitly budgeted

Runtime/native writer owns changes to:

- `segno_engine_api.h`: the one fixed timing input/function, two appended snapshot receipt fields, and the eight-int coherent timing override array; remove obsolete split timing-setting exports after callers are converted.
- `lockfree_ring.h`: one named timing-vector payload (including receipt revision), no packed bits beyond the explicit edit mask.
- `engine_private.h` and `engine.c` initialization/reset: callback-applied atomic timing state, one posted timing command/revision tracker, receipt fields, removal of obsolete producer mirrors.
- `engine_commands.c`: strict vector producer and new-record pending guard; delete split timing producers. Do not globally rewrite unrelated cancel-arm callers.
- `engine_process.c`: all-or-none callback capture check, vector apply, scoped inline pending cleanup, success/refusal receipt publication.
- `engine_snapshot.c`: one bounded coherent timing tuple read and last-coherent control-thread cache, true applied readback and receipt publication; no desired mirror masquerading as receipt.
- `audio_engine.dart`, `native_audio_engine.dart`, `engine_snapshot.dart`, generated bindings: one `setRecordTimingSettings` method matching the vector (explicit default, remembered division, overrides and edit mask), snapshot fields, same-tuple track timing reconstruction despite separate track/lane reads, and real FFI marshalling on the control thread. No allocations in the callback. Update production fake engine and test fixtures coherently; do not keep obsolete API wrappers only to avoid fixture work.
- Native tests and all old low-level timing callers: migrate to the coherent operation. A test-only builder for vectors is acceptable; no production compatibility facade.

Run ffigen because the header changes, explicit formatting, symbol parity, standard/ASAN/telemetry-off native gates and the C++ shim. Freeze a new separately named library plus source/binary hashes for root/adversary; do not overwrite M3.14's immutable library. This is a real narrow ABI change, unlike pretending the current setter pair already has a receipt.

## Repository and one application owner

`RecordTimingCubit` remains the sole default/track owner. Proposed pure port shape follows the existing family contracts, with explicit naming:

- `RecordTimingSnapshot? recordTimingSnapshot` and `durableRecordTimingSnapshot`: default RecordTiming, remembered GridDivision, explicit track overrides, captureLocked; `effectiveTiming(address)`/`canEdit(address)`.
- `recordTimingLifetime`, per-address `recordTimingRevision(address)`, and `ordinaryRecordTimingChanges` where a track value may be null (Use default).
- Ordinary `setTiming`, `setTrackTiming({required channel, required timing})`, and the two live ordinary gate-toggle consumers' `setEnabled` all go through this same serial queue. Preserve the existing methods as actual product entrypoints, not bypass aliases.
- Controller `setControllerTiming(address, timing, {releasedTiming, required lifetime, required revision})` returns `RecordTimingOutcome` with applied/rejected/superseded/recoveryRequired. No new claim or revision until confirmed acceptance.
- `runRecordTimingExclusive`, `flushRecordTiming`, `recoverRecordTiming`, a failure stream and idempotent close completion.

Make readiness explicit in an immutable state that includes the accepted default and track snapshot. Initial Immediately is provisional until startup validation completes; ready Immediately must emit a distinct state. Load staging occurs outside the serial transaction callback before entering it; no self-awaiting load/flush/recovery inside the queue.

Repository owns the one pending native vector/receipt and distinct live and durable restart intents. It exposes `setRecordTimingSettings`, `settleRecordTimingSettings`, applied snapshot/readiness, failures/recovery and lifetime fencing using existing repository patterns. Owner queue reads the latest confirmed snapshot at operation execution, not a caller-captured stale full vector; it changes only intended addresses. While stopped it can accept validated deferred intent without a fabricated native receipt, then actual start must replay/check it. Startup and applySession each send one final vector (including all8 inherit entries), with no earlier global/default/clear passes that partially publish readiness. Autonomous replay settles with a deadline and informs the owner even if no later edit occurs.

## Exact durable storage and arbitration

Keep existing keys: `looper.quantize`, `tempo.quantize_div`, and `track_record_timing.0` through `.7`. No envelope migration. Strictly read raw typed values, not helpers that silently map malformed enum to null or defaults. Defaults are false/off only for absent valid scalars. For explicit codes accept only bool/integer ranges; reject strings/floats/out-of-range. Read all ten scalar checkpoints (two default plus eight tracks) before any startup application. An invalid final track cannot leave a partially applied default.

A timing transaction stages and verifies durable Settings intent **before** native mutation. On native known refusal restore the exact checkpoint, including absence, and do not publish owner/claim priority. On store failure before native admission, restore any partially changed scalars and leave native arms untouched. Failed compensation installs recovery; a normal successfully compensated rejection does not permanently poison future flush. Preserve the default's remembered division while Immediately; a Held musical division with Released Immediately must project the previously durable remembered division, not leak the temporary Held division into restart/toggle behavior. A Released quantized choice owns its own division. Include remembered division in live and durable snapshots/checkpoints explicitly so this is testable.

Existing Control MIDI/External ledgers arbitrate held versus ordinary values. Reuse them with typed timing values and per-address revision; no separate timing interpreter. Author-supplied Released values are durable, ordinary writes supersede prior held cleanup only after acceptance, and non-held toggles stay durable on retirement. Track Use default emits null and supersedes only that target's claims while retaining source contacts/latches. A held cleanup refused during capture remains owed and durable Released intent remains saved; on capture→idle, the existing serialized retirement retry wakes and attempts cleanup once. A failed attempt must not spin on meter ticks.

During capture an unrelated fresh timing acquisition is rejected without changing state, Settings, revision or obligations. Save uses the known durable Released snapshot under the owner gate, even while audible held timing remains unchanged because cleanup is locked. Unknown receipt/storage recovery blocks Save visibly; it must not automatically stop capture. Shutdown waits pending transactions and owed cleanup; capture/refusal leaves the appliance on with existing Retry/Keep playing behavior.

## Lifetime, timeout, session and shutdown

Lifetime is `(sessionRevision, mixGeneration)`. Check it before storage mutation, before native admission and after every await; validate captured address revision both in owner and post-acceptance Control bookkeeping. Ordinary reset/new write can supersede queued stale acquisition for only its address. Old operation failures cannot publish a toast/outcome or replay payload into a replacement. If restoring a global Settings checkpoint is still owed, recovery repairs only that obligation and adopts current replacement state; it must not stop the new rig or reapply its old timing.

Known native refusal with exact prior vector is ordinary rejected. Wrong receipt/readback, unresolved timeout, or failed compensation is recoveryRequired. Keep timing admission/readiness blocked and the bounded obligation available to Retry. Do not stop a running capture to tidy up an uncertainty. If the callback later settles, observe the result but do not silently retry a refused user edit. When safe, explicit recovery reconciles the exact durable checkpoint/native state or a replacement's authoritative vector. No late accepted command may enter a new engine lifetime; restart must remain blocked while unresolved old pending native work could be replayed. Recovery after a failed initial load must revalidate all stored scalars before readiness.

App explicitly owns RecordTimingCubit, subscribes to failures and awaits it after Control cleanup. Session lock order: Mixer → Click → Playback → Record length → Record timing. Session mapping receives durable timing/default-memory/override fields under this gate. Never call its queueing flush/recover from inside that same exclusive callback, nor await old Control cleanup that reacquires it during recall. Session replacement installs one final authoritative vector, then publishes readiness; does not persist recalled preferences globally.

Root startup removes the old post-start per-track restore and independently-created default load race. It stages strict timing checkpoints before start, installs the stopped replay intent, starts and awaits timing receipt. LooperBloc routes its track timing event to the owner and tracks it in PersistFlush. Both audio setup quantize toggles and LoopLengthPage consume confirmed owner state and surface capture lock/readiness. Shutdown retains synchronous controller cutoff, recovers then retries owed releases only on explicit Retry, and includes final timing flush. Keep playing reopens future input without replaying old holds.

## Implementation order and independent gates

1. Root reviews this concrete native scope and exact port/key names; technical reviewer checks control/callback ordering. Independent adversary freezes oracle first. Do not begin with temporary UI-only targets.
2. Runtime writer publishes pure port, then native vector/receipt and focused native red/green cases. Freeze source/new library before other processes consume it. Next repository, strict scalar storage, owner and Control dispatch.
3. Model writer consumes the frozen port: seven-choice targets/readouts/endpoints, capture-lock picker semantics, current/current versus full-range defaults, repair/Escape preservation. No policy copied into a second owner.
4. After writer transfer, coordinator handles App/bootstrap/Session/Bloc/audio setup/LoopLength composition, locales/Pen, broad constructor fixtures and disposal. Keep writer file ownership disjoint and two test processes maximum.
5. Focused proof: literal normalized boundaries; all8 and explicit Immediately/inherit; same-value native capture refusal; queue-full no mutation; pending Record acquisition guard with safe Stop/cancel; armed division reschedule, gate-off cancellation and untouched Sound/Band/siblings; callback withheld/wrong result/timeout; each scalar fault; initial load/readiness/reconnect; held/ordinary/reset/lifetime; Session Save and real shutdown. Native sample/frame expectations must be literal and independently computed, not produced by the production timing helper.
6. Root final aggregate coverage/static/Bloc/native plus cross-author source review and independent adversarial runtime matrix bind the exact current candidate. Preserve first failures and distinguish author-only rendering, published-head CI, human merge and physical timing/hardware proof.

## Technical review and execution gate

The independent technical review covered VGV conventions, simplicity and scope.
It closed early image preparation, coherent publication including the Dart
multi-call snapshot, and waiting-arm versus capture distinctions. Keep standalone
`le_engine_get_track` side-effect free: it may use the prior coherent tuple on an
interrupted copy, but does not update the control-thread cache. The full
`le_engine_get_snapshot` may refresh it. No product decision is reopened.

The coordinator approves this bounded technical direction. Before implementation,
the independent adversary freezes literal behavioral expectations from accepted
requirements. Final source and native execution still must prove this design.
No native-only compatibility stage or unrelated timing framework is authorized.

## Success Criteria

```success-criteria
GOAL: Touch, MIDI and External controls share confirmed recording timing without partial settings, lost queued requests or temporary Held values leaking into Save/restart.

SUCCESS CRITERIA:
- Nine fixed targets expose seven accepted choices, explicit Immediately versus inheritance, musical readouts and exact Cancel | verify: flutter test test/control/binding test/control/midi_controls_page_test.dart test/control/external_pedal_page_test.dart test/control/external_expression_page_test.dart
- One native vector preserves queued-arm semantics and rejects capture/full queues without mutation; image capture preparation is fenced before side effects | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Complete native and Dart timing snapshots never mix revisions; same-vector refusals have explicit receipts; test instrumentation demonstrates failure sensitivity | verify: manual Frozen independent native/FFI oracle and negative controls, with source/library hashes.
- Strict storage checkpoints, rollback, remembered division and lifetime/recovery retain exact durable intent | verify: flutter test test/looper/cubit/record_timing_cubit_test.dart && (cd packages/settings_repository && flutter test) && (cd packages/looper_repository && flutter test)
- Held/Released arbitration, ordinary resets, capture-owed cleanup, Session Save and shutdown use one owner | verify: flutter test test/control test/session test/app test/looper
- Native settings and mapping pages preserve accepted layout and do not display unconfirmed choices as applied | verify: manual Inspect native renders/actual app; save matching Pen references and verify the on-disk hash.

NON-GOALS:
- Tempo, Click, Count-in, signature, defaultMultiple, Follow/Pitch, Fade, full live-Control Session Load, deployment or physical hardware proof.

VERIFICATION COMMAND: flutter test test/control test/session test/app test/looper && bash packages/segno_engine/src/test/run_native_tests.sh
```

Use the repository's working SDK. The writer may refine focused test filenames
while preserving every behavior above. Run the unchanged coverage/static/Bloc
workflow, FFI regeneration/symbol parity, standard/ASAN/telemetry-off native and
C++ shim checks. Keep independent source review separate from author renders,
published-head CI and human merge approval. Never overwrite a frozen library.

## Frozen integration names

The pure port is `lib/looper/model/record_timing.dart`: `RecordTimingAddress`,
`RecordTimingSnapshot`, `RecordTimingLifetime`, `RecordTimingStatus`,
`RecordTimingOutcome` and `RecordTimingControl`. `RecordTimingState` carries
`defaultTiming`, `rememberedDivision`, immutable `trackOverrides`,
`captureLocked` and `recordTimingReady`. Missing readiness uses a null public
snapshot; it must not appear as a confirmed Immediately setting.

Settings exposes `RecordTimingCheckpoint` with nullable `quantize` and
`division`, plus immutable integer-code `trackOverrides` (absence omitted,
explicit zero retained). `readRecordTimingCheckpoint` validates all ten scalars;
`restoreRecordTimingCheckpoint` restores/verifies only differing scalars under
the existing storage queue. The repository's complete startup/session call is
`setRecordTimingSettings(defaultTiming:, rememberedDivision:, trackOverrides:)`,
followed by `settleRecordTimingSettings`. Existing receipt defaults are 10 ms and
50 attempts. Held controller writes use that same pending transaction with a
separate durable intent; no second interpreter is added.
