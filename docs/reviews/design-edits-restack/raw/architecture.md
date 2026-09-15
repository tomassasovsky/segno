## Architecture Review

Reviewed the complete staged and working slice on `codex/design-edits-restack` against `09c8e9c2d79d2bb5c1090319db6ae6b223cb92a9`, the accepted Tracks base, rather than master or the later integration tip. The intended merge is original slice `6cdfb9fb`: 34 files covering mode gates, reversible capture edits, and grouped Clear All history. This initial report precedes the coordinator's requested native corrections.

Read the project instructions, build/test and tracking contracts, architecture role, reporting instructions, and updated slice 2a ledger. Stack: Flutter/Dart with Bloc/Cubit and repository packages, plus a C audio engine reached through Dart FFI. No implementation or Git changes were made during this review. Public paths below are repository-relative.

### Layer Separation

- New layer or package dependency violations: 0.
- Mode requests remain presentation → bloc → repository → `AudioEngine`. The chooser reads the domain gate through the repository and dispatches the request through `LooperBloc`; it does not import or call native clients.
- Group history belongs to `LooperRepository`; `ControlCubit` delegates whole-rig clear and recovery rather than implementing a second group owner. Native slots and audio-thread commands remain below the `AudioEngine` seam.
- No new package or external dependency is introduced. Updated production and test engine implementations provide the new interface methods. Existing package manifests, test directories, and lint configuration remain intact.

### State and Ownership Assessment

- The chooser removes the obsolete clear-before-switch path and its bounded wait, retaining mounted checks and rechecking the gate after confirmation. Playing tracks are stopped through native FIFO commands; captures, queued actions, and incompatible live spans are refused.
- Mode clocks are changed on the audio thread. Track PCM, effect chains, mute state, and slot history are not rewritten by the mode switch itself. The earlier full-track waveform reset remains present in extracted `apply_undo_to_empty`.
- Native cancel/freeze completion reports and repository deferred recovery are reasonable owners, but several transitions leave those owners inconsistent. The findings below are actionable in the reviewed content.

### Critical — Arm frozen-clear bookkeeping before consuming its report

Location: `packages/segno_engine/src/core/engine_commands.c:1231` and `:1245`.

`le_clear_track` posts a freeze CLEAR, drains events again, and only then sets `clear_restore_pending` at line 1260. The audio callback can apply the posted command and publish `LE_EVT_CLEAR_FROZEN` before that second drain. `le_handle_clear_frozen` sees the still-false flag and discards the report; control then sets the flag with no remaining event to complete it. The take loses its restore offer and deferred undo waits indefinitely. This is a real producer/consumer interleaving, not covered by the existing sequential tests that run the audio callback after `le_engine_clear_undoable` returns.

Fix: make the successful command publication and control bookkeeping safe against immediate completion before a drain can consume it, preserving the existing retired-layer staging requirement and failed-push behavior. Add deterministic coverage for completion arriving in this interval without adding a public test-only API.

### Critical — Reset and invalidate deferred recovery with its history

Location: `packages/segno_engine/src/core/engine_private.h:701`; missing lifecycle updates in `engine.c:393` and `engine_commands.c:1254`.

New recovery flags are allocated with the engine but never reset by configure, which resets the existing history and both event rings. A restart while a frozen clear is pending leaves `clear_restore_pending` true after the report has been discarded; the new rig can report an indefinitely pending restore with no associated history. A later destructive clear also does not clear this flag: if a freeze and then a destructive clear are posted before audio processes them, the old frozen report can still file a clear restore point after the destructive clear. That contradicts the session-load rule that old takes cannot be restored. The existing cancel path explicitly invalidates `cancel_pending`; frozen recovery needs equivalent ownership and stale-event protection.

Fix: reset all new deferred fields during configure and invalidate frozen/cancel completion when history is replaced or destroyed. Associate completion with the history generation where needed so a late report cannot attach to a newer pending operation. Cover restart, destructive-clear supersession, and a subsequent fresh capture/recovery cycle.

### Critical — Preserve a deferred group member through repeated undo and redo

Location: `packages/looper_repository/lib/src/looper_repository.dart:1767`.

After Clear All with one frozen member, grouped undo restores ready members and parks the frozen member's undo. An immediate grouped redo removes that parked undo and also deletes its `_clearRestore` snapshot, although native audio and its eventual restore point still belong to the cleared take. The code then places every member in `_clearAllGroup` without retaining the pending member in `_clearAllPending`. The next group query while completion is pending sees no native restore point and dissolves the group. If completion has already arrived, subsequent restoration can recover audio but no longer recover the deleted lane-chain snapshot. The current waiting-member test only checks that a later poll does not perform the cancelled undo; it stops before the next undo/redo cycle.

Fix: cancel the deferred undo while retaining the still-cleared take's recovery snapshot and pending group classification. Verify another undo both before and after frozen completion, with nondefault lane effects and chain flags, restores the entire group and preserves repeated redo symmetry.

### Critical — Reconcile declined mode requests before persisting them

Location: `lib/looper/bloc/looper_bloc.dart:493`; related polling gate at `packages/looper_repository/lib/src/looper_repository.dart:656`.

An accepted command request is immediately stored as the intended new mode. If the audio thread later declines it, the engine continues reporting the old mode, which is also the previous `LooperBloc` mode. The new state handler persists only a change between reported modes, so it never repairs the saved new preference. The repository may eventually return its in-memory intent to the old mode, but that correction does not itself change the reported mode or notify persistence. A subsequent application launch can therefore apply a mode the original operation never switched to.

Additionally, `_rememberLooperMode` runs below `_poll`'s equality return: identical reports from a quiet rig never count toward the twelve-report fallback. The existing rejection test changes the playhead on every poll and verifies only in-memory restart replay, masking both cases.

Fix: reconcile request progress for every relevant engine report independently of projection deduplication, and give persistence an observable confirmed-intent correction. Preserve explicit choices made while the engine is closed. Cover repeated identical reports and an accepted-then-declined request through the repository/bloc/settings path, including a cold-start preference check.

### Critical — Restore history using the current mode's clock rules

Location: `packages/segno_engine/src/core/engine_process.c:2329`; analogous empty-track redo at `:2292`.

The VGV reviewer reproduced both directions against current sources, and this reviewer inspected that reproducer, its output, and the relevant restoration code. Multi take → undoable clear → Free → undo republishes the old 2000-frame master in Free; a new sibling captured for 500 frames is then rounded to 2000. Free 500-frame take → clear → Multi → undo restores the take with master length zero. `RESTORE_CLEAR` reinstates historical master length before inspecting the current mode; `REDO_FROM_EMPTY` computes a fallback base without establishing the shared clock when none exists.

The old restoration code assumed the history and current mode agreed. Switching with live content is new in this slice, while switching an empty rig with hidden history was already possible on the base; this report does not label every form of that inherited edge as newly introduced. The coordinator explicitly included correction of this current mode/history invariant in the native follow-up scope.

Fix: apply current-mode clock rules to both clear restore and empty-track redo. Free/Song must keep the shared master and grid dormant; shared-clock modes must establish a valid base when recovering the first take. Verify both transition directions, subsequent independent capture duration, and unchanged recovered PCM.

### Native Callback, Ordering, and FFI

- No new heap allocation, locks, blocking I/O, or control-thread buffer ownership transfer was found in the audio callback. New mode work loops over the bounded track set. Capture cancellation/freezing reuses existing finalization and slot-history mechanisms; pool growth and retirement remain control-side.
- Reviewed state-command acknowledgement increments, effective-state/length tracking, queued undo, partial overdub punch-out, clear/redo, configure, and fresh-capture callers. The latch prevents duplicate undo from posting a second record toggle, and the extracted empty transition preserves the prior visual reset and layer-generation invariant.
- The frozen-event lifecycle findings above remain the native ownership blockers. Sanitizer success alone would not prove these sequencing cases.
- New C entry points `le_engine_looper_mode_gate`, `le_engine_clear_restore_pending`, and `le_engine_redo_reclears` match declarations, generated lookup names/signatures, native Dart wrappers, the `AudioEngine` interface, and fake implementations. Gate enum values match native and Dart projection. No new unsupported C++ atomic-shim operation was introduced.
- The old clear-and-wait chooser path and old content-lock implementation callers are removed. Replacement tests assert stop-with-content-preserved, no destructive clear, capture refusal, and the new recovery semantics rather than retaining tests for the deleted contract.

### Test Evidence and Limits

Inspected the changed native, repository, bloc, chooser, control, and pumped-engine test bodies. They cover primary/multiple/division gates, independent clocks, normal and void capture recovery, queued operations within a block, grouped recovery, and FFI mode forwarding. The identified gaps require additional thread orderings and complete repeated recovery cycles.

The VGV current-source reproducer printed the incorrect 2000-frame Free master and sibling length, and the missing Multi master after recovery; it used the existing native test helpers. Other pass counts in the slice ledger describe the original slice's historical validation. They do not establish that this reconstructed head or subsequent fixes pass. The coordinator owns new suite execution, analyzer/lint checks, and symbol checks. No appliance timing, desktop visual approval, or current CI result is claimed here.

### Verdict

Layer direction and package structure are clean. Resolve the five behavioral ownership and state-reconciliation findings before this review can support a clean gate. Native follow-up changes will be authored under the coordinator's explicit assignment after this report and require another review by a different reviewer.

### Native Follow-up Under Explicit Implementation Assignment

The coordinator assigned this reviewer ownership of the native corrections only after the initial report above was saved. The following is author evidence, not an independent clean review of these corrections.

- Frozen-clear ownership is now armed after a successful command post and before the existing second event drain. The report carries the matching clear generation, using a new named four-word payload in the internal command union; the command size and exported ABI are unchanged. Immediate completion can finish the point once, and a superseded report cannot consume a newer point. The existing retired-layer staging drain remains in place before shadow reclaim. No new callback allocation, lock, or blocking operation was added.
- Every accepted clear invalidates older pending recovery and queued taps before the drain. Configure resets the new deferred fields and the published clear indicator along with the old history and rings.
- Both clear undo and base-take redo use the same current-mode clock restoration. Free/Song restore the private track clock without resurrecting a historical shared master. Shared modes retain a surviving master or restore the saved master; if history came from Free/Song and no master exists, the restored take establishes one. Control-side pending master prediction follows the same rule.
- Deterministic native tests force audio consumption between CLEAR publication and the second control drain, reject a superseded report, exercise destructive clear before frozen completion, reconfigure during freeze and cancellation, and restore history across Free/Song and Multi/Sync/Band in both directions through clear undo and base-take redo. Subsequent independent capture remains 500 frames rather than inheriting the erased 2000-frame master. The queued-arm gate test now checks before any audio drain.
- The scheduling hook is private to the core native test compilation under `LE_NATIVE_TESTS`; production compilation contains neither the hook nor a public testing API.

Validation observed on this checkout: the final targeted tests fail 32 assertions when compiled against the original staged native source with only the scheduling hook added, and pass with the current native corrections. The full native runner exits successfully with all five suites reporting `ALL PASSED`, including the core, race, MIDI, and macOS plugin suites. The coordinator owns the remaining sanitizer configurations, generated-binding refresh, Dart checks, and final combined validation. No hardware behavior or current CI outcome is inferred from this result.

### Independent Follow-up on Repository and Bloc Corrections

Inspected the coordinator's current implementation and changed tests. Grouped redo now preserves the deferred member's chain snapshot, returns it to the pending group set, and keeps completed members in the ready set. The new repeated clear/undo/redo/undo test verifies group membership and restores distinct effects, disabled chain flags, and inheritance metadata; the original grouped-history finding is resolved in the inspected content.

Mode settlement now runs before projection equality can suppress a poll. A request settlement can emit an unchanged projection, and the repository exposes a nullable settled mode instead of exposing unconfirmed intent to persistence. The bloc saves connected settlements and immediate offline choices, while pending native requests cannot write the requested preference. Identical-report coverage verifies settlement and restart replay. These changes resolve the original persistence and polling finding in the inspected content; final combined test execution remains the coordinator's gate.

The initial native findings are addressed by the author changes described above and await independent review. Reviewers are separately checking event-ring capacity and hidden history containing incompatible spans after a mode change; this follow-up does not preempt their conclusions or claim those edges are covered by the single-span clock-model regressions.

### Verified Callback Span Race and Correction

A second independent reviewer and this reviewer reproduced the same queued-crown race using public transport calls: Free mode, stopped tracks of 500 and 1500 frames, crown track 0, then queue crown track 1 and a switch to Sync before processing audio. Control accepts the old base of 500; the callback previously selected the new base of 1500 and assigned the shorter take a half division, although its actual ratio is one third. Band has the same trigger. This is distinct from restoring hidden incompatible history.

Under the coordinator's bounded follow-up assignment, the callback now validates actual spans against the actual target base before changing the mode or clocks. A pure private span predicate is shared with the control gate, keeping whole multiples and the supported half/quarter rules identical. The additional callback work traverses only the fixed track set and introduces no allocation, blocking, new atomics, or public symbol. Stale comments describing an unconditional content lock and equal-length Multi tracks were corrected.

The permanent regression fails six assertions before the change and passes afterward. It covers rejection of the 500/1500 pair and acceptance of a compatible 500/1000 pair for both Sync and Band, unchanged track lengths and stopped states, and byte-identical saved audio. The full native runner passes all five suites on this revised source. The non-Clang C++ atomics-shim compile and whitespace checks also pass. Independent re-review was requested from the reviewer who reproduced the issue.

### Event Queue Capacity Assessment

No event-queue saturation trigger was found through the typed transport and recovery calls used by the application. Those calls drain pending reports before posting new recovery work; layer supply is capped at two outstanding shadows per track, with eight tracks total. Further layer supply requires control to consume the preceding reports. A track cannot repeatedly post new capture recovery without advancing through capture and another event drain. Even allowing an additional superseded recovery report per track leaves the normal outstanding traffic far below the event ring's 255 usable slots.

The raw command escape hatch can bypass control-side ownership, and arbitrary injection of internal command codes is outside that bound. The application has no caller of that escape hatch beyond the generated binding; the typed latency helper posts a command that produces no recovery report. This review does not claim to have proven arbitrary raw-command traffic safe, or to have reproduced overflow through a supported application path. No speculative queue enlargement or recovery buffering was added.

The verified incompatible-hidden-history case remains separate and unresolved pending the performer's recovery-policy decision. No automatic mode change, padding, truncation, or history deletion was introduced to decide that policy implicitly.

### Approved Incompatible-History Policy Implemented

The performer subsequently approved refusal without mutation, with an explanation of a compatible mode and no automatic mode change. Under the coordinator's native implementation assignment, the engine now exports `le_engine_history_mode_gate(engine, channels, redo)` and result codes `LE_ERR_MODE_MISMATCH` (-7) and `LE_ERR_NOT_READY` (-8). The former means recovered completed spans do not fit the current mode and clock; the latter means a required recovery report or preceding clock change has not settled.

The query projects selected histories in ascending channel order without draining reports, consuming history, posting commands, or changing live slots. Clear undo and base-take redo call it before any mute command, history pop, live-slot swap, or transport change. It accounts for already queued restores through their effective lengths and master predictions. Free/Song accept arbitrary completed spans; shared modes require exact supported multiples or divisions. Ordinary overdub layer edits retain their existing span and behavior.

The pending rules preserve the whole operation:

- Frozen/cancelled captures wait for their final report. A refused native frozen recovery no longer queues a speculative tap; an explicit retry can run once the report has settled. The repository can park a known frozen Clear All group and preflight all members together after every point is ready.
- Typed mode, crown, and defining-record commands carry a private sequence acknowledged by the callback after either acceptance or refusal. An earlier clear uses the existing state-command acknowledgement counter to fence its possible master reset. Configure resets both kinds of bookkeeping.
- Re-clears and same-span layer edits add no content and bypass clock fences. This is necessary for a checked in advance grouped redo: posting member zero's CLEAR must not cause member one's query to refuse the same group. The exact full-mask preflight followed by three synchronous per-member queries and redos is covered without intervening audio processing.
- Recovery waits beside an unknown defining capture. Record finalization does not expose a pending PLAYING target: it remains RECORDING through the seam deferral. Finalization now publishes its settled clock and length before a release state store, and the gate acquires state before reading those values. A queued first RECORD is fenced before its callback has even published RECORDING.

Deterministic evidence includes retained 500-frame audio beside cleared 750-frame history; both-empty redo in both request orders across Multi/Sync/Band; unknown frozen reports; mode/crown changes; an unrelated last clear that changes the projected base; and a defining 750-frame capture beside 500/1000-frame redo history. Refusal preserves native history counts/points, live slot identity, PCM, mutes, lengths, and transport. Public PCM export reports the refused hidden take as empty, then returns byte-identical 750-frame audio after an explicit Free or Song retry; the playhead visits all 750 frames. Public PCM checks also verify both restored redo tracks at their exact 500/750 lengths.

The new policy tests failed 60 assertions before operation guards were added. The grouped re-clear regression failed six assertions before narrowing the fences, and the queued defining-record regression failed ten assertions before its acknowledgement/publication fix. All final targeted tests pass. The full native runner on the final policy source reports `ALL PASSED` for all five suites; the non-Clang C++ shim compile and whitespace checks pass. Existing later-take silence and partial overdub tests pass unchanged in behavior. Three older tests were updated from speculative frozen recovery to the approved not-ready/explicit-retry contract while retaining their audio and restoration assertions.

This section is author evidence for native changes. The independent reviewers own their final native correction review, and the coordinator owns generated FFI/Dart validation, sanitizer configurations, the combined application gate, and shipping authority. No appliance or current CI result is claimed here. The earlier pending policy question is resolved by the explicit performer decision and implementation described in this section.

### Final Pending Cancellation Correction and Obsolete Path Removal

The independent simplicity reviewer verified one additional public-call ordering: hide a 750-frame Free take on track 1 with Undo, switch to Multi, record 500 frames on track 0, cancel track 0 with Undo, then request track 1 Redo before audio processes the cancellation. The cancelled sibling already projects EMPTY on the control thread, but its callback still finalizes the capture and establishes a 500-frame shared master. Checking only the selected track's pending report missed that clock change and allowed incompatible recovery.

`packages/segno_engine/src/core/engine_commands.c:1351` now returns `LE_ERR_NOT_READY` for any pending sibling cancellation when recovering content in a shared-clock mode. Once its report settles, the unchanged 750-frame history is rejected with `LE_ERR_MODE_MISMATCH` against the actual 500-frame clock. Explicit Free recovery remains available. This adds one bounded control-side flag check and no callback work, allocation, lock, or ownership change. The public gate comment documents the sibling case.

The permanent regression at `packages/segno_engine/src/test/test_engine_core.c:21517` fails eight assertions before this correction and passes afterward. It verifies the transient refusal, untouched redo history, settled mismatch, and explicit Free recovery at the full original length. All eight focused policy tests pass, and the full native runner on this final source exits successfully with all five suites reporting `ALL PASSED`. The non-Clang C++ shim compile and whitespace check also pass.

The obsolete frozen-clear branch and its forward declaration were removed from `le_apply_queued_undo`. Frozen recovery now requires the approved checked retry, and clear resets queued taps; only the existing same-span layer retirement path still queues undo. The full native suite covers those retained layer and partial-capture behaviors. Final independent re-review and bridge regeneration were requested after this source change; this appendix records author validation and does not substitute for those gates.

### Independent Review of the Final Repository and Presentation Policy

The coordinator's current repository changes wait for every frozen member, check the complete group mask, and execute members in ascending order. Both undo and redo retain group membership and saved effects on a compatibility refusal. A Redo cancels a parked grouped Undo before settlement can restore a member. Per-track redo updates saved metadata and mutes only after the native edit succeeds. The full-mask projection and native pending-restore lengths support the subsequent single-track checks; the no-content-addition exception keeps grouped re-clears from refusing their own earlier member.

The refusal stream preserves the `AudioEngine` seam and contains only the requested action and result. Presentation displays localized Undo/Redo guidance naming Free or a brief wait-and-retry message. The view cancels its subscription and dismisses the toast on disposal; the repository closes its controller. No automatic mode switch or UI data-client dependency was added. The reviewed bridge maps both new result codes, passes the channel mask unchanged, converts the redo direction to the native integer convention, and checks disposal before the native call. No additional actionable architecture finding was found in these independently authored changes; combined tests and final generated-symbol validation remain the coordinator's checks.
