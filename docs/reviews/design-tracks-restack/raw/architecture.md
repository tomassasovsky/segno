<!-- cspell:ignore lproj -->

## Architecture Review

Reviewed the reconstructed Tracks slice in the isolated review checkout against `origin/master` / `848f1337251989f849c7851f72b6126b5c1712ea`, including staged and working changes. The follow-up review on 2026-09-15 inspected the three original fixes, new App/domain/native/FFI tests, the subsequent compact Wave layout fix, and the final readout-field removal in the four files identified by the coordinator. This evidence concerns the reconstructed earlier slice, not the later integration tip. The coordinator owns implementation and validation execution; this reviewer changed only this report, made no Git changes, and did not touch the dirty owner checkout.

Read the checkout's `AGENTS.md`, the supplied owner instructions, `docs/PROGRESS.md` build and architecture sections, `docs/TRACKING.md`, the architecture role and review reporting instructions, and the accepted slice's implementation ledger. Stack: Flutter/Dart, Bloc/Cubit, repository packages, and a C engine reached through Dart FFI. The configured lints include Very Good Analysis and Bloc lint.

### Layer Separation

- New import/dependency violations found: 0.
- Checked the changed production imports and package manifests. The track state and new snapshot facts flow from the native engine through `segno_engine` and `LooperRepository`, with presentation actions dispatched through the existing blocs/cubits. The `AudioEngine` seam remains intact.
- `TrackWaveform` and the app window bridge obtain waveform data through the repository; neither imports the native client or touches native memory. No repository or data package gains a presentation dependency.
- Existing composition-root brightness-client wiring was retained, not introduced by this slice. The existing accepted queue-boundary presentation policy and deferred control surfaces are not re-litigated here.

### State Management Assessment

- `TracksCubit`: the stage-view selection is a local presentation preference; immutable state and existing load/disposal ownership are preserved.
- Track selectors: live peak and play position remain in complete domain equality and are excluded from `steadyProps`, preserving the per-leaf rebuild split. The shared cursor remains owned by `ControlCubit`.
- Window bridge: the new cursor identity check handles equally named tracks; frame/readout acknowledgements still invalidate on readiness and errors; timers and subscriptions are cancelled on teardown. Removed control-channel APIs have no remaining implementation callers in the reviewed tree.
- `PeakMeterBar`: the clip timer is cancelled on disposal and is not restarted by its own expiry rebuild.
- `LooperRepository`: the native visual and repository sweep now use the same track coordinate. The cache retains its content/history/state key, drops empty tracks during projection, and clears on session replacement. Capture refreshes continue; stable playback refreshes after a complete sweep and on subsequent track wraps.
- `Track.wholeBars`: the shared domain projection depends only on the sibling transport model, with no presentation dependency or cycle. Both displays consume it; the App gate compares the projected result, keeping recording growth out while forwarding changes to visible completed-track bars.

### Original Findings — All Resolved

The following descriptions preserve the original reviewed failures and locations. The resolution paragraphs describe the current implementation and discriminating regression coverage; these are not open findings.

#### Match waveform samples to each track's playhead — resolved

Location: `lib/looper/view/wave_track_row.dart:300-310`; duplicate consumer at `lib/app/view/app.dart:839-844`.

The new views combine `readTrackWaveform(channel)` with `Track.progress`. The latter is `positionFrames / lengthFrames` over the track's entire take. However, `viz_tap_frame` still writes every `a_track_viz` buffer using `masterPosition / masterLength` (`packages/segno_engine/src/core/engine_process.c:3133-3141`). A 2× take therefore has a waveform representing one base-loop segment spread across the full width, with a playhead moving at half that scale; a Sync division produces repeated short loops across the waveform while its playhead wraps within each short loop. The cached wrap policy cannot repair different coordinate systems. The selected-track display and Wave rows do not identify the audio beneath their playheads.

Fix: publish each track's waveform against the same resolved track position and finalized length that the snapshot publishes, retaining the mixed output's separate master-loop tap. Make the repository's sweep use that same track clock. Cover distinct first/second-segment peaks on a multiple and a Sync division so the test proves waveform/playhead alignment, not merely read-call counts.

Resolution: `track_viz_tap_frame` now indexes the buffer with `trk_play_pos / lanes[0].a_len` at `packages/segno_engine/src/core/engine_process.c:3159`. It runs after the mixer resolves the full read coordinate and before transport advance at line 4822; the snapshot publishes that same last-frame coordinate at line 4872. Mixed output remains master-indexed. The repository now uses `track.progress` at `packages/looper_repository/lib/src/looper_repository.dart:2452` for sweep completion. Native tests check different first/second-segment values on a multiple, distinct halves of a Sync division, and independent Free/Song positions and values. Repository tests distinguish a full track lap from master wraps. These assertions would fail under the original coordinate mismatch.

#### Retain waveform content for tracks first viewed after stopping — resolved

Location: `packages/looper_repository/lib/src/looper_repository.dart:2462-2466`.

The cache is populated only when a UI consumer asks for a track. In the current native implementation, a stopped track contributes zero `frame_trk_peak`, and the master tap continues replacing its buckets while a sibling plays. Record and play track B without displaying its waveform, stop B while A continues, wait one A loop, then select B on the small display or open Wave view: the first cache read receives only zeros and retains them because B is stopped. A cached track can suffer the same failure if it changes to stopped while off-screen: `_WaveformKey.state` forces a replacement read when it is next viewed. The retained take then looks empty until it plays again.

Fix: retain the native per-track visual buffer while the track is stopped, independent of whether a view previously subscribed. Clear/reset its visual buckets and accumulators when content is discarded or replaced so an empty/new take cannot inherit the retained image. Cover a stop with a running sibling followed by the first waveform read after a complete sibling lap.

Resolution: the per-track tap skips states other than playing/overdubbing at `packages/segno_engine/src/core/engine_process.c:3163`. A running sibling can no longer erase a stopped track before its first UI read, and stopped play positions remain held. The audio-thread `reset_track_viz` helper at line 618 clears published buckets and local accumulators/cursors on void finalization, explicit clear, and undo-to-empty; configure retains its reset. Reset remains track-scoped. `test_track_visual_retained_until_content_removed` at `packages/segno_engine/src/test/test_engine_core.c:4476` records distinct tracks, stops one while a sibling runs several laps, compares the retained waveform byte-for-byte and checks its position, then covers clear, undo-to-empty, and redo playback. Recording before a finalized duration still develops its image during playback, matching the accepted lazy-waveform contract.

#### Derive bar counts from each track's actual duration — resolved

Location: `lib/looper/view/tracks_view.dart:397-398`; duplicated at `lib/app/view/app.dart:1022-1024`.

Both surfaces calculate track bars as `transport.loopBars * track.multiple`. A Sync/Band half or quarter take deliberately has `multiple == 1` and `syncDivisor > 0`; its native length is `base / divisor` (`packages/segno_engine/src/core/engine_process.c:1053-1056`). Under a four-bar primary, a two-bar half-length take is consequently labeled and ruled as four bars. Free/Song tracks can likewise have their own tempo-related durations while the master has no loop-bar count. This calculation duplicates a timing assumption in two presentation consumers rather than using the authoritative track duration.

Fix: provide a shared domain projection of track duration into bars using the applicable frame length and grid/tempo/signature facts, including valid division and independent-clock cases. Consume that projection on both displays and include its inputs in the readout change gate. Add assertions for a four-bar primary with half/quarter tracks and the independent-clock policy.

Resolution: `Track.wholeBars` at `packages/looper_repository/lib/src/models/track.dart:199` projects actual finalized frames through the established master grid, or sample rate/tempo/signature when no established grid exists. It permits one frame of rounding and omits unknown/fractional counts and recording growth. Engine tempo-grid documentation confirms BPM uses denominator-note units, consistent with the fallback calculation. Both display consumers use the helper. `_sameReadoutFacts` compares the result at `lib/app/view/app.dart:976`, so duration/grid/tempo/signature/sample-rate changes reach the readout. Domain tests cover divisions, multiples, independent clocks, 7/8, grid precedence, invalid timing, and rounding. View tests assert displayed and ruler bars, changed timing inputs, and rebuild scope. App tests independently check duration/grid and fallback timing changes reach the selected readout.

### Compact Wave Layout — Introduced by This Slice, Now Resolved

The initial 800×600 overflow was a reachable desktop bug introduced by the first design slice. Master has no `WaveTrackRow`; the original `ec3e25f0` version has the same unscaled information column as the initially restacked version. `TracksView` divides its remaining height among Wave rows after fixed chrome and 22-pixel gaps, while each row reserves 24-pixel top/bottom padding. With three rows and the disconnected banner, the information column can exceed its row height; four rows are more constrained.

This is not proof of an appliance-size failure, but it is within the retained desktop development path. `macos/Runner/Base.lproj/MainMenu.xib:335` starts the resizable window at 800×600, `MainFlutterWindow.swift` preserves that frame, and window setup does not resize macOS. `shouldFullscreenMainWindow` only fullscreens on at least two displays. Raising the bar-projection test to 1920×1080 alone did not remedy this path.

The current fix wraps the finite-width information block in `FittedBox(fit: BoxFit.scaleDown)` at `lib/looper/view/wave_track_row.dart:131`. It can shrink to a short row without overflowing and leaves the large-screen geometry unscaled when it fits. The new test at `test/looper/view/tracks_view_test.dart:1523` renders four tracks at 800×600 with the disconnected default setup, checks layout exceptions, and taps every row to verify both selection and its record event. The final Tracks view file passed 101 tests, including this regression, in the coordinator's `segno-restack-wave-responsive.txt` log.

### Dependency Direction

- Direction violations introduced: 0; circular package dependencies introduced: 0.
- Clean dependency chain: stage/widgets → blocs and repository-domain API → `LooperRepository` → `AudioEngine`/`segno_engine` → C engine.
- The implemented fixes remain at the existing native waveform publication and domain timing boundaries; no new service or package was introduced.

### Native Ownership and FFI

- New peak and play-position work is bounded; no allocation, blocking I/O, locks, or control-thread buffer ownership transfers were added to the callback.
- Crown reconciliation runs on the audio thread over the bounded track set. Explicit handoff and the accepted resolved-display crown policy preserve their existing owners. Configure, finalize, clear, undo-to-empty, redo, restore, and session-commit call paths were traced.
- `position_frames`, `pending_trigger`, and `output_peak` agree in the C declarations, generated Dart bindings, snapshot projection, and native snapshot reads. No new dynamically loaded entry point was added. `PumpedNativeEngine` forwards the new master peak.
- Added atomics use the existing atomic helpers and existing acquire/release primitives, so the C++ shim does not acquire an unsupported operation from this change.
- The implemented tap runs after the mix resolves `trk_play_pos` and before transport advance, preserves stopped images, and resets per-track visual state on content death. Its local accumulators and resets remain audio-thread-owned; control-side reads load the published atomics. No loop-buffer pointers are exposed or retained. Existing live/retired buffer ownership invariants remain unchanged. The reset adds a bounded 512 atomic stores on a content command, not allocation or blocking work.
- Snapshot tests allocate native structures and verify native-to-Dart field projection, unarmed sentinel handling, equality on position/trigger/peak-only changes, and equal-value hashes. The updated full-track visual documentation is also present in regenerated bindings.
- Removed stage/readout/volume-overlay classes, control payload, channel handler, exports, and callbacks have no remaining implementation references. The persisted indicator preference remains used by lane-cache telemetry; it is not an obsolete compatibility path. Removal of the old volume-overlay control channel leaves no pending listener or command owner behind.
- App tests use distinguishable mixed and per-track sample buffers and unequal track/master phases, covering the real selected payload and empty selection clearing. Existing readiness, failure/retry, and superseded-delivery cases remain present. The remaining window readiness handler and app subscriptions retain their previous lifecycle ownership.

### Package Structure

- `looper_repository` and `segno_engine`: existing manifests, tests, and lint configuration remain; no new package or dependency is introduced.
- New widgets separate stage chrome, track rows, ruler painting, and fast moving leaves without adding a second state owner.
- Test-generated analyzer exclusions were removed before final validation;
  no package analyzer configuration change remains in this slice.

### Final Readout Payload Cleanup — Reviewed

Independently reviewed the final changes in `lib/app/view/app.dart`, `lib/visualizer/performance_readout.dart`, `test/visualizer/performance_readout_test.dart`, and `test/visualizer/console_readout_view_test.dart`. `ReadoutTrack.pending` and `.layers` were unused by the current selected-track display; their constructor, decoder, encoder, equality, projection, and test fixture entries are now removed together. No consumer still reads either property.

The selected-track gate now compares state, mute, and projected whole bars, in addition to the existing transport/crown and other separately owned readout inputs. Removing pending, undo depth, and the redundant content comparison cannot hide a current rendered readout change: state/mute are retained, crown comes from the transport comparison, and content/duration affect the shared bar projection. Waveform delivery has its separate state/progress path. Domain `Track.pending`, `pendingTrigger`, undo history, `layers`, complete equality, and main-stage consumers remain intact. Existing remaining-field wire round-trip and view behavior assertions are retained. No layering, lifecycle, schema parity, or behavioral issue was found in this cleanup.

### Debounce Test Timing Repair — Reviewed

Reviewed `test/looper/bloc/looper_bloc_test.dart:1766` against master. The eight persistence tests now create their bloc inside `fakeAsync`, drain event microtasks before checking immediate writes, and advance the debounce clock explicitly. The configured interval remains 30 milliseconds, and the expiry checks still advance three intervals. All 20 mock verification statements, their arguments, call counts, and order are unchanged.

The tests still verify every engine update during a drag, no persistence before expiry, one eventual write per target, independent lane targets, granular plugin updates without replacing the complete chain, cancellation on session load, flushing on close, and explicit flush events. Assertions run before cleanup, so closing the bloc cannot supply a write that makes an expiry assertion pass. Tests formerly using teardown now close in `finally` and drain close-related microtasks within the same fake clock; the explicit close test keeps its own close operation before its final assertion. The outer source-controller teardown remains present. `LooperBloc` and `WriteDebouncer` production code are unchanged from master. No assertion or cleanup regression was found.

The coordinator's `segno-restack-looper-debounce-fix.log` reports all 104 tests in the file passed. The final root run remains a separate validation gate.

### Validation Evidence and Limits

This reviewer inspected current implementation and test bodies and read the coordinator's resulting logs:

- `segno-restack-native-viz.txt`: all five native suites report `ALL PASSED`, including the new retention regression and updated coordinate assertions.
- `segno-restack-native-asan-isolated.txt` and `segno-restack-native-telemetry-isolated.txt`: all five suites report `ALL PASSED`; no reported AddressSanitizer error appears in the inspected ASAN log.
- `segno-restack-bars-tests.txt`: 119 model/view tests passed before the compact-row test was added.
- `segno-restack-wave-responsive.txt`: the final Tracks view file passed 101 tests, including four-row 800×600 layout and interaction coverage.
- `segno-restack-app-waveform-fix.log`: 37 passed, six explicitly skipped.
- `segno-restack-snapshot-fix.log`: 86 passed.

These runs were executed by the coordinator and test authors, not independently rerun by this reviewer. This report does not claim device validation, visual/golden approval, current-head CI, or completion of the coordinator's remaining aggregate checks. Those gates remain the coordinator's responsibility.

### Verdict

Architecture is clean in the reviewed current content, including the final readout payload cleanup and debounce test timing repair. All three original behavioral findings and the subsequently traced compact-window overflow are resolved. No unresolved actionable architecture or bug-focused ownership/thread/FFI finding remains. The coordinator's final aggregate rerun and merge/device gates remain separate from this completed review.
