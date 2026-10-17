# Simplification Analysis

## Scope and examined version

Independent simplicity, reuse, removed-behavior, and efficiency review of the second design slice, relative to `09c8e9c2d79d2bb5c1090319db6ae6b223cb92a9`. The comparison includes staged and working source plus the untracked mode-persistence test. The reconstruction merge ancestry is not used as the comparison base. No design-file filesystem access, implementation edits, commits, or ref changes were performed by this review.

Initial and reproduction source hashes:

| File | Git blob hash |
| --- | --- |
| `lib/looper/bloc/looper_bloc.dart` | `cfea1a148e317d1438b51f685a2920ef7771253b` |
| `packages/looper_repository/lib/src/looper_repository.dart` | `935ed6a35afff61c0e36a14edda3a697b160500c` |
| `packages/segno_engine/src/core/engine_commands.c` | `bb0c91b17cf88497a7a9dea1de5c77dfd6f526ea` |
| `packages/segno_engine/src/core/engine_process.c` | `12b88ee3abc48a8097a534a69fe2b4e8bb00dc75` |
| `packages/segno_engine/src/core/engine_private.h` | `d5f2c339efc7e313068b72397d55142b60a861ef` |

Final recheck after the native author's callback-span repair:

| File | Git blob hash |
| --- | --- |
| `packages/looper_repository/lib/src/looper_repository.dart` | `8accb1c38e5c87e6efde262cf84e56e88ebeded5` |
| `packages/segno_engine/src/core/engine_commands.c` | `057c96f3198f91525c0964b5a0248d5de0b86977` |
| `packages/segno_engine/src/core/engine_process.c` | `4ab76f1c978097aef3d4427075951bf32dc5962f` |
| `packages/segno_engine/src/core/engine_private.h` | `5a72ae4f331c7ac4a0a9a54356dde9ec6997aa84` |

Read the requested simplicity role, build review instructions, repository instructions, the build/test section of `docs/PROGRESS.md`, and `docs/TRACKING.md`. Traced mode selection through the shared presentation helper, bloc persistence, repository settlement, native gate and callback. Traced single and grouped clear/undo/redo through repository chain/mute recovery, native history ownership, deferred events, state acknowledgements, and audio clock restoration. Reviewed the interface, generated-binding, mock/fake and test changes, and the removed clear-before-switch path.

## Core purpose

Allow fitting recorded loops to survive a mode change; refuse capture, queued-action and incompatible-span states; stop playing loops after confirmation; preserve useful recovery for canceled takes, partial overdubs and clears; treat Clear All and its recovery as a grouped edit. Acknowledged native mode reports must determine persisted settings. These behaviors must preserve callback ownership and avoid allocation, blocking, locks or I/O in new callback paths.

## Findings from the original review

### Resolved — Preserve the complete span when restoring history after a mode change

- Location: `packages/segno_engine/src/core/engine_process.c:1097` (`le_restore_track_clock` calling `le_restore_multiple_or_divisor`).
- Scenario: record 500-frame and 750-frame takes in Free; stop the 500-frame take, clear only the 750-frame take, switch to Multi, then undo that clear. All public API operations succeed. The restored track reports 750 frames but is assigned `multiple=1` against the retained 500-frame master. Across 1,500 processed frames its playhead reaches only 499, so its final 250 recorded frames never play.
- Why this belongs to this slice: the previous content lock refused this mode switch while the 500-frame take remained. The new gate accepts the visible fitting track, while the new restoration clock helper reinstates incompatible hidden history without checking it. The existing ratio helper assumes a length already valid for the master; integer division silently changes the audible span when that assumption fails.
- Fix: validate a recoverable take against the target/current clock before committing either the mode transition or restoration. Preserve the saved audio and history when the operation cannot fit; never pass an incompatible length into the multiple/divisor helper. The policy for when to refuse recovery versus the mode change needs the owning task's product decision. Cover both clear undo and base-take redo, including a retained sibling.
- Verification before the approved recovery-policy fix: the temporary harness `/tmp/segno-mode-review-repro.c` includes existing native helpers and uses only public operations to establish the scenario; it does not mutate engine state. `/tmp/segno-mode-review-repro.sh` compiles against the native runner's source list. `/tmp/segno-mode-review-repro.log` and `/tmp/segno-mode-review-repro-after.log` reproduce the 750-frame take reaching only position 499.
- Approved-policy resolution: a new read-only native history gate rejects incompatible recovery before consuming a slot or changing history/mutes. The independently compiled `/tmp/segno-recovery-policy-review.c` observes query and Undo returning `-7`, the restore point surviving, and the track remaining EMPTY against the unchanged 500-frame master. Choosing Free and waiting for its callback allows the same Undo; playback then reaches position 749. `/tmp/segno-recovery-policy-review.log` retains that evidence. The original truncation finding is closed.

## Resolved finding — Recheck span compatibility on the callback before clock conversion

- Location: `packages/segno_engine/src/core/engine_process.c:304` (`le_looper_mode_switch_blocked`) and the `LE_CMD_SET_LOOPER_MODE` dispatch.
- Scenario: Free contains stopped 500-frame and 1,500-frame takes, with track 0 crowned. Queue `crownPrimary(1)` followed immediately by Sync. The control gate and setter both succeed using the still-published 500-frame primary. The callback applies the queued crown first, then switches against the 1,500-frame primary. It assigns the unchanged 500-frame track `sync_divisor=2`, which represents 750 frames rather than 500.
- Cause: the callback rechecks capture/arm/playback state but omits the span predicate. The chosen primary can change earlier in the same command FIFO without changing those states. This is reachable through ordinary typed public calls, with no ring injection or test-only field mutation.
- Fix: check the target mode's span rule on callback-owned lengths and primary before changing the mode or clocks. Refuse the stale transition and preserve the current mode; keep the control-side gate for immediate user feedback. Add the queued-crown regression for Sync/Band.
- Resolution: the native author added the shared pure `le_mode_span_fits` predicate and made the callback select the actual target base and verify actual spans before clock conversion. The added native regression checks refusal for 500/1,500-frame takes and acceptance for 500/1,000-frame takes in both Sync and Band, along with unchanged PCM and track state.
- Independent recheck: rebuilt the same temporary harness against the final hashes above. `/tmp/segno-mode-review-repro-after.log` reports mode Free, crown 1, master 0, unchanged 500/1,500-frame lengths, and both divisors 0 after the queued-crown request. The fabricated half-span no longer occurs. The new predicate is bounded, allocation-free and reused by control and callback. This finding is closed and excluded from the returned active findings.

## Unnecessary complexity, reuse and efficiency

No additional actionable simplification was verified.

- The shared `requestLooperModeChange` removes the obsolete clear/wait/timeout implementation from both mode-selection callers. Its post-confirmation gate read is necessary because the pedal can change capture state while the dialog is open.
- `apply_undo_to_empty` consolidates the existing callback reset and preserves the generation/acknowledgement distinction that a generic destructive clear would break.
- `clearRestorePending` and `redoReclears` expose native history facts that repository grouping cannot safely infer from a stale projected track. Their production implementations, public interfaces, exports, mocks/fakes, and generated bindings agree.
- Confirmed, pending and restored clear groups, plus parked undo taps, describe distinct reachable recovery states. In particular, removing pending membership loses a capturing group member, while treating its point as confirmed restores stale effects for a void capture. No smaller replacement preserving these behaviors was established.
- The pending length/master, frozen generation, cancel and punch-out latches serve demonstrated command/event timing windows. They are not speculative backward-compatibility paths.
- The new callback work uses existing bounded track/lane iteration, clock helpers and fixed-capacity rings. No new allocation, lock, blocking call or I/O was found in those callback changes. Control-side history retention remains necessary to keep restored audio alive.
- Investigated discarded event-ring push results. Typed recovery operations first drain events; outstanding layer slots and one pending recovery per track bound traffic between drains. No ordinary-call sequence producing 255 queued reports was verified. Manually injecting internal events/commands would bypass the ownership contract and is not evidence for an additional production finding.
- The dialog's two intrinsic-width buttons are a bounded layout cost introduced to accommodate the longer confirmation labels; no material efficiency issue was verified.

## Code to remove and YAGNI

No verified code-removal recommendation. Estimated removable production lines: 0. No documentation removal is proposed. The added recovery state is warranted by current behavior and should not be replaced by compatibility paths or speculative abstractions.

## Approved recovery-policy follow-up

The user-approved policy preserves the entire current session and recoverable history on a mode mismatch, explains how to choose Free and retry, and never changes mode automatically. Reviewed native guards and query, clock/Clear acknowledgements, Dart bridge and result mapping, whole-group preflight, parked grouped undo, refusal events, shared App toast, localization and focused tests.

This completed follow-up supersedes the pending native/recovery findings from the earlier review rounds. Final examined blobs:

| File | Git blob hash |
| --- | --- |
| `packages/looper_repository/lib/src/looper_repository.dart` | `328a82a050dfa0126af33b22b992f166a03a0954` |
| `lib/app/view/app.dart` | `7105dfaca2b407c32c9f8af0953b241932c0f5bf` |
| `packages/segno_engine/src/core/engine_commands.c` | `8d9948ae1a2fa1ef3c3a299dafa6f2993719c34f` |
| `packages/segno_engine/src/core/engine_core.h` | `0188150fbd56b9fe8cdac7388161263a36fe6bf3` |
| `packages/segno_engine/src/core/engine_process.c` | `363530bd454ca6e78bee62a35e635947ec38ee80` |
| `packages/segno_engine/src/core/engine_private.h` | `55e6ef7f7f9568465a43a593fbaa7f8f07145d67` |
| `packages/segno_engine/src/core/segno_engine_api.h` | `8161f046eca9f188e39f65e4ea3f525394319a05` |
| `packages/segno_engine/lib/src/audio_engine.dart` | `9eaa3d48b065e2b43af34e1e4b4ee8f26dfd3994` |
| `packages/segno_engine/lib/src/native_audio_engine.dart` | `1ff21bf5f8fb1b889739791c9dfc9660d54c5a03` |
| `packages/segno_engine/lib/src/generated/segno_engine_bindings.dart` | `f911806e2388db092cb320df7c8666c9ace87a3e` |

### Resolved — Do not let a grouped re-clear fence its next member

- Location at discovery: `packages/looper_repository/lib/src/looper_repository.dart:1866` and `packages/segno_engine/src/core/engine_commands.c:1342`.
- Scenario: Clear All two completed takes, undo the group, then Redo. Whole-mask preflight succeeds. The first per-track redo posts CLEAR. The next per-track preflight sees that earlier CLEAR awaiting its acknowledgement and returns `notReady`, leaving only the first member cleared while the toast claims the session is unchanged.
- Independent verification: `/tmp/segno-recovery-policy-review.log` reports group gate `0`, first member gate `0`, first redo `0`, second gate `-8`; after a callback the first member is EMPTY and the second PLAYING. This follows the repository's actual query/redo ordering, using only typed public native calls.
- Resolution: native preflight now distinguishes edits that can introduce a recovered span from re-clears and same-span layer edits. Only span-adding recovery needs the pending-clock fence; selected unknown frozen/cancel reports still wait. The change is a bounded pre-scan, without a repository bypass flag or extra policy layer. Reviewed the synchronous group regression and the regression preserving a fence before an unrelated last CLEAR could change the restore base.
- Independent recheck against `engine_commands.c` blob `9b395a4969f3aaee05f7b98d686852c893e4401e`: `/tmp/segno-recovery-policy-review-after.log` reports group/first/second gates all `0`, and both tracks EMPTY after the synchronous query/redo sequence. The same binary also verifies the original incompatible recovery stays refused, an explicit Free retry plays all 750 frames, and `test_undo_during_later_take_keeps_the_span` passes. This finding is closed.

### VGV, architecture and bridge audit

- Applied the architecture and VGV review roles to the final follow-up, including package manifests, lint configuration and the documented Flutter/Bloc → repository → FFI data boundaries. No package dependency, new package, reverse dependency or circular dependency was introduced.
- Presentation remains above the repository boundary. `RecoveryRefusal` carries the requested action and a domain result; no presentation widget imports a native data client. All surfaces share the repository refusal event and existing App toast path.
- Repository mutation ordering protects recovery metadata: a failed native redo preserves remembered mutes and chains; successful re-clear snapshots/drops them; successful clear undo restores them. Whole-group preflight and ascending execution match the native projection order. Frozen groups wait as a group before preflight, and void members are removed without restoring stale effects.
- The broadcast refusal stream is closed with the repository; App subscribes once and cancels its subscription/dismisses its toast on disposal. Repeated refusals replace the named toast. The message does not navigate or switch modes. The Spanish message was corrected to use the actual visible mode label, Free.
- Independently reviewed the bridge author's `AudioEngine` interface, `NativeAudioEngine`, `MockAudioEngine`, every changed fake, generated bindings, `EngineResult` decoding and related tests. The C `uint32_t` mask and `int32_t` direction match generated FFI types. `NativeAudioEngine` checks handle lifetime before calling the binding. Native results `-7` and `-8` map separately; no fallback swallows these outcomes. Exports expose the existing interfaces without a new dependency layer.
- The native preflight is read-only, has bounded stack storage, and does not drain events or perform a speculative queued recovery. Clock acknowledgements distinguish accepted commands from completed callback policy. No added callback allocation, lock, blocking or I/O was found.
- Independent focused bridge tests: `engine_result_test.dart` and `mock_audio_engine_test.dart`, **67 passed**, `/tmp/segno-recovery-bridge-unit-review.log`. Real FFI history tests: **4 passed**, `/tmp/segno-recovery-bridge-ffi-review.log`, against the rebuilt test library with SHA-256 `9fe798b4ad2360a59df4e44d1425a2d653608c3cb388659f62d0af7f46e2736d`. This exercises masks, direction, mismatch retention, explicit Free recovery, pending mode acknowledgement, and disposed-handle rejection. No skipped native tests are counted as executed verification.
- Independent focused App refusal tests: **3 passed**, `/tmp/segno-recovery-ui-review.log`, covering Undo/Redo explanations, retained Tracks view and mode, dismissal, replacement of a pending explanation, and timeout.
- Final real-FFI recheck: the four history bridge tests plus the independently authored cancellation regression **all passed (5 tests)**, `/tmp/segno-recovery-ffi-final-review.log`. The library SHA-256 was independently checked as `afeaa61afbdfc8cb4a020ea5395a52770cd64875bd7a8f41675f7c7a5a5a178b`. The temporary Dart regression had failed against the earlier library, so this is a demonstrated regression check rather than a new assertion that only mirrors the fix.
- No additional actionable VGV, architecture or simplicity findings were verified. The gate and recovery bookkeeping serve the approved behavior; no speculative abstraction or compatibility layer is recommended.

### Resolved — Wait for an unselected canceled take to establish its clock

- Location: `packages/segno_engine/src/core/engine_commands.c`, history gate's shared-master capture check.
- Public-call scenario: record 750 frames on track 1 in Free, undo it to empty, switch to Multi, start track 0 and capture 500 frames, then Undo track 0 and Redo track 1 before the next callback. The pending cancel makes track 0's effective state EMPTY, while its callback will still finalize and establish a 500-frame master. Because the gate checks `cancel_pending` only on selected tracks, it accepts track 1's 750-frame recovery against an assumed new master. The callback then plays that take at `multiple=1` against 500 frames.
- Independent evidence: `/tmp/segno-recovery-policy-defining-review.log` reports the sibling recovery gate and redo both `0`, followed by `master=500`, `recovered_len=750`, `multiple=1`. The `/tmp/segno-recovery-policy-review.c` harness uses typed public calls only. Other scenarios in that same run continue to pass.
- Resolution: before a shared-mode recovery adds a span, the native gate now waits for any sibling `cancel_pending`. Independent modes retain their own clock behavior. The saved recovery remains untouched while cancellation settles, then the actual finalized master determines fit.
- Independent final evidence: `/tmp/segno-recovery-policy-final-review.log` shows gate and redo both `-8`, master 500 after the cancellation, and the 750-frame take still EMPTY. The same independently authored scenario also passed through the final Dart/FFI library: `/tmp/segno_cancel_recovery_review_test.dart` verifies `notReady` before the callback, `modeMismatch` after the normal snapshot drains the cancel report, unchanged retained redo, then exact 750-frame PCM recovery following explicit Free selection. See `/tmp/segno-recovery-ffi-final-review.log`. This finding is closed.
- Related reviewed repair: queued defining RECORD uses the existing clock-command acknowledgement; active/armed/count-in capture is fenced, and finalization release-publishes state after its master/length writes. `le_effective_state` acquires that state before the gate reads finalized lengths. Together these cover queued, active, finalizing and canceled defining-take clock windows without callback allocation or blocking.
- Removed-behavior recheck: the old frozen-clear branch in `le_apply_queued_undo` and its forward declaration were removed. Native frozen/cancel recovery now returns `notReady`; repository parked requests own the wait, and a clear already clears native queued taps. The deleted branch is therefore obsolete, not a lost recovery path. In-flight same-span overdub undo still uses the existing native queue.

## Final assessment

The callback race, direct history truncation, grouped Redo interaction, and pending-cancellation clock interaction are independently verified fixed. The approved recovery-policy follow-up is complete, including independent bridge, VGV and architecture review. Active findings: **Critical 0, Important 0, Suggestion 0**. No further simplification is recommended. Local tests and review do not claim CI or appliance validation.
