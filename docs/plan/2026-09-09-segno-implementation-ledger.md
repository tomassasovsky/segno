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
  paints in its own layer so the playhead never re-shapes its labels; the readout gate no longer
  reopens on a growing take, and a cursor move between equally named tracks
  still reaches the second display.
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

Accepted as is: `Track.pending` and `Track.pendingTrigger` are two fields
for one fact (the wire guarantees `pending == (pendingTrigger != null)`; the
fixtures would all move for a getter), and the overdub punch-out boundary
rule (D8) is named in the view rather than published by the engine.

### Next step

Slice 2 (`implementation-map.md`): per-track record options and the timing
rules, starting with the explicit crown handoff in Loop settings (the
`LooperCrownPrimaryPressed` event and `crownPrimary` API are kept for it).
