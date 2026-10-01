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


### Current-master reconstruction (2026-09-15, #1058)

The first design slice now starts from master `848f1337`, preserving the
current UART console, CTRL dispatch and appliance lifecycle. The source
branch `ec3e25f0` is retained as a merge parent. This step does not include the
later assignment, MIDI or FX slices from the complete integration checkpoint.

The independent review found defects that historical first-slice and later-tip
checks did not establish as fixed:

- Per-track waveform samples now span that track's whole recorded length,
  using the same resolved playback position as its playhead. This supersedes
  review round 3's master-lap cache policy above. Multiples and divisions no
  longer combine one coordinate system's samples with another's playhead.
- Stopped tracks retain their native waveform even before their first display;
  Clear and Undo-to-empty reset only the removed track's shape.
- Both displays use one domain projection for whole bars, including divided
  and independent loops. Unknown or fractional bar counts remain unknown;
  growing recordings do not rebuild the readout on every sample.
- The compact desktop Wave view scales its metadata to the available row
  height, preserving the full-size appliance layout and all four track targets.
- Selected-track frame tests assert actual waveform samples and independent
  playheads, including equal-name selection changes and empty tracks. Snapshot
  tests assert the native position, queued-trigger and output-peak fields.
- Preview providers and the Sessions dismissal test follow the current console
  lifecycle. Settings now calls the second window the selected-track display.

Final per-head validation and review evidence are recorded under
`docs/reviews/design-tracks-restack/`. Earlier review and CI results do not
certify this reconstructed head. The subsequent PRs still need reconstruction
in dependency order; this is not a merge of the full redesign.
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


### Slice 2a reconstruction (2026-09-15, #1060)

The mode-rules and reversible-edits slice is reconstructed on the reviewed
Tracks/UART base `09c8e9c2`, retaining its original `6cdfb9fb` parent. This is
the independently tracked part of #1012; timing and the Loop settings cards
remain subsequent slices.

The review repaired frozen-clear completion ordering and generation
ownership, deferred-state resets, current-mode clock restoration, persistence
of confirmed mode choices, and group metadata through rapid Undo/Redo.
A queued crown change now rechecks spans in the callback with the same fit
rule used by the control gate.

The user approved this completed-recording recovery policy:

- If an older take cannot fit the current mode, refuse before changing audio,
  history, effects, mutes or transport. Explain how to select Free and retry
  the same Undo or Redo. Do not stop or switch the session automatically.
- Preflight every member of Clear All recovery before restoring any member.
  A group containing unfinished frozen captures waits for all lengths to
  settle. Redo while that group is waiting cancels the whole waiting Undo.
- A clock-changing command still in flight asks the player to retry when it
  finishes. It must not be described as an incompatible recording.
- A short partial take inside an established Multi cycle remains a full-span
  loop with silence outside the captured audio. Do not confuse it with an
  older completed recording of a different length.

Final review and validation are under `docs/reviews/design-edits-restack/`:
2,255 app tests and 1,610 package tests passed, with native safety runs,
150-symbol FFI parity, analysis, Bloc lint and formatting clean. All five
review roles have no unresolved findings in this slice.
The later stack, Linux/appliance validation and human merge gates remain open.
## Slice 2b — Timing ownership and session recall (#1061)

Reconstructed on reviewed slice 2a `cf16b6b7`, retaining original timing
parent `42c4d079`. Tracking: #1061, part of #1012 and #1058; PR #1014 remains
stacked on the slice 2a branch. This section supersedes the original timing
slice's migration, Once relaunch and session-recall assumptions.

### Accepted behavior

- Record timing is one setting: Immediately, Loop start, Bar, 1/2, 1/4,
  1/8 or 1/16. Each track can inherit the default or keep an explicit value.
  The engine reads its own gate and division at recording boundaries. A
  refused change does not enable the old grid, change the displayed choice
  or persist an edit. Immediate recording retains its remembered grid.
- Overdub decay is 0–100 percent. Zero keeps previous layers; 100 replaces
  prior audio as the pass is written. Intermediate values compound across
  overdub passes. Changes ramp at the write head; playback does not decay.
  A nullable per-track override remains distinct from its default.
- Loop/Once is available in all five modes. Enabling Once during playback
  finishes the current pass. Explicitly launching a track after its automatic
  Once end plays its full recording from the beginning, without restarting
  siblings or changing their shared clock. Queued recording actions retain
  their own behavior. Default and group Once edits use one atomic native
  command, so queue refusal cannot change only some tracks.
- Count-in and Sound start exclude each other. Tempo owns their startup
  restore; Record Options edits the same repository state. Delayed preference
  reads cannot overwrite a recalled session or a later user edit.

### Ownership and persistence

Widgets dispatch typed events through Bloc/Cubit and repositories to
`AudioEngine`. Settings stores typed defaults and nullable overrides. The
obsolete per-track boolean preference is removed without migration.

Session schema v8 holds timing, decay, Loop/Once and length-preset overrides
in four content-independent maps. Empty tracks retain their settings, including
explicit values equal to defaults. First-use offline recall restores all eight
tracks' desired settings before any audio interface has been configured.

Save detaches caller maps before its first await. With a running engine it
waits for accepted commands to publish and captured layers to settle, then
reads BPM, tempo source, signature, exact bar count, mode and primary track
from the same native report. Offline saves use the detached desired settings.
It never infers recorded bar count from BPM or a future recording preference.

Recall validates unsupported tempo sources and invalid bar counts before
clearing anything. It waits for the clear to publish before restoring the
exact grid and importing audio. Recalled settings do not overwrite startup
preferences merely because a session was opened.

### Engine boundary and validation

The public APIs carry per-track recording division and feedback, exact
BPM/source restoration, a masked Once update, exact session bar count and
command-publication settlement. Successful posts are counted on control;
only the callback owns the applied count and release-publishes it after
snapshot updates. Readers acquire that publication before testing the
snapshot. No callback allocation, file I/O or lock was added.

The final rebuilt native library, five review roles, aggregate tests and
coverage evidence are recorded in `docs/reviews/design-timing-restack/`.
Native-dependent Dart tests were run with that library; earlier slice counts
are not used as proof for this reconstruction. The pumped test engine also
forwards native crown and recording settings instead of reporting defaults.

### Boundaries and next step

Hardware timing, audible decay transitions and physical pedals still need
appliance validation. Full remote CI remains a separate gate for this stacked
PR, and merge approval remains with the user.

Existing Free/Song audio session import and shared-mode division import
limitations remain explicit. This slice verifies musical settings and exact
shared-grid recall, not every older audio import transport. External tempo is
reserved and rejected on this reconstructed head until its receiving path is
integrated. No compatibility fallback or automatic mode conversion is added.

Next: slice 2c, the accepted Loop settings hub and its editors, using these
shared timing, playback and recall rules.

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
  overrides and could not express "follow the default"; their unused UI
  commands and all-track playback sweep are retired. The Loop settings pages
  use the shared playback default or nullable per-track overrides through
  `LooperOneShotToggled` and `LooperRepository.setOneShot`.
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


## October 1 reconstruction — Loop settings (#1012 / #1015)

This entry supersedes the historical slice-2c implementation details above.
The rebuilt slice sits on the recording-timing reconstruction, retaining
session schema 8 and the four independent nullable override maps. There is no
second Loop settings manifest or legacy migration path.

- A length or mode request copies the complete effective preset vector into
  one bounded engine command. Callback validation precedes every stop or
  mutation. A queue with one slot cannot apply only half the transition.
- The repository admits one pending mode/length request. It reads command
  settlement before a fresh snapshot and publishes only an exact confirmed
  vector and mode. Callback refusal leaves the confirmed cache intact.
  Timeout stops the engine and reports failure; closing a settings view does
  not stop audio. Configure clears abandoned commands before replay.
- Startup and session recall submit one complete vector. Save waits for a
  pending request and rejects a superseded session. Reconnect cancels the old
  request before restarting, preserves automatic recovery, and replays the
  last confirmed values. Offline choices apply without a callback.
- Defaults and every track retain independent Auto/Bars memory and nullable
  inheritance. Multi uses shared length while preserving inactive per-track
  values. Empty-track overrides survive save/recall. Refused timing changes
  leave the display and both saved timing keys unchanged.
- Touch and Flutter focus share edit, commit, reset and Cancel behavior.
  Double-tap resets once; Back, scope change and capture cancel drafts.
  Leaving Loop settings for Stage closes the original tray. Removed controls
  include the coarse quantize group and orphan multiple/all-track Once
  commands; bootstrap and session replay keep their lower-level APIs.
- Eleven Loop goldens were inspected against the saved Pen design. Five
  related Settings/routing goldens were intentionally refreshed and reviewed.
  These checks are author visual evidence, distinct from CI and hardware.

The normalized checks and resolved review findings are in
`docs/reviews/design-loop-settings-restack/README.md`. Native and session
correctness use sample/state assertions, refusal tests and red/green
reproductions, rather than regenerating expectations from the implementation.
The separate Audio & tempo processing and physical UART encoder work remain
explicit later milestones. Existing human merge gates remain in force.
