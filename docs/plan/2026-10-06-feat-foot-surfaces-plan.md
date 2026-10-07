# Foot surfaces: Pending Hold, FX Toggle/Hold, Custom face, foot Tuner, New Loop and recording retry by foot

<!-- cspell:ignore Eukr Gtjy RKTE dged slotless memmove -->

Tracking: #1229, `autonomy:merge-gate`, human merge gate.
Status: plan, revised after the PR #1237 review (findings H1-H2, M1-M6,
L1-L11 applied; §9 maps each). Parts 1 and 4 in build.
Base: `origin/claude/segno-integration` at `097e1ef68` (Reverse P3 merged). Unless a branch is
named, every `file:line` below is on that head. Branch-qualified references:
`origin/claude/peel-1164-p3` (PR #1233, "PeelP3", in review), `origin/claude/library-1178-p5`
(PR #1216, "LibP5"), `origin/claude/settings-tiles-plan-1199` (PR #1208,
"Settings plan"), `origin/claude/recording-recovery-plan-1198` (PR #1205,
"Recording plan").

Scope (issue body and the gap inventory of 2026-10-06):
- the two owner-approved pen section 10 proposals: the Pending Hold cue, and FX
  Toggle/Hold per pedal (with its held-contact LED);
- E6-7 foot Tuner, which replaces the tray tuner that #1199 retires;
- E6-9 New Loop by foot and Record-performance retry by foot;
- E6-10 the Custom performance face;
- E5-8 the FX-mode pedal binding fixes #884, #873 and #601.

Design source: the 107 MB main-checkout `segno-ui.pen`, group `01 CURRENT UX`,
read through the pencil MCP (not saved). Executable reference for gestures and
captions: `docs/design/pedal-performance-study.js` and
`docs/design/tuner-performance-study.js` in the main checkout (untracked, see
the design-studies note in `docs/PROGRESS.md`). Contract:
`docs/handoff/segno-app/accepted-behavior.md` §4 (`:286-309`).

## 1. Current boundary (verified)

### 1.1 Modes and faces

- `InteractionMode` is `record, mute, fx, custom, mixer, fade, reverse`
  (`lib/looper/model/interaction_mode.dart:8-50`); `bootDefaults` is
  `[record, mute]` (`:60`). `ControlCubit` owns it
  (`lib/control/cubit/control_state.dart:82`) and `setMode` is the single entry
  (`lib/control/cubit/control_cubit.dart:1428-1530`), which replaces
  `_surfaceVisit`, runs `_invalidateGestures` (`:2949-2972`) and does per-mode
  entry work.
- Faces: `tracks_view.dart:219-225` picks `FootMixerView` for mixer,
  `FootFadeView` for fade, `FootReverseView` for reverse, and the Tracks
  columns for everything else. FX only changes the stage background
  (`:215-217`). **Custom shows the Tracks face**
  (pen note `MV9wz`: "the screen still shows the Tracks face while it is in
  force ... The face is a separate piece of work").
- Each face is a full-screen pedal map built from the shared
  `PerformancePedal` widget (`lib/looper/view/performance_pedal.dart:14-88`, with `detailIcon` and
  `detailHighlighted` since Reverse P3)
  over a pure role table and projection (`lib/control/model/foot_fade.dart:154-193`,
  `projectFootFade` `:216-248`), a stateless actions object
  (`lib/control/foot_fade_actions.dart:8-84`) and a `part` of `ControlCubit`
  (`lib/control/cubit/control_foot_fade.dart:3-75`). On-screen contacts enter
  through `footFadePressed/Released/Cancelled` and `activateFootFadePedal`
  (`control_cubit.dart:2089-2108`). Refusals bump a counter in `ControlState`
  (`footFadeFailure`, `footReverseFailure`, `control_state.dart:117-120`) that a
  `BlocListener` in `tracks_view.dart:129-161` turns into a toast. Reverse
  follows the same shape (`lib/control/model/foot_reverse.dart`, whose
  `recorded`/`busy` split is at `:44-57`, `lib/control/cubit/control_foot_reverse.dart`,
  `lib/looper/view/foot_reverse_view.dart`). The foot Peel
  surface is in review (PeelP3).
- LEDs: `ControlCubit._pushProjected` (`:3305-3324`) projects
  `projectTrackLed` (`lib/control/control_projection.dart:76-131`) and the
  physical mask `_physicalButtonMask` (`:251-303`, slot-less rule `_slotless`
  `:244-249`); custom, mixer, fade and reverse map to `PedalMode.custom`
  (amber) on the wire (`:205-213`). Invariants:
  `lib/control/invariants.dart:143-206`.
- `takeLocked` is `_closing || power UI up || sessionTransitionActive`
  (`lib/app/application/app_runtime.dart:154-155`). `_onPress` drops every
  press while it holds (`control_cubit.dart:2341`), and those refusals are
  silent because the power dialog or the session load already owns the screen
  (`app.dart:433-437`).

### 1.2 Gestures

`_HoldGesture` (`control_cubit.dart:72-120`) arms a `Timer` at `_longPress`
(`:1050`, default 800 ms, `loadPedalLongPressMs` `:1177`), runs `onHold` and
retires the tap, or runs the tap on release. Every pedal hold is armed through
`_armGesture` (`:2690-2703`); the external jacks also use it (`:467`). Nothing
publishes that a hold is pending, so no surface can draw a cue.

### 1.3 FX mode

- Dispatch is inline in `_onPress` (`:2374-2396`): a track switch's binding
  for the current bank (`PedalBindingKey`, per bank,
  `lib/control/binding/pedal_binding.dart:24-62`) wins; an unbound switch
  toggles its own track chain (`trackPressed`, `:1802-1803`). `PedalBinding` already carries
  `BindingBehavior.toggle | momentary` per switch, plus an optional
  `holdTarget` (`pedal_binding.dart:135-170`, `canHold` `:245-247`); a
  momentary press captures and restores (`_pressBinding` `:3112-3160`,
  `releaseAllMomentary` `:2984-2990`). Stop is panic on tap and restore on
  hold (`_armStop` `:2768-2773`, `_armStopRestore` `:2781-2801`); Bank hold is
  Record performance (`_armBank` `:2861-2867`); Rec/Play, Undo and Clear are
  inert (`:2398-2437`).
- The FX LED already follows the two behaviors: a momentary binding is lit
  only while its contact is held; a toggle binding reads the live target
  (`_boundChains` `:3210-3246`, `control_projection.dart:114-129`).
- The face is the #692 Candidate A re-dress of the Tracks columns
  (`lib/looper/view/track_column.dart:256-300`, `_FxChainDressing` `:926`).
  #884: `_TrackSlot.build` constructs `TrackColumn` with no `fxTarget`
  (`tracks_view.dart:554-563`), so the cell shows the column's own chain
  (`track_column.dart:271-273`) and a pedal bound elsewhere reads blank.
  #873: `_stageFxTargetLabel` prints `LANE {lane}` 0-based and without the
  track (`track_column.dart:895-902`). The shared label `fxStageLabel`
  (`lib/control/binding/binding_labels.dart:22-43`) is already 1-based and
  names the track. #601: the Signal cards it names were retired in
  `4219c3fbb` ("the Signal tray domain retires"); `chainSummary` no longer
  exists on the trunk.

### 1.4 Custom mode

`_onPress` handles MODE (exit) and Bank (page) on contact and arms every other
switch through `_armCustom` (`:2362-2373`, `:2450-2462`); assignments come from
`PedalSetup.customFor(button, bank)` (`lib/control/binding/pedal_setup.dart:270-287`).
LEDs: `_customFunctionStates`/`_physicalCustomStates` (`:3335-3366`),
`_customActionIsActive` (`:3394-3449`; `recordPerformance` is lit while
`_performanceArmed`). `ControlCommand.recordPerformance` runs
`_togglePerformanceRecordAccepted` (`:2623`, `:2818-2825`), which arms or
disarms through `PerformanceRepository` directly.

### 1.5 Tuner

- Tray face `lib/tuner/view/tuner_tray_panel.dart`: arms in
  `didChangeDependencies` and disarms in `dispose` (`:37-49`), one pill per
  non-loopback input with no paging (`:66-79`), and by design does not mute
  (`:14-16`). Its only entry is the tray rail (`lib/looper/view/tray/tray_navigation_rail.dart:45-46`,
  `lib/looper/view/tray/tray_panel.dart:142-143`).
- `TunerCubit` (`lib/tuner/cubit/tuner_cubit.dart`) arms through
  `LooperRepository.setTunerInput` (`:59`, `:76`, `:107`), accepts readings at
  confidence >= 0.5 (`:43`), holds a stale reading dimmed for 1.2 s then clears
  it (`:39`, `:165-177`), and returns early without starting that hold when the
  snapshot's `tuner_input` differs from its own (`:148-151`). A4 is the const
  `kReferenceHz = 440` (`lib/tuner/pitch.dart:49-52`); `pitchFromHz` already
  takes a `reference` (`:66`) that the cubit never passes (`:158`). Nothing
  persists a reference or an input. Provider: `app.dart:565-571`.
- Native: `le_engine_set_tuner_input` (`segno_engine_api.h:2338-2348`) taps the
  conditioned input before any lane or FX (`engine_process.c:6803-6805`) and
  never touches the signal; `LE_CMD_SET_TUNER_INPUT` resets analysis and
  disarms on an out-of-range channel (`:3509-3525`); boot is -1
  (`engine.c:796-799`); snapshot `tuner_hz`, `tuner_confidence`, `tuner_input`
  (`segno_engine_api.h:1219-1224`). Silence publishes 0 Hz every hop
  (`engine_process.c:5266-5282`).
- Monitor mute is persistent intent: `LooperRepository.setMonitorMute`
  (`looper_repository.dart:5251-5263`) is replayed on restart (`:2645-2652`),
  captured into Session saves (`lib/app/fx_chain_persistence.dart:166-175`,
  `:488`) and perf-logged natively (`engine_process.c:3887-3892`). There is no
  temporary mute anywhere. Pairs exist only in Dart (`InputSetup.pairOf`,
  `packages/looper_repository/lib/src/models/input_setup.dart:69-84`).
- #909: with the tuner armed, `tuner_tap_block` shifts a 2048-sample ring with `memmove` every
  frame (`engine_process.c:5245-5251`) and runs a whole YIN pass in one
  callback. PR #912 (`fix/tuner-callback-latency-909`) fixes both but targets
  `master`, not this trunk.

### 1.6 New Loop and the recorder

- LibP5 `SessionCubit.newLoop()` (`lib/session/cubit/session_cubit.dart:456-529`
  on LibP5) preserves the outgoing rig (D7, `_preserveOutgoing` `:286`),
  releases held momentaries (`:476`), and applies the empty rig through
  `_applyRig`, whose first step is `PerformanceRepository.disarmAndFinalize()`
  (`:570`). The Library plan names it "the one method a foot binding (E6-9)
  will call" (LibP5 `docs/plan/2026-10-06-feat-library-sessions-plan.md:251-252`;
  D14 is `:424-428` on the trunk). The LibP4/LibP5 review's Finding 2 (Open or
  New loop during a track capture drops the take or fails as a save) is not yet
  fixed on either branch; Part 7 depends on that fix. `ControlActionGroup.sessions` is empty
  (`lib/control/binding/control_action.dart:70-71`).
- Held takes, `saveHeld()` and the recorder's `saveRecovered()` are Recording
  plan Parts 8 and 9 (`docs/plan/2026-10-06-feat-recording-recovery-plan.md`
  at `57a5324b8`: Part 8 `:1011`, Part 9 `:1068-1103`, D9 `:643`). A held take
  holds no guard (`:592-595`), so arming a new take while one is held is
  admitted. `Held(saveFailed: true)` is set inside the recorder cubit's
  `saveRecovered` (`:1095`). Nothing on the trunk retries a failed save.
- Finishing a capture opens the completion sheet whatever stopped it
  (`onPerformanceRecorderState`, `lib/looper/view/tracks_commands.dart:436-466`).

## 2. Pen screens each part must match

| Part | Screens (node ids) |
|---|---|
| 1 Pending Hold | 10 `Pending Hold · proposal` (`v0aHo`, face `PRSrG`): `pedal-hold-progress` `IBL3g` 159 x 3 at x 21, y 221 of the 201-wide pedal, track `#303b4b`, fill `#a8c7fa` growing left to right; the held pedal's hint text brightens from `#aebdd2` to `#d2e3ff` |
| 2 FX face | 10/03 `Performance / FX` (`Pmk4g`, `noDGu`); 10 `FX held contact · proposal` (`Pz1HA`, `ri60q`); 04 `Rack activation` (`J8U51x`: Active when On/Off Latched, Held Foot down, Released Foot up) and `Pedal banks` (`WmJsF`) for the meaning of Toggle and Hold |
| 3 Custom face | 10/02 `Performance / Custom` (`D1aJr9`, `uEukr`); note `MV9wz`; 20/03 `Recording by foot` (`E7kQV`); 08/02 `Pedals / Custom controls` (`OgLiI`) |
| 5, 6 Tuner | 23/1 `Tune an input` (`o9d3X`), 23/2 `In tune` (`lDOKf`), 23/3 `No signal` (`d9CLS`), 23/4 `Live monitoring` (`sMhKO`), 23/5 `18 inputs` (`ta3Fj`); 24/1 `Press Mixer · Hold Tuner` (`nGtjy`) |
| 7 New Loop | 19/02 `New loop / Keep current session` (`U2bRH`) for the copy; 19/06 `New loop / Ready` (`uRKTE`) |
| 8 Retry | 20/03 `Recording by foot` (`E7kQV`), 20/05 `Interrupted recording` (`dgedL`), 20/06 `Save failure` (`owAnd`) |

Pedal map geometry shared by every face (pen `Performance pedals`, e.g.
`ECxUp`): Clear 168 x 300 at x 451 and Bank at x 668 in the raised row; the
front row 201 wide at x 0, 217, 434, 651, 868, 1085, 1302, 1519; pedal face
159 x 216; caption 25 px `#e7edf6`, hint 19 px `#aebdd2`. An unavailable pedal
draws its face at opacity 0.3, caption 0.35 and LED 0.4.

## 3. Notice policy and the Reverse P3 review lessons, applied to every part

The shared notice policy (coordinator, 2026-10-06, the same one Peel P3 is
being fixed to):

1. **An empty track's pedal is dimmed and silent.** Where a pedal stands for a
   track, `hasContent == false` draws it at the unavailable opacities and a
   press does nothing and says nothing.
2. **A busy or refused press on recorded material gets a notice.** A recorded
   track that is capturing, pending or refused by the engine keeps its real
   words (never "Empty"), **stays enabled**, and a press shows the face's
   failure toast. The same holds for any switch that has an action but cannot
   run it now (a stale binding, an unavailable assigned target, a recording
   that is saving): it is drawn with its real words, the caption may be dimmed
   where the pen dims it, but the pedal stays enabled. `PerformancePedal`
   drops a contact when `enabled` is false (`performance_pedal.dart:93`), so
   only an enabled pedal lets an on-screen tap reach the dispatcher and give
   the same notice a physical press gives (merged Reverse:
   `foot_reverse_view.dart:337-340`). On-screen and physical contacts always
   behave the same.
3. **Assigned-action refusals always get a notice.** A Custom, External or
   MIDI assignment that is refused for any reason, an empty target track or an
   unavailable action included, shows a toast from any mode. Rule 1 does not
   apply to assignments: an assignment is not the track's own pedal.

Only a switch with **no action at all** in the current mode is dimmed and
silent (`enabled: false`): an empty track's own pedal, a Tuner position past
the last input, an unbound switch the pen dims, Bank with one input page.

How each part applies it:

| Part | Dimmed and silent | Enabled with a notice when refused |
|---|---|---|
| 2 FX face | unbound Rec/Play, Stop, Undo and Clear (the pen dims them, `noDGu`) | any bound switch whose binding is stale or whose write is refused |
| 3 Custom face | unassigned switches | every assigned switch, including an unavailable action or an empty or busy target track |
| 6 Tuner | positions past the last input (`—`), Rec/Play, Bank with one page | reference at its 420 or 460 limit, failed save, failed arm or mute |
| 7 New Loop | – | whatever `SessionCubit.newLoop` refuses, with its own notice |
| 8 Recording retry | – | a press while the take is saving (caption `Saving recording` dimmed, pedal enabled); a failed retry |

Lessons from the Reverse P3 review (PR #1209), which this policy settles:

- **Markers take real layout space.** The hold-progress bar, the Toggle/Hold
  line, the Tuner's status line and every caption row are laid out at all
  times and only change opacity or text, so nothing reflows. Each face gets a
  geometry test in the `es` locale with the longest caption, asserting that no
  two text boxes intersect (the probe matrix the review asked for).
- **Busy tracks never read "Empty".** No face derives a word from
  availability. Content words come from content (`hasContent`); whether a
  switch can act now is a separate fact, as the merged Reverse model splits
  `recorded` from `busy` (`lib/control/model/foot_reverse.dart:44-57`).
- **Silent only where the policy says so.** Presses dropped under
  `takeLocked` also stay silent, as on every face today (§1.1), because the
  power dialog or the session load already owns the screen.
- The guards the review found untested get one test each in every new cubit
  part: the session-transition gate, the visit identity of a late failure
  report, Exit while not editable, `toggleMode` out of the new mode, and that
  inert switches leave transport untouched.

## 4. Parts

### Part 1: the Pending Hold cue (about 200 production lines; no dependencies)

**Model.** `ControlState` gains `pendingHolds: Set<PedalButton>` (the pedals
whose hold is armed and not yet settled) and `holdThreshold: Duration` (the
loaded `_longPress`). It publishes only the fact, never an instant (review
L2): the Pi has no RTC and NTP steps the wall clock after boot, so the widget
times the bar from its own ticker. `_armGesture` gains a `PedalButton? cue`
argument; when non-null, and only in a mode whose surface draws pedals
(Mixer, Fade, Reverse, FX, Custom, and later Tuner and Peel), the button is
added and the state emitted. Tracks and Mute draw no pedals (O1), and every
stomp there would otherwise rebuild the whole Tracks screen for a cue it never
shows (P1 review M1). It is removed, in any mode, when the hold fires, the release lands, or the gesture is cancelled
(`_HoldGesture` reports each through one `onSettled` callback added to
`press`). `onSettled` never emits after `close()` (`isClosed` guard): `close`
cancels every gesture. Every `_armGesture` call site that arms a pedal passes
its button; the external jack site (`:467`) passes null, since no surface
draws CTRL jacks. `_invalidateGestures` and `_cancelSurfaceHolds` clear the
set.

**View.** `PerformancePedal` gains `holdPending` and `holdThreshold`. It
always lays out the 3 px bar slot under the face (opacity 0 when idle). When
`holdPending` turns true it runs an `AnimationController` of `holdThreshold`
from 0 (the ticker is monotonic, and no per-frame cubit emits are needed);
when it turns false the bar hides. While pending the hint text brightens
(`#d2e3ff`); the bar's track is `#303b4b` and its fill `#a8c7fa` (pen
`IBL3g`), three new `SurfaceTheme` tokens (`holdTrack`, `holdProgress`,
`holdPendingText`). Every face
passes `state.pendingHolds.contains(button)`; Mixer and Fade get the cue at
once (Reverse arms no holds, so it never shows one). The bar slot moves every
face's layout by 3 px, so the Mixer, Fade and Reverse goldens are regenerated
in this part.

**Refusals.** None new: the cue only shows a gesture the cubit already armed.

**Tests.** Cubit: arming a Fade track hold and a Mixer Undo hold publishes the
button; release before the threshold, the hold firing, a mode change, a
session change (`_cancelSurfaceHolds`) and close each remove it, and close
emits nothing afterwards. Widget: 400 ms after `holdPending` turns true with
an 800 ms threshold the fill is half the 159 px track, full at 800 ms, gone
after release; the bar slot height is identical with and without a pending
hold; `es` geometry probe. Golden: `foot_mixer_pending_hold.png` matching
`PRSrG`'s bar and hint colour, plus the regenerated face goldens.

```success-criteria
GOAL: Every on-screen pedal whose hold is pending shows the pen's progress bar and brightened hint, and nothing reflows when it appears.
SUCCESS CRITERIA:
- pendingHolds gains the button on arm and loses it on release, hold, mode change, session change and close; nothing is emitted after close. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The bar fills linearly to the threshold from the widget's own ticker, and its slot takes the same space idle and pending. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- The Mixer, Fade and Reverse goldens are regenerated and compared on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: on the appliance, hold Undo on the foot Mixer: the bar fills over 800 ms and the level resets to unity as it completes; a short press shows the bar briefly and steps the level down. | verify: manual on device
NON-GOALS:
- A cue in Tracks and Mute modes, which draw no pedals (owner decision O1); an LED cue.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 2: the FX face with Toggle/Hold per pedal (about 640 production lines added, about 300 removed; no dependencies)

**Decision D1.** FX mode gets a pedal-map face (10/03) like Mixer and Fade, and
the #692 Candidate A re-dress of the Tracks columns is removed:
`TrackColumn.fxTarget`, `inputNames`, `_FxChainDressing` and
`_stageFxTargetLabel` (`track_column.dart:129-175`, `:256-300`, `:445`,
`:895-902`, `:926-`), the `fxSurface` background branch
(`tracks_view.dart:215-217`), and the tests that exercise those fields
(`test/looper/view/tracks_view_test.dart:1003-1187`). The pen draws FX as this
face (`noDGu`), and the approved FX Toggle/Hold proposal is drawn on it; the
Candidate A notes all sit in `02 EARLIER APPLICATION`. This closes #884 and
#873 by construction: the caption reads the binding, and the stage words come
from the shared `fxStageLabel`/`bindingTargetLabel`. The PR quotes the #692
history for the owner: on 2026-08-26 the owner asked to keep the track
waveform visible behind FX cells; pen 10/03 supersedes that, and this face
removes the waveforms that ruling kept.

**Model** `lib/control/model/foot_fx.dart`: `FootFxPedal` roles for all ten
switches and a pure `projectFootFx(ControlState, LooperState, FxNames)`, where
`FxNames` is a small resolver built from `LooperRepository` in the view
(`FxChainLookup` is an extension on the repository,
`packages/looper_repository/lib/src/fx_chain_lookup.dart:6`, not a type a
projection can take):
- **Every bindable switch** (Rec/Play, Stop, Undo, Clear and the four track
  switches; only MODE and Bank are unbindable, `pedal_binding.dart:68-71`)
  with a binding for the current bank: title = the target's chain or effect
  name from `FxNames` (the #884 data source), falling back to
  `bindingTargetLabel`; detail = `Toggle` for `BindingBehavior.toggle`, `Hold`
  for `momentary` (pen `ri60q`); hint = `Hold · <hold target label>` when the
  binding has a `holdTarget`; semantics add `fxStageLabel`; drawn active and
  enabled. FX `_onPress` already runs these bindings for every bindable button
  (`control_cubit.dart:2378-2397`), so the face now shows pedals that act.
  A stale binding (`decodeTarget() == null`) reads the assignment screen's
  broken-row wording with its caption dimmed, and stays enabled (§3 rule 2).
- Unbound track switch: title = the track's chain name or `Track N`, detail
  `Toggle` (it toggles the track chain, `:1802-1803`).
- Unbound Rec/Play, Stop, Undo and Clear: dimmed and inert, as the pen draws
  them (`noDGu`, opacity 0.3). This removes the unbound-Stop panic and its
  restore hold (decision D3, owner decision O3).
- **Track FX off / Track FX on (O3).** `ControlCommand.trackFxOff`
  (`command:track-fx-off`) and `trackFxOn` (`command:track-fx-on`), the first
  members of `ControlActionGroup.fx` (`control_action.dart:63-65`), with
  labels `Track FX off` / `Track FX on` (`control_action_labels.dart`, l10n en
  and es) and `_runCommand` cases that call `_sweepTrackChains`
  (`control_cubit.dart:1916-1923`), which stays: it is the panic's own code
  and the commands need it. Off turns every track chain that has effects off;
  on turns every track chain on, the empties included, and does not restore
  an earlier pattern, which its label says. The public `panicTrackChains` and
  `restoreAllTrackChains` go, and so does the FX arm of `ControlCubit.stop()`
  (`:1741-1742`, which called the panic). Assignable on Custom, External and
  MIDI like any command; their LED follows the generic command rule (lit on
  contact). A refused sweep gets Part 3's assigned-action notice when that
  lands. The PR's release note says:
  "FX mode: Stop no longer switches every track's effects off, and holding it
  no longer switches them back on. Assign Track FX off and Track FX on to any
  pedal, CTRL switch or MIDI control instead (Pedals > Custom controls,
  External pedals or MIDI controls)."
- **One-time notice (O3, rule 3, like D11).** The first time FX mode is
  entered after the update, an info toast says: "Stop no longer switches
  every track's effects off in FX mode. Assign Track FX off or Track FX on to
  a pedal instead." A settings flag `fx.stop_change_notice_shown` is written
  when it is first shown, so it shows once per install, whatever the outcome
  of the write (a failed write may show it once more, never on every entry).
- **MODE is Exit (decision D13).** Pen 10/03 draws MODE as `Exit`, lit, and
  accepted §4 requires a foot Exit. On the trunk a MODE press in FX ran the
  configured MODE pair (Mute on press, Custom on hold). In FX it now exits on
  contact to the mode FX was entered from (`_fxReturn`, `:1101`), with no hold,
  as Custom's MODE already does (`:2362-2373`).
- Bank: `Bank A/B`, `Switch bank`, as the pen draws it. Its hold keeps
  Record performance (`_armBank` `:2861-2867`), which the pen's slice-4c note
  documents (`po4RZ`: "Bank Hold retains performance-recording access");
  10/03 draws no hint, so none is drawn.
- MODE: `Exit`, lit.
- `selected` mirrors the physical LED, which already lights a momentary only
  while held and a toggle while its target is enabled (`_boundChains`
  `:3210-3246`, extended here to the four non-track bindable switches through
  the physical mask). The held pedal's detail line brightens while its contact
  is held (`ri60q`, Light FX 1) through `PerformancePedal.detailHighlighted`
  (`performance_pedal.dart:74`).

**Cubit.** `footFxPressed/Released/Cancelled` and `activateFootFxPedal` admit
on-screen contacts into `_handleEvent` the way `footFadePressed` does
(`:2089-2108`); a cancelled on-screen contact restores a held momentary, so
a contact that leaves can never strand a target on (B1). FX dispatch stays in
`_onPress` (`:2374-2437`) minus the unbound-Stop panic and the bound-Stop
restore hold (`_armStop` and `_armStopRestore` are deleted; `_sweepTrackChains`
stays for the commands). In FX mode the Rec/Play, Stop, Undo and Clear mask
rule (`control_projection.dart`) lights each only for what its binding
drives, read from the same per-switch values the face reads
(`ControlState.fxSwitches`, published by the cubit beside the frame push, so
the face and the LEDs cannot disagree).

**Refusals** (§3). A stomp on a stale binding: toast `footFxUnavailable`
("This pedal's effect is no longer available. Reassign it in Pedal
assignments."). A refused enable write: the new `footFxFailure` counter and
toast ("The effect could not be switched. Try again."). Both are reached from
the face and from the foot alike, because the pedal stays enabled. No FX
switch dims for an empty track: chains exist and toggle on empty tracks.

**#601.** Closed as obsolete with the evidence in §1.3. The face reads each
target's own `enabled` flag (a slot target its slot, a chain target its
chain), so a bypassed effect never reads as active here.

**Tests.** Projection: bound chain on another stage (the #884 repro: pedal 1
bound to Input 2's chain, track 0 without effects) names the chain and its
stage; a loop-lane target names `Track 2 lane 1`, or the track's own name in
its place when it has one (`pedalAssignStageLoop`, `app_en.arb:1558`; the
#873 repro, 1-based); momentary reads `Hold`, toggle `Toggle`, hold target
adds the hint; stale stays enabled with the broken-row text and its tap
toasts; a bound Rec/Play and a bound Stop show their binding and run it from
an on-screen tap; unbound Stop is dimmed and its press changes no chain; bank
B shows B bindings. Widget: momentary LED and highlighted detail only while
the contact is held; toggle stays lit after release; Exit returns to Record.
Commands: `command:track-fx-off` and `command:track-fx-on` round-trip and are
the FX group's whole listing; assigned on Custom, off leaves a chain-less
track alone, on cures a stale bypass on one, and a second off writes nothing;
an assigned `Track FX on` from a CTRL switch supersedes an older MIDI hold;
unbound Stop does nothing on tap or hold; `stop()` in FX does nothing. The
one-time notice shows on the first FX entry and not on the second, and not
after a restart once the flag is set. Goldens `foot_fx_default.png` (`noDGu`),
`foot_fx_held.png` (`ri60q`) and `foot_fx_spanish.png`, `es` geometry probe.
Removal:
`! grep -rn "fxTarget\|_FxChainDressing\|_stageFxTargetLabel" lib test`.

```success-criteria
GOAL: FX mode shows the pen's pedal-map face, every bindable switch names what its binding drives with a Toggle or Hold line, and a held momentary lights only while held.
SUCCESS CRITERIA:
- A pedal bound to a chain on another stage names that chain and stage; a lane target is 1-based and names its track. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Bound Rec/Play, Stop, Undo and Clear show and run their bindings on screen and by foot; unbound ones are dimmed and inert. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Toggle and Hold lines follow BindingBehavior; the momentary LED and highlight last exactly as long as the contact. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- A stale binding stays enabled and its press shows one toast on screen and by foot. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Track FX off and Track FX on are assignable FX-group commands that sweep the track chains as the panic and its hold did; the FX Stop and stop() no longer do. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The one-time notice shows on the first FX entry only. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- MODE exits FX on contact to the mode FX was entered from. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The Tracks-column FX re-dress is gone. | verify: ! grep -rnE "fxTarget|_FxChainDressing|_stageFxTargetLabel" lib test
- Goldens match noDGu and ri60q on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: a momentary FX pedal's LED is lit only while the foot is down; a toggle stays lit. | verify: manual on device
NON-GOALS:
- New binding semantics. Pen 04 models activation per rack (On/Off latched, Held foot down, Released foot up) with several racks per pedal, which is why 10/03 titles pedal 1 `FX A1`; the trunk binding is one target per key with toggle or momentary. `Released` and multi-rack titles wait for the E5-8 activation redesign. FX activation editing; the Mute and Tracks faces.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 3: the Custom face (about 560 production lines; depends on PR #1233)

**Model** `lib/control/model/foot_custom.dart`: `projectFootCustom(PedalSetup,
ControlState, …)` for all ten switches, following `role()` in
`pedal-performance-study.js` (`view === 'custom'`):
- MODE: `Exit`, lit. Bank: `Bank A/B`, `Switch bank`.
- Every other switch: title = `controlActionLabel` of its Press, or the
  hardware name (`Record / Play`, `Stop`, `Undo`, `Clear`, `Track N`) when
  Press is None; hint = `Hold · <label>` when it has a Hold. A switch with a
  Press or a Hold is **enabled**, available or not (§3 rule 2): an
  unavailable action reads its broken-assignment words with the caption
  dimmed and its press gives the notice. Only an unassigned switch is dimmed
  and inert (`MV9wz`: "an unassigned one does nothing").
- A switch whose Press is `recordPerformance`: `Record performance`, or
  `Stop recording` (lit) while `_performanceArmed` (20/03 `E7kQV`, where the
  Stop switch carries it). Part 8 adds the saving and held captions.
- `selected` = the published `ControlState.customLit: Map<PedalButton, bool>`
  (review L8). `_physicalCustomStates` (`:3352-3366`) reads private cubit
  fields, so the cubit computes the map once and stores it next to
  `_pushProjected` (`:3305-3324`); the LED frame and the face read the same
  value, so they cannot disagree.

**View** `lib/looper/view/foot_custom_view.dart` (header with Exit, the
recording indicator from `StageTopBar` when armed, as 20/03 draws `01:23`, and
Settings calling `openSegnoSettings`, not the tray), and the face branch in
`tracks_view.dart:219-225`.

**Cubit.** `footCustomPressed/Released/Cancelled`, `activateFootCustomPedal`
into the existing `_onPress` custom route (`:2362-2373`). Tile taps keep
selection-only (`track_column.dart:401-406`), which no longer matters on this
face.

**Refusals** (§3 rule 3; review H1 and L9). Every refused assigned action gets
one notice, from any mode. PR #1233 (PeelP3) is fixing assigned Fade, Reverse
and Peel refusals to report from any mode through their own reporters, in
`_runAction`'s `TrackOperationAction` arm when no channel accepted (PeelP3
`456654207`), with listeners no longer gated on the mode; this part
depends on #1233 and reuses that path rather than adding a second one. For
every other action it adds one `assignedActionFailure` counter carrying the
action's label, bumped in two places: where `_runAction` (`:2560`) returns a
refusal for an action with no reporter of its own, and at the early return
for an `UnavailableAction` in `_fireCustomAction` (`:2473`), which never
reaches `_runAction`; the External (`_fireExternal`) and MIDI paths get the
same early-return bump. The listener sits beside #1233's in `tracks_view.dart`,
not gated on the mode, and shows "<action> is unavailable right now." (one
cause, one notice). An empty or busy target track is refused with this notice
too: an assignment is never dimmed for its target's content.

**Pen write-back.** `uEukr` dims Record/Play (Hold · Peel), Stop and Undo
(Hold · Redo) although they carry assignments; the build dims only unassigned
switches, per `MV9wz`. The note is owed in pen section 10 beside `uEukr`
(§6, write-back list W2); builders do not edit the pen, so the coordinator
writes it when this part merges.

**Tests.** Projection over a setup with bank A/B track assignments, a Hold-only
switch, an unavailable instrument action and `recordPerformance` on Stop;
Bank flips the track captions; widget contacts reach `_armCustom`, including
an on-screen tap on an unavailable action, which toasts; LED parity through
`customLit`; the guards in §3. Refusal cases: Custom Press = Fade on an empty
Track 3 and on a Track 3 whose fade write is refused, Custom Press = Reverse
on a capturing track, each one toast through #1233's reporter and none from
`assignedActionFailure`; an unavailable action from Custom, External and MIDI,
one toast each. Goldens `foot_custom.png` (`uEukr` with the departure) and
`foot_custom_recording.png` (`E7kQV`).

```success-criteria
GOAL: Custom mode has its own pedal-map face that names each switch's assignment for the current bank and lights exactly what the LEDs light, and every refused assignment says so once.
SUCCESS CRITERIA:
- Captions, hints and availability follow PedalSetup.customFor for banks A and B; unassigned switches are dimmed and inert; assigned ones stay enabled. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Record performance reads Stop recording and is lit while armed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Each refused assigned action shows exactly one toast, from Custom and from Tracks mode through External and MIDI, including Fade and Reverse on #1233's path and an unavailable action at the early return. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Goldens match uEukr and E7kQV on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: enter Custom with MODE Hold; each assigned switch acts and the face matches the LEDs. | verify: manual on device
NON-GOALS:
- Editing assignments (Pedals setup owns it); held/saving recording captions (Part 8).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 4: native tuner mute (about 160 production lines: about 70 C, 90 Dart; builds on the trunk port of PR #912)

**Base (review M5).** PR #912 (#909: the tuner's per-frame `memmove` and
whole-callback YIN pass) is based on `master` and conflicts with the trunk in
`engine_private.h`, in the same tuner block this part edits. Another agent is
porting it onto the trunk as `claude/tuner-latency-909-trunk`; this part is
built on that branch (rebased onto it once it is pushed), so the conflict is
resolved once. The port is a merge gate for Part 6, not only a hardware note:
the foot Tuner stays armed while loops play, which is the load #909 measures.

**Decision D2.** The Tuner's temporary mute is a native mask owned by the tuner
arm, not the persistent monitor mute. Monitor mute is saved, Session-captured,
replayed and perf-logged (§1.5); a Tuner that borrowed it would need restore
logic on Exit, teardown and session replacement, and any unrelated save during
tuning could persist it. The native mask cannot outlive the tuner.

**Contract** (`segno_engine_api.h`, after `le_engine_set_tuner_input`):
`LE_CMD_SET_TUNER_MUTE = 132` (ledger range 132-135; 133-135 stay reserved)
and `LE_EXPORT int32_t le_engine_set_tuner_mute(le_engine* engine, uint32_t input_mask);`
posted through the ring like `le_engine_set_tuner_input`
(`engine_commands.c:3459-3465`). Returns `LE_ERR_INVALID` for a null engine,
`LE_OK` otherwise. Snapshot gains `uint32_t tuner_mute_mask` next to
`tuner_input`.

**Audio side.** `engine_private.h`: `_Atomic uint32_t a_tuner_mute_mask` beside
`a_tuner_input` (`:1521`). Handler: 0 while `a_tuner_input < 0` (a mask without
an armed tuner is refused), otherwise the mask with bits for absent inputs
dropped, guarded at 32 inputs like `engine_process.c:3555-3557` (`1u << 32` is
undefined; review L3). **Every** `LE_CMD_SET_TUNER_INPUT` (arm, move or
disarm, `engine_process.c:3509-3525`) stores 0: the mask belonged to the
tuning that just ended and the caller re-sends it for the new input, so a
moved tuner never keeps silencing the previous pair. `le_engine_reset_runtime`
(`engine.c:500-884`, run by configure and by a retained reopen) already
disarms the tuner and resets every monitor (`:799`, `:805`); it stores 0 for
the mask beside them. The monitor block reads the mask once per block where it
builds `mon_mut[]` (`engine_process.c:4950`) and ORs bit `c`, so the existing
mute path (`:4974`, `:5408-5410`) does the rest. Track lanes record from `in_c`
untouched (`:6422-6434`) and the detector keeps tapping before the mute
(`:6803-6805`). Not perf-logged: it changes no musical record; a captured
monitor stem gets silence for the muted input, exactly what was audible, as
with a monitor mute. The format doc says so beside the other unlogged
commands.

**Dart.** Regenerate bindings (then `dart format`, per the ffigen note in
`docs/PROGRESS.md`); `AudioEngine.setTunerMute({required int inputMask})` in
the engine, the native and the mock engines (the mock follows the native rules);
`EngineSnapshot.tunerMuteMask`; `LooperRepository.setTunerMute(Set<int>
inputs)` that remembers the mask next to `_tunerInput`
(`looper_repository.dart:360-364`) and re-sends it after the input re-arm on
restart (`:2536-2540`); `setTunerInput` clears the remembered mask on every
call, as the engine does (review L4), so the Dart image never goes stale;
`TunerReading` carries `muteMask`.

**Native tests** (new `packages/segno_engine/src/test/test_engine_tuner.h`,
included after `test_engine_peel.h`; fixture as `test_monitor_mute`,
`test_engine_core.c:8517-8553`; four inputs at 0.1, 0.2, 0.3, 0.4, every
monitor clean to output 0, so output 0 is the sum of what is heard):
- `test_tuner_mute_literal`: out 0 is 1.0; arm input 2, mask `0xC`: 0.3,
  snapshot `0xC`; mask `0xFFFFFFFF`: 0.0, snapshot `0xF`; mask 0: 1.0; null
  engine refused.
- `test_tuner_mute_keeps_monitor_mute`: monitor mute on input 0, arm input 1,
  mask `0x2`: 0.7; mask 0: 0.9; a monitor mute set on input 1 under the mask
  survives the mask ending (0.7) and `a_muted` is 1 there and 0 elsewhere.
- `test_tuner_mute_owned_by_arm`: a mask while disarmed stays 0; disarm
  clears it; a move to another input clears it; an out-of-range arm (a
  disarm) clears it; configure disarms and clears both.
- `test_tuner_mute_detector_and_capture_independent`: a 220 Hz sine of
  amplitude 0.5 on input 2, armed and muted; output 0 is silent while track 0
  records input 2, and the exported 4096 frames equal the input sample for
  sample; then `tuner_hz` is within 1 Hz of 220 with confidence >= 0.5.
- `test_tuner_mute_not_logged`: with a performance capture armed, no
  events.log record carries 132, 53 or the monitor-mute code, and the input's
  monitor stem is zero for the muted frames.

```success-criteria
GOAL: The engine can silence the monitors of chosen inputs for exactly as long as the tuner is armed, without touching monitor mute, track capture or the detector.
SUCCESS CRITERIA:
- Literal monitor sums with and without the mask, with a persistent monitor mute alongside, and after disarm, move and configure. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The detector reads a muted input and a track records it sample-exactly; no events.log record is written. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- The repository re-sends the mask after a restart, clears it on any tuner input change, and the mock engine follows the native rules. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
- Analyzer is clean. | verify: dart analyze --fatal-infos lib test packages
NON-GOALS:
- Any UI; the #909 callback cost itself (the trunk port of PR #912).
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5: tuner settings and the reading owner (about 520 production lines; depends on Part 4)

**Settings.** `SettingsRepository` gains `loadTunerReferenceHz`/`saveTunerReferenceHz`
(int, default 440, clamped 420-460) and `loadTunerInput`/`saveTunerInput` (int,
default -1 meaning "first available"), plain appliance preferences like
`savePedalLongPressMs` (`settings_repository.dart:597-602`). They are not
Session state: recall preserves appliance preferences (accepted §6.9).
`lib/tuner/application/tuner_settings.dart` (`TunerSettings`, shaped like
`FadeSettings`, `lib/looper/application/fade_settings.dart:15-72`): `live`,
`changes`, `load()`, `setReference(int) -> Future<bool>` and
`setInput(int) -> Future<bool>`; a failed write restores the previous value
and returns false.

**Reading.** `TunerCubit` becomes the reading owner only: it takes
`TunerSettings`, computes `pitchFromHz(hz, reference: settings.live.referenceHz)`,
and keeps thin `arm`/`disarm`/`selectInput` until Part 6 moves arming to
Control (review L5): the tray face, or Settings Part 5's tuner handle
(Settings plan `:541`, "arms TunerCubit"), still arms through the cubit, never
a widget calling the repository. A reading whose input differs from the armed
one is cleared at once (review L6; fixes `:148-151`): it belongs to another
input, it is not "no signal". The cubit no longer re-pushes
`setTunerInput` on a mismatch (trunk `tuner_cubit.dart:148-151`): with D12
every `setTunerInput` also clears the tuner mute, so a re-push by a second
arm owner would unmute the input mid-tune and move the tuner (P4 review L1).
Part 5 removes it before Part 6 arms from Control. Silence keeps the 1.2 s
dimmed hold, then clears (decision D5).

**Foot model** `lib/control/model/foot_tuner.dart`, from
`tuner-performance-study.js`:
- `FootTunerSelection {page, muted}` (transient, in `ControlState`).
- `projectFootTuner(LooperState, FootTunerSelection, TunerPreferences)`: the
  tunable inputs are `0..inputChannels-1` minus `excludedInputMask`; pages of
  four; the source is the stored input if tunable, else the first tunable;
  `mutedInputs` = the source and its pair partner (`InputSetup.pairOf`) when
  muted. Roles: tracks 1-4 = `Tuner input` (title = input name from the view,
  detail `Input N`, lit when it is the source, `—` and unavailable past the
  last input, 23/5); Stop = `Mute input`/`Unmute input`, detail
  `Input muted`/`Input audible` (pen 23/1, 23/4; lit while muted); Undo =
  `Reference −`, Clear = `Reference +`, both hint `Hold · 440 Hz`; Bank =
  `Inputs a–b`, hint `Next inputs` when there are two or more pages, lit on
  pages after the first, unavailable with one page; MODE = `Exit`; Rec/Play
  unavailable.
- `lib/control/foot_tuner_actions.dart` (stateless, repository and settings
  only): `arm(source, mutedInputs)` = `setTunerInput` then `setTunerMute`;
  `disarm()` = `setTunerInput(-1)` (the native disarm clears the mask);
  `select(index)`, `toggleMute`, `stepReference(±1)`, `resetReference()`,
  `nextPage()` (wraps, and selects the page's first input, as the study does).

**Tests.** Settings round trip, clamping and failed-write restore; reading at
A4 = 432 names 432 Hz as A in tune; a mismatch clears the reading in the
same emit, and `TunerCubit` never calls `setTunerInput` on a snapshot
mismatch; projection with
2, 4, 6 and 18 inputs (`Inputs 17–18`, two `—` pedals), a loopback-excluded
input, a pair (muting input 4 mutes 3 and 4), an empty device; actions order
`setTunerInput` before `setTunerMute`.

```success-criteria
GOAL: Tuner reference and input persist as appliance preferences, the reading uses the reference, and the foot Tuner's paging, pair muting and actions exist as tested pure code.
SUCCESS CRITERIA:
- Reference clamps to 420-460, resets to 440 and survives a restart; a failed write keeps the previous value. | verify: (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/tuner
- Readings use the stored reference; an input mismatch clears at once; silence clears after the hold. | verify: /Users/Tomas/development/flutter/bin/flutter test test/tuner
- Paging, pair muting and source fallback match the study for 2, 4, 6 and 18 inputs. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- The mode and face (Part 6). The tray face keeps working through TunerCubit.arm/disarm, which Part 6 removes.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 6: the foot Tuner mode and face (about 660 production lines; depends on Part 5; merge gated on the trunk port of PR #912)

**Mode.** `InteractionMode.tuner` (not in `bootDefaults`), with every
exhaustive `InteractionMode` site: `ModeAction.token`
(`control_action.dart:346-354`), labels (`control_action_labels.dart:70-80`),
`toggleMode` (`control_cubit.dart:1308-1316`, Tuner returns to Record),
`setMode` (`:1428-1530`), `recPlay`, `stop`, `trackPressed`, `_onPress`,
`projectTrackLed`, `_physicalButtonMask` and the `PedalMode.custom` mapping
(`control_projection.dart:76-131`, `:205-303`), `invariants.dart:152-206`,
`tracks_commands.dart:113-125`, `:226`, `:311`, `track_column.dart:365-406`,
`wave_track_row.dart:88-116`, `pedal_plate.dart:624-626`, `:1047-1056`,
`looper_theme.dart:125-130`, `surface_theme.dart:233-240`. MODE Press/Hold
pickers, Custom, External (24/1 `Press Mixer · Hold Tuner`) and MIDI reach it
through the catalogue built from `InteractionMode.values` (`control_action.dart:456-467`).

**Cubit part** `lib/control/cubit/control_foot_tuner.dart` (the Fade shape):
`_tunerEditable`; `setMode(tuner)` resets the selection to `muted: true` on
the source's page and calls `FootTunerActions.arm`; leaving the mode (any
`setMode`, close) calls `disarm`; `_onTunerPress` with Exit first, contact
actions on tracks, Stop and Bank, and holds on Undo and Clear through
`_armGesture` (so Part 1's cue shows). A device or input-count change
re-projects and re-arms the new source; with no tunable input the tuner is
disarmed and the face says so (rule 5). `footTunerPressed/Released/Cancelled`
and `activateFootTunerPedal` for on-screen contacts. Control does not depend on
`TunerCubit` (`control_cubit.dart:121-126`); both read `TunerSettings`.

**Face** `lib/tuner/view/foot_tuner_view.dart` (under `lib/tuner` so its tests
live in `test/tuner`, which Settings Part 6 runs): `A4 reference` block (418 x
120 at x 0, y 90 of the pedal area: label 24 px, value 56 px, `Hz` 24 px), the
reading block (852 x 279 at x 868: input name 27 px, status 20 px, note 120 px,
direction `Flat`/`In tune`/`Sharp` 27 px, cents 21 px, the −50..+50 meter with
its scale), and the pedal map; with no reading the note is `—` and the
direction `Play one note` (23/3); the face's Settings button calls
`openSegnoSettings`.

**Tray.** `TunerTrayPanel` and `test/tuner/view/tuner_tray_panel_test.dart` are
deleted, and `TunerCubit` loses `arm`/`disarm`/`selectInput`. The tray's Tuner
entry (the rail entry on the trunk, or Settings Part 5's handle if it landed
first) calls `setMode(InteractionMode.tuner)` instead, so there is one tuner
surface (rule 4).

**Default route (review M3, decision D11).** Once Settings Part 6 deletes the
tray, the Tuner must stay reachable on a default install (rule 1). The trunk's
default `PedalSetup` has MODE Press Mute and Hold Custom with an empty Custom
map (`pedal_setup.dart:143-152`), so no switch carries Tuner. The design gives
the default: the pedal study's initial setup (`docs/design/pedal-ux-study.js:8`)
puts `FX` / `Hold · Tuner` on Track 2 in the Custom map, which the pen draws on
`uEukr` (Pedal 2 `FX`, `Hold · Tuner`). This part makes `Hold · Tuner` on
Custom Track 2 bank A part of the default setup: a fresh install gets it, and
an existing install gets it only where that Hold is empty (a stored setup with
anything there keeps it, rule 1). Seeding is one-shot (plan review DM2): a
settings flag `pedal.tuner_default_seeded` is written at the first attempt,
whatever its outcome, so a player who later removes `Hold · Tuner`, or clears
the custom assignments, never gets it back. It is skipped, and the flag left
unset for a later boot, while the stored setup is malformed or uncertain
(`ControlState.pedalSetupUnavailable` or `pedalSetupPersistenceUncertain`):
seeding must not replace bytes the user has not chosen to overwrite. The
seeding is written through the normal confirmed `setPedalSetup` path and
announced once with a toast (rule 3): "Tuner is on Custom: hold MODE,
then hold pedal 2." The rest of the study's default map is not seeded: most
of its actions (Transpose, Speed, Multiply) do not exist yet.

**Refusals and notices** (§3), all through `footTunerFailure`:
- a failed reference or input save: `Tuner settings could not be saved. Try
  again.` (the study's copy);
- a failed native arm or mute (`EngineResult` not OK): `The tuner could not
  start. Try again.`, and the input is reported as audible because it is;
- Reference + at 460 Hz or Reference − at 420 Hz: `A4 reference is at its
  limit.` The pedal stays enabled because its Hold (reset to 440) still acts.
Positions past the last input (23/5's `—`) and Bank with a single page are
dimmed and silent: nothing is there to refuse.

**What Settings Part 6 needs from this part** (Settings plan `:550-566`):
1. A foot-entered Tuner surface over the app-wide `TunerCubit`: this part's
   `FootTunerView` reading `TunerCubit` (`app.dart:565-571`).
2. No class whose name contains `TrayPanel` in `lib/tuner` or `test/tuner`, so
   its `grep -rnE "SettingsTray|TrayPanel|_TrayHandle|kTray"` can pass once it
   deletes the tray: `TunerTrayPanel` and its test are deleted here.
3. Tuner tests under `test/tuner` that do not depend on the tray:
   `test/tuner/view/foot_tuner_view_test.dart`,
   `test/tuner/cubit/tuner_cubit_test.dart`,
   `test/tuner/application/tuner_settings_test.dart`.
4. No new tray dependency: the face uses `openSegnoSettings`, never
   `SettingsTrayCubit` (unlike `foot_fade_view.dart:135`,
   `foot_mixer_view.dart:123` and `foot_reverse_view.dart:85`, which Settings
   Part 2 reroutes).
Nothing else; Settings Part 6 then deletes the tray rail entry this part
re-pointed.

**Tests.** Dispatch: entry mutes the source (and its pair) and arms; Stop
toggles; Undo/Clear step 1 Hz and hold resets; Bank pages and wraps; Exit
disarms and the mask is 0; a mode change and close disarm; the §3 guards.
Widget and goldens for all five 23/x screens (`foot_tuner_tune.png`,
`_in_tune`, `_no_signal`, `_monitoring`, `_18_inputs`) and the `es` probe.

```success-criteria
GOAL: The Tuner is a foot performance function that selects inputs by bank, mutes only the selected input or pair while it is up, adjusts A4 420-460 with reset to 440, and exits by foot; the tray tuner is gone.
SUCCESS CRITERIA:
- Entering mutes the source and its pair and arms the detector; Exit, a mode change and close disarm and clear the mask. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/tuner
- The five 23/x screens render from real state; goldens match on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/tuner test/screenshots
- No TrayPanel class remains under lib/tuner or test/tuner, and the tray's Tuner entry enters the mode. | verify: ! grep -rn "TrayPanel" lib/tuner test/tuner && /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Analyzer, Bloc lint and coverage. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
- A default setup, and a stored setup with an empty Custom Track 2 Hold, carry Hold · Tuner there; a stored setup with that Hold assigned keeps it; the one-time notice shows once; removing Hold · Tuner and rebooting does not bring it back; a malformed or uncertain setup is not written and the flag stays unset. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The trunk port of PR #912 is in the trunk before this part merges. | verify: git merge-base --is-ancestor origin/claude/tuner-latency-909-trunk HEAD
- HARDWARE: default pedal setup, guitar on input 1: hold MODE (Custom), then hold pedal 2 (Tuner); the string reads, the monitor is silent while a track records it; MODE (Exit) restores monitoring. | verify: manual on device
- HARDWARE: with the tuner up and four tracks playing on the Pi 5, callback p99 stays under budget. | verify: manual on device
NON-GOALS:
- Secondary-display Tuner feedback (E6-11); instruments in the input list (E8-14).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 7: New Loop by foot (about 230 production lines; depends on PR #1216 with the LibP4/LibP5 review's Finding 2 fixed)

**Action.** `ControlCommand.newLoop('command:new-loop')` in
`ControlActionGroup.sessions` (`control_action.dart:70-71`, the group's first
entry), label `New loop` (pen 19/01). Assignable to Custom, External and MIDI
like every command.

**One path (review M2).** The foot runs exactly the method the Library button
runs, `SessionCubit.newLoop`, with no rule of its own in Control:
`_runCommand(newLoop)` only bumps `ControlState.newLoopRequest` (a monotonic
counter, the `clearAllPulse` pattern, `tracks_view.dart:185-193`) and is
accepted (contact LED); `takeLocked` already gates it. An app-level
`BlocListener<ControlCubit>` in `app.dart` calls
`SessionCubit.newLoop(request: <the counter value>)` once per bump; Control
never depends on `SessionCubit`. What New loop does while a track captures or
has a pending arm is decided once, inside `newLoop` under `runExclusive`, by
the fix for the LibP4/LibP5 review's Finding 2 (end the take first, or refuse
with a typed refusal); the foot inherits it whichever way it goes. A refusal
or failure reaches the player through the existing session failure toast
(`onSessionState`, the `tracks_view.dart` SessionCubit listener), the same
words the Library button gets. A press while the Library is open returns to
Tracks first (Library D14).

**Notice.** By foot there is no confirm sheet (accepted §4: "work directly by
foot"); preservation is what makes that safe (rule 2), and the outcome is
never silent (rule 3). `newLoop` takes an optional `request` and echoes it in
`SessionState.newLoopRequest` with the `SessionOutcome.newLoop` it emits, plus
`preservedName` (set by `_preserveOutgoing`, LibP5 `:286`, null when nothing
was preserved). The app listener shows `<name> stays in your Library.` (the
19/02 sentence) only for an outcome whose request it issued, so the Library
button's New loop, which already asked with its sheet, gets no second notice.
No toast when nothing was preserved.

**Performance recording (owner decision O2).** A running performance
recording is finished and saved first: the shared apply path calls
`disarmAndFinalize` (LibP5 `:570`), as the Recording plan's guard row for
`sessionApply` says (`:601`). What appears on stage: the new empty loop
(19/06, `New loop N`), the recording indicator turns off, and a toast says
`Recording saved. Find it in Library > Audio.` The completion sheet that
`onPerformanceRecorderState` opens today (`tracks_commands.dart:436-466`) does
not open over the new loop: `PerformanceRepository.disarmAndFinalize` records
the stop cause `sessionApply` on the capture status, the recorder state
carries it, and the listener shows the toast instead of the sheet for that
cause. This applies to every session apply (Open and both New loop paths),
one rule (rule 4); the take stays in Library > Audio. Recording plan Part 13,
which replaces the sheet's saved face, keeps this cause.

**Tests.** The command round-trips; a bump calls `newLoop` exactly once with
its request; a foot New loop and a Library New loop on the same fake
`SessionCubit` produce the same refusal while a track captures (whatever
#1216 decides); the preserved-name toast shows for the foot request only, and
not when nothing was preserved; takeLocked; a New loop while a performance
take is armed finishes it and shows the saved toast, not the sheet.

```success-criteria
GOAL: A pedal, CTRL switch or MIDI control assigned New loop runs the Library's New loop through the same method and rules, says which session it kept, and finishes a running performance recording without covering the new loop.
SUCCESS CRITERIA:
- The command round-trips and calls SessionCubit.newLoop exactly once per press, with no capture rule of its own in Control. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/app
- The foot and the Library button get the same refusal and failure toasts. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app test/session
- The kept-session toast shows only for the foot's request and only when something was preserved. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app test/session
- A session apply that finishes a performance take shows the saved toast and no completion sheet. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view test/performance
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: assign New loop to a Custom switch, record two tracks while recording the performance, press it: the stage reads New loop N with the toasts above, the old session opens from the Library with both tracks, and the take is in Library > Audio. | verify: manual on device
NON-GOALS:
- Any change to what New loop keeps or resets (Library plan D9) or to its capture rule (#1216).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: Record performance retry by foot (about 170 production lines; depends on Recording plan Parts 8 and 9, and Part 3)

**Dispatch.** `_togglePerformanceRecordAccepted` (`control_cubit.dart:2818-2825`)
reads the repository's capture status: armed → `disarm()`; finalizing or
saving → refused with toast `The recording is still saving.`; held with Save
available → `saveHeld()` (the retry); held without an available Save (USB
drive absent) or idle → `arm()`. Arming while a take is held is admitted: a
held take holds no guard (Recording plan D9, `:592-595`), and the held take is
left alone. Every caller gets the retry: Custom, External, MIDI, the Bank hold
and the MODE hold path, since they all reach this method (rule 4).

**One failed-save fact (review L11).** Control cannot call the recorder cubit,
and the Recording plan sets `Held(saveFailed: true)` inside the cubit's own
`saveRecovered` catch (`:1095`), so a failed foot retry would leave the Record
performance page without its 20/06 line. Instead the repository's held status
carries `saveFailed`, set by `saveHeld()` when it throws and cleared when it
starts; the recorder cubit's `Held` reads it rather than keeping its own. Both
the page (20/06) and the foot read one fact. §6 asks the Recording plan to
adopt this in its Parts 8 and 9.

**Captions** (Custom face): `Record performance`, `Stop recording` (lit),
`Saving recording` (caption dimmed, pedal enabled so a tap or a stomp gives
the notice, §3 rule 2), `Save recording` (held), from
`pedal-performance-study.js` `role()`. A failed retry by foot shows the 20/06
sentence as a toast: `Could not save the recording. It is kept here for
another try.`

**Tests.** Each status row of the table above, from an on-screen tap and a
physical press alike; a throwing `saveHeld` sets `saveFailed`, keeps the take
held, toasts, and the page shows the 20/06 line; a second press retries and
completes; an absent drive arms a new take and leaves the held one alone.

```success-criteria
GOAL: The Record performance switch starts, stops and, when a take is held, retries its save by foot, with captions that say which it will do.
SUCCESS CRITERIA:
- Status-to-action table holds for idle, armed, saving, held with Save available and held without it, on screen and by foot. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- A failed retry keeps the take, sets the repository's saveFailed, toasts the 20/06 sentence, and the Record performance page shows its 20/06 line. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/performance
- Captions follow the four phases on the Custom face. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: pull the USB drive while recording, reconnect it, press the switch: the take saves. | verify: manual on device
NON-GOALS:
- Discard by foot (destructive; stays on the page behind its confirm).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Order and dependencies

- Part 1 is independent.
- Part 2 is independent.
- Part 3 depends on PR #1233 (assigned Fade, Reverse and Peel refusals from
  any mode).
- Part 4 builds on `claude/tuner-latency-909-trunk`, the trunk port of PR #912.
- Part 5 follows Part 4. Part 6 follows Part 5, merges only after the #912
  port is on the trunk, and unblocks Settings Part 6.
- Part 7 waits for PR #1216 with Finding 2 fixed.
- Part 8 waits for Recording Parts 8 and 9 and this Part 3.
- Faces landed before Part 1 pick up the cue when it lands, because the cue
  lives in `PerformancePedal`.

| Part | Production lines | Native | Depends on |
|---|---|---|---|
| 1 Pending Hold | ~200 | – | – |
| 2 FX face | ~640 (+~300 removed) | – | – |
| 3 Custom face | ~560 | – | #1233 |
| 4 Tuner mute | ~160 | command 132 | #912 trunk port |
| 5 Tuner owner | ~520 | – | 4 |
| 6 Tuner mode and face | ~660 | – | 5; #912 port merged |
| 7 New Loop by foot | ~230 | – | #1216 with Finding 2 fixed |
| 8 Recording retry | ~170 | – | #1198 P8, P9; 3 |

## 5. Decisions under the owner rules

Owner decisions (2026-10-06, answering the planner's questions):

- **O1.** No pedal strip on Tracks or Mute: the Pending Hold cue shows on the
  faces that draw pedals (Mixer, Fade, Reverse, FX, Custom, Tuner, and Peel
  when it lands). Building pen 10/01 as a Tracks pedal face is separate work.
- **O2.** New Loop by foot finishes a running performance recording, as the
  Library's New loop does (Part 7 says what the stage shows).
- **O3 (answering Q3).** The FX-mode Stop panic and its restore hold are
  dropped, as pen 10/03 shows. Two assignable commands, `Track FX off` and
  `Track FX on`, join the FX action group so a player can put the sweep on any
  switch through Custom, External or MIDI. The release note names the change,
  and a one-time in-app notice on the first FX entry after the update says
  it on stage too (rule 3, as D11 does; plan review DM1). Part 2.

Decisions taken under the standing rules:

- **D1 (pen authority, rule 4).** FX mode gets the pen's pedal-map face and the
  Tracks-column re-dress (#692 Candidate A) is removed; #884 and #873 close
  with it, #601 closes as obsolete (§1.3).
- **D2 (rule 2).** The Tuner mute is a native mask tied to the tuner arm, never
  the persistent monitor mute (Part 4).
- **D3 (pen authority, review M1).** The FX face follows 10/03 for Stop and
  Bank: an unbound Stop is dimmed and inert, so the track-chain panic and its
  restore hold leave FX mode; Bank reads `Switch bank` and keeps its Record
  performance hold, which pen note `po4RZ` documents. The panic's new home is
  owner decision O3.
- **D4 (rule 4).** Tuner arming moves from `TunerCubit` to Control's foot
  actions in Part 6; `TunerCubit` keeps the reading. One surface, one arm
  owner.
- **D5 (rule 1).** The tuner keeps its 1.2 s dimmed hold on silence and then
  clears ("no signal clears the old reading"); confidence stays 0.5. Both are
  measured baselines to confirm on hardware (accepted §4.12). A reading from
  another input clears at once.
- **D6 (owner decision O2).** New Loop by foot finishes a running performance
  recording through the shared path, and a session apply that finishes a take
  shows a toast, not the completion sheet.
- **D7 (rule 3).** New Loop by foot toasts the preserved session's name, scoped
  to its own request; the Library's button keeps its sheet and gets no toast.
- **D8.** Engine numbers: command 132 only; facts 352-355 and commands 133-135
  are unused and returned to the ledger. No events.log or Session schema bump.
- **D9 (rule 3).** Presses dropped under `takeLocked` stay silent on every new
  face, as on the existing ones (§3).
- **D10 (shared notice policy).** Every part follows §3: only a switch with no
  action is dimmed and silent; every switch with an action stays enabled and
  notifies its refusal, on screen and by foot alike.
- **D11 (rule 1, review M3).** The default pedal setup carries `Hold · Tuner`
  on Custom Track 2 bank A, from the design's default map; existing installs
  get it only where that Hold is empty, with a one-time notice, once per
  install (a `pedal.tuner_default_seeded` flag), and never over a malformed
  or uncertain setup (Part 6, plan review DM2).
- **D13 (pen authority, Part 2 build).** In FX mode MODE is the face's Exit,
  on contact, back to the mode FX was entered from, as pen 10/03 draws it and
  accepted §4 requires; it no longer runs the configured MODE pair there.
  Custom already behaves this way.
- **D12 (Part 4 build).** Every `LE_CMD_SET_TUNER_INPUT` clears the mask, not
  only a disarm, so a moved tuner never keeps silencing its previous input;
  configure and reopen clear it beside the tuner disarm they already do.

## 6. Findings for other plans, and the pen write-back list

Findings for other plans:

- Recording plan Part 13 (`:1227-1230`, `:1244` at `57a5324b8`) asserts
  `Stop recording` on the **Record/Play** pedal label. Pen 20/03 `E7kQV` is
  the Custom face with Record performance assigned to **Stop**; this plan's
  Part 3 owns that caption. Part 13's criterion should point at Part 3's test
  instead, and keep Part 7's `sessionApply` stop cause when it replaces the
  completion sheet's saved face.
- Recording plan Parts 8 and 9: carry `saveFailed` in the repository's held
  status (set by `saveHeld()`), and let the recorder cubit's `Held` read it,
  so a foot retry and the page share one fact (Part 8, review L11).
- The Settings plan's §5 names `foot_fade_view.dart:135` and
  `foot_mixer_view.dart:123` (`:43`) but not `foot_reverse_view.dart:85`,
  which Reverse P3 added after it was written; its Part 2 should reroute that
  button too. This plan adds no tray users. Settings Part 5's "arms
  TunerCubit" (`:541`) stays true until this plan's Part 6, which keeps the
  cubit's thin arm until then (Part 5, review L5).
- Library: the LibP4/LibP5 review's Finding 2 decides the capture rule for
  both New loop paths; Part 7 adds no rule of its own (review M2).
- PR #912 (#909) is being ported onto the trunk as
  `claude/tuner-latency-909-trunk`. Part 4 builds on it; Part 6's merge is
  gated on it (review M5).

Pen write-back list (shipped departures and additions; builders do not edit
the pen, the coordinator writes each `c/` note when its part merges):

- **W1, section 10 beside `PRSrG` (Part 1).** The cue ships on the pedal-map
  faces only; Tracks and Mute draw no pedals, so it does not appear there
  (owner decision O1). The bar is timed from the widget's ticker.
- **W2, section 10 beside `uEukr` (Part 3).** Only unassigned switches are
  dimmed; Record/Play (Hold · Peel), Stop and Undo (Hold · Redo) draw as
  assigned. Assigned switches whose action is unavailable stay enabled with
  dimmed captions.
- **W3, section 10 beside `noDGu` (Part 2).** Bound Rec/Play, Stop, Undo and
  Clear draw active with their binding; unbound ones stay dimmed as drawn. A
  stale binding stays enabled with its broken-row words. Bank's hold keeps
  Record performance without a hint, as `po4RZ` documents.
- **W4, section 23 (Part 6).** The default entry is Custom Track 2
  `Hold · Tuner` (D11); the face's Settings button opens Settings.
- **W5, section 08 beside `OgLiI` (Part 6).** The default Custom map carries
  `Hold · Tuner` on Track 2 bank A, seeded only where empty.
- **W6, section 20 beside `E7kQV` (Part 7).** A session apply that finishes a
  take shows `Recording saved. Find it in Library > Audio.`, not the
  completion sheet.

## 7. Questions for the owner

None open. The planner's Q1 and Q2 and the review's Q3 are answered (O1, O2
and O3 in §5).

## 8. Budget and review ceiling

Every part stays at or under about 660 production lines added; tests,
generated bindings, goldens and l10n are counted separately. Stop for review
on any further engine command, a Session schema change, a second tuner arm
owner, or a second New Loop path. Each part runs the Dart suite, `dart analyze
--fatal-infos lib test packages` and `bloc lint lib test packages`; Part 4 also
runs the native suite normal, ASAN and telemetry-off. Independent
architecture, test and adversarial reviews precede each publication; the
human merge gate stays.

## 9. PR #1237 review findings, applied

| Finding | Where it is applied |
|---|---|
| H1 assigned Fade and Reverse refusals silent outside their mode | Part 3 depends on #1233 and reuses its reporters; generic notice for the rest |
| H2 FX face hides bound Rec/Play, Stop, Undo, Clear | Part 2 projects every bindable switch |
| M1 D3 departure | D3 follows the pen; O3 gives the panic two commands |
| M2 New Loop guard in the wrong layer; Library toast | Part 7: one `newLoop` path, request-scoped toast, depends on Finding 2's fix |
| M3 Tuner unreachable after the tray | Part 6 default route, D11, W4, W5; hardware criterion with its setup |
| M4 notice policy inconsistencies | §3 rule 2 rewritten; Parts 2, 3, 8 keep switches with actions enabled |
| M5 PR #912 conflict | Part 4 builds on the trunk port; Part 6 merge gate |
| M6 pen write-back | §6 write-back list W1-W6 |
| L1 Part 1 hardware criterion | Undo on the foot Mixer |
| L2 wall clock; emit after close | Part 1 publishes a set, widget ticker times the bar; `isClosed` guard |
| L3 `1u << 32`; unarmed test | Part 4 guard; the test arms first |
| L4 stale Dart mask | `setTunerInput` clears the remembered mask |
| L5 interim tray arming | `TunerCubit` keeps thin arm until Part 6 |
| L6 old pitch under new name | mismatch clears at once |
| L7 #873 expected text | `Track 2 lane 1`; old tests deleted |
| L8 LED state not in `ControlState` | `customLit` published |
| L9 `UnavailableAction` early return | notice at `:2473` and the External and MIDI returns |
| L10 citations | §1.6 re-anchored to LibP5, trunk and `57a5324b8` |
| L11 recorder failed-save state | repository's held status carries `saveFailed` |
| Notes | #692 history quoted in Part 2; pen 04 multi-rack as a non-goal; `FxNames` resolver; no golden moves in Part 1 (the bar fits the existing gap, §10); `Not monitored` dropped |
| Delta DM1 (O3 not in the plan) | O3 recorded; Part 2 lists the commands, the `stop()` change, the one-time notice, tests and criteria; `_sweepTrackChains` kept |
| Delta DM2 (seeding) | D11 and Part 6: one-shot flag, skipped on malformed or uncertain setups, tests |
| Delta DL1, DL2 | §9 notes row corrected; Part 3 cites `_runAction`'s `TrackOperationAction` arm |
| P1 review M1, L1, L2 | Part 1 publishes only in pedal-drawing modes; `holdTrack` `#303b4b`; closing guard documented as defense (§10) |
| P4 review L1 | Part 5 drops the mismatch re-push and tests it |

## 10. Build record

### Part 1 (branch `claude/foot-surfaces-1229-p1`)

- Built as planned: `ControlState.pendingHolds` and `holdThreshold`;
  `_armGesture` takes a `cue` (null only for the CTRL jacks) and
  `_HoldGesture.press` an `onSettled` that runs once on hold, release or
  cancel; `_setHoldPending` is silent once the cubit is closing.
  `PerformancePedal` times the bar from its own `AnimationController`, and
  the Mixer and Fade faces pass the cue.
- **Departure: no golden moves.** The plan expected the 3 px bar slot to
  shift every face by 3 px. The pen puts the bar 5 px under the face inside
  the 16 px gap the app already leaves before the caption, so the slot is
  5 + 3 + 8 px and the layout is unchanged; the Mixer, Fade and Reverse
  goldens pass byte-identical (the full app suite ran them: 3484 passed, 56 skipped).
- The bar is two `ColoredBox`es, not a `LinearProgressIndicator`, so it adds
  no progress semantics and does not collide with the Mixer face's level bar.
- Teardown order: `close` first retires input, which cancels the gestures
  while the cubit is still open, so the cue clears with one ordinary emit;
  the `_closing`/`isClosed` guard is defense only (no current path reaches it
  after close), and the code says so (P1 review L2).
- **P1 review fixes (`ffa51848c`).** The cue is published only in Mixer, Fade,
  Reverse, FX and Custom; a Record- or Mute-mode stomp emits no state for it
  (test pins Undo and Bank in both modes). The bar's track is the new
  `holdTrack` token, `#303b4b` (`#4a586c` in high contrast).

### Part 4 (branch `claude/foot-surfaces-1229-p4`, on `claude/tuner-latency-909-trunk`)

- Built as planned, rebased cleanly onto the #912 trunk port (`c54865297`):
  the mask reset sits in the `LE_CMD_SET_TUNER_INPUT` handler beside the
  port's `tuner_raw_pos` and `tuner_pass.phase` resets.
- **Departure (D12):** `le_engine_reset_runtime` already disarms the tuner and
  resets every monitor on configure and on a retained reopen, so the mask is
  cleared there (`engine.c:800`), and every `LE_CMD_SET_TUNER_INPUT` clears
  it, not only a disarm.
- The mock engine follows the native rules; `LooperRepository.setTunerMute`
  refuses while disarmed or for an input outside `0..31`, and every
  `setTunerInput` clears the remembered mask.

### Part 2 (branch `claude/foot-surfaces-1229-p2`)

- Built on the trunk at `890f04936` (Peel P3, Settings P3/P4 and the #912
  port merged). `FootFxView` replaces the Tracks columns in FX mode; the
  #692 re-dress, its l10n strings and its golden (`tracks_fx_window.png`)
  are gone, and so are the twelve strings only it used.
- The face reads `ControlState.fxSwitches` (`({lit, stale})` per bound
  switch), which the cubit publishes beside the frame push from the same
  values the LEDs use; the four track LEDs still go through `boundChains`.
- `Track FX off` / `Track FX on`, the one-time notice (flag
  `fx.stop_change_notice_shown`, toast in `app.dart` beside the boot-mode
  notice) and MODE as Exit (D13) are built as the amended Part 2 says.
- **Departures:**
  - The pedal assignment page and its strings left the trunk with the old
    Settings page (`13b483025`). The face has its own `Toggle` and `Target
    missing` strings, and the stale-binding toast says "Reassign it." without
    naming a page; bindings are edited in the Control tray's pedal body
    (`pedal_tray_body.dart`).
  - The face's Settings button opens Settings (`openSegnoSettings`), as
    Reverse and Fade now do on the trunk; it never uses the tray.
  - Hint line: a bound switch without a Hold target shows its stage
    (`Input 2`, `Track 2 lane 1`) as the third line, the #884/#873 fix made
    visible; the pen draws no third line (write-back W3 adds it).
  - Accessible activation acts as press-and-release, so a momentary binding is
    a no-op there, as for a foot that lifts at once.
  - The Pending Hold cue (Part 1) is not wired into this face yet: whichever
    of #1247 and this part lands second passes `holdPending` here too.
- Verification: app suite 3469 passed, 56 skipped; settings_repository 204;
  analyze, Bloc lint and format clean. Mutations: 15 run, 14 killed; the
  survivor (not latching the notice flag in memory) only repeats a write of a
  flag already set, since the state field and its listener fire once.
