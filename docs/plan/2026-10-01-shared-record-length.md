# M3.14 — shared Record length

Issue #1026, dependent on shared Playback Loop/Once PR #1096 at
`2cf6c3adfc19b0e229717fe4b6d1748267b0c17a`. The campaign authorizes
implementation and publication; human merge approval remains required. This
plan is technically reviewed and does not claim a completed slice.

## Accepted behavior

The accepted mapping catalogue (`docs/design/mapping-parameter-targets.js`,
lines 30–39 in the design checkout) and accepted behavior sections 2.2–2.4
define nine fixed targets: Loop defaults and Tracks 1–8, including empty slots.
Record length is Auto (0) or 1–64 bars. Decode finite normalized values as
`round(64 * value)` after boundary coercion; use `1/64` relative steps and the
same conversion for readback/pickup. Reject non-finite input. Explicit Auto is
a Custom override; only Use default removes its membership. No recorded audio,
loop length, timing, pitch or history is resized by changing this future preset.

Keep target identities independent of selection, name and bank. Use strict
`DefaultRecordLengthTarget` / `TrackRecordLengthTarget(index)` with keys
`{"ctl":"defaultRecordLength"}` / `{"ctl":"trackRecordLength","index":n}`
for integer n0–7. No compatibility key or separate mapping envelope. Expose
them through the existing Loop controls catalogue and MIDI/External value
editors. Label endpoints Auto / n bar(s), never raw percentages. New External
buttons start current/current; MIDI/expression retain 0/1. Save and Cancel must
not preview length edits. Reversed endpoints and held/released ranges work.

Reject live edits during recording, including from MIDI/External. Multi uses
the default; track edits are unavailable there, while existing per-track
overrides remain stored and resume in an independent mode. UI disabled reasons
must explain the same rule enforced by the owner. Capture/mode checks must
occur again at actual admission, not only when a queued event was created.

## Ownership and transaction

Extend the existing RecordOptionsCubit with a narrow RecordLengthControl port,
immutable default/track address and snapshots, confirmed readiness, live and
durable Released views, address revisions and session/device lifetime. Keep
recDub, autoRecord and defaultMultiple behavior intact and independently ready;
defaultMultiple is not another Record length target. Replace the ordinary
default setter and LooperBloc per-track persistence path with this one owner.
Use one serial queue for length; do not introduce a generic settings framework.

Reuse the repository's coupled length-vector/mode transaction and native
setTrackLengthPresets/setLooperModeWithPresets APIs. Receipt requires drained
commands and raw eight-slot lengthPresetBars plus expected mode. Keep expected
vector/mode/lifetime fixed at admission. Native capacity refusal is valid:
fixed bars must fit the engine's capacity at 30 BPM/current signature. Preserve
the 64-bar product catalogue; test it using a correctly sized native fixture.
Never substitute projected state or enqueue success for raw acceptance.

Add exact scalar checkpoints/readback/rollback using existing default/track
Settings keys, preserving absent vs explicit Auto and unrelated settings. Stage
all nine startup reads and validate before publishing any intent. Strict invalid
stored values stay preserved and visibly refused. Success/failure fences prevent
old read/write/rollback results from poisoning a replacement session or device.
Retry must repair the original pending obligation without applying old payload
to a new rig or bypassing failed initialization validation.

Retain a separate durable restart vector. Held values stay live; Save and
reconnect use authored Released values and exact override membership. Ordinary
Use default invalidates only that address, defeating older cleanup while
preserving source contact/latch and siblings. Handle competing MIDI/External
sources, refused release and retiring mappings through the established shared
control arbitration. Do not invent a second controller interpreter.

Length and mode share a native transaction. Integrate ordinary mode changes
with that ownership so they cannot commit stale Held presets or race pending
length writes. Preserve accepted stop-and-switch UX and latent Multi overrides.
On accepted entry into Multi, submit the live default and durable Released
track overrides in one mode/vector transaction. Only after receipt increment
track-address revisions and supersede track claims through existing nullable
ordinary-change events. Preserve default claims, contact/latch, and unrelated
controls. Refusal changes none of these; leaving Multi restores the retained
ordinary/Released overrides without replaying retired Holds.

Release during recording stays an owed Control cleanup. Retain Released
persistence/restart projection; refuse its live command while capture is locked
and extend existing retry eligibility with capture/mode/settlement facts so it
retries once safe, under the original lifetime/revision. No extra timer or
deferred-settings queue. Save can serialize confirmed durable Released without
changing the live preset; shutdown remains on until cleanup can complete. Never
stop recording just to retire a source. A callback refusal that leaves the exact
previous vector/mode rejects and rolls back storage without stopping the take;
timeout or partial/unexplained state requires recovery.

Add one bounded callback capture predicate in existing LENGTH_PRESETS and
MODE-with-vector paths, before mutations and even for a same-mode vector. Scan
fixed tracks for recording/overdubbing; do not add unrelated mode restrictions
to ordinary preset writes. Preserve the existing stronger mode gate. No new API,
allocation or locking is required. Recheck observed capture at receipt before
metadata acceptance. Raw vector plus commandsSettled cannot distinguish an
identical-vector rejection from acceptance; do not claim an unavailable exact
native acknowledgment. The callback guard guarantees no preset mutation during
capture, including a record command preceding the vector in the same callback.

Repository-owned bounded receipt observation must cover synchronous engine
restart callers without an owner/UI polling loop. Use the established 10ms/50
attempt settlement policy. Wrong receipt/timeout stops uncertain processing,
blocks unsafe restart and offers explicit recovery. Preserve confirmed choices.

Session settings gates acquire Mixer → Click → Playback → Record length in a
single consistent order. Await initialization before acquiring queues; read
durable snapshots directly inside locks. Never call a queued setter/flush while
holding that same queue or await Control cleanup from inside it. Replace session
capture's live length vector with the durable vector; session apply adopts its
saved vector, not startup preferences or old Held intent. Include ordinary and
controller writes in Save/shutdown drains. Shutdown cuts ingress, drains,
retires holds and requires confirmation before goodbye; failure stays on.

## Work sequence and boundaries

1. Runtime/VGV, simplicity and scope review; independent literal/native/failure
   oracle frozen before product edits. Confirm mode/capture cleanup contract.
2. Runtime writer: RecordLength port, RecordOptions owner, Control dispatch,
   LooperRepository, Settings checkpoints and focused behavioral tests.
3. After port freeze, model/UI writer: target/resolver/catalogue/readouts,
   value-editing views and their model/page/render tests. Reuse LoopSlider with
   keyboardStep 1/64, lengthPresetLabel readouts and existing edit cancellation;
   canonicalize endpoints through the domain conversion. Use the existing
   length group label rather than Playback; no 65-choice popup or new group.
4. Root after a writer release: App/bootstrap, LooperBloc, Loop length page,
   Session gate/mapping, locales and composition fixtures. No overlapping paths.
5. Source freeze, independent execution plus an isolated negative control,
   full app/affected package/static/coverage checks, saved Pen references and
   actual desktop UI. Five review perspectives, root bug gate and exact-head
   CI before readiness. Preserve all failed attempts and fixture explanations.

At most two product writers and two tests. No recursive delegation. Reuse
unchanged evidence only with matching sources/dependencies. Appliance behavior
and the inherited M5 full session load with live Control defect remain separate.

## Success Criteria

```success-criteria
GOAL: Touch, MIDI and External controls share confirmed Record length choices, with honest lock rules and safe Save/restart/recovery.

SUCCESS CRITERIA:
- Literal endpoints, Auto membership, fixed eight-track identities, finite conversion and musical readouts are correct | verify: flutter test test/control/binding test/control/record_length_dispatch_test.dart
- Enqueue is not acceptance; refusal, wrong raw receipt, timeout, rollback, startup and stale lifetime preserve confirmed or explicitly blocked state | verify: flutter test test/looper/cubit/record_length_transaction_test.dart && (cd packages/looper_repository && flutter test test/length_receipt_test.dart)
- Multi/capture locks are enforced through ordinary and controller paths; latent overrides and existing audio survive mode changes | verify: flutter test test/looper/bloc/record_length_persistence_test.dart test/looper/cubit/record_length_transaction_test.dart
- Save while held serializes Released; reconnect and shutdown drain/refusal/retry obey the same owner | verify: flutter test test/session/record_length_persistence_test.dart test/app/view/app_test.dart
- Adding and editing mappings uses Auto/bars, preserves ranges on Cancel, and ordinary Use default remains distinct from explicit Auto | verify: flutter test test/control/midi_controls_page_test.dart test/control/external_pedal_page_test.dart test/control/external_expression_page_test.dart test/looper/view/loop_settings/loop_settings_test.dart
- Native prepared takes retain their samples and lengths; capacity refusal is honest; a receipt-bypass negative control fails its predetermined assertion | verify: manual Execute the frozen independent native oracle, retain normal and negative-control results, compare exact source/library hashes.
- Native mapping pages and existing Loop settings retain accepted layout without clipped focus or labels | verify: manual Inspect native renders and actual app, save matching Pen section and verify on-disk hash.

NON-GOALS:
- Record timing, defaultMultiple remapping, Tempo/Count-in, other remaining control families, native DSP redesign, deployment and physical hardware proof.

VERIFICATION COMMAND: flutter test test/control/binding test/control/record_length_dispatch_test.dart test/looper/cubit/record_length_transaction_test.dart test/looper/bloc/record_length_persistence_test.dart test/session/record_length_persistence_test.dart test/app/view/app_test.dart test/control/midi_controls_page_test.dart test/control/external_pedal_page_test.dart test/control/external_expression_page_test.dart test/looper/view/loop_settings/loop_settings_test.dart && (cd packages/looper_repository && flutter test test/length_receipt_test.dart)
```

The VGV/runtime, simplicity and independent scope reviews are incorporated
above. The independent 25-group behavioral oracle was frozen before product
edits at SHA-256 `c7dbb68821e848c5e565ec7af9b3432d4e3f1b3e2f2bb59c7f7ba0c4613d5889`.
All three roles find Record length alone a coherent slice. No product decision
remains open for this plan; implementation evidence is still required.

Use the repository's absolute Flutter SDK command for execution. Final suite
filenames can be reconciled with implementation while preserving every behavior
above. Run unchanged coverage floors, fatal-info analysis, explicit formatting,
positive-scope Bloc lint and native standard, sanitizer, telemetry-disabled and
C++ shim gates for the narrow native guards before publication. Freeze a new
native test library after those edits; never replace one in use by a test.
