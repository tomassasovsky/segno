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
- Review round 4 (same day, on the round-3 fixes): a record pressed on a
  sibling behind a queued restore of the only take read a master of 0 and
  took the defining path; the press now reads the master any pending
  restore re-establishes (`le_rig_effective_master_len`). The repository
  counts a frozen clear-all member as a member from the clear (the engine
  queues the tap and restores the take when its point lands) instead of
  refusing to answer in that window, restores the chains for an undo tapped
  at a frozen clear, and gives a mode request six polls of a running engine
  before dropping it (the ring drains on the audio callback, and a device's
  first callback can come later than two polls). Accepted as is: a frozen
  member retired by a fresh take in that same window leaves the group
  silently, the way a void capture does.
- Review round 5 (same day, on the round-4 fixes): the round-4 native test
  passed without its fix (the audio thread decides defining-or-not on its
  own clock); it now arms with quantize on, which only a non-defining press
  does. An undo tapped at a frozen clear is held by the repository
  (`_pendingClearUndo`) and taken on the first poll after the engine files
  the point, so a capture that held nothing is forgotten instead of having
  its pre-clear chains restored onto an empty track (the F3 leftover-chain
  rule), and a void member leaves the restored group's redo. A frozen
  capture is remembered audible (the engine files its point unmuted). The
  running-engine guard on the mode request was unreachable (both flags come
  from the same snapshot bit) and is gone; the window is twelve polls.
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

## Slice 2b — Timing ownership (#1012)

Branch: `claude/segno-slice2b-timing-1012`, stacked on slice 2a's branch
until PR #1013 merges.

### Decisions

- Record timing is one product setting (`RecordTiming`: Immediately, Loop
  start, bar, 1/2, 1/4, 1/8, 1/16) that the engine's quantize gate and
  musical division pair into (`RecordTiming.of`). The default is the global
  gate and division; a track's override sets the engine's per-track gate
  (existing) and the new per-track division
  (`le_engine_set_track_quantize_div`), which the audio thread reads live at
  every boundary check, so two armed tracks can fire on different grids in
  the same lap. `Track.recordTimingOverride` is the whole setting; the older
  three-way `quantizeOverride` is a getter over it (the routing dialog's
  "always" writes the default's own timing when that waits, else the loop
  top).
- Overdub decay is a percent (0 = Off keeps every layer whole; 100 replaces
  the pass); the engine takes `1 - decay / 100` as feedback, by default
  (existing global) and per track (`le_engine_set_track_overdub_feedback`,
  negative = inherit). A change during a pass ramps at the write head over
  the punch fade (about 10 ms) instead of stepping; playback never decays.
- Once works in all five modes. Free and Song keep the track's own clock
  wrap; in Multi, Sync and Band a track's lap ends on the shared clock: a
  k-multiple when the master wraps back to its first segment, a Sync/Band
  division every base/n frames, a 1x take at the wrap. The check runs before
  the grid arms fire, so a take finalized at that boundary plays its first
  lap. A track launched mid-lap in the shared-clock modes stays aligned to the
  master and stops at the end of the lap it joined; from a held transport the
  next launch starts at the top. Documented assumption: the accepted text's
  "subsequent launch starts at the beginning" is read on the shared clock,
  not as a private restart.
- Count-in and Sound start already exclude each other in the engine (D9);
  the repository mirrors it in its re-apply caches, the snapshot now
  publishes `auto_record`, `quantize` and the feedback coefficients (global
  and per track) so surfaces and the session capture read what the engine
  holds, and the two cubits that own the settings persist each other's
  cleared value and follow the engine's report.
- Ownership: the defaults (record timing, decay) persist as app settings
  (`looper.record_timing` is not a new key: the existing gate and division
  keys stay the source, `looper.overdub_decay` is new); per-track overrides
  persist per track (`track_record_timing.N`, migrated from the old
  `track_quantize.N` gate on first read, and `track_overdub_decay.N`). The
  session manifest captures the defaults like the tempo grid (saved, not
  applied on load) and captures and restores the per-track overrides with
  the track, like the length preset.
- Left to slice 2c: the Length & quantize and Playback & overdub editors
  (Tracks / Defaults / 1-8 selector), which will replace the boolean quantize
  toggle and the division picker with one record timing chooser; the
  existing surfaces keep working on the same engine setting meanwhile.

### Changed ownership

- Engine: `le_engine_set_track_quantize_div`,
  `le_engine_set_track_overdub_feedback`, `le_live_subdiv_ratio` per track,
  the per-track boundary loop, `le_one_shot_stop` shared by
  `advance_track_clock_frame` and `le_shared_clock_one_shots`, the ramped
  per-track feedback in `mix_tracks_frame`, snapshot fields `quantize`,
  `auto_record`, `overdub_feedback` and the three per-track overrides.
- Dart engine: `RecordTiming`, `setTrackQuantizeDiv`,
  `setTrackOverdubFeedback`, the snapshot fields.
- Repository: `setRecordTiming`, `setTrackRecordTiming`, `setOverdubDecay`,
  `setTrackOverdubDecay`, `TransportState.recordTiming/quantize/autoRecord/
  overdubDecay`, `Track.recordTimingOverride/overdubDecayOverride`, the
  count-in and Sound start mirror, session apply of the overrides.
- Session: `Session.recordTiming/overdubDecay`,
  `SessionTrack.recordTiming/overdubDecay`. Settings: the keys above.
- App: `LooperTrackRecordTimingChanged`, `LooperTrackOverdubDecayChanged`,
  `PlaybackOptionsCubit`, the exclusivity in `RecordOptionsCubit` and
  `TempoCubit`, the boot restore of the overrides and the default decay.

### Checks

- Native: `run_native_tests.sh` 5 suites ALL PASSED, also with
  `-fsanitize=address` and `-DLE_CALLBACK_TELEMETRY=0`; new tests for the
  per-track division (own boundary, forced loop top beside a sibling on the
  global grid, inherit, bounds), the per-track feedback (override, sibling,
  inherit, the mid-pass ramp), Once in Multi (1x, a 2x multiple enabled
  mid-lap), a Sync division, and a finalize at the wrap, and the published
  record start settings with the D9 exclusion.
- `segno_engine` 242 (field golden extended), `looper_repository` 430,
  `settings_repository` 138, `session_repository` 84,
  `performance_repository` 111; root suite and coverage recorded in the PR;
  analyzers clean in every touched package; `bloc lint` clean; pumped-native
  and fuzz suites against a hand-built library.

### Review round 1 (2026-09-09, on the first commit)

- The Once check ran before the grid and section arms fired, so at a lap
  end a queued punch-out on a Once track landed as a punch-in on the stopped
  track (an extra lap), a Band section stop restarted the section, and the
  arm's `handle_record` measured a transport the Once stop had just held and
  unparked user-stopped siblings. The check now runs after both arm loops; a
  track whose arm fired into an overdub this frame is skipped (the queued
  pass wins, Once ends the track at its end). Four native tests pin the
  three races and the queued punch-in.
- A take finalized mid-lap stopped on the tail of its own recording. Each
  track now counts the frames it has been sounding (`sounding_frames`) and a
  lap end only stops it after a whole lap (`k * base`, or the division's
  length); the mid-lap finalize and the division tests pin it.
- The count-in and Sound start mirrors in the two cubits compared against
  the engine's own report, which reads 0/off while the engine is stopped and
  lands a block late while it runs, and would have persisted that. Both are
  now projected from the repository's held values (which already mirror
  the D9 exclusion), so they read right while stopped and in the mock
  flavour.
- Noted, not changed: the session captures a track's timing override from
  the engine's report, so a forced gate with an inherited division is saved
  with the division baked in and comes back explicit (custom stays custom),
  and a save while the engine is stopped drops the overrides, as it does the
  One Shot flags today.

### Not verified here

- Hardware timing of the per-track grids and of the Once stop on the
  appliance; the design's smoothing wants a listening check on hardware.
- The accepted editors are slice 2c; nothing in this part changes a screen
  beyond the routing dialog's three-way now writing a timing override.

### Next step

Slice 2c: the Loop settings hub and its six submenus, Undo/Redo/Clear All
wiring, goldens, and the pen write-back of any departure.

## Slice 2c — Loop settings surfaces (#1012)

Branch: `claude/segno-slice2c-loop-settings-1012`, stacked on slice 2b's
branch until PR #1014 merges.

### Decisions

- The accepted Loop settings are full-screen pages at the pen's size
  (`LoopSettingsPage`: the hub and its six submenus plus the Time signature
  page as one page stack, each page a 1920 x 1080 canvas scaled down to fit
  a smaller window). They open from the console tray's Loop rail entry and
  from the desktop Settings rail's Loop settings entry; the tray's in-panel
  Loop domain (Tempo / Click / Mode tabs) and the desktop Tempo and Mode
  sections are gone with their tests, so the settings have one path each.
- Record timing has one owner in the app, `RecordTimingCubit` (the gate and
  the division persisted in their existing keys, applied as one repository
  call); the boolean quantize cubit is gone and the two audio-setup toggles
  read the gate off the new one.
- The Length & quantize and Playback & overdub editors carry defaults and
  per-track overrides with field-level inheritance: the repository now holds
  a default length preset and a default Loop/Once beside the decay default
  (`setDefaultLengthPreset`, `setDefaultOnce`), per-track overrides
  (`setTrackLengthPreset` with `null` = follow, `0` = an explicit Auto;
  `setTrackOnce`), and pushes every track's effective value on start and on
  a mode change. In Multi the length is shared: every track is given the
  default and its override is stored but inactive ("Shared in Multi"). A
  session manifest keeps carrying effective values; on load they become
  overrides only where they differ from the default.
- A capture in progress locks the Recording page and the Length & quantize
  page behind the pen's banner; the Playback & overdub page stays live.
- The Loop mode cards show a refused mode's reason in place of its
  description (from the engine's gate) and ask "Stop loops and switch" in
  the pen's own dialog; the console confirm dialog stays the default for
  the other callers of `requestLooperModeChange`.
- Audio & tempo is a readout: the recorded-speed state with its choices
  disabled and one line saying tempo following is not available yet.
- Undo, Redo and Clear All already reach the grouped edits of slice 2a
  from keys (`Z`, `Y`, `C`, `Shift+C`) and pedals (`LooperAction.undo` and
  `clear`); no new wiring was needed here.
- Departures from the pen, written into `segno-ui.pen` as the note
  `c/ Implementation · slice 2c` (section EYla4): the pen's own icon glyphs
  are drawn with lucide equivalents (chevron, check, arrow-left, repeat,
  arrow-right-to-line, minus, plus, timer, music); the pen's hex colours map
  onto the console theme tokens as slice 1 did; the Length page's lock
  banner sits under the scope selector with the sections moved down by 92;
  the tempo steps are two labelled buttons (1 BPM / 0.01 BPM) rather than
  the pen's unlabelled pair; the click output routing and level sit on the
  Audio tray's Device tab (and the desktop Audio section) until the slice-3
  Mixer owns them; the tray's Tracks domain lost its Lengths tab and the
  desktop Tracks section its length and One Shot rows, so each setting has
  one path.

### Checks

- Root: `flutter test` and `dart analyze` clean, `bloc lint` clean; new
  tests for the record timing cubit and every Loop settings page (hub
  summaries and navigation, mode reasons and the dialog, the recording
  notes and lock, tempo taps and the signature grid, length scope and
  overrides and Multi sharing and lock, playback overrides and the decay
  slider, the audio readout).
- `looper_repository` 432, `settings_repository` 141 (defaults and
  overrides for length and Once); the engine is untouched by this part.

### Not verified here

- The pages on the appliance's two displays and by encoder; the pen's
  encoder focus rectangles are not implemented. The goldens
  (`test/screenshots/loop_settings_screenshots_test.dart`, eleven pages
  including the lock, the dialog and a per-track scope) were generated and
  checked against the pen on the author's machine; the tray's Loop previews
  are gone with the tray domain, and the suite loads the lucide package
  font so the icons render as glyphs rather than tofu boxes.

### Review round 1

A review pass (eight finder angles, one verifier per candidate) confirmed
ten findings and a set of cleanups, fixed in the second commit:

- The deleted Click tab had carried the click output routing and level;
  nothing else did, and a fresh unit's mask of 0 routes the click nowhere.
  A `ClickOutputSection` / `ClickOutputCard` now sits on the Audio tray's
  Device tab and the desktop Audio section until the Mixer (slice 3) owns
  them, reusing the old strings. The loop-to-grid sync switch went with the
  same tab; the design has no equivalent (sync is always on), so the
  `tempo.sync` key and `TempoCubit.setSyncTempo` are gone and the engine's
  default stands.
- `RecordTimingCubit` keeps the last musical division while the gate is
  off, so the two on/off switches no longer collapse a chosen quarter into
  the loop top; `setTiming` leaves the division key alone when the gate is
  off.
- The session manifest carries the per-track length and Once OVERRIDES
  (nullable, like record timing and decay) and the rig defaults, captured
  from the repository's projection through `SessionLoopSettings`; the old
  effective fields and `oneShotChannels` are gone, and `applySession`
  writes overrides verbatim after putting every track on the default.
- The legacy per-track rows (the tray's Tracks > Lengths tab, the desktop
  Tracks section's length and One Shot rows) dispatched effective values as
  overrides and could not express "follow the default"; they are retired
  with `LooperOneShotToggled`, `LooperAllOneShotToggled` and
  `LooperRepository.setOneShot`, so the Loop settings pages are the one
  path.
- A mode request the engine drops reverted the remembered mode without
  re-pushing the presets the request had pushed; `_rememberLooperMode` now
  re-pushes across the Multi boundary. `setLooperMode` pushes only the
  length presets of override channels, and only when crossing Multi; Once
  never depends on the mode.
- The repository setters write the engine before re-projecting (one state
  per tap, override and effective value together); the default setters
  return early when unchanged, so the cubits' restore behind bootstrap is a
  no-op; the track count comes from the last projection rather than a
  second engine walk; the start replay's push is bounded to the engine's
  tracks.
- The mode cards rebuild on the state the gate reads (track states, queued
  triggers, lengths), and their refusal wording is `looperModeRefusal`'s,
  shared with the snackbar. The pen's stop dialog lives in
  `looper_mode_change.dart` as the one confirm; the `confirm` callback and
  the console-dialog fallback are gone.
- `LoopSlider` gained `onChangeEnd`: the tempo drag applies live and
  persists once at the end, the decay drag previews locally and commits at
  the end.
- Cleanups: `LoopSettingsPageId` is the hub's only enum; the hub reads the
  defaults from the cubits like the pages; `scopedOrigin` replaces four
  origin ternaries; `LoopOutlinedButton` carries the four fills (the top
  bar, the dialog and the signature chip use it); the rail is built from
  `TrayRailEntry` and the desktop rail's Loop row is an action, not a
  section; 65 orphaned l10n keys and a duplicate `loopLengthAuto` are gone;
  the screenshot suites share one font loader and the tracks goldens load
  the lucide font (the settings gear was a tofu box).
- Left as is: a `tempo.length_preset.N` of 0 saved by the previous build
  reads as an explicit Auto override (the repo does not add migrations;
  Use default clears it in one tap); the pen-width parameters on the Loop
  widgets stay (the pages are pen-geometry canvases, as slice 1's
  `PrimaryCrown(size:)`).

### Review round 2

A check of the round-1 commit found three things, fixed in the third
commit: the per-track override fields on the manifest were only written
for a channel with content, so an override on an empty channel was lost on
save (the case the old `oneShotChannels` covered); the overrides are now
session-level maps keyed by channel (`Session.lengthPresetOverrides`,
`onceOverrides`, `SessionRig` likewise) and restore bounded to the engine's
tracks. The mode cards' rebuild key gained the count-in and the in-flight
layer, both of which the engine's gate reads. A cancelled slider gesture
ends at the committed value, so a preview never outlives its touch.

A third check found the slider's tap and drag recognizers each cancelling
on the interaction the other wins, so a plain tap committed twice, once at
a stale value; the commit now rides the raw pointer (one pointer up, one
commit). A manifest preset above the engine's 64-bar limit was cached
while the engine refused it; every path clamps to the limit now.

### Next step

Slice 3 (inputs, outputs, Mixer and FX), per `implementation-map.md`.

## Slice 3 — Inputs, outputs, Mixer and FX (#1016)

Six parts, listed on the issue: 3a the mix model (engine + repository),
3b output destinations, 3c the Audio routing and Output setup surfaces,
3d the Mixer, 3e FX placement and printing, 3f the FX surfaces.

### Slice 3a — the mix model

Branch: `claude/segno-slice3-mixer-fx`, stacked on slice 2c's branch until
PR #1015 merges.

#### Decisions

- **Pan** is a per-lane engine value (`le_engine_set_lane_pan`, -1..1)
  applied to the lane's stereo pair after its chain and after the wet
  cache, with a unity-centre balance law: the near side stays at unity and
  the far side falls on a quarter-sine, exactly silent at the hard side.
  Centre is bit-identical to the pre-slice engine, so every fingerprint and
  cache invariant holds; a lane routed to one output receives the pair's
  mid, so pan there is a plain attenuation. The accepted records leave the
  pan law to engineering; this is it.
- **Solo** is a per-track engine flag (`le_engine_set_track_solo`): while
  any track is soloed, only soloed tracks route. It sits beside mute in the
  audible gate and never writes it; chains keep running and the dry meters
  keep reading; monitors are not tracks and are unaffected. Solo is
  performance state: not saved with a session, cleared by a session load.
- **Capture trim** (`le_engine_set_input_trim`, linear, 0..+12 dB) scales
  only the sample a lane records; the monitor path, the input meters, the
  clip detector, the sound-activated trigger and the tuner read the
  untrimmed conditioned input. A direct store, so it holds while stopped.
  The repository speaks dB (-24..+12, half-dB steps) and converts.
- **Every hardware input can be monitored**: `LE_MAX_MONITORED_INPUTS` is
  `LE_MAX_CHANNELS` (32). A monitor is about 3.3 KB, so the array costs
  106 KB.
- **The recorded image.** A lane's pan and balance gain are fixed from its
  input's setup when the take starts (`_seedLaneImage`, beside the chain
  snapshot): a pair member sits hard on its side, a mono input where its pan
  put it. Later input edits move the live monitor and future takes only.
  The engine is given each lane's EFFECTIVE pan (image plus the track's
  pan, clamped) and volume (level times the balance gain), so a track's
  fader and pan move every lane together and a stereo take keeps its image.
- **Stereo pairs are two lanes.** Lane buffers stay mono; a pair records
  as one lane per member with pans -1/1, and the pair's balance is a gain
  the repository composes onto each side (the favoured side at unity, the
  other on the pan law). No stereo lane type was added to the engine.
- **Meters for the Mixer**: per-track post-fader stereo peaks (`peak_l`,
  `peak_r`, after volume, pan and the track chain), per-input raw peaks,
  per-monitor peaks (what it routes) and per-output-channel peaks after the
  master gain and limiter, all trailing snapshot fields; the repository
  projects them per channel the device has.
- **Typed mix targets** (`MixTarget`: track level/pan, input level/pan,
  pair balance) carry a byte-stable canonical string like `FxAddress`, the
  identities slice 4's assignments bind to. Output buses join in 3b.
- `InputSetup` (trims, pans, pairs with balance) is the repository's
  remembered intent, projected on `LooperState`, saved with the session and
  restored on load; input names stay appliance-wide as before.

- Persistence: `track_pan.N` and the per-device input setup keys
  (`input_trim/pan/pair/balance.<device>.N`) in settings, restored at boot
  after the engine starts; the manifest carries `tracks[].pan`, each lane's
  recorded image as `lanes[].pan` (the engine's pan minus the track pan, so
  a lane the track pan pushed into the clamp comes back as far from centre
  as it still plays: a known, small loss), the monitors' pans as a record
  and a session-level `inputSetup`. Solo is not persisted anywhere.
- Bloc events: `LooperTrackPanChanged`, `LooperTrackSoloToggled`,
  `LooperSoloCleared`, `LooperMixerReset`, and the `LooperInputEvent`
  family (trim, pan, pair, balance) persisting the whole input setup under
  the device name.

#### Checks

- Native: the 5 suites plain, with ASan and with telemetry off; new tests
  `test_lane_pan_law`, `test_track_solo_gates_routing`,
  `test_input_trim_scales_capture_only`, `test_monitor_pan_and_wide_inputs`,
  `test_track_stereo_peaks_follow_fader`. ffigen regenerated and formatted.
- Dart: `segno_engine` 262, `looper_repository` 451 (the new
  `mix_model_test`), `settings_repository` 146, `session_repository` 98,
  `performance_repository` 111; root 2207; analyzers clean at the root and
  in every touched package; `bloc lint` clean.

#### Review round 1

A review pass (four finder angles, six verifiers) confirmed a set of
findings, fixed in the second commit:

- A lane's level, image and balance are the repository's own values
  everywhere: the projection shows the level (`Lane.volume`, `Track.volume`)
  rather than the engine's level-times-balance, and the manifest carries
  `lanes[].volume` as the level, `lanes[].pan` as the image and
  `lanes[].balance`, all captured from the projection, so a save/load no
  longer collapses a pair's balance into the level (the first fader move
  after a load used to un-silence the balanced-out side).
- A lane added after the defining take gets the track pan and, on its first
  take (an overdub), its own image (`setLaneCount` pushes grown lanes and
  drops the image of a lane that leaves the window; the overdub path seeds
  lanes without an image). Boot restores the track pans after the lane
  counts.
- Solo is honoured by the offline performance render and the DAW export
  (an audibility gate across every track, seeded from the arm manifest's
  new per-track `solo`); pan stays out of both, which are mono.
- The meters read what reaches an output: a lane or monitor routed only to
  a disabled output meters nothing, on the legacy route and on the track
  bus alike. The pan's gains are computed when the pan is set (two loads
  per lane per frame instead of a cosine); the trim and the solos are read
  once per block; the meter publish and the Dart snapshot lists are bounded
  by the device's channel counts; the Dart snapshot drops `inputTrim` (the
  repository keeps its own intent).
- Pairing is refused while a track fed by either member is armed or
  capturing (the accepted rule), and a pair past the engine's ceiling is
  refused before it is stored. Reset mixer walks every remembered track,
  so a reset while stopped clears what the next start would replay.
- The input setup is session-owned (the design's sentence: pairing, trim
  and position belong to the saved session setup; names stay
  appliance-wide), so a load replaces it and now re-persists it, and the
  track pans, so the next boot matches the loaded session. The settings
  writers are per input; a whole-setup writer serves the load.
- Cleanups: `InputSetup.with*` helpers and one `_applyInputSetup` path;
  `setInputSetup` for the boot restore and the load; `MixTarget` follows
  `FxAddress` (`tryParse`, `canonicalString()`) and drops the track level,
  which `TrackVolumeTarget` already names; `SessionMonitor.pan` (write-only)
  is gone; the dead dB-of-gain conversion is gone; the Dart balance law and
  the engine's pan law share pinned constants.

#### Review round 2

A check of the round-1 commit found the fresh-take path still projecting
and saving the engine's gain as the level (a lane whose fader was never
touched had no level of its own), a grown lane pushed at unity instead of
the track's level, the wholesale setup push posting sixty-four ring
commands on every load, and the DAW export leaving a track silent at arm
with no breakpoint although the activator's manual value is on. Fixed in
the third commit: the seed and the growth give a lane the track's level,
`setInputSetup` pushes only the inputs either setup names, the export
writes the seed audibility at the start, and a reset while stopped clears
the caches without a refused engine call.

#### Not verified here

The pan law by ear and the meters on the appliance; the offline
performance render replays solo but not pan (it renders lane 0 mono as
before), which the stems export does not need and the master capture
already contains.

### Slice 3b — output destinations

Same branch, stacked on slice 3a's PR #1017 until it merges.

#### Decisions

- **Output buses.** Destination `k` is the stereo pair of hardware outputs
  `2k` and `2k + 1` (`LE_MAX_OUTPUT_BUSES` = 16; a device with an odd
  channel count has a single-jack last bus, processed as `l == r`). Each
  bus owns a level (0..1, retained behind the mute), a mute, Stereo/Mono
  and a balance on the lane pan law (`le_engine_set_output_level/mute/
  mono/balance`, ring commands 61 to 64, `lanef {bus, 0, value}`), and its
  own effect chain (`le_engine_set_output_fx*`, commands 65 and 66). The
  frame order is now tracks, monitors, click, then per bus: chain, the
  performance tap, Mono or balance, level, mute; then the global master
  gain and limiter and the output meters. A bus at its defaults with no
  chain costs nothing per frame. Every fact is published in the snapshot
  (`output_bus_count`, `output_level[]`, `output_muted[]`,
  `output_mono[]`, `output_balance[]`, `tail_reset_rev`,
  `perf_follow_output`, trailing fields).
- **The Master insert is bus 0's chain.** `le_engine.master_fx`, the
  `le_engine_set_master_fx*` family and ring codes 51 and 52 are gone; the
  engine and the Dart engine interface speak output buses only, and the
  repository maps `FxStage.master` to bus 0 (`kMasterOutputBus`) until
  slice 3f rebuilds the FX surfaces around one chain per destination. The
  chain now colors everything summed onto the first pair, live monitors and
  the click included, which the accepted design asks of an output chain and
  the old D-MASTER rule (monitors uncolored, first ENABLED pair) forbade;
  both tests flipped.
- **The click is processed by its destination.** It sums in before the
  buses, so a destination's chain, level and mute process it like every
  other source routed there (accepted: "Click is included if routed
  there"), and it now reaches the output meter and the master gain. The
  output-enabled mask still gates it structurally.
- **The performance capture tap** defaults to the captured bus after its
  chain and before its level, Mono, balance, mute, the master gain and the
  limiter (Output setup, "Performance capture boundary"; accepted: "Final
  output volume/mute is excluded by default"). `le_perf_set_follow_output`
  sets the policy the next arm freezes into `perf.follow_output`; a running
  take keeps its policy, and the flag survives a (re)configure because it is
  a preference, not device state. The captured bus is the first one with an
  enabled channel (mono when only one is), so a disabled left jack captures
  the right one; the snapshot publishes it as `perf_capture_bus`. The
  capture is a DESTINATION now, not the first two enabled channels
  anywhere: a rig with its two jacks on different pairs captures one of
  them in mono, which is what a destination means. The arm
  snapshot records `followOutput`, `captureBus` and that destination's
  `outputLevel` and `outputMuted`; `perf_render` skips the master stage for
  a default take and, under Follow, replays the captured bus's level and
  mute from the log (commands 61 and 62 are perf-logged) before the master
  gain and limiter. A manifest with no `followOutput` key is a take from
  before the policy existed, captured post-gain, so it reads as Follow. The
  golden parity test runs both policies.
- **Cut all sound** (`le_engine_cut_sound`, command 67): every playing,
  recording or overdubbing track goes through the Stop handler (a take in
  progress finalizes, and the stop is perf-logged per track so a log replay
  does not hear it past the cut), a running count-in is cancelled, and every
  built-in chain on every stage has its DSP state AND its delay rings cleared
  in the one callback that applies the command, while its type, count, params
  and enables stay; `a_tail_reset_rev` advances and the snapshot carries it.
  The clear is deliberately NOT spaced the way a chain stomp's re-enable
  clears are (see the review round below): the cost is proportional to the
  rings actually allocated, paid once on a deliberate press. A hosted plugin
  has no reset seam and keeps its own tail. Monitors keep their
  preferences.
- **Bypass drains the tail** (accepted: "bypass sends new audio dry and
  drains old wet tails"), for the types that have one. `le_fx_type_drains`
  is true for a ring-owning type with no reported latency (delay, echo,
  reverb): those are linear, so `enable_mix` scales the slot's FEED — the
  output is `dry * (1 - mix) + effect(dry * mix)`, the 5 ms ramp moves the
  new audio from the effect to the dry path, and once the feed is silent
  the slot keeps running on silence with its tail summed onto the dry
  signal until the tail has stayed under 1e-4 for 50 ms or 8 s have passed;
  then it settles and is skipped (bit-exact passthrough, D-BITEXACT
  intact). Everything else keeps the old crossfade and settles with no
  drain: a kernel with no memory has no tail, and its small-signal gain would
  make a scaled feed overshoot both endpoints (a drive at 15x reads +2 dB
  above wet at mix 0.2); the octaver holds a delayed copy of the dry signal,
  which summed onto the direct path would double the audio for the latency
  window; a hosted plugin owns its tail and has no reset seam. A re-enable
  mid-drain keeps the state; a re-enable from a settled bypass, and any
  retype, still resets and clears the rings.
- **Stop drains Post tails; Mute gates them.** The lane body now has two
  gates: `fed` (playing and not gated) feeds the chain, `gate_ok` (not
  muted, not soloed away) lets its output through. A Stop or Clear cuts
  the feed and the lane's tail drains through its route; a Mute gates the
  lane whole, tail included, while its player continues. The Track chain
  routes via the union of the gate-open lanes' destinations, so its tail
  drains after a Stop and is gated by a Mute with the track; the shared
  tails that keep draining under Mute are the output chains'. The old
  "wet routes only while audible" rule is gone.
- **Persistence.** The output setup is session-owned like the input setup
  (`Session.outputSetup` = `{level, muted, mono, balance}` maps keyed by
  bus, each holding only the destinations off that fact's default, the
  object omitted when all are empty) and kept per device in settings
  (`output_level/mute/mono/balance.<device>.<bus>`, `loadOutputSetup`,
  `saveOutputBus`, `replaceOutputSetup`), restored at boot, re-persisted
  on session load. The repository holds `OutputSetup` (an `OutputBus` per
  destination off its defaults), pushes the four facts of an edited bus,
  replays them on start and applies a rig's whole setup on session load.
  Bloc events `LooperOutputLevelChanged/MuteChanged/MonoChanged/
  BalanceChanged` and `LooperCutSoundPressed`;
  `PerformanceRepository.setFollowOutput`.
- **Per-source output selection** is already the engine's model: every
  lane, every monitor and the click carry their own output mask, and a
  destination is a pair of those channels. Nothing was added for it here.
  A track-wide route (one choice for every lane of a take) is a
  convenience the Audio routing surface owns in 3c, together with
  persisting it and clearing it on a session load; a repository cache
  without those outlives both. There is no backing track source in the
  engine to route.
- **Kept as is.** The global master gain and limiter stay as the final
  stage after the buses; retiring the global gain in favour of bus 0's
  level is a surface decision for slice 3c (the Mixer's master fader). Bus
  level changes are instant (no ramp), like the lane volume today.

#### Changed ownership

`le_engine.outputs[]` replaces `master_fx`; `le_perf_capture.follow_output`;
`le_fx_state.enable_drain / enable_quiet`; `fx_apply_chain`'s ramp
arithmetic; `mix_tracks_frame`'s `audible` split into `fed` / `gate_ok` /
`routes`; `le_perf_first_enabled_pair` steps by bus; `perf_render`'s
`le_pr_render_master` is conditional on the take's policy and replays bus
0's level and mute. Dart: `MasterBusControl` gained the bus setters and
`cutSound`, `EnginePerformanceCapture` the policy setter; `EngineSnapshot`
the seven trailing fields; four fake engines updated.

#### Checks

- Native: the 5 suites plain, with ASan and with telemetry off; flipped
  `test_click_processed_by_output_bus`,
  `test_count_in_click_captured_when_routed`,
  `test_output_fx_colors_monitors`, `test_output_fx_ch_out_4_is_bus_0`,
  `test_fx_bypass_drains_tail_then_settles`; new
  `test_perf_master_tap_pre_level_by_default`,
  `test_perf_master_tap_follow_output_post_gain`,
  `test_perf_capture_first_bus_with_enabled_channel`,
  `test_output_bus_level_mute_mono_balance`,
  `test_output_setters_reject_invalid_and_clamp`,
  `test_cut_sound_stops_tracks_and_clears_tails`,
  `test_fx_bypass_new_audio_dry`,
  `test_stop_drains_lane_tail_and_mute_gates_it`, and from the review round
  `test_output_bus_honours_disabled_channels`,
  `test_fx_retype_mid_drain_starts_clean` and
  `test_perf_follow_survives_configure_and_capture_bus`; the golden parity
  test runs both capture policies. ffigen regenerated and formatted.
- Dart, with `SEGNO_ENGINE_LIB` built so the FFI-gated suites actually run:
  `segno_engine` 306, `looper_repository` 475, `settings_repository` 152,
  `session_repository` 103, `performance_repository` 118, `daw_export` 100;
  root 2246; analyzers clean at the root and in every
  touched package; `bloc lint` clean; cspell clean on the changed markdown
  against the repository's dictionary.

#### Review round 1 (2026-09-09, on the first commit)

Eight finder angles, then a verify pass. Fixed in the second commit:

- **A disabled output channel carried audio.** The bus stage read and wrote
  both channels of its pair regardless of the structural gate, so a
  decorrelating chain on the bus put its right-hand output onto a disabled
  jack, and Mono halved a pair with one jack disabled. The per-block bus
  snapshot now carries the pair's enabled bits: a disabled channel feeds the
  chain as silence, is never written, and Mono averages the enabled channels
  only.
- **A retype mid-drain replayed the old effect's ring.** The re-enable edge
  skips its clean reset while a drain is in flight, and nothing cleared the
  drain budget on a type change, so an echo bypassed and then retyped to a
  delay read the echo's repeats out of the ring. `le_fx_entry_reset` now
  clears the budget, which is the same edge every retype goes through.
- **The bypass drain overshot for a kernel with no memory and doubled the
  dry for the octaver.** The feed ramp is only sound for a linear,
  ring-owning effect; `le_fx_type_drains` now picks those, and every other
  type keeps the crossfade (see the Decisions entry).
- **Cut all sound is perf-logged per track**, like `le_one_shot_stop`'s
  synthetic stop, so a log replay does not hear a track past the cut. The
  ring clear was moved to `fx_apply_chain`'s spaced path first and then moved
  back: deferring a slot's clear means passing it DRY until its turn, and dry
  is the wrong output for a fully wet effect — a verifier showed a full-wet
  delay on a live monitor bursting the raw input at full level for the
  deferral window, at the instant the user asked for silence. The stagger
  exists for a chain stomp, which repeats and can be held down; Cut is one
  deliberate event, and one callback carrying a few hundred microseconds of
  memset is the cheaper of the two failures. Pinned by a test with two
  ring-owning slots on one chain, which a per-chain stagger would show on the
  second. The cost is proportional to the rings allocated (one ring is
  `sample_rate` floats per channel, so a rig with twenty ring-owning slots is
  several MB of memset in that callback); the note in the code says so rather
  than quoting a figure.
- **The Follow-output render assumed bus 0.** The engine captures the first
  bus with an enabled channel, so a rig on the second pair rendered with the
  wrong destination's level. The snapshot publishes `perf_capture_bus`, the
  arm manifest records `captureBus`, and the render replays that bus.
- **A jack's structural gate is not a bus mute, and the tests now say so.**
  A verifier read the bus stage's new gating as silencing a take when an
  output is disabled mid-record. It does — but not because of this slice:
  every source already masks by the enabled mask before summing, so a
  disabled channel carries nothing to capture, and it did not before either.
  That is `le_engine_set_output_enabled`'s stated contract (the routing
  graph, not a gain), and the bus mute deliberately differs (it is a gain
  after the tap). The bus now reads its pair without that gate, which is
  equivalent and simpler, and a test pins the two side by side.
- **A pre-3b take rendered without the master gain.** `followOutput` absent
  meant "pre-level", but every take on disk was captured post-gain; it now
  reads as Follow, and the key is always written so the two cannot be
  confused.
- **The capture policy reverted on every device change.** `configure` reset
  `a_perf_follow_output`; it is a preference, not device state, and now
  survives.
- **The pumped test engine dropped every new snapshot field.** It rebuilt
  the snapshot from an explicit field list; `EngineSnapshot.copyWith`
  replaces that. A verifier then showed the guarantee was only moved, not
  made: the constructor's parameters are optional with defaults, so a field
  added later without a `copyWith` parameter still compiles and silently
  yields the default. A source-level golden now pins the `copyWith`
  parameter names to the declared field list, and it was mutation-checked
  (drop one parameter, the suite fails; restore it, it passes).
- **One edit posted four ring commands and four preference writes.** A level
  ride re-posted the mute, Mono and balance behind it and could delete a
  mute set between two of its ticks. Each setter now pushes its own fact,
  and settings has one writer per fact like the input setup's.
- **The compatibility layer went.** `le_engine_set_master_fx*`, ring codes
  51 and 52 and the Dart `setMasterFx*` family are deleted; the engine
  interface speaks buses and the repository owns the `FxStage.master` to bus
  0 mapping (AGENTS.md: remove obsolete paths).
- Cleanups: one `le_store_pan` for the three pan/balance handlers, one
  `perf_push_master` for the two taps, one `le_fx_entry_clear_rings` for the
  two ring clears, one snapshot struct per bus instead of eleven parallel
  arrays and seventeen parameters, `OutputSetup.fromMaps`/`toMaps` instead
  of four hand-written conversions, the unused destination/mask helpers
  deleted rather than left with a hard-coded channel count,
  and the stale D-MASTER / D-MASTERCH / "click is excluded from the capture"
  comments rewritten to what the code does, along with every "Master insert"
  section label that now names a 16-destination loop.
- Contracts that had drifted from the code: `engine_fx.h`'s `fx_apply_chain`
  block (it still promised "NO tail spill on bypass"), `le_fx_entry_reset`'s
  doc (it now touches the drain half deliberately), the capture-policy
  setter's doc in both the C header and the Dart interface (it is a
  preference and survives a reconfigure), `performance-event-log-format.md`
  (codes 51 and 52 retired, 61 to 67 added with their replay verdicts) and
  `performance-manifest-format.md` (the four new `armSnapshot` fields and the
  absent-key rule). The plugin install path publishes a type change the ring
  handlers never see, so it clears the drain state too.
- Three tests were mutation-checked after a verifier showed they passed
  against the reverted fix: the retype-mid-drain test now pre-rolls past the
  ring length (its silence assertion was reading calloc zeros), the legacy
  render default got a third golden-parity run whose manifest omits the key,
  and the `copyWith` golden is pinned to the field list.

#### Review round 2 (2026-09-09, adversarial verification of round 1)

Every round-1 fix was handed to a skeptic told to refute it, then four
critics swept the whole change for new bugs, unaddressed findings and test
honesty. Three of the fixes were themselves wrong, and several tests passed
against their own reverted fix. Fixed in the third commit:

- **The capture destination was recorded before the arm.** The engine settles
  it inside `le_perf_arm`, from the output gate as it stands then; the
  manifest read it from a snapshot taken before lane export and manifest I/O
  — the same race that retired the old `clockFrame` anchor (#262). A manifest
  naming one destination while the take captured another sends the offline
  render to the wrong level rides, silently. It is now read after the arm and
  the crash-survival file is rewritten.
- **The `copyWith` guarantee was only relocated.** The constructor's
  parameters are optional with defaults, so a field added later without a
  `copyWith` parameter still compiles and yields the default. Two source-level
  goldens now pin the parameter list to the field list and check that each
  parameter feeds its own field.
- **The spaced ring clear was worse than the memset.** Deferring a slot means
  passing it dry, and dry is the wrong output for a fully wet effect. Reverted
  to clearing at once, with the reasoning in the code.
- **A jack's structural gate is not a bus mute.** A verifier read the new
  gating as silencing a take when an output is disabled mid-record. It does —
  but so did the engine before this slice, because every source already masks
  by the enabled mask, and that is `le_engine_set_output_enabled`'s stated
  contract. A test pins the mute and the disable side by side.
- **`tool/build_test_lib.sh` had stopped compiling**, so every FFI-gated Dart
  test had been skipping silently: it predates the vendored RNNoise and the
  restore TUs. Repaired, which brought back 32 pumped-engine tests, 11 in
  `looper_repository` and 29 more at the root.
- Tests that passed against their own reverted fix, found by reverting each
  one: the Cut silence test and the retype test both read calloc zeros
  because they never filled the ring (both now pre-roll past its length), the
  render's capture-bus filter had no coverage (a fourth golden-parity run
  names a destination the take did not capture and requires the render to
  diverge), and the pumped snapshot had none (it now asserts the facts the
  old hand-written list dropped). Each was mutation-checked: revert the fix,
  the test fails; restore it, the test passes.
- Smaller: the guards `perf_bus` and the shared capture push had lost
  (`master_out_ch[0] >= 0`, the armed check), `le_perf_first_enabled_pair`
  reading the published channel mirror the rest of the snapshot uses, the
  Cut stop entry asserted in the log, the plugin install path clearing the
  drain state, and the last "Master insert" labels on what are now
  16-destination loops.

#### Not verified here

The bus stage and the tail drain by ear on the appliance; the drain floor
and window (1e-4 for 50 ms, 8 s cap) are engineering values the listen
check may move. The offline render replays the captured bus's level and mute
but not its Mono, balance or chain (the accumulator is mono and the arm
manifest carries no bus chain yet). The Follow output preference has no
surface or setting yet: the repository setter exists for the Performance
recording page. The output setup is kept per device in settings as well as
in the session, following slice 3a's input-setup precedent, so loading a
session replaces the device's stored destinations; whether the boot restore
should come from the last session instead is a question for slice 3c's
surfaces.

#### Next step

Slice 3c: the Audio routing and Output setup surfaces.

### Slice 3c — the Audio routing and Output setup surfaces

Same branch family, `claude/segno-slice3c-routing-surfaces`, stacked on 3b's
PR #1018.

#### Decisions

- **One route, four tasks.** The pen draws Input setup, Recording inputs,
  Output routing and Output setup as four pills in one nav row, not as four
  routes, so they are page state: switching tasks keeps the route and its
  Back button pointing at Settings. `openAudioRouting()` joins
  `openLoopSettings()` in `segno_navigator.dart`, with its own re-entrancy
  guard cleared by `resetSegnoNavigatorForTest`.
- **The frame is reused, not forked.** `LoopPenCanvas` and
  `LoopSettingsFrame` already draw the pen's 1920 x 1080 canvas, its 96 px
  top bar, the crumb and Stage, so Audio routing imports them. Its children
  are positioned in the 1720 x 984 main area, which is why every `top` in
  the page is the pen's screen y minus 96.
- **The path is Settings, not a ninth rail domain.** The accepted design
  says "Settings → Audio routing", so the desktop Settings rail gains a
  Routing row beside Loop settings and the tray rail is left alone. A ninth
  tray row collapsed the pen's fill spacer between the domains and
  Brightness, which the rail's own test measures.
- **Input setup** reads the slice-3a projection and dispatches the slice-3b
  events that had no consumer until now: `LooperInputPanChanged`,
  `LooperInputBalanceChanged`, `LooperInputTrimChanged` and
  `LooperInputPairChanged`. A linked pair shows one Balance where a mono jack
  shows Pan, and names its two members with their ordered left and right
  identities. The trim slider lands on the accepted half-decibel step, so the
  readout can show what the engine holds.
- **The lock is derived from the projection.** The repository keeps its
  "armed or capturing" predicate private, so the page re-derives it from the
  tracks it can see and says why the format is frozen, rather than drawing a
  control that would be refused.
- **Clipping is a fact about the source**, so the meter's tail lights on the
  engine's held clip flag rather than on the decayed level, and the note
  under the trim becomes the accepted sentence while it holds.
- **Eighteen jacks scroll.** The pen draws four cards; a device with more
  inputs scrolls the row rather than shrinking the cards past legibility.

#### Checks

- Dart: root 2253 with the test library built; `dart analyze` clean at the
  root; `bloc lint` clean; the two settings goldens the new rail row changes
  regenerated and eyeballed (715 px each, the row and nothing else).

### Recording inputs

- **A track's sources are a track-scoped choice**, so the task carries its own
  scope row rather than following the stage selection: the eight tracks are
  numbered buttons and the chosen track's name is shown beside them.
- **Lane semantics are the retiring dialog's, kept verbatim.** Unchecking a
  jack frees that lane in place, because compacting would renumber the lanes
  and move a recorded take onto another source. A new jack fills an already
  free lane; only when every lane is taken does the track grow, and the growth
  is dispatched before the routing so the lane exists before it is addressed.
  A track already at `kMaxLanes` refuses rather than addressing a lane the
  engine can never have.
- **The lock is per track.** A capturing or armed track says why its jacks are
  frozen; its siblings stay editable in the same view.

#### Checks

- Dart: root 2230 passing and 35 skipped, `dart analyze` clean over `lib` and
  `test`, `bloc lint` clean over 235 files, both arb files at 1081 keys with
  no key present in one and missing from the other.
- Every behavioural claim above is mutation-checked: ignoring the lock,
  growing after routing instead of before, never reusing a freed lane,
  freeing the wrong lane, drawing nothing as recorded, and never showing the
  empty note each fail exactly one test and no other.

### Destination names

- **The unit is the destination, not the jack.** A destination is a stereo
  pair (bus `k` = outputs `2k` and `2k+1`), which is what a player patches and
  names; naming the jacks separately would ask for two names for one cable
  pair and leave every routing surface to guess which to show. The per-jack
  output gate keeps its own key, because a name and a gate are different facts
  about different units.
- **Names are per device**, like input names, and an unnamed destination falls
  back to its jack numbers in a short form so a card can carry the full label
  above the name without both lines saying the same words.
- An odd-channel device leaves the last destination holding a single jack; it
  is labelled and masked as one rather than promising a socket the interface
  has not got.

### Output routing

- **Each source kind carries its own destinations**, per the accepted rule
  that a recording-only track route never implicitly becomes a live input
  route. Live inputs route through their monitor, tracks through their lanes,
  the click through its own output mask.
- **A track's route is the whole track's.** Every lane is written, because
  writing lane 0 alone would leave the rest going elsewhere while the card
  claimed a route half the track has. Lane 0 is read back as the track's
  answer; lanes can only disagree by way of a session saved before this
  surface owned the route, and writing every lane is what puts them in step.
  This is the track-wide route `setLaneCount` deferred to this slice.
- **Either jack of a pair means the destination is reached**, so a card never
  offers to switch on something already partly on.
- **Hear live belongs to the live inputs** and to no other kind. Auto says
  whether it is hearing anything right now, and a monitor muted in Mixer says
  so rather than looking switched on.

#### Deviation from the pen

The accepted design's third source kind is "Backing & click". This console has
no backing player: there is no engine, repository or bloc seam for one
anywhere. The kind ships with the accepted label and the click alone, because
a card for a source that routes nothing would be a control that does nothing.
The backing card lands with the backing player.

#### Checks

- Dart: root 2254 passing and 35 skipped, `looper_repository` 468 passing,
  `dart analyze` clean over both packages, `bloc lint` clean over 239 files,
  both arb files at 1099 keys with no key in one and missing from the other.
- Mutation-checked: ignoring what is armed in the Auto note, routing lane 0
  only, reading the monitor's route for the click, a destination that can only
  be added, Hear live shown for every kind, a half-driven pair reading as
  unreached, and an odd-channel device claiming the jack it has not got each
  fail exactly the tests that name them.

### Output setup

- **Every fact is the chosen destination's own**: format, level, balance and
  mute are per destination, and the page opens on the master because that is
  the destination a player meets first.
- **The meters read that destination's own jacks**, outputs `2k` and `2k+1`,
  and a muted destination meters silence whatever the engine's last block
  said. Below the meter's floor the readout says nothing is coming out rather
  than printing a large negative number that would read as a level.
- **The routing meter's fill was wrong and is fixed here.** It lit cells in
  proportion to amplitude while the scale under it prints four evenly spaced
  ticks, so a signal at -24 dBFS lit a sixteenth of the meter under a label
  that says a third. It is not the stage's `peakMeterFill` either: the two
  surfaces print different scales, and each meter has to agree with the one
  drawn under it.

#### Checks

- Dart: root 2263 passing and 35 skipped, `dart analyze` clean over `lib` and
  `test`, `bloc lint` clean over 240 files, both arb files at 1109 keys with
  no key in one and missing from the other.
- Mutation-checked: editing the master whatever card is chosen, metering the
  first pair whatever destination is chosen, metering a muted destination's
  last block, reading the balance slider as a level, a mute that never says it
  is muted, a Mono note that always shows, and a decibel-linear meter fill
  each fail exactly the tests that name them.

### The name pages

- **The header action names the side of the rig the task is on**: the two
  input tasks offer Input names, the two output tasks Output names, exactly
  as the pen draws them.
- **They are page state, not routes.** The pen draws them behind the same
  frame, so Back returns to the task they were opened from rather than out to
  Settings, and the tab pills give way to the list.
- **The output list is one row per destination**, not per jack, because that
  is the unit a name belongs to.
- Renaming reuses the console's one rename sheet, with an empty name allowed:
  emptying the field is how a port is handed back its numbers.

#### Checks

- Dart: root 2267 passing and 35 skipped, `dart analyze` clean over `lib` and
  `test`, `bloc lint` clean over 241 files, both arb files at 1115 keys with
  no key in one and missing from the other.
- Mutation-checked: a header action that always names the inputs, a Back that
  leaves the route from the list, an output list drawn per jack, and a rename
  that is dropped each fail exactly the tests that name them.

### What retired with it

- **The Tracks routing tab and its per-track routing dialog.** They were the
  only dispatchers of the lane routing events, which the two new tasks now
  own. Their per-track quantize group is not lost: slice 2's Length & quantize
  page already writes the same override, and the dialog's three-way control
  was reading a derived view of it.
- **The interim click output card**, on the console's Device tab, and the
  output chips of the desktop settings' click section. Where the click goes is
  Output routing's; how loud it is has nowhere else to live until the Mixer
  holds it, so the section keeps the level and was renamed for what it is.
- **The Tracks tray panel lost its strip**, because a lone pill over a single
  body chooses nothing.
- Twenty-nine strings and five goldens went with those surfaces.

### Review round 1

Six reviews ran over the slice: correctness, removed behaviour, pen geometry,
test quality, and one each over the two engine pull requests beneath it that no review
had covered.
What they found in 3c, and what it cost:

- **Audio routing was unreachable on the appliance.** The accepted design
  reaches it from Settings; on the console the tray IS Settings, and the
  desktop settings page is behind a right-click, a key and a menu bar. A row
  on the Audio face's Device tab opens the route, and the click's level rides
  with it — the console had lost that too when the interim card retired.
- **The format lock asked about one jack**, while the repository refuses the
  pair change when EITHER member is armed. The control was drawn live and
  silently refused. It now asks about both, from one predicate.
- **Nothing clamped a chosen source or destination to the open device.** After
  an interface narrows, the page fell back to the first card while the
  controls went on editing the old one: the trim wrote a jack with no card,
  the level wrote a bus with no jack, and the lock described a third thing.
  Each projection now clamps, and everything below reads the clamped value.
- **A route saved on a wider rig could not be switched off.** Setting a
  destination must not claim a socket the interface has not got; clearing must
  reach both jacks. They are now different masks, and a stale route keeps a
  card of its own so it can be cleared at all.
- **"Reaches nothing" tested the raw mask**, so a source driving only jacks
  the device has not got looked routed while being silent.
- **A jack a track records beyond the device had no card**, so a lane from a
  wider rig was invisible, could not be switched off, and survived every
  restart. Those jacks
  now get their own cards.
- **A full track's cards looked live** and did nothing when tapped. They are
  drawn inert, with a sentence saying why.
- **Input setup was 96 px too low**, the whole tab: it used the pen's screen
  origin where its siblings used the main-area one. With that corrected the
  tab's internals line up. The tab also gained the meter readout it was
  missing, the clip line the pen puts beside the trim note rather than in
  place of it, the pen's own card ordinals, and the pair member's side on both
  the card and the trim label.
- **The clip tail was four cells, the pen draws two**, and the output meter's
  cells are 24 high, not the input meter's 28.
- **The name rows were a pill inside a row**; the pen makes the whole
  1708 x 108 row the button.
- **Two tests were vacuous**: the rename guard's real value is the store write
  it avoids, and the Routing rail row asserted a widget rather than a route.
  Both now test what the code does, and the route's own guard is covered where
  it lives.

#### Checks

- Dart: root 2243 passing and 35 skipped, `looper_repository` 469 passing,
  `dart analyze` clean, `bloc lint` clean over 238 files, both arb files at
  1091 keys.
- Every fix above is mutation-checked, and two of the first tests written for
  them were themselves vacuous under mutation and were rewritten.
- Six goldens added for the four tasks and the two name pages, which had none;
  the console Device tab's golden regenerated for the new row.

### What the same round found beneath this slice

The two engine pull requests under this one had never been reviewed. Two of
their findings were verified and fixed on slice 2b, and the stack was rebased
onto the fix:

- **A perf-log wire code collided.** The per-track decay code reused 315,
  which the performance-arm fact already had further down the same enum.
  Duplicate enumerator values are legal C, so it compiled silently, and the
  two codes carry different arms of the union: a decay set during a capture
  could hand the offline renderer a position, a master length and an iteration
  read out of a float. It is 317 now, in the wire-format table, and a test
  walks every code so the next one cannot collide silently.
- **The session's own record timing and overdub decay were write-only.** Only
  the per-track overrides reached the rig, so a track that follows the default
  came back on whatever the app was last set to.

The remaining three were then verified and settled too: the Sync force-arm
and the split quantize snapshot are fixed, and the per-track ordering claim
was refuted.

### The twelve engine findings, settled

Both engine pull requests beneath this slice went through an adversarial
round: one verifier per finding with a refute-first posture, then an
independent skeptic on anything that survived. Nine were confirmed by both
and are fixed; three were refuted with the code that blocks them.

Fixed on slice 2a: the dead master clock a mode switch left running after an
undo-to-empty (a 100-frame Free take was being padded to the erased take's
800 and played on its clock); a gate that measured published lengths where
the audio thread measures effective ones; the divide by zero its double read
allowed; two undo taps in one audio block restarting a recording; a mode
chosen with the device closed never being persisted; the grid outliving the
master it measured; and a clear-all redo group standing down over a member
whose undo was still parked.

Fixed on slice 2b: a Sync force-armed defining take starting off the
primary's loop top, which played the sub-loop rotated; and a snapshot that
could publish the quantize gate without its division, so a session saved in
that window recorded a different record timing from the one chosen.

Refuted: a dropped clear-frozen event (the control thread drains the event
ring either side of that push, so it cannot be full); a tempo derived from a
cleared take (that is the stated contract — a defining take sets the grid
and the restore path depends on the tempo surviving); and a per-track
quantize ordering race (neither direction makes the track inherit a live
grid before the arm is cancelled).

Two of the reviews corrected the work rather than just confirming it. The
skeptic on the double-tap rejected the originally proposed fix, which would
have wedged every effective-state read; and two existing tests proved that
the mode projection is load-bearing for the waveform sweep, so the
persistence moved to the point of choice instead.

One fix carries no test: the divide by zero is structural, the double read
it removes is the whole failure mode, and the race binary that could
exercise it deliberately links no engine code.

#### What did NOT retire, and why

The Signal face's per-jack output gate stays. It is a different fact from
anything the accepted routing design offers: a structural switch per hardware
output, with the last-live-output guard (#569) behind it, where Output setup's
mute is a per-destination mix fact that retains its level. Retiring it would
drop a shipped feature the accepted design does not replace. It needs a design
answer before it can move.

#### Checks

- Dart: root 2223 passing and 35 skipped, `dart analyze` clean over `lib` and
  `test`, `bloc lint` clean over 237 files, both arb files at 1086 keys.
- Five goldens regenerated and eyeballed (the Tracks tray with no strip, the
  Device tab with no click card), five deleted with their surfaces.

## Slice 3d — the Mixer view (#1016 part 3d)

Part 3d has two surfaces and they are not the same size of work. The MAIN
Mixer view is app-only over owners that all exist. The FOOT Mixer needs a
fourth interaction mode, which the survey found costs a pedal protocol
version and a firmware change and touches ten sites. They ship separately;
this is the first.

### The Mixer view

- **A third stage view, not a page.** `StageView` gains `mixer` and the two
  exhaustive switches over it — the view menu and the instrument area — point
  at every site that had to change. The chrome, the two dB scales and the
  session strip are the stage's own.
- **One owner, two surfaces.** Mute, Solo, pan and level dispatch the events
  slice 3a built and nothing else: the accepted design is explicit that a
  Mixer edit must not create a second mixer state.
- **The level's marker rides the meter.** The pen draws one control over the
  thing it governs rather than a fader beside it. Dragging anywhere in the
  meter's height sets the level; the lanes keep metering underneath; a double
  tap returns the track to unity, as the pan returns to centre.
- **Both sides meter separately**, from `peakL` and `peakR` — the fields
  slice 3a added for exactly this and which nothing drew until now. They are
  subscribed in their own leaf, so a level tick redraws two bars rather than
  the strip.
- **The dB scale follows the view.** It aligned to the Track column's meter
  by construction; it now takes the insets of whichever view is showing, so
  it lines up with the meter beside it either way.
- **Reset mixer** appears only in the Mixer, and clearing every Solo is a
  long press on a Solo button. Both events existed with handlers and no UI.

#### Deviations from the pen

- **No FX edit button.** The pen draws a pair — edit and bypass. The FX
  editor is slice 3f and does not exist, so that button would open nothing.
  The bypass ships; the edit button lands with the surface it opens.
- **No Backing & click sheet.** The pen draws it as a modal over the Mixer
  with four controls. Only the click's volume has an owner in this product:
  there is no backing player anywhere, and the engine has no click pan. The
  same call slice 3c made for the routing source, made once for both.
- **The strip scales below the pen's height.** The pen's strip is 858 tall
  with every part fixed, which is right at 1080p and impossible in a desktop
  window a third of that. Below its minimum the whole strip scales as one
  piece rather than silently sacrificing a part.

#### Checks

- Dart: root 2253 passing and 35 skipped, `dart analyze` clean over `lib` and
  `test`, `bloc lint` clean over 239 files, both arb files at 1107 keys.
- Mutation-checked: a pan that writes on every drag tick, a Solo long press
  that does nothing, two lanes reading one side, Reset mixer drawn in every
  view, and a level double tap that does not return to unity each fail
  exactly the test that names them.
- One golden added for the view, with a panned track, a soloed one, a muted
  one and an empty one.

#### Not verified here

The foot Mixer. It is a fourth interaction mode: a new member of the mode
enum, the mode cycle, the entry switch, the press matrix, the LED and caption
projection, the invariants, the pedal protocol and the firmware. That is its
own change and its own risk.


## Slice 3e — FX placement and printing (#1016 part 3e)

Five things: placement per instance, Pre printed once from the dry originals,
the All tracks recorded-mix chain, channel handling and level per instance,
and instance identities that survive all of it.

### Placement

- **It rides the ENTRY, not the address.** A pedal binding persists an
  `FxAddress` plus a slot id, and the accepted design requires a placement
  move to keep its assignment — so putting placement on the address would
  break the one thing the move must preserve.
- **A chain is stored Pre-first**, so the split the engine has to know is one
  boundary index rather than a per-slot flag. The write boundary partitions
  BEFORE it clamps: a clamp that cut across the partition would name a Pre
  count larger than the chain describing it.
- **The partition is stable**, so re-partitioning an ordered chain is the
  identity and a reorder within a stage survives the next write. Reorder is
  refused across the boundary on every chain, because the chain would be
  re-partitioned straight back.
- **Post is the wire default and is omitted**, so a chain with no Pre entry
  persists byte for byte as before. The legacy `stage` integer of a different,
  removed pre/post model is still ignored on decode.
- Live inputs and recorded parts have a setter. Whole tracks and outputs do
  not — see the deferral below.

### The print

The loop-stage wet cache becomes the printer. It renders exactly the Pre
prefix from the lane's dry pool and swaps the result in at the lane's own loop
boundary. That IS the accepted "prepared from original sources" and "switched
at an audio-safe boundary", and the recording is untouched: the print is a
rendered copy, so the dry original stays the render source however many times
the Pre chain is edited.

- **Post stays live, printed or not.** Not a choice: a Post tail has to be
  able to drain past a Stop and a baked tail cannot, so the whole-chain render
  the cache used to do was already at odds with the tail contract slice 3b
  shipped. The cost is that a cached lane now pays its Post chain's CPU, where
  before it paid none and its Post tail could not drain at all.
- **The key is the Pre prefix**, so a Post edit leaves the print standing
  rather than dropping the lane to live processing for a change that cannot
  make the render stale. The channel handling folds into that key too.
- **Stop takes the Pre tails with it.** There is no single place a track stops
  in this engine, so the edge out of sounding is watched per track. A Pre-only
  chain is additionally carried by the route closing; a chain with both needs
  the clear, which is what the second tail test pins.

### The All tracks chain

One config, one DSP instance per output bus. Since slice 3b every source picks
its own destinations, so "the combined recorded mix" is a per-destination
quantity: a track on Main and a track on Monitor are two different mixes, and
one shared instance would have to send each track's audio to the other's
jacks. The chain the player edits is one; the filter memory cannot be.

Topology keys off emptiness like the track bus, so an empty chain leaves the
tracks routing straight to their outputs bit-identically. It persists with its
own settings key and a manifest field at schema v8.

### Channel handling

Per instance, on every chain owner: input choice before the effects, output
choice and then level after them, on the engine's one unity-centre pan law.
The choices ride the entry's FEED, so a bypassed entry passes the pair through
exactly as it arrived. Read from a per-chain cache refreshed once per buffer —
the arrangement the enable bits use — so the hot path costs one flag on an
untouched chain and needs no per-lane array.

### Deviations and deferrals

- **A whole track's chain is stored wholly Post**, like an output chain. The
  accepted design does give a whole track a Pre/Post switch, but a Pre entry
  is printed from a dry original and this stage has none: it processes the SUM
  of the track's parts, computed live from lanes that each own their own
  recording. Delivering it needs either a per-part fan-out (one instance, N
  engine slots, and an identity story for that) or a bounce, which the design
  treats as its own journey. Storing a placement the engine cannot honour
  would be a control that reads as doing something and does not, so the
  write boundary forces Post and the question is recorded on #1016.
- **The All tracks chain is not an `FxStage` yet.** An address is what a pedal
  binding persists, so it arrives with the surface that can show what a
  binding points at — slice 3f. The engine and the repository own the chain
  from here.
- **The offline performance renderer does not model the Pre tail cut.** It
  replays the lane chain from the event log, which carries no channel handling
  and no stop-edge tail clear; it already documents its divergences from the
  live engine and this joins them.

### Checks

- Native suite green in all five variants, before and after every change.
- Dart: root 2261 passing and 35 skipped; `looper_repository` 495;
  `session_repository` 105; `settings_repository` 155; `segno_engine` 283.
  `dart analyze` clean at the root and in every touched package.
- Mutation-checked, each failing exactly the test that names it: clamping
  before partitioning, moving a re-placed entry in place instead of to its
  stage end, dropping the output stage's fixed Post, an unstable partition,
  always writing the placement key, dropping placement from a boundary arm or
  from equality, never pushing the Pre count, dropping the Stop-edge Pre tail
  clear, printing the whole chain instead of the Pre prefix, dropping the
  printed slots' masking, sharing one All tracks instance across destinations,
  writing an empty All tracks chain to the manifest, applying the channel
  handling to the dry as well as the wet, dropping the generation bump on a
  channel change, and pushing only the first entry's channels.
- Two tests were rewritten after a mutation survived them: the stage-end move
  (the entry had no stage-mate to be ordered behind) and the per-destination
  All tracks claim (a memoryless effect cannot show shared filter memory).
- Two of my own claims were withdrawn rather than shipped unobservable: a
  routing predicate keyed on a Post tail, and the pan-law reconstruction that
  a truncated read produced — recovered from git before it reached a commit.

## Slice 3e — the whole-track Pre render (#1016, owner direction 2026-09-10)

The owner settled the question part 3e deferred: keep the whole-track Pre/Post
switch, and build a non-destructive processed copy of the combined track. The
boundary is fixed in `docs/design/2026-09-10-whole-track-pre-render.md`; this
records what was built and what it cost.

### What it is

A track's Pre run is rendered over the combination of its parts — each part's
own PRINTED material at its level, mute and pan, summed — and swapped in at
the track's loop top. The parts' prints are the input, not something the job
re-renders, so it costs one stereo buffer rather than a copy of every part. A
part with no chain contributes its dry recording at level, which is its own
printed material.

### The rule the whole design rests on

**It renders only while every part's chain is wholly Pre.** A part carrying a
Post entry keeps the track's Pre run live, with the reason reported through
the cache's telemetry.

That one condition is what keeps every accepted behaviour: a part's Post tail
still drains past a Stop, the per-instance promise its own switch makes holds
without the player needing to know a render exists, and Bounce's two
categories still partition the chain.

The first design put the parts' whole chains inside the render and accepted
that a part's Post tail became captured material. An adversarial review of the
design confirmed twenty-six objections against it. The decisive one: flipping
a switch in the Whole track editor would change what a part's own editor
promises, on the default configuration, since a new instance on a recorded
destination is Post. Rendering a tail region to play at the Stop edge does not
rescue it either — the tail a Stop needs depends on where the player stopped,
and one stored region encodes one position.

### Engineering notes worth not rediscovering

- **Engaging must remove the parts from the bus, not merely bypass their
  slots.** A force-bypassed entry is unity passthrough, not silence, so
  bypassing alone would play the track's material twice.
- **The key is refolded every buffer, not memoised.** It spans every part's
  chain, level, pan and mute as well as the track's own Pre run, so a memo
  would want a bump on some fifteen setters and one missed bump plays a render
  that no longer describes the track. The refold is gated on a published
  render, so a track without one costs one relaxed load.
- **The cache now carries two entry classes.** The graveyard sizing, the LRU
  scan, the budget, shutdown and the job accounting were all lane-indexed; the
  accounting in particular assumed one mono source in three hard-coded places
  and now derives from the job's shape.

### A defect in shipped code, fixed on the way

The idle-track lane skip (#897) left a STOPPED track out of the lane loop when
none of its parts carried a chain. The Track-stage chain runs outside that
loop and kept ticking, but the routing mask is built inside it — so a
Track-stage Post reverb drained into nothing. "Stop drains Post tails" held
for a track whose parts had chains and silently did not for a track with all
its effects on the track itself, which is the canonical case.

### Checks

- Native suite green in all five variants, before and after every change.
- Dart: root 2262 passing and 35 skipped; `looper_repository` 496;
  `session_repository` 105; `settings_repository` 155; `segno_engine` 283.
  `dart analyze` clean at the root and in every touched package.
- The owner's verification list, each as a native test: the combination
  processed as one signal (two parts at 0.5 through a unity drive give
  tanh(1.0), where a per-part fan-out would give twice tanh(0.5)), live and
  printed agreeing, edits re-rendering from the originals rather than
  compounding, the recording and its layers surviving an overdub and an Undo
  under an engaged render, a part's Post entry keeping the track live and
  still sounding right, and Stop taking the Pre tails while the Post run
  drains.
- Mutation-checked: leaving a part out of the combination, dropping the
  printability rule, keeping the track's Pre tails at Stop, and restoring the
  idle-skip defect each fail exactly the test that names them.
- One test was rewritten after a mutation survived it: a part whose chain is
  wholly Post is refused by a different gate, so the case that actually
  distinguishes the rule is a part carrying BOTH placements.

### Not verified here

Playback transforms. Speed, Reverse, pitch preservation and Follow tempo do
not exist in this engine. The accepted direction for Speed is to stream from
originals inline, which composes with a render from originals — both read the
same recordings — but nothing tests that until Speed exists.

## Slice 3f part 1: the FX destination model

The FX surfaces the accepted design draws address five destinations: a live
input, a recorded part, a whole recorded track, All tracks, and one output.
The stage enum named four, and two of those five had no address at all. This
part builds the model underneath the surfaces, with no UI change of its own.

### What the stage enum says now

`input`, `loop`, `track`, `allTracks`, `output`. The `master` stage is gone.
It named one insert on the first output pair, which slice 3b had already
turned into one chain per output destination; `FxStage.output` carries the
destination in the address it already had a field for.

A persisted binding still spelling `master` decodes to `null` and goes inert.
That is the AGENTS rule (remove obsolete paths, do not migrate) and it is also
the safer reading: `master` named a stage whose meaning was "the first enabled
pair", and silently rewriting it as destination 0 would point a binding at a
destination its author never chose.

### One chain per destination, all the way down

The repository held one `_masterEffects` list and one flag. Both are maps
keyed by bus now, with the Track stage's own conventions:

- A destination's entry is dropped when its chain lands back at the default,
  so an entry in the map means "this destination is configured" and a cleared
  destination stops claiming a persisted key.
- `applySession` writes every destination the OLD rig configured as well as
  the ones the arriving rig names, so a session that mentions no destination
  resets rather than inherits.
- The restart replay walks the map instead of pushing bus 0.

Persistence follows the same shape: the settings key is `output_fx_chain.<bus>`
with a clear for a destination a load drops, the session manifest carries
`outputChains` (one record per destination, schema v9) where it carried a bare
`masterChain` string, and the performance arm snapshot records
`PerformanceOutputChain` per destination beside its `PerformanceTrackChain`
twin.

### What a binding can point at

The picker offers the All tracks chain and every destination the OPEN DEVICE
has, not only the destinations already carrying effects. A destination exists
because the interface has the jacks; a picker that hid the empty ones would
have nowhere to point a binding at the chain the player is about to build
there. `chainEntriesAt` draws the same line: an empty destination within the
device's count names a real, stompable chain, the way a configured monitor
does.

Binding rows name a destination by ORDINAL (`Output 1`), not by jack pair or
by the rig's rename. The label helper has neither the channel count that
decides whether the last destination is a pair or a single jack, nor the
rename map, and a row that guessed either would name a socket the interface
may not have.

### The retiring Signal domain

Its four tabs stay four tabs, now an explicit subset of the enum rather than
the enum itself, and they address destination 0. The All tracks chain is not
reachable from that face — it never was — and arrives with the FX surfaces
that replace it in the rest of 3f.

### A defect in shipped code, fixed on the way

`packages/performance_repository`'s test fake never grew the methods slice 3e
added to the engine interface: the five All tracks setters, the four
channel-handling setters and the two `preCount` arguments. Every test in that
package failed to COMPILE, so its whole suite (coverage floor 99%) was
silently absent rather than failing. Fixed on the 3e branch, where it was
introduced.

### Checks

- Dart: root 2264 passing and 35 skipped; `looper_repository` 501;
  `session_repository` 105; `performance_repository` 118;
  `settings_repository` 155. `dart analyze` clean everywhere, bloc lint clean.
- Five repository tests for the per-destination model: two destinations
  holding independent chains pushed to their own buses, the chain flag and
  entry flag and a parameter each addressed per destination, a destination
  past the ceiling refused rather than wrapped, `applySession` resetting an
  unnamed destination, and every configured destination replaying on restart.
- Two bootstrap tests: each destination persisting and restoring under its own
  key across a cold boot, and a load that drops a destination clearing ITS key
  so the next boot does not resurrect the previous rig on that pair.
- Mutation-checked: pushing only the arriving rig's destinations, replaying
  only destination 0 on restart, and dropping the destination at the engine
  boundary each fail exactly the tests that name them.
- Three goldens regenerated: the pedal binding list now offers `All tracks
  chain` and `Output 1 chain` where it offered one `Master chain`.

### A trap worth not rediscovering

`chainEntriesAt` is an EXTENSION on the repository, so `when(() =>
looper.chainEntriesAt(...))` does not stub it — mocktail RUNS it and registers
a stub against whichever member it happened to touch last. Two tests carried
such a line. They worked by accident while the extension's last call was
`masterEffects`; when it became `state`, they stubbed `state` to return a list
of effects. The real extension resolves from the members already stubbed
around it, so the fix was to delete the lines.

## Slice 3f part 2: the Effects destinations surface

The pen's `01 Effects · destinations`: one page for every destination, not one
page per stage. The Sound type row picks the strip, the strip picks the source,
and the chain underneath is whatever that source carries. A live input, a
recorded part, a whole track, All tracks and an output all arrive at the same
editor, which is what makes this one surface rather than five.

### What it draws

The Sound type row (Live inputs / Recorded tracks / Outputs), the strip for
that kind, the context row, and the chain in processing order.

- **Live inputs** carry the two-tier source card and the Off / Auto / On Hear
  live control, written through the monitor cubit that owns the Input stage.
- **Recorded tracks** carry the single-line buttons with All tracks beside the
  last track in the SAME strip, and a part picker offering only the parts that
  track actually has. Switching tracks returns the picker to Whole track: a
  part index names a lane of the track it was chosen on.
- **Outputs** carry the destination cards and the sentence that says what an
  output chain actually processes.

The chain is the pen's horizontal strip: a card per effect, a plain line
between consecutive cards, and a wider break with NO line where the Pre run
hands over to the Post run, because the loop player is in there. The
connectors have no arrowheads — the owner rejected them twice, and the order
of the cards is what says which way the signal goes.

### Where each control writes

Each stage has one owner and the page uses it: the monitor cubit for a live
input, and the looper bloc's own per-stage events for a part, a track, All
tracks and an output. There is deliberately no shared "set the enabled bit"
setter to route through — that is what would let one surface's write land on
another stage's chain.

Each strip keeps its own place, and so does each kind's chain scroll. Browsing
the chain never changes the selected source, and a context switch restores a
strip rather than resetting it.

### What this part does NOT do

The editors. Opening a card, the rack chain editor with its connected pedals,
the parameter controls, the channel-handling footer, the Pre/Post switch
itself, Add effects, Reorder, rack options and presets are the rest of 3f. The
two buttons that will reach them are drawn and inert.

The All tracks chain also gained a projection here: slice 3e built it in the
engine and the repository and left it unreadable from the app.

### Checks

- Root suite 2278 passing, 35 skipped; every package suite green; analyze and
  bloc lint clean.
- Ten widget tests: the Sound type row switching strips, each strip keeping its
  place across a switch, the tracks strip listing tracks with All tracks beside
  them, All tracks carrying neither part picker nor placement tag, a track
  switch returning the picker to Whole track, the cable between consecutive
  effects and the break where the Pre run ends, an output chain carrying no
  placement tag while a track chain does, the empty state, power writing to
  each stage's own owner, and a live input's chain both read and written
  through the monitor cubit.
- Mutation-checked: carrying the part across a track switch, drawing a cable
  across the stage break, and showing the placement tag on every destination
  each fail exactly the tests that name them.
- Four screenshots at the pen's 1920 x 1080.

### Two gaps this surface makes concrete

**There is no rack artwork, and no rack.** The accepted design's chain is made
of RACKS — named groups of pedals with their own level — drawn with the
original Looper X artwork. This engine's chain is a flat run of at most eight
entries with no grouping, and the extracted catalogue (159 presets, 66 artwork
files) is not in this repository. So a card here is one effect, drawn with the
app's own vocabulary rather than a placeholder picture pretending to be
artwork. Both are owner decisions, recorded on the issue.
