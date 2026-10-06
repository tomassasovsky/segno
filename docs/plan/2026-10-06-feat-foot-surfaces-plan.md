# Foot surfaces: Pending Hold, FX Toggle/Hold, Custom face, foot Tuner, New Loop and recording retry by foot

<!-- cspell:ignore Eukr Gtjy RKTE dged slotless memmove -->

Tracking: #1229, `autonomy:merge-gate`, human merge gate.
Status: plan. Nothing built.
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
  will call" (`docs/plan/2026-10-06-feat-library-sessions-plan.md:251-252`, D14
  `:491-495`). `ControlActionGroup.sessions` is empty
  (`lib/control/binding/control_action.dart:70-71`).
- Held takes, `saveHeld()` and the recorder's `saveRecovered()` are Recording
  plan Parts 8 and 9 (`docs/plan/2026-10-06-feat-recording-recovery-plan.md`
  `:1000-1092`, D9 `:635-660`). Nothing on the trunk retries a failed save.

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
2. **A busy or refused press on a recorded track gets a notice.** A recorded
   track that is capturing, pending or refused by the engine keeps its real
   words (never "Empty"), stays enabled, and a press shows the face's failure
   toast.
3. **Assigned-action refusals always get a notice.** A Custom, External or
   MIDI assignment that is refused for any reason, an empty target track
   included, shows a toast. Rule 1 does not apply to assignments: an
   assignment is not the track's own pedal.

How each part applies it:

| Part | Pedals that stand for a track | Other refusals |
|---|---|---|
| 2 FX face | none: track switches drive chains, which exist on empty tracks, so no switch dims for content | stale binding and failed write: notice (rule 3 for bindings); Rec/Play, Undo and Clear have no action in FX and stay dimmed and silent, as today |
| 3 Custom face | none: every switch is an assignment | every refused assignment: notice (rule 3), empty target track included |
| 6 Tuner | none: track switches are inputs; positions past the last input read `—` and are dimmed and silent, as an absent input is not a refusal; Rec/Play has no action and is dimmed and silent | reference at its 420 or 460 limit, failed save, failed arm or mute: notice |
| 7 New Loop | none | refused while a track records or is pending: notice (rule 3) |
| 8 Recording retry | none | press while the take is saving: the caption is dimmed (`Saving recording`) and a physical press still gets a notice; failed retry: notice |

Lessons from the Reverse P3 review (PR #1209), which this policy settles:

- **Markers take real layout space.** The hold-progress bar, the Toggle/Hold
  line, the Tuner's status line and every caption row are laid out at all
  times and only change opacity or text, so nothing reflows. Each face gets a
  geometry test in the `es` locale with the longest caption, asserting that no
  two text boxes intersect (the probe matrix the review asked for).
- **Busy tracks never read "Empty".** No face derives a word from
  availability. Content words come from content (`hasContent`); whether a
  switch can act now is a separate `enabled`, as the merged Reverse model now
  splits `recorded` from `busy` (`lib/control/model/foot_reverse.dart:44-57`).
- **Silent only where the policy says so.** Presses dropped under
  `takeLocked` also stay silent, as on every face today (§1.1), because the
  power dialog or the session load already owns the screen.
- The guards the review found untested get one test each in every new cubit
  part: the session-transition gate, the visit identity of a late failure
  report, Exit while not editable, `toggleMode` out of the new mode, and that
  inert switches leave transport untouched.

## 4. Parts

### Part 1: the Pending Hold cue (about 220 production lines; no dependencies)

**Model.** `ControlState` gains `pendingHolds: Map<PedalButton, DateTime>`
(start instant of each pending hold) and `holdThreshold: Duration` (the loaded
`_longPress`). `_armGesture` gains a `PedalButton? cue` argument; when non-null
it records `now()` for that button and emits; the entry is removed when the
hold fires, the release lands, or the gesture is cancelled (`_HoldGesture`
reports each through one `onSettled` callback added to `press`). Every
`_armGesture` call site that arms a pedal passes its button; the external jack
site (`:467`) passes null, since no surface draws CTRL jacks. `now` is injected
into `ControlCubit` for tests (default `DateTime.now`).
`_invalidateGestures` and `_cancelSurfaceHolds` clear the map.

**View.** `PerformancePedal` gains `holdStartedAt` and `holdThreshold`. It
always lays out the 3 px bar slot under the face (opacity 0 when idle) and,
while a hold is pending, animates the fill from `(now - start) / threshold` to
1 with an `AnimationController` (no per-frame cubit emits), and brightens the
hint (`#d2e3ff`, a new `SurfaceTheme` token beside the hint colour). Every face
passes `state.pendingHolds[button]`; Mixer and Fade get the cue at once
(Reverse arms no holds, so it never shows one).

**Refusals.** None new: the cue only shows a gesture the cubit already armed.

**Tests.** Cubit: arming a Fade track hold publishes the button with the
injected instant; release before the threshold, the hold firing, a mode
change, a session change (`_cancelSurfaceHolds`) and close each remove it.
Widget: with a pending start 400 ms ago and an 800 ms threshold the fill is
half the 159 px track (pump 0), full at 800 ms, gone after release; the bar
slot height is identical with and without a pending hold; `es` geometry probe.
Golden: `foot_fade_pending_hold.png` matching `PRSrG`'s bar and hint colour.

```success-criteria
GOAL: Every on-screen pedal whose hold is pending shows the pen's progress bar and brightened hint, and nothing reflows when it appears.
SUCCESS CRITERIA:
- pendingHolds is set on arm and cleared on release, hold, mode change, session change and close. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The bar fills linearly to the threshold, and its slot takes the same space idle and pending. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: on the appliance, hold MODE on the foot Mixer: the bar fills over 800 ms and the hold fires as it completes; a short press shows the bar briefly and fires the press. | verify: manual on device
NON-GOALS:
- A cue in Tracks and Mute modes, which draw no pedals (question Q1); an LED cue.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 2: the FX face with Toggle/Hold per pedal (about 620 production lines added, about 250 removed; no dependencies)

**Decision D1.** FX mode gets a pedal-map face (10/03) like Mixer and Fade, and
the #692 Candidate A re-dress of the Tracks columns is removed:
`TrackColumn.fxTarget`, `inputNames`, `_FxChainDressing` and
`_stageFxTargetLabel` (`track_column.dart:129-175`, `:256-300`, `:445`,
`:895-902`, `:926-`), and the `fxSurface` background branch
(`tracks_view.dart:215-217`). The pen draws FX as this face, and the approved
FX Toggle/Hold proposal is drawn on it; there is nowhere else to put a
per-pedal Toggle/Hold line. This closes #884 and #873 by construction: the
caption reads the binding, and the stage words come from the shared
`fxStageLabel`/`bindingTargetLabel`.

**Model** `lib/control/model/foot_fx.dart`: `FootFxPedal` roles for all ten
switches and `projectFootFx(ControlState, LooperState, FxChainLookup)`:
- Track switch with a binding for the current bank: title = the target's chain
  or effect name from `FxChainLookup` (the #884 data source), falling back to
  `bindingTargetLabel`; detail = `Toggle` for `BindingBehavior.toggle`, `Hold`
  for `momentary` (pen `ri60q`); hint = `Hold · <hold target label>` when the
  binding has a `holdTarget`; semantics add `fxStageLabel`. A stale binding
  (`decodeTarget() == null`) reads the assignment screen's broken-row wording,
  disabled.
- Unbound track switch: title = the track's chain name or `Track N`, detail
  `Toggle` (it toggles the track chain, `:1802-1803`).
- Stop: `All FX off`, hint `Hold · Restore FX` (existing panic and restore);
  Bank: `Bank A/B`, `Switch bank`, hint `Hold · Record performance` (existing
  `_armBank`); MODE: `Exit`; Rec/Play, Undo, Clear: unavailable (inert today).
- `selected` mirrors the physical LED, which already lights a momentary only
  while held and a toggle while its target is enabled (`_boundChains`). The
  held pedal's detail line brightens while its contact is held (`ri60q`,
  Light FX 1) through `PerformancePedal.detailHighlighted`, which Reverse
  added (`performance_pedal.dart:74`).

**Cubit.** `footFxPressed/Released/Cancelled` and `activateFootFxPedal` admit
on-screen contacts into `_handleEvent` the way `footFadePressed` does
(`:2089-2108`); FX dispatch itself stays where it is (`_onPress`
`:2374-2437`). No new state.

**Refusals** (§3). A stomp on a stale binding: toast `footFxUnavailable`
("This pedal's effect is no longer available. Reassign it in Pedal
assignments."). A refused enable write: the new `footFxFailure` counter and
toast ("The effect could not be switched. Try again."). No FX switch dims for
an empty track: chains exist and toggle on empty tracks.

**#601.** Closed as obsolete with the evidence in §1.3. The face reads each
target's own `enabled` flag (a slot target its slot, a chain target its
chain), so a bypassed effect never reads as active here.

**Tests.** Projection: bound chain on another stage (the #884 repro: pedal 1
bound to Input 2's chain, track 0 without effects) names the chain and its
stage; a loop-lane target names `Track 2 · lane 1` (the #873 repro, 1-based);
momentary reads `Hold`, toggle `Toggle`, hold target adds the hint; stale is
disabled with the broken-row text; bank B shows B bindings. Widget: momentary
LED and highlighted detail only while the contact is held; toggle stays lit
after release; Exit returns to Record. Goldens `foot_fx.png` (`noDGu`) and
`foot_fx_held.png` (`ri60q`), `es` geometry probe. Removal:
`! grep -rn "fxTarget\|_FxChainDressing\|_stageFxTargetLabel" lib`.

```success-criteria
GOAL: FX mode shows the pen's pedal-map face, each track switch names what its binding drives with a Toggle or Hold line, and a held momentary lights only while held.
SUCCESS CRITERIA:
- A pedal bound to a chain on another stage names that chain and stage; a lane target is 1-based and names its track. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Toggle and Hold lines follow BindingBehavior; the momentary LED and highlight last exactly as long as the contact. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- The Tracks-column FX re-dress is gone. | verify: ! grep -rnE "fxTarget|_FxChainDressing|_stageFxTargetLabel" lib
- Goldens match noDGu and ri60q on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: a momentary FX pedal's LED is lit only while the foot is down; a toggle stays lit. | verify: manual on device
NON-GOALS:
- New binding semantics; FX activation editing; the Mute and Tracks faces.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 3: the Custom face (about 560 production lines; no dependencies)

**Model** `lib/control/model/foot_custom.dart`: `projectFootCustom(PedalSetup,
ControlState, …)` for all ten switches, following `role()` in
`pedal-performance-study.js` (`view === 'custom'`):
- MODE: `Exit`, lit. Bank: `Bank A/B`, `Switch bank`.
- Every other switch: title = `controlActionLabel` of its Press, or the
  hardware name (`Record / Play`, `Stop`, `Undo`, `Clear`, `Track N`) when
  Press is None; hint = `Hold · <label>` when it has a Hold; enabled when
  Press or Hold is assigned and available. Unassigned is drawn at the pen's
  unavailable opacities (`MV9wz`: "an unassigned one does nothing").
- A switch whose Press is `recordPerformance`: `Record performance`, or
  `Stop recording` (lit) while `_performanceArmed` (20/03 `E7kQV`, where the
  Stop switch carries it). Part 8 adds the saving and held captions.
- `selected` = `_physicalCustomStates` for that switch, so the face and the
  LED cannot disagree.

**View** `lib/looper/view/foot_custom_view.dart` (header with Exit, the
recording indicator from `StageTopBar` when armed, as 20/03 draws `01:23`, and
Settings calling `openSegnoSettings`, not the tray), and the face branch in
`tracks_view.dart:219-225`.

**Cubit.** `footCustomPressed/Released/Cancelled`, `activateFootCustomPedal`
into the existing `_onPress` custom route (`:2362-2373`). Tile taps keep
selection-only (`track_column.dart:401-406`), which no longer matters on this
face.

**Refusals** (§3 rule 3). Every assigned action the dispatcher refuses (an
unavailable target, an empty or busy target track, a refused engine result)
gets one notice, from any mode, since Custom, External and MIDI share
`_runAction` (`control_cubit.dart:2560`). Operations that already report their
own refusal keep their toast and add nothing: Fade (`footFadeFailure`),
Reverse (`footReverseFailure`) and Peel (`footPeelFailure`, PeelP3, which
already notifies an assigned Peel from any mode). Everything else bumps a new
`assignedActionFailure` counter with the action's label; its listener sits
beside PeelP3's in `tracks_view.dart`, not gated on the mode, and shows "<action>
is unavailable right now." (one cause, one notice). Before this part those
refusals were silent. Rule 1 does not dim a Custom switch whose target track
is empty: it is an assignment, so it stays enabled and its press gives the
notice.

**Pen write-back (owner).** `uEukr` dims Record/Play, Stop and Undo although
two carry assignments; the build dims only unassigned switches, per `MV9wz`.
The departure is recorded in the PR for the owner to write into the pen (this
plan does not edit the pen).

**Tests.** Projection over a setup with bank A/B track assignments, a Hold-only
switch, an unavailable instrument action and `recordPerformance` on Stop;
Bank flips the track captions; widget contacts reach `_armCustom`; LED
parity with `_physicalCustomStates`; the guards in §3. Goldens
`foot_custom.png` (`uEukr` with the departure) and `foot_custom_recording.png`
(`E7kQV`).

```success-criteria
GOAL: Custom mode has its own pedal-map face that names each switch's assignment for the current bank and lights exactly what the LEDs light.
SUCCESS CRITERIA:
- Captions, hints and availability follow PedalSetup.customFor for banks A and B; unassigned switches are dimmed and inert. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Record performance reads Stop recording and is lit while armed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Each refused assigned action shows exactly one toast, from Custom and from Tracks mode through External and MIDI; Fade, Reverse and Peel keep their own toast and add none. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Goldens match uEukr and E7kQV on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: enter Custom with MODE Hold; each assigned switch acts and the face matches the LEDs. | verify: manual on device
NON-GOALS:
- Editing assignments (Pedals setup owns it); held/saving recording captions (Part 8).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 4: native tuner mute (about 160 production lines: about 90 C, 70 Dart; no dependencies)

**Decision D2.** The Tuner's temporary mute is a native mask owned by the tuner
arm, not the persistent monitor mute. Monitor mute is saved, Session-captured,
replayed and perf-logged (§1.5); a Tuner that borrowed it would need restore
logic on Exit, teardown and session replacement, and any unrelated save during
tuning could persist it. The native mask cannot outlive the tuner: disarming
clears it in the same command.

**Contract** (`segno_engine_api.h`, after `le_engine_set_tuner_input`):
`LE_CMD_SET_TUNER_MUTE = 132` (ledger range 132-135; 133-135 stay free) and
`LE_EXPORT int32_t le_engine_set_tuner_mute(le_engine* engine, uint32_t input_mask);`
posted through the ring like `le_engine_set_tuner_input`
(`engine_commands.c:3459-3465`). Returns `LE_ERR_INVALID` for a null engine,
`LE_OK` otherwise. Snapshot gains `uint32_t tuner_mute_mask` next to
`tuner_input`.

**Audio side.** `engine_private.h`: `_Atomic uint32_t a_tuner_mute_mask` beside
`a_tuner_input` (`:1521`). Handler: store `mask & ((1u << in_channels) - 1)`,
or 0 while `a_tuner_input < 0` (a mask without an armed tuner is refused by
storing 0). `LE_CMD_SET_TUNER_INPUT` stores 0 whenever it disarms
(`engine_process.c:3509-3525`). Boot and every configure store 0
(`engine.c:796-799`). The monitor block reads the mask once per block where it
builds `mon_mut[]` (`engine_process.c:4950`) and ORs bit `c`, so the existing
mute path (`:4974`, `:5408-5410`) does the rest. Track lanes record from `in_c`
untouched (`:6422-6434`) and the detector keeps tapping before the mute
(`:6803-6805`). Not perf-logged: it changes no musical record; a captured
monitor stem gets silence for the muted input, exactly what was audible, as
with a monitor mute.

**Dart.** Regenerate bindings (then `dart format`, per the ffigen note in
`docs/PROGRESS.md`); `AudioEngine.setTunerMute(int mask)` in the engine, the
native and the mock engines; `EngineSnapshot.tunerMuteMask`;
`LooperRepository.setTunerMute(Set<int> inputs)` that remembers the mask next
to `_tunerInput` (`looper_repository.dart:360-364`) and re-sends it after the
input re-arm on restart (`:2536-2540`); `LooperState.tuner` carries
`muteMask`.

**Native tests** (new `packages/segno_engine/src/test/test_engine_tuner.h`,
included like `test_engine_fade.h`; fixture as `test_monitor_mute`,
`test_engine_core.c:8517-8553`):
- `test_tuner_mute_literal`: 48 kHz, 4 in, 2 out; monitors 0-3 on, all to
  out 0, inputs constant 0.1, 0.2, 0.3, 0.4. Out 0 is 1.0 (±1e-6). Arm input
  2, mask `0b1100`: out 0 is 0.3; snapshot `tuner_mute_mask == 0xC`. Mask 0:
  1.0.
- `test_tuner_mute_keeps_monitor_mute`: monitor mute on input 0, tuner mask
  `0b0010`: out 0 is 0.7; tuner mask 0: 0.9 (input 0 still muted, its
  `a_muted` unchanged).
- `test_tuner_mute_cleared_by_disarm_and_configure`: mask set, then
  `le_engine_set_tuner_input(e, -1)`: out 0 is 1.0 and the snapshot mask 0;
  a mask posted while disarmed stays 0; reconfigure clears it.
- `test_tuner_mute_detector_and_capture_independent`: a 220 Hz sine of
  amplitude 0.5 on input 2, armed and muted; after 0.5 s `tuner_hz` is within
  1 Hz of 220 and confidence >= 0.5; track 0 recording input 2 over the same
  frames holds the input samples exactly (literal compare of 4800 frames).
- `test_tuner_mute_not_logged`: with a performance capture armed, a mask
  change adds no events.log record and the input's monitor stem is zero for
  the muted frames.

```success-criteria
GOAL: The engine can silence the monitors of chosen inputs for exactly as long as the tuner is armed, without touching monitor mute, track capture or the detector.
SUCCESS CRITERIA:
- Literal monitor sums with and without the mask, with a persistent monitor mute alongside, and after disarm and configure. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The detector reads a muted input and a track records it sample-exactly; no events.log record is written. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- Repository re-sends the mask after a restart and the mock engine records it. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
- Analyzer is clean. | verify: dart analyze --fatal-infos
NON-GOALS:
- Any UI; the #909 callback cost (PR #912).
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
drops `arm`, `disarm` and `selectInput` (arming moves to Control in Part 6),
and starts the stale hold on an input mismatch too (fixes `:148-151`). It keeps
the 1.2 s dimmed hold, then clears to no reading (decision D5).

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
  `Input muted`/`Input audible`/`Not monitored` (lit while muted); Undo =
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
A4 = 432 names 432 Hz as A in tune; mismatch starts the hold; projection with
2, 4, 6 and 18 inputs (`Inputs 17–18`, two `—` pedals), a loopback-excluded
input, a pair (muting input 4 mutes 3 and 4), an empty device; actions order
`setTunerInput` before `setTunerMute`.

```success-criteria
GOAL: Tuner reference and input persist as appliance preferences, the reading uses the reference, and the foot Tuner's paging, pair muting and actions exist as tested pure code.
SUCCESS CRITERIA:
- Reference clamps to 420-460, resets to 440 and survives a restart; a failed write keeps the previous value. | verify: (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/tuner
- Readings use the stored reference; an input mismatch clears after the hold. | verify: /Users/Tomas/development/flutter/bin/flutter test test/tuner
- Paging, pair muting and source fallback match the study for 2, 4, 6 and 18 inputs. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- The mode and face (Part 6). The tray face keeps working: until Part 6 it arms through LooperRepository.setTunerInput directly, as TunerCubit did.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 6: the foot Tuner mode and face (about 650 production lines; depends on Part 5; PR #912 on the trunk before its hardware criterion)

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
deleted. The tray's Tuner entry (the rail entry on the trunk, or Settings Part
5's handle if it landed first) calls `setMode(InteractionMode.tuner)` instead,
so there is one tuner surface (rule 4).

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
- HARDWARE: guitar on input 1: MODE Hold → Tuner, the string reads, the monitor is silent while a track records it; Exit restores monitoring. | verify: manual on device
- HARDWARE: with the tuner up and four tracks playing on the Pi 5, callback p99 stays under budget (needs PR #912 on the trunk). | verify: manual on device
NON-GOALS:
- Secondary-display Tuner feedback (E6-11); instruments in the input list (E8-14).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 7: New Loop by foot (about 210 production lines; depends on PR #1216, Library Part 5)

**Action.** `ControlCommand.newLoop('command:new-loop')` in
`ControlActionGroup.sessions` (`control_action.dart:70-71`, the group's first
entry), label `New loop` (pen 19/01). Assignable to Custom, External and MIDI
like every command.

**Dispatch.** `_runCommand(newLoop)` refuses while any track is capturing or
has a pending arm (toast `Finish recording first.`, the study's
`Finish recording` reason), and otherwise bumps `ControlState.newLoopRequest`
(a monotonic counter, the `clearAllPulse` pattern, `tracks_view.dart:185-193`)
and is accepted (contact LED). `takeLocked` already gates it. An app-level
`BlocListener<ControlCubit>` in `app.dart` calls `SessionCubit.newLoop()` once
per bump; Control never depends on `SessionCubit` (rule 4: one New Loop
method, the Library's). A press while the Library is open returns to Tracks
first (Library D14).

**Notice.** By foot there is no confirm sheet (accepted §4: "work directly by
foot"); preservation is what makes that safe (rule 2). So the outcome is never
silent (rule 3): on `SessionOutcome.newLoop` the listener shows the 19/02
sentence as a toast, `<name> stays in your Library.`, naming the preserved
session. `SessionState` gains `preservedName`, set by `_preserveOutgoing`
(LibP5 `:286`) and null when nothing was preserved (an untouched rig), in
which case no toast is shown. A refused or failed New Loop shows the existing
session failure toast (`onSessionState`).

**Decision D6.** A running performance recording is finished and saved first,
because the shared apply path calls `disarmAndFinalize` (LibP5 `:570`). The
recorder's completion flow then shows as it does for the Library's New loop
(rule 1, one path). See question Q2.

**Tests.** Refusal while capturing and while pending (toast, no bump); bump
calls `newLoop` once; preserved-name toast and no toast for an untouched rig;
takeLocked; the catalogue round-trips `command:new-loop`.

```success-criteria
GOAL: A pedal, CTRL switch or MIDI control assigned New loop runs the Library's New loop directly, refuses while a track records, and says which session it kept.
SUCCESS CRITERIA:
- The command round-trips, is refused with a toast while capturing or pending, and otherwise calls SessionCubit.newLoop exactly once. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/app
- The toast names the preserved session; none appears when nothing was preserved. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app test/session
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: assign New loop to a Custom switch, record two tracks, press it: the stage reads New loop N and the old session opens from the Library with both tracks. | verify: manual on device
NON-GOALS:
- Any change to what New loop keeps or resets (Library plan D9).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: Record performance retry by foot (about 160 production lines; depends on Recording plan Parts 8 and 9, and Part 3)

**Dispatch.** `_togglePerformanceRecordAccepted` (`control_cubit.dart:2818-2825`)
reads the repository's capture status: armed → `disarm()`; finalizing or
saving → refused with toast `The recording is still saving.` (the caption is
dimmed, but a physical press still arrives and gets the notice, §3 rule 3); held with Save
available → `saveHeld()` (the retry); held without an available Save (USB drive
absent) or idle → `arm()`. Every caller gets the retry: Custom, External,
MIDI, the FX Bank hold and the MODE hold path, since they all reach this
method (rule 4).

**Captions** (Custom face, FX Bank hint): `Record performance`, `Stop
recording` (lit), `Saving recording` (unavailable), `Save recording` (held),
from `pedal-performance-study.js` `role()`. A held take's failure copy stays on
the Record performance page (20/05, 20/06); a failed retry by foot shows the
20/06 sentence as a toast: `Could not save the recording. It is kept here for
another try.`

**Tests.** Each status row of the table above; a throwing `saveHeld` keeps the
take held and toasts; a second press retries and completes; an absent drive
arms a new take and leaves the held one alone.

```success-criteria
GOAL: The Record performance switch starts, stops and, when a take is held, retries its save by foot, with captions that say which it will do.
SUCCESS CRITERIA:
- Status-to-action table holds for idle, armed, saving, held with Save available and held without it; a failed retry keeps the take and toasts the 20/06 sentence. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/looper/view
- Captions follow the four phases on the Custom face. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Analyzer and Bloc lint are clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: pull the USB drive while recording, reconnect it, press the switch: the take saves. | verify: manual on device
NON-GOALS:
- Discard by foot (destructive; stays on the page behind its confirm).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Order and dependencies

Parts 1, 2, 3 and 4 are independent of each other and of other epics. Part 3
excludes Peel from its generic notice only if PeelP3 has landed; if Part 3
lands first, PeelP3 adds that exclusion when it rebases. Part 5
follows Part 4; Part 6 follows Part 5 and unblocks Settings Part 6. Part 7
waits for PR #1216; Part 8 waits for Recording Parts 8 and 9 and this Part 3.
Faces landed before Part 1 pick up the cue when it lands, because the cue lives
in `PerformancePedal`.

| Part | Production lines | Native | Depends on |
|---|---|---|---|
| 1 Pending Hold | ~220 | – | – |
| 2 FX face | ~620 (+~250 removed) | – | – |
| 3 Custom face | ~560 | – | – |
| 4 Tuner mute | ~160 | command 132 | – |
| 5 Tuner owner | ~520 | – | 4 |
| 6 Tuner mode and face | ~650 | – | 5 (PR #912 for hardware) |
| 7 New Loop by foot | ~210 | – | #1216 |
| 8 Recording retry | ~160 | – | #1198 P8, P9; 3 |

## 5. Decisions under the owner rules

- **D1 (pen authority, rule 4).** FX mode gets the pen's pedal-map face and the
  Tracks-column re-dress (#692 Candidate A) is removed; #884 and #873 close
  with it, #601 closes as obsolete (§1.3).
- **D2 (rule 2).** The Tuner mute is a native mask tied to the tuner arm, never
  the persistent monitor mute (Part 4).
- **D3 (rule 1).** FX keeps Stop panic/restore and the Bank hold for Record
  performance, captioned on the face, though 10/03 dims Stop; accepted §4's
  "clear current actions" is the panic. Recorded for pen write-back.
- **D4 (rule 4).** Tuner arming moves from `TunerCubit` to Control's foot
  actions; `TunerCubit` keeps the reading. One surface, one arm owner.
- **D5 (rule 1).** The tuner keeps its 1.2 s dimmed hold and then clears ("no
  signal clears the old reading"); confidence stays 0.5. Both are measured
  baselines to confirm on hardware (accepted §4.12).
- **D6 (rule 1).** New Loop by foot finishes a running performance recording,
  as the shared Library path does (Q2).
- **D7 (rule 3).** New Loop by foot toasts the preserved session's name; the
  Library's own button keeps its sheet.
- **D8.** Engine numbers: command 132 only; facts 352-355 and commands 133-135
  are unused and returned to the ledger. No events.log or Session schema bump.
- **D9 (rule 3).** Presses dropped under `takeLocked` stay silent on every new
  face, as on the existing ones (§3).
- **D10 (shared notice policy).** Every part follows §3: empty track pedals
  dimmed and silent, busy or refused presses on recorded material and every
  refused assignment notified, one notice per cause. Part 3 adds the one
  generic notice for assigned actions that have none of their own.

## 6. Findings for other plans

- Recording plan Part 13 (`:1227-1230`, `:1244`) asserts `Stop recording` on
  the **Record/Play** pedal label. Pen 20/03 `E7kQV` is the Custom face with
  Record performance assigned to **Stop**; this plan's Part 3 owns that
  caption. Part 13's criterion should point at Part 3's test instead.
- The Settings plan's §5 names `foot_fade_view.dart:135` and
  `foot_mixer_view.dart:123` (`:43`) but not `foot_reverse_view.dart:85`,
  which Reverse P3 added after it was written; its Part 2 should reroute that
  button too. This plan adds no tray users.
- PR #912 (#909) targets `master`; it needs a rebase onto this trunk before the
  foot Tuner can be left armed during performance.

## 7. Questions for the owner

- **Q1.** The pen draws the Pending Hold cue on the Tracks pedal map (10/04),
  but Tracks and Mute modes in the app show track columns with no on-screen
  pedals. The plan draws the cue on every face that shows pedals (Mixer, Fade,
  Reverse, FX, Custom, Tuner) and nowhere in Tracks or Mute. Should Tracks and
  Mute gain an on-screen pedal strip to carry it?
- **Q2.** New Loop by foot during a performance recording finishes and saves
  the recording (D6), because the Library's New loop does. Should a foot New
  Loop keep the performance recording running instead? That would need the
  shared apply path to skip `disarmAndFinalize` when the device configuration
  is unchanged.

## 8. Budget and review ceiling

Every part stays at or under about 650 production lines added; tests,
generated bindings, goldens and l10n are counted separately. Stop for review
on any further engine command, a Session schema change, a second tuner arm
owner, or a second New Loop path. Each part runs the Dart suite, `dart analyze
--fatal-infos` and `bloc lint lib test packages`; Part 4 also runs the native
suite normal, ASAN and telemetry-off. Independent architecture, test and
adversarial reviews precede each publication; the human merge gate stays.
