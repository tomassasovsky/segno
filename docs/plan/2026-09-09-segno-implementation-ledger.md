# Segno implementation ledger

Running record for the accepted-design implementation programme (epic #1009,
design under #919). One section per slice; each carries decisions, changed
ownership, the checks actually run and their results, unresolved findings,
true blockers and the exact next step. Later entries supersede earlier ones.

## Slice 1 — Tracks view, selected-track display, first-take crown (#1010)

Branch: `claude/segno-app-implementation-7c90a8`.

### Decisions

- **Crown ownership stays native.** `a_primary_track` remains the engine's
  designation. The engine now crowns the first track that completes a take
  while nothing is crowned, and clears the crown when every track is empty.
  Explicit `le_engine_crown_primary` remains the timing handoff. The
  designation still survives clearing the primary while siblings hold audio
  (D18's re-record rule for Sync/Band); the repository projects the crown the
  screens draw as "the designation if it has content, else the lowest track
  with content, else none", which is the prototype's `SegnoPrimaryTrack.current`.
- **The crown is a readout.** The Sync/Band-only tappable badge is gone from
  the Tracks view. Handoff moves to Loop settings in slice 2.
- **Per-track play position and output peak join the snapshot** as trailing
  fields so the bottom progress bars, the 7" playhead and the footer output
  level read real owners instead of the master position.
- **No CPU readout yet.** The pen draws `CPU 18%`; the only honest source is
  the callback telemetry, which is a whole-session mean kept out of the
  render-rate snapshot on purpose (#722). A live load figure is engine work
  and is deferred; the top bar omits the readout rather than faking it.
- **Mode pill and bank pair leave the main bar.** The accepted top bar has
  Library, session name, bank, view menu and Settings. Function · bank moves
  to the 7" footer as the design draws it.
- **Mixer view deferred to slice 3.** It needs pan, solo and stereo metering
  the engine does not have. The view menu offers Track and Wave.
- **7" volume overlay retired.** The accepted small display is a readout; the
  MIX pill and its control back-channel go with it. Track level stays
  adjustable from the Signal tray and by controllers until the Mixer view lands.

### Changed ownership

- Engine: `le_track.a_play_pos`, `le_engine.a_out_peak_bits`, primary
  reconcile after every content change.
- Repository: crown projected from the snapshot (resolved), not from the
  re-apply cache; a crown is pushed once at the next start and never
  re-applied after a restart (the reconfigured rig is empty and uncrowned).
- Presentation: new Tracks layout, view menu, footer; second display shows
  the selected track.

### Checks (2026-09-09, this Mac)

- `bash packages/segno_engine/src/test/run_native_tests.sh`: 5 suites ALL
  PASSED, including the seven new crown/position/output-peak tests and the
  rewritten Sync premise test (`test_sync_first_completed_take_becomes_primary`).
- `dart run ffigen` + `dart format` on the bindings: field-scoped diff plus
  the ASIO doc drift the committed bindings had already fallen behind on.
- `flutter test` in `packages/segno_engine`: 242 passed; `packages/looper_repository`:
  395 passed (crown resolution, cache-follows-engine, position/outputPeak).
- App: `dart analyze lib test` clean; `bloc lint lib test packages` 0 issues
  over 607 files; `test/looper/view/tracks_view_test.dart` +
  `test/app/view/app_test.dart` 114 passed; visualizer, theme, meter, cubit and
  common suites green; cspell clean on this ledger.
- macOS development build launched from the branch: Track view drawn as the
  accepted design at the desktop window size, a defining take on GUITAR
  crowned it, a later take on BOOM left the crown in place, the footer
  derived the tempo and ran the clock, and the view menu switched to Wave.
  Silent input means no meter fill was visible; colour states are covered by
  the widget tests.

### Unresolved findings / not verified here

- The second display: this Mac has one display, so the app skipped the
  7-inch window (the existing single-display notice). The selected-track face
  is covered by `test/visualizer/console_readout_view_test.dart` and the
  window wiring by `app_test.dart`; it has not been seen on the appliance.
- Appliance display sizes, touch, pedal LEDs and real audio were not
  exercised on hardware.
- Desktop windows narrower than the pen shrink the readout rows uniformly
  (`ShrinkToWidth`) instead of overflowing; the pen size renders 1:1.

### Review round 1 (2026-09-09, PR #1011)

The code review reported ten findings; all ten are fixed on the branch:

- Engine: `le_engine_configure` now drops the crown with the tracks it
  empties; a non-defining `finalize_new_track` reconciles the crown too; the
  snapshot publishes what an arm waits for (`pending_trigger`: grid / sound /
  section) so the queued cue reads the engine's own fact instead of the
  settings, and names the punch-out and section boundaries correctly.
- Repository: `Track.pendingTrigger`, `Track.layers`; `progress` reads 0
  while a take records (the write head is both position and length then).
- Stage: the footer counts a count-in down in place of the signature; the
  clip cap retires on a timer instead of on the next rebuild; the wave rows
  and the second display read a track's waveform once per content change,
  not once per playhead tick (superseded in round 2 below); the bar ruler
  paints in its own layer so the playhead never re-shapes its labels; the
  readout gate no longer reopens on a growing take, and a cursor move
  between equally named tracks still reaches the second display.
- Dead chrome state (`anyActive`, transport enables) removed.

### Review round 2 (2026-09-09, re-review of the round-1 commit)

A second review of the fix commit found that the waveform cache was wrong:
the engine's per-track visual buffer is a lazily swept tap (each bucket is
rewritten as the playhead leaves it; nothing is written during a defining
take, and a recording track contributes zeros), so a copy keyed on the
track's steady facts froze a flat or stale shape after a take, an undo or a
stop. Fixed:

- The copy now lives in `LooperRepository.readTrackWaveform` (one place, both
  consumers): it re-reads on every call until the playhead has swept a full
  lap past a content change (that call included), on every call while
  capturing, once per lap at the wrap while the track moves, and never while
  the track stands still. A session load drops every copy. The stage row and
  the second display read the repository on each rebuild again.
- A queued take-end reads Play (or Overdub under rec/dub, which the
  repository now projects as `TransportState.recDub`) instead of Overdub.
- The arm's `a_pending` store is a release, the snapshot's load an acquire,
  so a fresh arm is never paired with the previous arm's trigger.
- The bar ruler layer sits over the wave again (its lines stay visible
  across the bars); the footer count-in reuses `countingInLabel`; the clip
  cap's state is the timer itself; a view test the round-1 commit had split
  in two is whole again.

### Review round 3 (2026-09-09, re-review of the round-2 commit)

- The sweep is now measured on the clock the engine buckets the tap on: the
  master loop in Multi, Sync and Band, the track's own loop in Free and
  Song. A track's own progress was the wrong lap for a multiple (its buffer
  holds whichever base lap is sounding and is rewritten every master lap)
  and for a Sync division (a fraction of a master lap, so the sweep was
  declared done early).
- Copies of tracks that lose their content are dropped on every projection,
  so a take recorded or restored later under the same steady facts starts
  its own sweep instead of inheriting a finished one.
- `setRecDub` re-projects, so the queued take-end cue reads the new setting
  on the next frame; the ruler test asserts the layer order.

Accepted as is: a rec/dub take-end whose track had a mute deferred during
the take lands playing, not overdubbing (the UI has no pending-mute fact);
wrap detection needs at least one read per half lap, which the visible
stage and the second display's per-poll push provide.
Also accepted: `Track.pending` and `Track.pendingTrigger` are two fields
for one fact (the wire guarantees `pending == (pendingTrigger != null)`; the
fixtures would all move for a getter), and the overdub punch-out boundary
rule (D8) is named in the view rather than published by the engine.

### Next step

Slice 2 (`implementation-map.md`), tracked as #1012 in three parts: 2a
reversible audio edits and mode rules, 2b timing ownership, 2c the Loop
settings surfaces (the explicit crown handoff lands there; the
`LooperCrownPrimaryPressed` event and `crownPrimary` API are kept for it).

## Slice 2a — Reversible audio edits and mode rules (#1012)

Branch: `claude/segno-slice2-edits-1012`, stacked on slice 1's branch until
PR #1011 merges.

### Decisions

- Mode changes with recorded audio follow the accepted contract
  (`2026-09-07-loop-mode-transitions-ux.md`): the engine measures what a
  change would do (`le_engine_looper_mode_gate`: open, capturing, queued,
  spans, playing). Multi needs equal spans; Sync and Band need whole multiples
  of the primary or the divisions the engine plays (a half or a quarter);
  Song and Free take anything. A playing rig is stopped ahead of the switch
  by the engine itself (`le_engine_set_looper_mode` posts the stops in ring
  order), so the switch always lands on a stopped rig; the app asks "Stop
  loops and switch" before calling. Captures, queued arms and unfit spans
  refuse with their reason. No take is trimmed, repeated, stretched or
  padded, and nothing is cleared for a switch: the old clear-then-switch
  flow is gone with its strings.
- Landing a switch re-clocks the takes: into Song/Free each take runs its own
  clock at its length and the master goes dormant; into Multi/Sync/Band the
  master is re-established from the primary's span and each take's multiple
  or division is re-derived from its unchanged length.
- Undo during an overdub pass punches out now (not at the grid) and peels the
  pass once it retires; redo puts the partial pass back without resuming the
  capture. A pass that wrote nothing peels the previous layer (the brainstorm's
  recommendation for the exact-boundary case).
- Undo during a take cancels it: the take is finalized at its captured length
  exactly as a press would end it (a defining take still establishes the grid
  and derives the tempo), the track reads empty, and redo plays the take
  immediately (`LE_CMD_CANCEL_TAKE` / `LE_EVT_TAKE_CANCELLED`). A later take
  keeps its whole-loop span with silence outside what was captured; the seam
  crossfade is skipped for a cancelled take.
- A user clear on a capturing track freezes the take stopped at the clear and
  keeps it restorable (`LE_EVT_CLEAR_FROZEN` completes the restore point once
  the finalize has decided the length); undo brings it back stopped, never as
  a resumed capture. Clear All is one grouped edit in the repository
  (`clearAll`, `undoRestoresClearAll`, `undoClearAll`): the next undo on any
  member restores every member, the next redo re-clears the group (each
  member's next redo must be that re-clear, `le_engine_redo_reclears`); while
  a member has lost its restore point (a fresh take) the group stands down
  and the per-track history answers — nothing newer is overwritten. The
  frozen-capture and cancelled-arm treatment implements the capture-recovery
  proposal (`2026-09-08-capture-recovery-ux.md`, accepted for the established
  Multi cycle; the Clear All cases are the proposal's own choices), which the
  handoff contract lists under the settled history rules.
- The Undo pedal and key reach the group through the ordinary `undo`, so a
  performer who clears everything and taps Undo gets the rig back.
- The remembered looper mode (re-applied on start, persisted in settings)
  follows what the engine reports, not what was asked: a switch the gate let
  through can still be dropped on the audio thread when a record press lands
  in the same block, and that drop is silent to the caller.
- Review round 1 (same day): a cancelled take that captured nothing
  acknowledges its state command once; the cancel's control side no longer pre-zeroes the
  published length (the audio thread may decline a cancel that races a
  finalize); a late cancel report is ignored after a clear or a fresh take;
  an undo queued behind a freezing clear restores the frozen take instead of
  peeling a layer; a freezing clear on a take with nothing captured keeps
  nothing; Multi's gate measures whole multiples of the shortest take (what
  Multi itself records), Sync/Band the primary's multiples and divisions;
  the switch into a shared-clock mode re-establishes the tempo grid.
- Review round 2 (same day, on the round-1 fixes): a record pressed behind
  a cancel in flight resets the grid the cancel would have set, so it
  defines its own; an undo tapped behind a freezing clear on a recording
  take waits for the restore point (queued taps wait while the point is
  pending); a clear right behind a queued restore measures the length the
  restore will publish (`le_effective_len`) and keeps a restore point; a
  declined or void cancel still reports, so the cancel flag never lingers;
  an empty track never shows peelable layers on the wire (the depth is held
  at 0 while a frozen point is pending or a restore is in flight, and
  republished by the drain once the audio thread applied it — the fuzz
  suite's depths-sane invariant); the frozen take's layers go with its
  pending point when a fresh capture records over it. The repository takes
  group membership from the engine (`le_engine_clear_restore_pending`
  beside `undo_restores_clear`), ends a group when the engine retired a
  member's point or a single clear happens, and drops a mode request the
  reports never confirm (two polls) in favour of the reported mode.
- Review round 3 (same day, on the round-2 fixes): a clear right behind a
  queued restore records the master grid that restore re-establishes
  (`pending_master_len`), not the wire's 0, so its own restore brings the
  grid back; a cancel of a take that captured nothing empties the track
  without the clear handler's layer-generation bump (which only a
  control-side clear matches — a mismatch dropped every later retired layer
  on that track); the count-in grace abort had the same pre-existing bump
  and takes the same path now; the repository keeps unconfirmed frozen
  members apart from the group and drops one whose capture held nothing
  instead of ending the group; the restart replay of the looper mode is
  armed as a request so the first report after a start cannot overwrite the
  remembered mode; only polls count as reports. Accepted as is: a second
  undo tap queued behind a freezing clear is a no-op once the first restores
  (as after an undo-to-empty), documented at the apply site.
- The fuzz suite (`flutter test --tags fuzz`) and
  `pumped_native_engine_test` were run against a locally built engine
  library; `tool/build_test_lib.sh` itself does not build on this Mac (it
  lacks the rnnoise include and source list the native test script has), so
  the library was built by hand with that list.

### Changed ownership

- Engine: `le_engine_looper_mode_gate`, content rules in
  `le_engine_set_looper_mode`, `le_apply_mode_switch` on the audio thread
  (the D4 content lock is gone), `LE_CMD_CANCEL_TAKE`,
  `LE_EVT_TAKE_CANCELLED`, `LE_EVT_CLEAR_FROZEN`, a freezing clear
  (`LE_CMD_CLEAR` arg_f 1), undo during capture.
- Dart engine: `LooperModeGate`, `LooperModeControl.looperModeGate`.
- Repository: `looperModeGate`, `setLooperMode` keeps the remembered mode only
  when the engine took the change, `clearAll` and the grouped undo/redo.
- App: `requestLooperModeChange` drives the gate (dialog for playing,
  refusal reason otherwise); `ControlCubit.clearAll` is one grouped edit;
  `LooperModeChanged` persists only accepted changes; the console confirm
  dialog wraps long button labels.

### Checks

- Native: `run_native_tests.sh` 5 suites ALL PASSED, also with
  `-fsanitize=address` and `-DLE_CALLBACK_TELEMETRY=0`; 22 new or rewritten
  tests (mode gate spans/multiples/divisions/queued/capturing/playing,
  Song/Free re-clocking, undo during overdub, undo during a defining and a
  later take, clear during recording and overdubbing, the cancel and freeze
  races, `redo_reclears`, the round-2 one-block races).
- `segno_engine` 242, `looper_repository` 414, `performance_repository` 111,
  `session_repository` 84 tests passed; root suite and coverage recorded in
  the PR; analyzers clean in every touched package; `bloc lint` clean.

### Not verified here

- Hardware timing of stop-and-switch and of the cancelled take on the
  appliance; the accepted mode cards with per-card reasons are slice 2c (this
  part surfaces the reason in a snackbar from the existing chooser).
- A rec/dub take-end during a count-in and the zero-audio cancelled take are
  handled (nothing to redo), not separately exercised on hardware.

### Next step

Slice 2b: per-track record timing (Immediately / Loop start / grid) and
overdub decay inheriting from defaults, Loop/Once in every mode, count-in and
Sound start exclusivity at the engine boundary.
