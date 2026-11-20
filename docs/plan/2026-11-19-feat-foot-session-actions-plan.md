---
title: "Session actions by foot"
type: feat
date: 2026-11-19
issue: 1910
---

# Session actions by foot

<!-- cspell:words Penpot writeback IMMED manualslib Unfiled footswitch neighbour colour -->

Tracking: [#1910](https://github.com/tomassasovsky/segno/issues/1910),
`autonomy:plan-gate`. New loop by foot is
[#1229](https://github.com/tomassasovsky/segno/issues/1229) Part 7
([`2026-10-06-feat-foot-surfaces-plan.md`](2026-10-06-feat-foot-surfaces-plan.md)).
The default Custom map is
[#1908](https://github.com/tomassasovsky/segno/issues/1908). This plan stops
for the owner's answers to the six decisions below. Nothing is built until
they are answered.

## Where it stands

- The design's catalogue (`docs/design/pedal-action-catalogue.js` in
  segno-design) lists four session actions: `command:new-loop` "New loop"
  under Modes & functions, and `session:previous` "Load previous session",
  `session:next` "Load next session" and `session:save` "Save session" under
  Sessions. No study dispatches the three `session:` actions, and Penpot
  page 19 "Sessions · New loop & recall" draws only touch: eight screens and
  one `c/` note, about the loop template. What a foot Open does is not
  designed.
- In the app, `ControlActionGroup.sessions`
  (`lib/control/binding/control_action.dart`) has a heading
  (`actionGroupSessions`) and no entries. `ControlCommand` has no New loop.
- `SessionCubit` (`lib/session/cubit/session_cubit.dart`) has the operations.
  - `open(id)` reads and validates the target first, ends a take in progress
    (`_endCaptures`, up to 20 s), saves the outgoing rig when it has changed
    (`_preserveOutgoing`), finishes a running performance recording
    (`_applyRig` calls `disarmAndFinalize`), applies the rig stopped, and
    emits `loaded`. Opening the session that is already open does nothing.
  - `save()` writes back to the open session. With no open session it saves
    under the next automatic name, `New loop N`, and makes that current. It
    does not end a take: the save writes the settled tracks only.
  - `newLoop()` ends takes, saves the outgoing rig, and starts and saves an
    empty rig named `New loop N`.
- On touch, Open asks `Stop playback and open <name>?` only while a track
  plays, captures or is armed (`openWithConfirm`,
  `lib/library/view/library_preview_card.dart`). A running performance
  recording does not make it ask.
- The catalogue is listed newest first by save time
  (`SessionRepository.listSessions`), and the Library shows that order,
  filtered by its folder chip and search.
- Assigned actions from Custom switches, external pedals and MIDI all run
  through `ControlCubit._runAction`
  (`lib/control/cubit/control_cubit.dart`). A refused action shows
  `<action> is unavailable right now.` once. Every press is dropped, with no
  notice, while `takeLocked` holds: a session is opening, the power dialog
  is up, or audio is starting.
- A settled session action shows a notice on the stage whoever asked for it
  (`showSessionOutcome`, `lib/looper/view/tracks_commands.dart`): `Session
  saved`, `Saved as <name>`, `Session loaded`, or the failure's own words.
  Notices reach the 7" readout as well. While a session opens, the stage
  shows nothing; only the Library dims its buttons.
- A footswitch press while the Library is open returns to Tracks before it
  acts (`LibraryCubit._onPedalEvent`).
- When a session apply finishes a performance recording, the recorder's
  completion sheet opens over the new session. #1229 Part 7 plans a notice
  there instead; it is not built.

## What other products do

- Boss loop stations number their memories. The RC-300 and RC-500 list
  `MEMORY INC` and `MEMORY DEC` among the functions a pedal can be assigned,
  and the RC-500 also lists `EXTENT INC` and `EXTENT DEC`
  ([RC-500 manual, Memory settings](https://www.manualslib.com/manual/2363651/Boss-Rc-500.html?page=8)).
  The order is the memory number, which the player sets by where they
  save.
- Boss GT multi-effects have a `BANK MODE` setting for the bank pedals
  ([GT-1000 manual, Play option](https://www.manualslib.com/manual/1585380/Boss-Gt-1000.html?page=41);
  the GT-10 manual describes the two values): `IMMED` changes the patch as
  soon as the pedal is pressed, and `WAIT` shows the new bank and changes
  nothing until a number pedal is pressed.
- The design's own reference MIDI index
  (`SegnoReferenceMidiActions`, which the study labels as evidence only)
  gives numbers to `session:previous` and `session:next` and none to Save
  or New loop.

Segno has no memory numbers (§6.2: "No artificial session-slot limit"), so
the order has to come from something the player already controls. D1 uses
names and folders. D2 uses the `WAIT` pattern only when a press would stop
sound.

## Decisions for the owner

### D1. The order "previous" and "next" follow

Recommended: name order inside the open session's folder.

- The steps stay inside the folder of the open session. Sessions outside a
  folder (Unfiled) are a group of their own. A folder is then a set list.
- Inside the group, sessions are ordered by name, ignoring case, with
  numbers compared as numbers: `2 Verse` comes before `10 Outro`. The
  player sets the order by naming, for example `01 Intro`, `02 Song`.
- The ends do not wrap. Next on the last session opens nothing and says so
  (D6). §6.4 sets the same rule for backing files.
- With no open session (a fresh start, before anything is saved or opened)
  the group is Unfiled: Next opens its first session and Previous its last.
- The rig that is left is saved first, as every Open does: to its own
  session, or as `New loop N` in Unfiled when it has none. This is the
  existing rule and is not changed here.

The alternative is the Library's order, newest first. It changes while the
player performs: stepping away from a session that was overdubbed saves it,
which moves it to the top of the list, so the session that "next" names is
different after the save. A third option is a set list the player orders by
hand, as the backing list has Move Up and Move Down. It needs stored data
and a screen, and is left as a later addition if names turn out not to be
enough.

One consequence to know before answering: a prepared session that is
overdubbed on stage is saved with those overdubs when the foot steps to the
next one, because Open preserves outgoing work (§6.1). A player who wants
the prepared version back removes the overdubs (Undo or Peel) before
stepping, or keeps a duplicate in the Library.
Marking a session as not to be overwritten would be separate work.

### D2. The playback-interruption confirmation, by foot

§6.1 says Open "confirms any playback interruption". Touch asks only while
a track plays, captures or is armed.

Recommended: the same condition, and the foot confirms by pressing the same
control again.

- Nothing plays, captures or is armed, and no performance recording runs:
  the press opens the session at once.
- Otherwise the first press changes nothing and shows a warning notice on
  both screens, `Stop playback and open <name>?` with `Press again to
  open.`, for 6 s (the warning time the main screen uses). A second press
  of the same action inside that time opens the session. With no second
  press the notice goes and nothing has changed.
- The second press counts only when it comes at least 400 ms after the
  first, so one stomp that bounces does not confirm itself.
- Pressing the other direction while a confirmation is pending replaces it
  with that direction's session and restarts the 6 s.
- A running performance recording also makes the foot ask, with
  `Stop the recording and open <name>?`, because the Open ends it (D4).
  Touch does not ask in that case today; this plan leaves touch as it is.

The alternatives are no confirmation at all (the press always opens; the
outgoing rig is saved, so no audio is lost, and one accidental stomp stops
the sound in front of an audience), and always two presses (slower between
songs when everything is already stopped).

New loop by foot stays as #1229 decided: it acts on the first press with no
confirmation, and says which session it kept (§4.5: "work directly by
foot"). It therefore behaves differently from Open by foot while tracks
play. If the owner wants the two alike, New loop takes the same
press-again rule; say so with this answer.

### D3. What the screens and LEDs show while a session opens

Recommended:

- From the accepted press until the result, a neutral notice on both
  screens: `Opening <name>…`. The result replaces it.
- The result notice names the session: `<name> opened` in place of
  `Session loaded`, for touch and foot alike. From the stage a player
  cannot see the Library, so the name is the confirmation that the right
  session opened. The stage header shows the name too, as it does today.
- The interaction mode and the bank stay as they were, so a player stepping
  from Custom stays in Custom.
- No new LED pattern and no firmware or pedal-link change. The pressed
  switch lights while it is held, as every press does. The track LEDs
  follow the rig: they show the new session's tracks, stopped, once it is
  applied. Presses during the load are dropped as they are today.
- If the Library is open, the press returns to Tracks first, as every
  footswitch press does.

The alternative for the LEDs is to keep the pressed Custom switch in its
Active colour until the session has opened. It is left out until a load is
measured on the console (Device checks): if a typical session opens in
under about a second, the notice is enough.

### D4. A take or a performance recording in progress

Recommended: the foot follows the rules Open and New loop already have, and
adds none.

- A track take (recording, overdubbing or armed) is ended at its Record
  timing and saved with the outgoing session. If it has not ended after
  20 s, the action is refused with `The take is finishing. Try again when
  it has stopped.` and nothing has changed. Under D2 the foot has already
  asked before this happens.
- A performance recording is finished and saved before the session
  changes, as #1229's owner decision O2 says for New loop. The stage shows
  `Recording saved. Find it in Library > Audio.` and the completion sheet
  does not open over the new session (#1229 D6, built in Part 1 here).
- Save by foot ends nothing. A save during a take writes the settled
  tracks, as Ctrl/Cmd+S does; the take in progress is in the next save. A
  performance recording keeps running.

The alternative for the performance recording is to refuse Previous, Next
and New loop while one runs, so a recording of a whole set is never ended
by a session step; the player would stop the recording first. Keeping one
recording running across a session change is not possible in the capture
as built (it stamps one rig's chains and inputs at arm) and is out of
scope.

### D5. Save by foot on a rig with no session

Recommended: it takes the automatic name. `save()` already does this for
Ctrl/Cmd+S: the rig is saved as `New loop N`, that session becomes current,
and the notice says `Saved as New loop N`. A foot cannot type, and §6.2
makes naming optional. The player renames it later in the Library.

With an open session, Save writes back to it and shows `Session saved`.

The alternative is to refuse and ask the player to name the session on the
screen, which makes the action useless at the moment it is needed.

### D6. How refusals are reported

Recommended: each refusal is said once, in the words the same refusal has
on touch, and names the session when there is one.

| Case | What the player is told |
|---|---|
| Next on the last session, Previous on the first, or an empty group | `No next session in <folder>.` or `No previous session in <folder>.` (`Unfiled` for the root). A warning notice; nothing changes. |
| The target cannot be opened (sample rate, newer version, unconvertible, corrupt) | `Could not open <name>` with the reason the Library gives today. The open session stays. |
| The outgoing rig cannot be saved | `Could not save your current loop. Nothing was changed.` |
| The take did not end in time | `The take is finishing. Try again when it has stopped.` |
| Another operation holds a guard (a device change, a shutdown) | The guard table's sentence for it, as today. |
| Save failed | `Could not save your current loop. Nothing was changed.` |
| A press while a session is opening, the power dialog is up or audio is starting | Dropped with no notice, as every assigned press is today. `Opening <name>…` is on the screens during a load. |

`ControlCubit` hands the request over and adds no notice of its own, so one
cause gives one notice: the generic `<action> is unavailable right now.`
does not appear for these four actions.

A target that cannot be opened is not skipped. Next keeps naming it until
the player moves or repairs it in the Library. The alternative is to skip
it and open the one after, saying so; that hides a broken session in a set.

## How the request travels

`ControlCubit` does not depend on `SessionCubit` (a cubit never calls a
cubit). The four actions are `ControlCommand` members, with the keys the
design's catalogue uses:

| Member | Key | Group |
|---|---|---|
| `newLoop` | `command:new-loop` | sessions |
| `previousSession` | `session:previous` | sessions |
| `nextSession` | `session:next` | sessions |
| `saveSession` | `session:save` | sessions |

`_runCommand` for each of them emits a request on `ControlState` (a serial
number and the command, the `clearAllPulse` pattern) and reports the press
as accepted. `takeLocked` gates them like every assigned press. One
listener at the app level, in `lib/app/view/app.dart`, passes each new
request to a handler in `lib/app/foot_session_actions.dart`. The handler:

- for Save, calls `SessionCubit.save()`;
- for New loop, calls `SessionCubit.newLoop()` (#1229 Part 7);
- for Previous and Next, refreshes the catalogue
  (`SessionCubit.refreshSessions()`), finds the neighbour with a pure
  function over `SessionState.sessions` and `currentSessionId`
  (`lib/session/session_order.dart`), applies D2, and calls
  `SessionCubit.open(id)`, the method the Library's button calls.

The condition "an Open would interrupt" becomes one function that
`openWithConfirm` and the handler both use, so touch and foot cannot
disagree about it. Every rule about takes, saving and guards stays inside
`SessionCubit`.

## Parts

Each part is one PR on a branch `claude/foot-sessions-1910-p<K>`, and each
leaves every assigned action working.

### Part 1: New loop by foot (#1229 Part 7)

Built under #1229's decisions O2, D6 and D7. The PR says `Refs #1229` and
`Refs #1910`.

- `ControlCommand.newLoop`, its group, its catalogue label and foot caption
  in English and Spanish: `lib/control/binding/control_action.dart`,
  `lib/control/binding/control_action_labels.dart`,
  `lib/looper/view/foot_custom_view.dart`, `lib/l10n/arb/`.
- The request on `ControlState` and its emission:
  `lib/control/cubit/control_state.dart`,
  `lib/control/cubit/control_cubit.dart`.
- The app-level listener and the handler: `lib/app/view/app.dart`,
  `lib/app/foot_session_actions.dart`.
- `<name> stays in your Library.` for the foot's New loop only, and only
  when a session was saved: `lib/session/cubit/session_cubit.dart`,
  `lib/session/cubit/session_state.dart`,
  `lib/looper/view/tracks_commands.dart`.
- A performance recording finished by a session apply shows `Recording
  saved. Find it in Library > Audio.` and no completion sheet, for Open and
  New loop from touch or foot: the stop cause in
  `packages/performance_repository`, the recorder cubit's state, and
  `onPerformanceRecorderState` in `lib/looper/view/tracks_commands.dart`.

Acceptance:

- `command:new-loop` parses and prints back; the Sessions heading appears
  in the action picker with one row (`test/control/binding/control_action_test.dart`,
  `test/control/binding/binding_labels_test.dart`,
  `test/control/pedal_setup_page_test.dart`).
- A Custom press, an external switch and a MIDI control assigned New loop
  each emit one request per press, and none while `takeLocked` holds
  (`test/control/foot_custom_dispatch_test.dart`,
  `test/control/external_dispatch_test.dart`,
  `test/control/midi_devices_dispatch_test.dart`).
- One request calls `SessionCubit.newLoop` once; the kept-session notice
  shows for the foot's request and not for the Library's button, and not
  when nothing was saved (`test/app/foot_session_actions_test.dart`).
- A session apply that finishes a recording shows the saved notice and no
  sheet (`test/looper/view`, `test/performance`).
- Device: assign New loop to a Custom switch, record two tracks while a
  performance recording runs, press it. The stage reads `New loop N`, the
  old session opens from the Library with both tracks, and the recording
  is in Library > Audio.

### Part 2: Save session by foot

- `ControlCommand.saveSession`, label and caption; the handler calls
  `SessionCubit.save()`. Same files as Part 1 for the catalogue and the
  handler. No change in `SessionCubit`.

Acceptance:

- `session:save` parses and prints back and is listed under Sessions.
- With an open session, one press saves it and shows `Session saved`. With
  none, it saves as `New loop N`, makes that current and shows `Saved as
  New loop N` (`test/app/foot_session_actions_test.dart`, against a real
  `SessionCubit` over a temporary catalogue).
- A press during a track take saves and the take goes on; a press during a
  performance recording saves and the recording goes on.
- A failed save shows the save failure and no second notice.

### Part 3: Load previous and next session

- `ControlCommand.previousSession` and `nextSession`, labels and captions.
- The order: `lib/session/session_order.dart`, a pure function from the
  catalogue, the open session and a direction to a neighbour or to "none",
  under D1.
- The interruption condition as one function, used by `openWithConfirm`
  (`lib/library/view/library_preview_card.dart`) and the handler.
- The handler's confirmation under D2: the pending target, its 6 s timer
  and its notice (`lib/app/foot_session_actions.dart`,
  `lib/app/app_notices.dart`).
- `Opening <name>…`, `<name> opened`, `Could not open <name>` and the two
  end-of-group notices (`lib/looper/view/tracks_commands.dart`,
  `lib/l10n/arb/`).

Acceptance:

- Order (`test/session/session_order_test.dart`): name order ignoring case;
  numbers compared as numbers; only the open session's folder; Unfiled as
  its own group; no wrap at either end; no open session gives the first
  for Next and the last for Previous in Unfiled; an empty group gives none;
  an open session that is no longer in the catalogue gives none.
- With everything stopped, one press opens the neighbour through
  `SessionCubit.open` and the changed outgoing rig is saved first.
- While a track plays, the first press opens nothing and shows the
  question; a second press after 400 ms and inside 6 s opens; a second
  press before 400 ms does not; no second press leaves the rig as it was;
  the other direction replaces the pending target. The same with a
  performance recording running and nothing playing.
- A session change, opening the Library or the power dialog drops a
  pending confirmation.
- Each row of D6's table shows its notice once, and the generic assigned
  notice does not appear.
- The mode and bank after an Open by foot are the ones before it.
- Widget tests of the three notices on the stage at 1920x1080 and on the
  readout at 640x375, in both languages, with nothing clipped. The
  screenshot suites gain the question and `Opening <name>…`
  (`test/screenshots/notices_screenshots_test.dart`,
  `test/screenshots/readout_controls_screenshots_test.dart`).
- Device: a folder of three sessions named `01`, `02`, `03`; Next and
  Previous assigned to two Custom switches; step through the folder
  stopped and while playing; step with a take recording.

### Part 4: the design and the contract, and closing the issue

- The Penpot writeback below, and the snapshot PR in segno-design.
- `docs/handoff/segno-app/accepted-behavior.md`: §4.5 gains a row for
  session actions by foot, and §6.1 says how a foot confirms an
  interruption and what order the steps follow.
- Removes the Active threads row and says `Closes #1910`.

## Design writeback

Penpot, file **segno-ui**, through the `penpot` MCP server, one board per
call.

- Page `19 Sessions · New loop & recall`: three boards drawn from the
  screenshot suite, `09 / Foot / Open next / Confirm` (the stage with the
  question), `10 / Foot / Opening` and `11 / Foot / No next session`, and a
  `c/` note that records the order (D1), the press-again confirmation and
  its two times (D2), what shows during a load (D3), takes and recordings
  (D4), the automatic name on a foot Save (D5), the refusal table (D6),
  and the Boss `MEMORY INC / DEC` and `BANK MODE` references.
- Page `25 Main views and selected-track display`: the readout with the
  question in its notice band, and a note on the board.
- Page `08 Pedal setup & LEDs`, with a note on pages `24 External pedals ·
  Function assignments` and `26 MIDI controls and Learn`, which share the
  picker: the action picker's Sessions group with its four rows.
- Page `10 Performance · Tracks, Custom, FX & Mute`: the four foot
  captions on the Custom face, and a note that none is assigned by default
  unless #1908's map takes them.
- Page `20 Record performance & USB export`: #1229's W6, the saved notice
  in place of the completion sheet when a session apply finishes a
  recording.
- segno-design: `tool/penpot-snapshot`, commit `penpot/`, a PR linked to
  the app PR; `.github/segno-design.sha` moves to that commit if the
  `design` job needs it. `pedal-action-catalogue.js` already has the four
  keys and does not change.

## Device checks (on the console)

- How long an Open takes from the press to `<name> opened`, for an empty
  session, a four-track session and an eight-track session with layers.
  This decides the LED question in D3.
- The 400 ms and 6 s of D2 with a shoe on a footswitch: one firm stomp
  never confirms itself, and a deliberate second press is not missed.
- The question and `Opening <name>…` are readable on the 7" readout from
  standing height.

## Not in this plan

- A default Custom assignment for these actions. #1908 decides the map;
  a Hold suits them, since a Hold is harder to make by accident.
- A set list ordered by hand, and marking a session as not to be
  overwritten (D1).
- One performance recording across a session change (D4).
- Reopening the last session at start. With no open session the steps
  start from Unfiled (D1).
- Moving MIDI and external-pedal assignments into the session (#1206).
