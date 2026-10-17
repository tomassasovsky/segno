# Restore stationary Fade amounts through Clear history

Tracking: #1142, parent #1026, human merge gate. Implementation is authorized
within this reviewed scope. Independent review and publication gates remain.
Base is published
`c2e1d728293e2db03848362d6027cbc84692c468` (#1141). Scope excludes #1140 reopen.

## Outcome and boundary

Clear/Clear All reset removed material to unity. Undo restores each affected
track's coefficient **at the native Clear application boundary**, stationary
(amount=target, seconds=0), before restored playback can sound. Ordinary Fade/time
edits add no audio-history entry and retain Redo. Ordinary Undo-to-empty and Redo
from empty never resurrect an old moving Fade. Existing gain, duration, FX,
per-track/group history, transport and later independent edits retain their rules.

Implement ordinary, frozen-capture and grouped Clear together. One is a complete
vertical increment; shipping only ordinary Clear would leave the same action
incorrect for captured/grouped material. No Fade UI, Session schema change,
coefficient persistence owner, resampling or device-loss policy is included.

## Source binding and resolved mechanism

The original source analysis uses immutable c2e1. Its native tree is
`6f6d86e5ef4844a04585a32e1a7d1357bd368134`, identical to a921. The accepted
contracts are the parent Fade plan and Part 2. The captured-restoration amendment
below records the additional requirements found during implementation review.

The current ordinary point is filed control-side (`engine_commands.c`,
`le_build_restore_point`, `le_finish_clear`), before callback Clear. Frozen Clear
instead waits for `LE_EVT_CLEAR_FROZEN`; that event is currently discarded on a
full event ring. Neither a pre-post Fade snapshot nor extending that lossy event
is acceptable. Use **one bounded, latched native Clear-completion mailbox per
track**, replacing frozen event delivery and also serving ordinary Clear.

Keep ordinary restore points filed synchronously and keep
`clear_restore_pending` **frozen-only**. Making ordinary Clear pending would
change LooperRepository._clearTrack's existing pending→frozen/muted=false
interpretation. Avoid that regression and any extra ordinary candidate/cache.

Mailbox protocol (private to native, no generic abstraction):

1. Add atomic sequence plus atomic tuple fields for Clear operation tag, captured
   Fade amount bits, finalized length and master length. Reuse the local SC
   sequence/atomic-field bounded-copy pattern in `engine_snapshot.c:21–67`.
   Plain payload fields under a sequence guard still race in C and are forbidden.
   One bounded incoherent read returns not-ready; no spin, locks or allocation.
2. `handle_clear` samples Fade amount into a local before any finalize/reset.
   After finalization it has frozen length/grid, including zero-length void
   capture. At the end of Clear, publish the tuple and then the existing
   state-ack release. Thus collectors require both coherent identity and the
   corresponding Clear acknowledgement before exposing completed recovery.
3. Tag by the existing Clear/dub operation generation, not the Fade material
   generation observed before posting. A queued restore→Clear has effective
   content while the wire remains EMPTY; its callback amount belongs to the
   restored material that actually exists when Clear executes.
4. Add exact operation tag, amount and amount-ready to `LE_HIST_CLEAR` metadata.
   Ordinary entries start not-ready; completed mailbox data attaches only to
   the matching top CLEAR entry. Frozen entries are completed using the current
   pending slot/generation and callback length/grid, with STOPPED/unmuted rules
   unchanged. Do not write control-owned stacks from callback or pass pointers
   to movable entries. Layer entries leave these extra fields zero/unused.
5. Keep publication latched. If callback runs between post and `le_finish_clear`,
   a drain that cannot yet find the matching entry must leave the image available
   for the next drain. Match current identity and committed control bookkeeping;
   never re-arm a pending point already completed by an interleaved drain.
6. Removing the event removes its FIFO relation with preceding retired layers.
   After acquiring ready mailbox data, drain the preceding event-ring retirement
   reports **before** filing a frozen point, then revalidate pending identity.
   A drain performed only before acquiring readiness is insufficient. Implement
   this within existing `le_engine_drain_events`, not recursive public API calls.
7. Keep `history_mode_gate` read-only. After its existing Clear-ack acquire,
   `le_restore_clear` must collect/revalidate again and require amount-ready
   before copying the entry or queuing mutes/restore. This closes drain-before-ack
   races. Not-ready returns the existing refusal; no default unity or history pop.
   Existing frozen pending queries/drains and grouped deferred Undo remain intact.

A one-slot mailbox is sufficient: another accepted Clear supersedes old pending
recovery; Clear while effectively EMPTY drops the ordinary point; Undo moves CLEAR
to Redo and the next Clear drops that Redo; fresh capture drops erased history.
No live old point needs a report after a newer Clear on that channel. Atomic
payload ownership makes overwrite race-free even if control is reading. Prove
these schedules; do not rely on that argument without regression coverage.

## Dependency-ordered implementation

1. **Metadata and reliable completion.** In `engine_private.h`, extend the existing
   history entry and track-private mailbox; initialize all added fields in
   `engine.c` configure while callback/workers are quiescent. Adapt Clear capture,
   completion and reset retirement in `engine_process.c` and `engine_commands.c`.
   Preserve push-before-bookkeeping: command-ring refusal changes no history,
   coefficient or pending ownership. Full **event** ring cannot lose accepted
   Clear completion. Raw/internal/destructive Clear keeps its existing semantics;
   ignored mailbox images do not create recovery for raw Clear.
2. **Stationary restoration.** Extend existing `LE_CMD_RESTORE_CLEAR` payload in
   `lockfree_ring.h` with amount. Apply it before publishing restored transport or
   producing any sample; set amount=target with zero full-travel seconds and emit
   existing `LE_PLOG_FADE`. Playback phase follows native restoration semantics. Never restore old generation/lifetime. Keep Clear/New Loop/
   empty-refill fencing and ordinary nonempty layer Undo/Redo behavior unchanged.
   Re-clear after an independent Fade edit captures the newer actual amount.
3. **Remove obsolete event path.** Remove `LE_EVT_CLEAR_FROZEN=102` delivery,
   dispatch and unused frozen payload fields, including internal log-copy members
   only if unused. All surviving command/event numeric values must remain exactly
   unchanged. Existing Fade fact 321 reconstructs the coefficient; applied
   restored-material and state/phase facts 322/323 identify the audio it affects.
   These use the fixed 16-byte payload and event-log version 5, as described in
   the approved captured-restoration amendment.
   The enum lives in `segno_engine_api.h`; regenerate FFI and format the generated
   bindings, allowing only that obsolete constant deletion. Add no public
   function or snapshot field; escalate if needed instead of widening silently.
4. **Composed behavior and tests.** Extend `test_engine_fade.h` and the relevant
   existing ordinary/frozen/history fixtures in `test_engine_core.c`. Update the
   old test that pops/reinserts a frozen event to hold/inject a tagged mailbox
   completion through test-only seams, preserving its stale-report oracle.
   Add a small real-native repository group journey in existing
   `packages/looper_repository/test/fade_native_test.dart` or the existing history
   test file. Prefer no Dart production changes: native query contracts remain.

## Required observable oracles

- **Applied amount:** retain earlier published .75 while callback-owned amount
  becomes .5 before Clear consumption. Undo gives stationary .5, and known .5 PCM
  produces literal .25 at its first restored sample; no unity sample or old ramp.
- **Post-before-finish:** force callback Clear between command posting and control
  bookkeeping completion. Ordinary and frozen reports attach once to the correct
  point; no stuck pending or lost amount. Queued restore→Clear captures the amount
  after restore, not the earlier EMPTY/unity wire image.
- **Ring pressure:** fill evt_ring with valid benign reports, apply ordinary and
  frozen Clear, drain, Undo and verify PCM/amount/history. Saturate command ring:
  refused Clear leaves all state unchanged and later retry works. Delayed
  mailbox read across overwrite must yield a coherent matching tuple or refusal.
  This proves reliable Clear completion, not lossless unrelated layer/performance
  events when their existing event ring is saturated.
- **Frozen:** non-unity overdub Clear captures exact boundary, restores STOPPED
  with original layer/window semantics; early Undo follows existing pending
  behavior. Zero-frame initial capture remains void. Preceding layer retirement
  remains below CLEAR, so the next Undo still peels that layer.
- **Group/mute:** mixed playing, stopped/muted, frozen and empty/armed members
  restore their own .25/.6 amounts through one group action. Ordinary mute stays
  muted in engine/repository/persistence; frozen capture remains unmuted. Preserve
  group order, gain/FX/duration changes and existing partial-refusal semantics.
- **Lifecycle/history:** layer Undo/Redo keeps live Fade and Redo; Undo-to-empty and
  new capture reset runtime; ordinary Redo does not resume old Fade. Re-clear after
  a newer Fade edit restores the newer amount. Old tagged completion and old Fade
  requests cannot act on new recording, Session import or reset lifetime.
- **Performance:** live/restored literal output matches offline capture rendering
  using the Fade coefficient and exact restored material/state/phase facts;
  source PCM is unchanged. Test no callback allocation,
  blocking or unbounded retry; existing RT instrumentation remains valid.

## Budget, failure boundary and validation

The combined scope, including captured restoration, has a review ceiling of
500 added production lines. Count tests, generated bindings and documentation
separately. Stop for review above that ceiling, or for any new public function,
Session schema, generic mailbox framework, second history ledger, new Dart owner
or broad grouped-history rewrite. Event-log version 5 is explicitly included. Existing
pool/history limits remain; no new silent fallback from undoable to raw Clear may
be introduced. If full-history capacity prevents preserving an admitted point,
prove the existing bounded invariant or refuse before native mutation; do not
invent eviction of accepted history. This is a review checkpoint, not permission
to redesign all existing capacity handling.

Resolve dependencies before explicit formatting. Native change requires normal,
ASAN and telemetry-disabled native suites, documented C++ shim/header checks,
FFI regeneration/parity and a fresh matching library for Dart native tests.
Run focused tests first, then affected Looper ordinary coverage (95% without
native credit), matched native group tests, appropriate app Clear/Control tests,
strict analyzer, explicit format and positive Bloc. Reuse unchanged Session
capture/schema checks by source binding. Maximum two task-wide processes;
reviewers inspect evidence instead of rerunning suites. Freeze source/library
before independent architecture, test-quality, simplicity and readiness review.
Root owns remote CI, actual Claude review, publication and human merge gate.

## Success Criteria

```success-criteria
GOAL: Clear history restores each track's actual pre-clear Fade amount as stationary state without losing recovery or disturbing independent edits.

SUCCESS CRITERIA:
- Ordinary/frozen Clear and Undo preserve exact amounts, PCM/history and first audible samples under delayed callback, full event ring and refused commands. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Grouped Clear/Undo and existing mute/transport ownership remain coherent using a fresh source-matched native library. | verify: manual inspect bound actual-native repository group/ordinary-mute/frozen-control logs and literal output assertions.
- Native lifetime, performance replay, sanitizers, telemetry-disabled, C++ and unchanged symbol/code parity pass on frozen source. | verify: manual inspect native matrix logs, generated diff and surviving command/event value comparison.
- Applicable coverage floors, formatting, strict analysis, positive Bloc and independent current-source reviews pass. | verify: manual inspect source-bound local readiness evidence; retain remote CI and human merge gate.

NON-GOALS:
- Reopen/material retention or resampling (#1140), UI/mappings, duration settings, new Session schema, generic recovery framework or new public API.

VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```


## Approved implementation amendment: captured restoration

The original capture-across-Clear oracle exposed missing dry-source restoration
in offline rendering. Keep that oracle and repair its provenance in the existing
performance staging, drain and rendering owners. Do not move capture arm after
Undo or interpret generic Undo records as restoration. Root approved this
bounded amendment on issue #1142; the combined production-addition review ceiling
is now 500 lines, with tests, generated bindings and documentation counted
separately.

- Stage an immutable copy of the exact retained PCM on the control thread before
  restoration admission. Reuse the existing layer staging ring and disk owner;
  distinguish restored images by explicit kind and unique nonzero capture-local
  image ID. Preserve all active lanes in the file. Offline parity remains scoped
  to the existing lane-0 renderer. No new recorder, queue or callback allocation.
- Publish a typed applied restoration fact with channel, image ID, state and
  phase in the existing fixed 16-byte log payload. Read the resolved first-sample
  coordinate at the existing mixer boundary; do not duplicate mode math or use
  the previous block's playhead. Subsequent state/phase facts apply only to that
  restored image until Clear or replacement material retires it.
- Staging ownership includes a successfully queued PERF_ARM before its callback
  publishes armed. Never produce a successful armed restoration with image ID
  zero or missing provenance. Preserve joined disarm/rearm namespaces and prove
  callback completion between restoration posting and live-slot publication.
- Preserve the new metadata through native sidecar and real repository manifest
  finalization. Match kind/channel/ID exactly, validate lane/frame bounds and
  exact file size, and fail the affected stem on missing/truncated material or
  segment capacity exhaustion. Reuse existing incomplete/overrun reporting for
  copy, queue, ID, disk or manifest failure; capture failure must not refuse an
  otherwise valid musical Undo. A refused restore keeps history unchanged and
  may leave an unreferenced staged image under the existing cleanup owner.
- Validate moving and stationary literal PCM across Clear/Undo, patterned
  nonzero phase with a surviving grid, STOPPED restore and later Stop/Play,
  frozen partial capture, repeated/grouped restores, missing material, capacity
  and capture-lifetime schedules. Generic duplicate Undo records and ordinary
  layer history must not activate this typed path. General history/transport,
  multi-lane offline rendering, monitors/plugins and engine reopen remain out
  of scope; stop for review if they become dependencies.

Two related bounded corrections are included: the existing repository Clear
snapshot must include mute-only lanes, and a pending frozen Clear may retain
only its immediately preceding retirement generation. Pending frozen Clear must
not replenish new shadow slots. After its mailbox readiness acquire, drain those
retirements before clearing pending or filing CLEAR; fresh capture or superseding
Clear removes this permission. Prove exact PCM/layer order and stale rejection.

General layer-history reconstruction is tracked separately in #1143. A supported
same-span layer or processed-material swap, Undo to empty, or new overdub after
restored Clear explicitly ends unsupported source provenance and fails the
affected derived stem; the independently recorded master remains usable.
This limitation must not be reported as a storage or queue overrun.

Arm snapshots retain metadata-only empty lanes (including gain, mute, pan,
routing and effects) without exporting PCM. Applied restoration facts discover
stems absent from both snapshots; empty arm metadata alone creates no stem.
This uses the existing PerformanceRepository snapshot owner and model fields.
