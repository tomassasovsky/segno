# Independent M3.14 final source review

No unresolved actionable bug, architecture or test-quality finding remains in the reviewed production scope. This is a source-bound review against base `2cf6c3adfc19b0e229717fe4b6d1748267b0c17a`, including the untracked Record length port. It is not a merge-ready or exact-head CI claim.

Binding: `final-review-binding-v1.json`, SHA256 `2a3699532293506a3697553e57a14fbad62f8a461da97df549e29c13d68e95db`. All 29 changed production paths are included. A conservative 1,295-entry runtime/package/config/helper source read set is unchanged from the independent 44-case execution. Three subsequent UI-only changes are separated from that execution: C2's endpoint-cancel pair and the later ControlRowTile value-label layout correction. The binding snapshots 54 changed/new test files for provenance; it does not claim all 54 were executed by this reviewer.

The review used the project's AGENTS/build/tracking contract, the frozen independent oracle, VGV conventions role, architecture role and test-quality role. Expectations were frozen before author tests were read. No product, repository test, Git state or native library was modified; isolated private mutant copies are separate.

## Bug-focused conclusions and finding closure

**M314-C1 — closed.** A startup scalar read failure originally produced a brief rejected notice while leaving the memoized owner permanently unavailable through ordinary UI. Final `record_options_cubit.dart` reports `recoveryRequired` for initialization receipt failure and caught startup errors; `flushRecordLength` preserves the uninitialized outcome and `recoverRecordLength` stages/validates startup again. App's existing persistent Record length Retry action invokes that recovery without a shutdown detour. Malformed data stays stored and unavailable until corrected. The final owner hash is `df23c3c39c149c6389947545e31e0d2551970614c6c011e3d573b8a479295165`.

Root's actual App log `m314-length-root/startup-retry-app-v1.log` was read: both transient-read and malformed-value Retry cases pass. Its exact hash is in the final binding. Those are root-owned executions, not two additions to this reviewer's 44. The closure combines final source inspection with those concrete UI results.

**C2 — separately owned correction, source checked here.** The model/UI author reproduced and repaired repaired-target raw `.2/.8` being canonicalized on Escape. The final panel calls `onEndpointCancel` separately; the page restores the opening value with `preserveRaw: true`, while intentional numeric edits still canonicalize to bars. The real-page regression repairs Track volume to default Record length, edits heel, presses Escape, saves, and asserts exact `.2/.8` plus no length preview command. This reviewer read the correction and regression but did not discover or execute C2. Its author/root review remains separate.

**Late value-label layout.** `control_row_list.dart` additionally wraps the shown value in Flexible, one line and ellipsis; existing full semantics text and owner-lock activation gates remain intact. This does not touch native or owner behavior. Rendering proof belongs to the UI author; no new behavioral concern was found by source inspection.

**F1 — fixture-only.** The root Session fixture now processes actual frames and asserts capture ended before preset admission. This is distinct from the private harness's EngineConfig compile correction. Neither was treated as a product defect. Both historical failures/corrections remain described in execution evidence.

## Native and repository review

The C change is localized to `le_length_presets_check` in `engine_commands.c:2627`. It checks atomic recording/overdubbing state before vector/capacity mutation and is used by both vector admission/callback paths, including the same-mode case. It adds no callback allocation, I/O, mutex or new FFI symbol. Existing exported signatures and generated bindings remain unchanged. Direct native hostile-order tests exercise Record and Overdub before plain and same-mode vector changes using the new frozen library.

Repository admission and settlement are separate. `_settlePendingLengthSettings` requires the command fence, eight raw slots, exact mode, and no current capture before accepting intent and restart projection. Exact-prior refusal rolls back without stopping a healthy take; unexplained state or bounded silence blocks replay/requires recovery. Native acknowledgement remains inferred from raw state and fence rather than a unique command ID; the identical-vector history limitation is explicit in the oracle and execution report.

Restart state holds confirmed Released intent separately from live Held. Stop/session lifetime changes cancel or supersede pending work. The owner captures generation/session/revision before asynchronous persistence, checks again at admission/receipt, and keeps an exact scalar compensation obligation without replaying an old native vector into a replacement lifetime. The independent timeout, old-compensation and initial-read replacement cases passed.

## Architecture perspective

Layer violations found: **0 in the changed production scope**. Flutter presentation uses the existing Cubits/domain targets. Control receives a required pure RecordLengthControl port; the repository remains independent of Flutter presentation and scalar storage is mediated by SettingsRepository. No new data client import in presentation, dependency cycle, generic controller framework or compatibility layer was introduced.

RecordOptionsCubit is the single shared owner for ordinary length, mode and controller writes. It owns initialization, queue, per-address revisions, durable projection and compensation; Control owns accepted input-holder arbitration. These responsibilities remain distinct. Snapshot maps are copied/immutable at the public boundary; accepted state/events are published only after receipt. The domain port supports production injection and controlled tests and is not speculative abstraction.

Composition installs one owner, subscribes before loading, injects it into Control/LooperBloc, and keeps it alive until consumers drain. Owner close cancels subscriptions and awaits initialization/queue before closing streams. New timers live in the repository receipt lifecycle and are canceled on settle/fail/retire.

Session locks are consistently Mixer → Click → Playback → Record. Initialization is awaited before entering the Record gate; snapshot capture reads its durable state within the gate and does not await an owned setter/flush recursively. No lock-cycle or in-gate Control cleanup was found. Ordinary Bloc writes join the same owner; PersistFlush waits tracked work. App cuts controller ingress first, explicitly recovers on Retry, retries owed retirement, then checks final owner confirmation before halt. Capture refusal does not inject a Stop command. The inherited full live-Control Session Load limitation is not resolved by these changes or this review.

## Test-quality perspective

The independent run is **44/44**, with a separately passing focused L05 control and a meaningful expected-failing N1 isolated mutant. Source/log/library hashes and all failed preparation attempts are preserved in `independent-execution-v1.md`. There was no private aggregate coverage run; coverage and CI belong to root's full gate.

Relevant new and changed tests were read for assertions and failure boundaries: owner transaction, shared dispatch, repository receipt, scalar checkpoints, native C capture guard, root bootstrap/App, LooperBloc persistence, Session file output, pure model/resolver and mapping-page endpoint behavior. Existing constructor/provider fixture changes retain their behavioral assertions rather than deleting coverage. Fault-injecting stores and controlled engine fakes are justified for precise refusal timing; real native execution independently covers callback, PCM and capacity claims that those fakes cannot establish.

Assertions distinguish key absence from explicit Auto, accepted state from raw state, live Held from durable Released, rejected priority, capture preservation and file output. Tests explicitly await or pump work before observing acceptance. The native PCM/history case verifies existing recorded material rather than only checking preset metadata. C1 has actual App Retry tests; C2 has an actual page repair/Edit/Escape/Save test. No assertion-free coverage padding or mock of the owner under test was identified in the relevant reviewed additions.

Screenshots are author-only render validation, not ordinary CI proof. The private PowerOff tests use a supplied gate snapshot and do not substitute for the root's actual App fresh-capture shutdown journey. The actual Session file Save does not prove the known live-Control Session Load problem fixed. Exhaustive device/source formats, all modes/spans, process crashes, accessibility and appliance timing are outside this bounded run.

## Conventions and simplicity perspective

No actionable convention or simplicity deviation was found. The implementation extends existing owner/repository/typed-target seams and removes old direct write authority; there is no parallel settings blob or backwards-compatibility fallback. Musical conversion and exact target identity stay in domain models, while presentation labels and editor locks remain local UI concerns. Typed outcomes separate rejection, supersession and recovery. Scope remains Record length; Record timing and other shared families were not smuggled into this slice.

The owner/repository are necessarily longer because they now distinguish storage, admission, callback receipt, compensation and restart state. Those branches each cover an accepted failure contract and have targeted tests. This review does not recommend replacing them with a future generic transaction framework. The unrelated controller package analysis exclusion is neither endorsed nor changed by this review.

## Gate disposition

The independently exercised runtime/source scope is clean with the limits above. Root owns the final aggregate/static/native configurations, the separate UI review, exact-head CI and publication. Do not infer review:clean or ready-to-merge from this report alone.
