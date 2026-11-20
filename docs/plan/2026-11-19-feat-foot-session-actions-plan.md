---
title: "Sessions by foot: the Sessions face"
type: feat
date: 2026-11-19
issue: 1910
---

# Sessions by foot: the Sessions face

<!-- cspell:words Penpot writeback manualslib Unfiled -->

Tracking: [#1910](https://github.com/tomassasovsky/segno/issues/1910),
`autonomy:plan-gate`. New loop by foot is
[#1229](https://github.com/tomassasovsky/segno/issues/1229) Part 7
([`2026-10-06-feat-foot-surfaces-plan.md`](2026-10-06-feat-foot-surfaces-plan.md)).
The default Custom map is
[#1908](https://github.com/tomassasovsky/segno/issues/1908).

## Owner direction, 2026-11-19

The first version of this plan made `Load previous session` and `Load next
session` assignable actions with a press-again confirmation. The owner
tried a sketch of it and rejected it. Its faults:

- The player stepped without seeing what came next, and learned the name
  only while the session loaded.
- The fifth session of a set took four loads to reach.
- One switch behaved two ways: it opened at once when the rig was stopped
  and asked, on a 6 s timer, when it played.
- Four actions took four of the eight Custom positions.

The owner accepted a second sketch: Sessions as a performance function with
its own face, where the four track switches open the four sessions drawn
above them. This plan builds that.

## Owner decisions, 2026-11-19

All six decisions about the face were answered as recommended. The
sections under "The decisions in detail" keep the reasoning and the
alternatives that were not chosen.

1. **Order.** Name order inside the folder, ignoring case, numbers compared
   as numbers. No order set by hand, so Part 4 is not built.
2. **Save and New loop.** Undo saves on a press. Clear starts a new loop on
   a Hold, and a press of Clear does nothing. Both are also assignable
   commands. Previous and next are not built.
3. **Opening while something plays or records.** No second press and no
   timer. Each card says what the press ends.
4. **After each action.** The face closes after an Open, a Save or a New
   loop and returns to the mode it was entered from. A failed Open keeps
   the face up with the reason on its card.
5. **Folders.** The face starts on the open session's folder and page. A
   held Bank goes through the folders in name order, Unfiled last, and
   skips empty ones.
6. **The rest.** Save with no open session takes `New loop N`. The switch
   under the open session is lit. The readout's footer shows `Sessions`
   and the page.

## Where it stands

- The design's catalogue (`docs/design/pedal-action-catalogue.js` in
  segno-design) lists `command:new-loop`, `session:previous`,
  `session:next` and `session:save`. It has no Sessions function. Penpot
  page 19 "Sessions · New loop & recall" draws only touch.
- In the app, `ControlActionGroup.sessions`
  (`lib/control/binding/control_action.dart`) has a heading and no entries.
  `ControlCommand` has no New loop and `InteractionMode` has no Sessions.
- `SessionCubit` (`lib/session/cubit/session_cubit.dart`) has the
  operations. `open(id)` validates the target, ends a take in progress,
  saves the outgoing rig when it has changed, finishes a running
  performance recording, and applies the rig stopped. `save()` writes back
  to the open session, or saves a rig with none as `New loop N`.
  `newLoop()` saves the outgoing rig and starts an empty one. Its state
  holds the catalogue (`sessions`, `folders`) and the open session's id.
- A performance function is an `InteractionMode` owned by `ControlCubit`,
  with a pure projection of the ten pedals, a part file of the cubit, and a
  view that draws the pedals with `FootPedalRows`. The Tuner is the closest
  one: `lib/control/model/foot_tuner.dart`,
  `lib/control/cubit/control_foot_tuner.dart`,
  `lib/tuner/view/foot_tuner_view.dart`. Its track switches pick one of
  four inputs and Bank shows the next four. On the pedal link it is
  `PedalMode.custom`, so a new function needs no firmware change.
- `ControlCubit` does not depend on `SessionCubit`, and a cubit never calls
  a cubit.
- A settled session action shows a notice on the stage and on the 7"
  readout (`showSessionOutcome`, `lib/looper/view/tracks_commands.dart`).
- When a session apply finishes a performance recording, the recorder's
  completion sheet opens over the new session. #1229 Part 7 plans a notice
  there; it is not built.

## What other products do

- Boss GT multi-effects pair a bank pedal with number pedals: the bank
  pedal shows the next group of patches, and a number pedal loads one of
  them
  ([GT-1000 manual, Play option](https://www.manualslib.com/manual/1585380/Boss-Gt-1000.html?page=41)).
  The Sessions face is this pattern.
- Boss loop stations step numbered memories with `MEMORY INC` and
  `MEMORY DEC`
  ([RC-500 manual, Memory settings](https://www.manualslib.com/manual/2363651/Boss-Rc-500.html?page=8)).
  This is the pattern the owner rejected. It suits a two-digit display, and
  Segno has a screen that can show four names.
- Segno's own faces already work this way. The FX face shows four
  assignments and Bank shows four more. The Mixer pages four channels with
  Bank, and holding Bank switches between Tracks and Inputs. §4.5 gives
  Backing the same shape: select by foot, page, and Exit.

## The face

One function, `Sessions`, entered by an assigned switch (a Custom switch,
an external pedal or a MIDI control). While it is up:

| Switch | Does |
|---|---|
| Track 1 to 4 | Opens the session drawn above it |
| Bank | Shows the next four sessions; after the last page, the first |
| Bank, held | Shows the next folder |
| Undo | Save |
| Clear | New loop (D2) |
| Rec/Play, Stop | Their transport jobs, as on the Mixer and Fade faces |
| MODE | Exit |

On the main screen the face draws the ten pedals with their captions, as
every face does. Above the four track switches are four cards, one per
session: its name, track count and tempo. The card of the open session says
`Open now`. To the left are the folder's name and `Page 1 of 2 · 6
sessions`. A position with no session says `Empty` and its switch does
nothing.

The drawn pedals take taps, as the Mixer face's do, so the face can be
operated by touch as well.

## The decisions in detail

### D1. The order of the sessions on the face

The four positions need an order that does not change while the player
performs, so that a session stays over the same switch.

Recommended: name order inside the folder, ignoring case, with numbers
compared as numbers. It needs no stored data and no new screen.

It differs from the Library, which lists newest first. That order cannot be
used here: opening a session saves the one that is left, which moves it to
the top, so every card would shift after each Open.

The alternative is an order the player sets by hand: numbered rows in a
folder with Move up and Move down in the Library, as the backing list has
(§6.4), stored with the folder. Then switch N is always session N, whatever
the names are. It is Part 4 below. The owner chose name order, so it is not
built.

### D2. Save and New loop on the face

Recommended: Undo is Save on a press. Clear is New loop on a Hold, with the
red fill Clear's Hold already has (#1534); a press of Clear does nothing.
Clear sits beside Bank on the raised row, and Bank is pressed often in this
face, so a press that slips must not start a new loop.

The alternative is New loop on a press of Clear, which is one gesture
shorter.

Both are also assignable on their own, outside the face: `New loop`
(`command:new-loop`, owed under #1229 Part 7) and `Save session`
(`session:save`). They are built first, in Part 1, because the face's Undo
and Clear use the same path, and because Part 1 then works by itself before
the face exists. `Load previous session` and `Load next session` are not
built.

### D3. Opening while something plays or records

§6.1 says Open "confirms any playback interruption".

Recommended: no second press and no timer. The player has already entered
the face and reads the name before pressing. Each card states what the
press will end, in the warning colour:

- `Stops playback` while a track plays.
- `Ends the take` while a track records, overdubs or is armed. The take is
  ended at its Record timing and saved with the session that is left, as
  Open does today.
- `Ends the recording` while a performance recording runs. It is finished
  and saved, and the stage shows `Recording saved. Find it in Library >
  Audio.` in place of the completion sheet (#1229 O2 and D6).

§6.1 is updated to say that by foot the face's card is the confirmation.

The alternative is select, then confirm: the first press on a card marks
it, and a second press on the same switch opens it. It costs one press on
every Open and has no timer.

### D4. What happens after each action

Recommended:

- **Open.** The pressed card says `Opening…` and the other switches do
  nothing until it ends. Then the face closes, the mode is the one the
  face was entered from (as the FX face's Exit does), and the stage says
  `<name> opened` in place of `Session loaded`. Tracks are stopped (§6.1).
- **An Open that fails.** The face stays. The card shows the reason the
  Library shows for that session today, and the stage notice names the
  session: `Could not open <name>`. The open session is unchanged.
- **Save** and **New loop.** The face closes and the usual notice shows:
  `Session saved`, or `<name> stays in your Library.` for a New loop.
- **A press on the card of the open session** closes the face.
- **Exit** closes the face and changes nothing.

The alternative for Save is to keep the face up, for a player who saves and
then opens another session. Open already saves the session that is left, so
that case does not need it.

### D5. Folders, and where the face starts

Recommended:

- The face opens on the folder of the open session, on the page that holds
  it. With no open session it opens on the sessions outside any folder,
  shown as `Unfiled`.
- Holding Bank goes to the next folder, in name order, with Unfiled last,
  and wraps. A folder with no sessions is skipped.
- With no saved session at all, the four cards say `Empty`, and the side
  says `No sessions yet. Save or start a new loop.`

The alternative is to show every session in one list, ignoring folders. A
player with many sessions would page through all of them to reach a set.

### D6. Save with no open session, LEDs, and the readout

Recommended:

- Save on a rig with no session takes the automatic name, `New loop N`, as
  Ctrl/Cmd+S does, and the notice says `Saved as New loop N`.
- LEDs: the switch under the open session is lit in the `selected` state
  (white by default). Switches under other sessions and under empty
  positions are dark. MODE and Bank keep their usual lights, and a pressed
  switch lights while held. Pedals > LED colors gains the Sessions map, as
  every function has one.
- The 7" readout's footer shows `Sessions` and the page in place of the
  bank. The cards are on the main screen only.

## How the catalogue and the requests travel

`ControlCubit` owns the face, as it owns every face, and it needs the
catalogue, which `SessionCubit` holds.

- A listener at the app level (`lib/app/view/app.dart`) hands
  `SessionState`'s catalogue, folders, open session and last failure to
  `ControlCubit` whenever they change. `ControlState` keeps them for the
  projection.
- `ControlCubit` keeps the face's own state: the folder and the page.
- A press that needs the session layer emits a request on `ControlState`
  (a serial number and what is asked: refresh the catalogue, open an id,
  save, new loop). This is the `clearAllPulse` pattern.
- A second app-level listener passes each new request to
  `lib/app/foot_session_actions.dart`, which calls
  `SessionCubit.refreshSessions()`, `open(id)`, `save()` or `newLoop()`.
  These are the methods the Library and Ctrl/Cmd+S call. Every rule about
  takes, saving and guards stays inside `SessionCubit`.

Entering the face asks for a refresh, because the catalogue in state is
only as new as the last session action.

## Parts

Each part is one PR on a branch `claude/foot-sessions-1910-p<K>`, and each
leaves every assigned action working.

### Part 1: New loop and Save as assignable commands

New loop is #1229 Part 7, under its decisions O2, D6 and D7. The PR says
`Refs #1229` and `Refs #1910`.

- `ControlCommand.newLoop` (`command:new-loop`) and
  `ControlCommand.saveSession` (`session:save`), both in the Sessions
  group, with labels and foot captions in English and Spanish:
  `lib/control/binding/control_action.dart`,
  `lib/control/binding/control_action_labels.dart`,
  `lib/looper/view/foot_custom_view.dart`, `lib/l10n/arb/`.
- The request on `ControlState` and its emission:
  `lib/control/cubit/control_state.dart`,
  `lib/control/cubit/control_cubit.dart`.
- The app-level listener and the handler: `lib/app/view/app.dart`,
  `lib/app/foot_session_actions.dart`.
- `<name> stays in your Library.` for a New loop asked by foot, and only
  when a session was saved: `lib/session/cubit/session_cubit.dart`,
  `lib/session/cubit/session_state.dart`,
  `lib/looper/view/tracks_commands.dart`.
- A performance recording finished by a session apply shows the saved
  notice and no completion sheet, for Open and New loop from touch or
  foot: the stop cause in `packages/performance_repository`, the recorder
  cubit's state, and `onPerformanceRecorderState` in
  `lib/looper/view/tracks_commands.dart`.

Acceptance:

- Both keys parse and print back; the action picker shows the Sessions
  heading with two rows (`test/control/binding/control_action_test.dart`,
  `test/control/binding/binding_labels_test.dart`,
  `test/control/pedal_setup_page_test.dart`).
- A Custom press, an external switch and a MIDI control assigned either
  command each emit one request per press, and none while `takeLocked`
  holds (`test/control/foot_custom_dispatch_test.dart`,
  `test/control/external_dispatch_test.dart`,
  `test/control/midi_devices_dispatch_test.dart`).
- One request calls `SessionCubit.newLoop` or `save` once. Save writes
  back to the open session, or saves as `New loop N` with none open. The
  kept-session notice shows for the foot's New loop and not for the
  Library's button (`test/app/foot_session_actions_test.dart`, against a
  real `SessionCubit` over a temporary catalogue).
- A press of Save during a track take saves and the take goes on.
- A session apply that finishes a recording shows the saved notice and no
  sheet (`test/looper/view`, `test/performance`).
- Device: assign New loop and Save to two Custom switches; record two
  tracks while a performance recording runs; press Save, then New loop.
  The stage reads `New loop N`, the old session opens from the Library
  with both tracks, and the recording is in Library > Audio.

### Part 2: the Sessions face

- `InteractionMode.sessions`, its `mode:sessions` action and label
  `Sessions`. Every exhaustive switch over `InteractionMode` gains the
  case: `lib/looper/model/interaction_mode.dart`,
  `lib/control/binding/control_action.dart`,
  `lib/control/binding/control_action_labels.dart`,
  `lib/control/binding/pedal_led_labels.dart`,
  `lib/control/binding/pedal_led_map.dart`,
  `lib/control/control_projection.dart`, `lib/control/invariants.dart`,
  `lib/looper/view/tracks_view.dart`, `lib/looper/view/tracks_commands.dart`,
  `lib/looper/view/stage_top_bar.dart`, `lib/looper/view/track_column.dart`,
  `lib/looper/view/wave_track_row.dart`, `lib/theme/looper_theme.dart`,
  `lib/theme/surface_theme.dart`. It is never a boot mode, like the Tuner.
- The model: `lib/control/model/foot_sessions.dart`. The face's state (the
  folder and the page), the order under D1, the folders under D5, and a
  pure projection from the catalogue, the open session, the looper's state
  and the recorder's state to the ten pedals and the four cards.
- The cubit part: `lib/control/cubit/control_foot_sessions.dart`. Entering
  and leaving, the presses and the two Holds, the requests, and the mode
  the face returns to.
- The catalogue into `ControlState`: `lib/control/cubit/control_state.dart`
  and the listener in `lib/app/view/app.dart`.
- The view: `lib/looper/view/foot_sessions_view.dart`, with
  `FootPedalRows` and `FootTopBar`.
- The LED map for the mode, and its entry on Pedals > LED colors.
- The readout's footer for the mode (`lib/visualizer/`).
- `<name> opened`, `Could not open <name>`, the card lines and the
  captions, in English and Spanish.

Acceptance:

- Projection (`test/control/foot_sessions_projection_test.dart`): name
  order ignoring case with numbers as numbers; four per page; the last
  page padded with empty positions; the open session marked; an empty
  position unavailable; the folder order with Unfiled last and empty
  folders skipped; the start folder and page for an open session and for
  none; each card line of D3 for a playing track, a take and a running
  recording.
- Dispatch (`test/control/foot_sessions_dispatch_test.dart`): a track
  switch emits one open request for the session in its position; Bank
  pages and wraps; a held Bank changes folder and does not also page;
  Undo emits Save; a press of Clear emits nothing and a held Clear emits
  New loop; MODE returns to the mode the face was entered from; nothing
  is emitted while an Open is in flight or `takeLocked` holds; entering
  asks for a refresh.
- Against a real `SessionCubit`: an Open from the face saves the changed
  outgoing rig, ends a take, and closes the face on success; a failed
  Open keeps the face up with the reason on its card.
- LEDs (`test/control/pedal_led_projection_test.dart`): the open
  session's switch is lit, the rest follow D6.
- The view (`test/looper/view/foot_sessions_view_test.dart`): the four
  cards sit above the four track switches at 1920x1080; a tap on a drawn
  pedal or on a card acts as the switch does; nothing clips with a 40-character name,
  in both languages.
- Screenshots: the face with one page, a second page, a loop playing, an
  Open in flight, a failed Open and no sessions. Regenerated and viewed.
- Device: a folder of six sessions; Sessions assigned to a Custom switch;
  open the third while a loop plays; page to the sixth; hold Bank to
  Unfiled; Save; hold Clear for a New loop.

### Part 3: the design and the contract, and closing the issue

- The Penpot writeback below, and the snapshot PR in segno-design.
- `docs/handoff/segno-app/accepted-behavior.md`: §4.5 gains a Sessions row
  in the function table, and §6.1 says that by foot the face's card is the
  confirmation of an interruption.
- Removes the Active threads row and says `Closes #1910`.

### Part 4, not built: an order set by hand

- A stored order per folder in `packages/session_repository`, numbered
  rows in the Library's Sessions tab, and Move up and Move down in Manage
  (`lib/library/view/`). The face reads that order.
- D1 was answered with name order. This part is kept as a record of the
  alternative, for a later issue if names turn out not to be enough.

## Design writeback

Penpot, file **segno-ui**, through the `penpot` MCP server, one board per
call.

- Page `19 Sessions · New loop & recall`: boards drawn from the screenshot
  suite, `09 / Foot / Sessions`, `10 / Foot / Sessions / Playing`,
  `11 / Foot / Sessions / Opening`, `12 / Foot / Sessions / Could not open`
  and `13 / Foot / Sessions / Empty`. A `c/` note records why the face
  replaced previous and next (the four faults above), the Boss bank and
  number pattern, and decisions D1 to D6.
- Page `10 Performance · Tracks, Custom, FX & Mute`: the captions for
  `Sessions`, `New loop` and `Save` on the Custom face.
- Page `08 Pedal setup & LEDs`, with a note on pages `24 External pedals ·
  Function assignments` and `26 MIDI controls and Learn`, which share the
  picker: `Sessions` under Modes & functions, the Sessions group with
  `New loop` and `Save session`, and the LED map for the function.
- Page `25 Main views and selected-track display`: the readout's footer in
  the function.
- Page `20 Record performance & USB export`: #1229's W6, the saved notice
  in place of the completion sheet when a session apply finishes a
  recording.
- segno-design: `pedal-action-catalogue.js` gains `mode:sessions` and
  loses `session:previous` and `session:next`; `tool/penpot-snapshot`,
  commit `penpot/`, a PR linked to the app PR; `.github/segno-design.sha`
  moves to that commit if the `design` job needs it.

## Device checks (on the console)

- How long an Open takes from the press to `<name> opened`, for an empty
  session, a four-track session and an eight-track session with layers.
  If it is regularly over about two seconds, the card needs more than
  `Opening…`.
- The four cards are readable from standing height on the main screen.
- A held Bank and a held Clear are comfortable with a shoe, and a pressed
  Bank never reaches Clear's Hold.

## Not in this plan

- A default Custom assignment for `Sessions`. #1908 decides the map.
- `Load previous session` and `Load next session`.
- Marking a session as not to be overwritten. A prepared session that is
  overdubbed on stage is saved with the overdubs when another is opened,
  because Open preserves outgoing work (§6.1).
- One performance recording across a session change. The capture stamps
  one rig's chains and inputs when it is armed.
- Starting playback as a session opens. Tracks come up stopped (§6.1).
- Reopening the last session at start.
- Moving MIDI and external-pedal assignments into the session (#1206).
