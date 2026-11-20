---
title: "Sessions face: assigned sessions, tap to preview, hold to open"
type: feat
date: 2026-11-20
issue: 1921
---

# Sessions face: assigned sessions, tap to preview, hold to open

<!-- cspell:words Penpot writeback Unfiled -->

> **The map is withdrawn (owner, 2026-11-20).** While Part 2 was being
> built the owner asked whether sessions need to be mapped at all, and
> chose a list: the face shows every saved session, four to a page, with
> Previous and Next page. R1 to R3 below are kept as the record of what was
> considered and are no longer the design. "Owner decisions on the list"
> has what replaced them, and Part 2 is that list.

Tracking: [#1921](https://github.com/tomassasovsky/segno/issues/1921),
`autonomy:plan-gate`. It revises the Sessions face of
[#1910](https://github.com/tomassasovsky/segno/issues/1910)
([`2026-11-19-feat-foot-session-actions-plan.md`](2026-11-19-feat-foot-session-actions-plan.md)),
which is built and in review (#1911, #1912, #1913, #1915, #1916, #1919).
Nothing here is built. The owner answered R1 to R5 on 2026-11-20, so
Part 1 can start.

## Owner direction, 2026-11-19

After the face was built, the owner asked for three changes:

1. A map of sessions to pedals: a session sits over the switch the player
   gave it.
2. A simple tap shows a preview above the switch.
3. A hold opens the session, with a progress animation on the switch's LED.

## Owner corrections, 2026-11-20

The owner read the first version of this plan and tried a sketch of it.

- **The fill runs left to right,** not from both ends to the centre. This
  settles the direction and changes how the fill is built (R5): the board
  already has a left-to-right fill, so no new firmware is needed.
- **A session's tracks may be empty.** What matters in a session can be
  its setup: the loop mode, the tempo, the effects. The preview and the
  cards must show the setup, and must not present a session with no
  recordings as empty (R4).

## Owner decisions, 2026-11-20

All five decisions were answered as recommended. The sections under
"Decisions for the owner" keep the reasoning and the alternatives that were
not chosen.

1. **R1, the map.** One map for the whole Library. A position is a page
   and a switch. Bank turns the pages, and a held Bank does nothing.
2. **R2, assigning.** In the Library, on the session's preview card, with a
   sheet that draws the pages and their positions. Not from the face.
3. **R3, automatic assignment.** None. The face shows only the sessions the
   player assigned.
4. **R4, the preview.** Silent. Setup first (looper mode, tempo and time
   signature, loop length, count-in and click when on), then the effects by
   place, then the recordings or `No recordings`, then what opening would
   end. The cards show the mode and the tempo, then the recordings.
5. **R5, the fill.** Left to right, in the `selected` colour of the
   Sessions LED map, with no flash.

## Owner decisions on the list, 2026-11-20

Part 2 was built as the map (R1 to R3) in a working tree and not
committed. The owner then asked: "Do we need to map them? Can't we just
have the list by default? What about Next and Previous page and show all
sessions. We could have a reorder page if we wanted."

The list was chosen over the map for three reasons:

- It needs no setup. With the map a console's face starts empty and sends
  the player to the Library.
- It has one thing to learn, an order. The map adds positions, an assign
  sheet, and questions about replacing and removing.
- A reorder page gives the same result where it matters: the player puts
  the sessions of a set first.

What the list gives up: a session can change switch. Deleting one moves
every session after it up by one, and adding one does the same while the
order is by name.

Decided:

1. **One list.** Every saved session, whatever folder it is in, four to a
   page, in name order (D1 of #1910 stands again). An order set by hand is
   a later part, if it is wanted: then that order is kept and new sessions
   go at the end.
2. **Previous and Next page.** Clear shows the previous page and Bank the
   next, both on contact, both wrapping. They sit side by side on the rear
   row. Neither has a Hold.
3. **New loop moves to a Hold on Undo.** A press of Undo saves and a Hold
   starts a new loop, with the clearing Hold's fill. It does not stay on
   the Previous page switch: a foot that rests on a page switch must not
   start a new loop in the middle of a set. Undo's press now acts on its
   release, as every switch with a Hold does.
4. **A session can be hidden from the pedal.** The owner asked for "a
   setting to disable showing a session in there", "under a 3 dot menu" in
   the Library's list. Each row has a three-dot button; its sheet has `Hide
   from pedal`, or `Show on pedal` for a hidden session. A hidden session
   is on no switch, stays in the Library and opens from it as before. Its
   row says `Hidden from pedal`.
5. **The open session, when hidden,** is named in the readout (`Open:
   <name>`), since no switch can be lit for it.

Still open: the owner asked whether "New loop" is the right word. The
answer given was to rename the command to "New session", because the app
calls the saved thing a session everywhere else and uses "loop" for what
plays inside one. It is not decided, and it is a change of its own.

## What changes on the face

This table and "The face after this plan" below were written for the map.
Read them with "Owner decisions on the list": a press and a hold are as
written, and the rows about Bank, the map and assigning are replaced.

| Switch | As built (#1910) | After this plan |
|---|---|---|
| Track 1 to 4, tap | Opens the session above it | Shows that session's preview; opens nothing |
| Track 1 to 4, held | The same as a press | Opens the session; the LED fills left to right while the hold is pending |
| Bank | Next four sessions in the folder | Next page of the map |
| Bank, held | Next folder | Nothing (R1) |
| Undo, Clear, Rec/Play, Stop, MODE | Save, New loop on a Hold, transport, Exit | Unchanged |

Which sessions the face shows also changes. As built, it shows the open
session's folder in name order. After this plan it shows the sessions the
player assigned, each over its own switch on its own page.

These decisions of #1910 are replaced:

- **D1 (order).** Name order is replaced by the map. The alternative that
  plan kept as "Part 4, not built" (an order set by hand) is covered by the
  map and is dropped.
- **D4 (after each action), in part.** A tap keeps the face up. An Open
  still closes it. A press on the open session's switch no longer closes
  the face: a tap previews it, and a hold on it does nothing.
- **D5 (folders).** The face no longer shows folders (R1).

D2 (Save and New loop), D3 (no second press; the card says what an Open
ends) and D6 (Save with no session, LEDs, the readout) stay.

## What the code already has

- **Hold and tap on one switch.** `_armGesture`
  (`lib/control/cubit/control_cubit.dart`) arms a gesture with `onTap` and
  `onHold`. With a Hold armed, the tap runs on release. The threshold is
  the pedal's long-press setting (`loadPedalLongPressMs`, 800 ms by
  default). Bank on the face already works this way when there are folders.
- **Two LED fills on the board.**
  - The clearing fill (#1534). Passing `clears:` to `_armGesture` sends
    `CLEAR_HOLD` (`0x13`: switch, progress) every 20 ms. The board fills
    that switch's eight LEDs red from both ends toward the centre and
    flashes them when the app sends 255. Clear's Hold for New loop on this
    face uses it. Its colour and direction are fixed in the firmware.
  - The left-to-right fill (#1077). The `STATE` frame names one switch and
    a progress (`queued_button`, `queued_progress`, bytes 51 and 52 of the
    frame; `queuedButton` and `queuedProgress` on `PedalStateFrame`). The
    board fills that switch's LEDs left to right, in the colour the frame
    gives the switch, and lights the whole switch when a later frame no
    longer names it. Today only a waiting Song or Band section uses it:
    green for a section waiting to play, red for one waiting to record. An
    invariant (`song-queue-mirrors-engine`, `lib/control/invariants.dart`)
    says the field mirrors the engine's queue.
- **The on-screen cue.** A drawn pedal with a pending Hold shows a bar that
  fills from the left over `ControlState.holdThreshold`
  (`lib/looper/view/performance_pedal.dart`).
- **The preview's data.** `SessionRepository.readPreview(id)` returns the
  populated tracks (length, bars, layers, muted, effect count), the tempo
  and whether a mixdown exists, without reading audio. `readPeaks(id,
  track)` returns a track's waveform, read off the UI isolate. The Library
  uses both (`LibraryCubit`, `lib/library/view/library_preview_card.dart`).
  It carries no setup beyond the tempo and a count of effects.
- **The setup is in the manifest.** A saved `Session`
  (`packages/session_repository/lib/src/models/session.dart`) holds the
  looper mode (Multi, Sync, Song, Band, Free), the tempo and time
  signature, the loop length in bars, the record timing, the count-in, the
  click, and the effect chains of each input, lane, track, the All tracks
  stage and each output. `decodeFxChain` (`packages/looper_repository`)
  turns a stored chain into its entries.
- **A card today** shows the name, the count of recorded tracks and the
  tempo. A session with no recordings reads `No tracks`.
- **Listen.** `SessionRepository.startAudition(id)` plays the session's
  `mixdown.wav` through the engine's audition voice on every enabled
  output. The engine refuses it while a performance recording runs.
- **A stable identity.** A session's id is its bundle directory's name. A
  rename and a move to another folder keep it. A copy and a restore from
  USB get a new one.
- **No stored position.** Nothing records where a session sits on the
  pedal. `listSessions` reads directories only, so a file beside the
  bundles does not disturb it.

## Decisions for the owner

### R1. One map, or one per folder

Recommended: one map for the whole Library. A position is a page and a
switch (`Page 2 · Switch 3`). Bank shows the next page that has a session
and wraps after the last. A held Bank does nothing, so Bank turns the page
on contact again. Folders stay a way to organize the Library and have no
effect on the face.

The alternative is one map per folder, with a held Bank going to the next
folder as today. It suits a player who keeps one folder per show. It costs
a second level to learn on the face, and a session's position would change
when it is moved to another folder.

### R2. Where a session is assigned

Recommended: in the Library, on the selected session's preview card. A
`Pedal` row shows `Not on the pedal` or `Page 1 · Switch 3`, with `Assign…`
and `Remove`. `Assign…` opens a sheet that draws the pages, each with its
four positions and the name of the session in each one. A tap on a position
assigns the session to it.

- A tap on a position that holds another session asks `Replace <name>?`.
  The replaced session stays in the Library and leaves the pedal.
- Assigning a session that already has a position moves it.
- The sheet always shows one empty page after the last used one, so a new
  page starts by assigning to it.
- The Library's rows show the position beside the name.

The alternative adds a second place: a tap on an `Empty` card of the face
opens a list of sessions to put there. It is not in this plan; the Library
already has the list, the search and the folders.

### R3. Whether anything is assigned automatically

Recommended: nothing. A session is on the face only when the player
assigned it. With no assignment the four cards say `Empty`, and the side
says `No sessions on the pedal yet. Assign them in Library.`

The alternative gives every session the first free position the first time
it is saved. The face then works with no setup, and it fills with sessions
nobody chose (`New loop 7`), which the player must remove by hand.

### R4. What the preview shows, and whether it sounds

Recommended: a silent preview, on the main screen, in a panel above the
four cards. It shows the setup first and the recordings second, because a
session can be a prepared setup with nothing recorded:

- the name, and when the session was last saved;
- the setup: the looper mode, the tempo and time signature (or `No
  tempo`), the loop length in bars when one is set, and the count-in and
  the click when they are on;
- the effects, by place, named as the FX face names them: `Inputs`,
  `Tracks`, `All tracks`, `Outputs`. A place with no effects is left out,
  and a long list ends in `+N`;
- the recordings: one row per recorded track with its waveform and its
  number of layers, and `Muted` where every lane is muted. A session with
  none says `No recordings` in one line and gives the space to the setup;
- what opening it would end, in the warning colour, as the card says today
  (`Stops playback`, `Ends the take`, `Ends the recording`).

The cards change with it. A card shows the name, then the looper mode and
the tempo (`Song · 84 BPM`), then the recordings (`3 tracks`, or `No
recordings` in place of `No tracks`).

The previewed session's card is outlined. The panel stays until another
tap, a page turn, or the face closes. The text shows first and the
waveforms when they have been read.

Which settings the panel lists is the owner's call. The list above is the
recommendation; the manifest also holds the record timing, the quantize
division and the input trims, which are left out to keep the panel
readable from standing height.

The alternative adds sound: the tap also plays the session's saved mix
(Listen). The mix goes to every enabled output, so on stage the audience
hears it, on top of whatever is playing. It cannot run during a performance
recording, and a session with no recordings has no mix to play. If the
owner wants it, it should be a separate gesture and not the tap.

### R5. The colour of the fill

The direction is settled: left to right (owner, 2026-11-20). It is built on
the board's left-to-right fill, which takes its colour from the frame, so
the colour is the app's choice and needs no firmware change.

Recommended: the `selected` colour of the Sessions LED map (white by
default), which is the colour of the switch under the open session. The
fill then ends as a fully lit switch in the colour that means "this
session is open".

The alternative is red. On the board a red left-to-right fill already
means "a section is waiting to record", and a green one "a section is
waiting to play", so both would say something else here.

There is no flash at the end. The flash belongs to the clearing fill. The
board lights the whole switch when the hold fires, and the card says
`Opening…`.

## The face after this plan

- **Entering.** The face opens on the page that holds the open session, or
  on page 1 when the open session has no position. No session is shown.
  The readout says `Press a switch to see its session. Hold it to open.`
  When the open session has no position, the readout also names it:
  `Open: <name>`.
- **A press** on a switch with a session shows it in the readout at once.
  A press on an empty position does nothing.
- **A hold** on that switch fills its LEDs left to right, and the LED bar
  of the drawn switch with them. Releasing before the threshold opens
  nothing: the LEDs go dark and the session stays shown. At the threshold
  the whole switch lights and the Open is asked for: the readout and the
  switch's caption say `Opening…` and the other switches do nothing until
  it settles. Then the face closes, as today.
- **A failed Open** keeps the face up with `Could not open` under the
  switch, as today, and the switch goes dark again.
- **The open session's switch.** A press shows it. A hold does nothing and
  draws no fill.
- **Captions.** A switch with a session is named for it, with its looper
  mode and tempo under the name and `Hold · Open` under that. An empty
  position says `Empty`, dimmed.
- **Touch.** The drawn switches take contacts as on every face: a press
  shows the session and a hold opens it.
- **LEDs.** Unchanged apart from the fill: the switch under the open
  session is lit, the others are dark. Clear's Hold for New loop keeps the
  red fill from both ends: it is the clearing Hold.
- **A waiting Song or Band section.** The frame has one left-to-right
  fill. On this face the track switches stand for sessions, so the face
  does not draw a waiting section on them, and the field is free for the
  hold.
- **The 7" readout.** Unchanged: `Sessions` and the page.
- **While a take is locked** the switches do nothing, as today.

A session that is deleted leaves its position empty. A copy and a session
restored from USB have no position.

## How it is built

- **The map** belongs to the session layer. `SessionRepository` reads and
  writes one file beside the bundles in the sessions root, a list of
  positions holding session ids. An id with no bundle is dropped when the
  file is read. `SessionCubit` keeps the positions in its state and has
  `assignToPedal(id, position)` and `removeFromPedal(id)`, each refreshing
  the catalogue as its other mutations do.
- **Control still never reads the session layer.** The hand-over that
  exists (`footSessionCatalogueOf`, `ControlCubit.setSessionCatalogue`)
  gains the positions. `projectFootSessions` places sessions by position.
  The folder code of Part 2b is removed: `folder` on
  `FootSessionsSelection`, `footSessionFolders`, `footSessionsStartFolder`,
  `hasOtherFolders`, `nextFolder`, and `compareSessionNames` with
  `orderedSessions`.
- **The gesture.** `_onSessionsPress` arms a track switch with
  `_armGesture`: `onTap` sets the previewed id and `onHold` asks for the
  Open. `FootSessionsSelection` gains `previewId`, cleared by a page turn.
  A switch whose hold could not open anything (an empty position, the open
  session, a locked take) arms no Hold, so its tap acts on contact.
- **The fill.** It does not use `clears:` or `CLEAR_HOLD`. While a track
  switch's hold is pending, the Sessions frame names that switch in
  `queuedButton`, gives it the fill's colour, and sets `queuedProgress`
  from the time held over the threshold. A ticker pushes a frame at a
  fixed interval until the gesture settles; the interval is chosen on the
  console (a `STATE` frame is about 57 bytes, 5 ms at 115200 baud). When
  the hold fires, the next frame names no switch and keeps the colour, so
  the board lights the whole switch; it goes dark when the Open settles or
  fails. `song-queue-mirrors-engine` is narrowed to the modes that draw
  sections, and a new invariant says that in Sessions the field is a
  pending hold's or empty.
- **The setup in the preview.** `SessionSummary` gains the looper mode,
  read leniently like the tempo, for the cards. `SessionPreview` gains the
  loop length, the count-in, the click and the stored chains grouped by
  place. The repository still does not look inside a chain;
  `SessionPreviewCubit` names the effects with `decodeFxChain`.
- **The preview's data** is not Control's. A `SessionPreviewCubit` in
  `lib/session/cubit/`, over `SessionRepository`, loads `readPreview` and
  the peaks for one id and drops a result a later request superseded, as
  `LibraryCubit` does. The face's view asks it whenever
  `ControlState.footSessions.previewId` changes. The Library keeps its own
  loading; moving it onto this cubit is a possible follow-up and is not in
  this plan.
- **The panel** is a widget class in `lib/looper/view/`. A feature never
  imports another feature, so it does not use the Library's row widgets; it
  shares the waveform painter if that is already outside the Library, and
  otherwise the painter moves to a shared place.

## Parts

Each part is one PR on a branch `claude/sessions-map-1921-p<K>`, stacked on
#1910's last branch, and leaves a working product.

### Part 1: tap to preview, hold to open

On the face as built (name order, folders).

- `lib/control/cubit/control_foot_sessions.dart`: the track switches' tap
  and Hold, and the ticker of the fill. The open session's switch no
  longer closes the face.
- `lib/control/model/foot_sessions.dart`: `previewId`, the pending hold,
  the captions.
- `lib/control/control_projection.dart`, `lib/control/binding/` and
  `lib/control/invariants.dart`: the fill in the Sessions frame, no
  waiting section on the face, and the two invariants.
- `packages/session_repository`: the looper mode on `SessionSummary`, and
  the setup and the chains by place on `SessionPreview`, with their tests.
- `lib/session/cubit/session_preview_cubit.dart` and its state.
- `lib/looper/view/foot_sessions_view.dart`: the panel, the outlined card,
  the cards' mode and `No recordings` lines, the long press on a card, the
  side text.
- Strings in English and Spanish.
- Tests: the dispatch tests (a tap never opens; a hold opens once; a
  release before the threshold previews; a hold on the open session does
  nothing), the frame's fill at the start, the middle and the end of a
  hold and after a release, the projection tests, a cubit test for
  `SessionPreviewCubit`, the view tests, and the screenshot scenes
  (previewing a session with recordings, one with a setup only, an
  unreadable one, and a pending hold).
- No firmware change, so `firmware/test/run_tests.sh` runs only if
  `packages/pedal_repository` is touched.
- Penpot: page 19, the boards drawn for #1917 redrawn with the panel, plus
  a board for a pending Hold; a `c/` note with R4 and R5 as answered.

As built, after the owner's review of the face on 2026-11-20:

- **The owner rejected the first build's look** (bordered cards over the
  switches and a boxed preview panel) and chose, from ten rendered
  layouts, a labelled list drawn the way the Mixer and Fade faces draw
  their readouts. This replaces R4's list of what the preview shows.
- **The face has no cards.** Each track switch is named for its session in
  the caption under it: the name, then the looper mode and tempo (or `Open
  now`, `Opening…`, `Could not open`), then `Hold · Open`.
- **One unboxed readout above the track switches,** seven evenly spaced
  lines. Its first line's capitals sit on the top of the Clear and Bank
  pedals' faces, its last line sits on the baseline of their captions,
  and its left and right edges are the first and last track switches'
  faces.
  - With no session shown: the folder, the page, and `Press a switch to
    see its session. Hold it to open.` While something plays or records,
    the line above that says what an Open would end, so it is on screen
    before any press.
  - With one shown: its name, then `Loop mode`, `Tempo`, `Loop length`
    (left out when none is set), `Tracks` (a strip of eight segments and
    how many are recorded) and `Effects` (names in signal order, four and
    then `+N`, or `None`). The last line says what opening it would end,
    or `Opening…`, `Open now`, `Could not open`.
  - Not shown: the saved date, the count-in, the click, each track's
    layers and waveform, and which place an effect is on.
- **A press shows the session at once,** not on release, so a hold always
  fills under the name of the session it opens. A release before the
  threshold opens nothing and leaves the session shown.
- **The hold's fill on the screen is the drawn switch's LED bar,** filling
  from the left (`PerformancePedal.holdFillsLed`), in place of the bar
  under the face. It is the same bar in the same place as on the pedal.
- **The fill on the pedal** goes out every 30 ms while the hold is pending
  (`ControlCubit._openFillInterval`). `projectFrame` takes it as
  `openFill`. A held switch over a session reads `selected`, not
  `pressed`, so nothing changes colour between the fill and the Open.
- **One hold to open at a time.** A second track switch going down while
  one is pending cancels both. A hold opens only if its switch still
  stands for the same session; when it no longer does (the page turned,
  the session gone, takes locked) the hold and its fill end at once.
- Nothing had to change to keep a waiting Song section off the face:
  `showsSectionQueue` already shows one only in Record mode and in Band's
  Mute mode. `song-queue-mirrors-engine` leaves the Sessions face to the
  new invariant `sessions-fill-is-a-held-switch`.
- `SessionPreview` carries the looper mode, the loop length and the stored
  chains by place. It does not carry the count-in or the click, and the
  preview reads no audio.
- The Penpot writeback is in tomassasovsky/segno-design#25 (#1917): page
  19 draws the face in nine boards, `09 / Foot / Sessions` to
  `17 / Foot / Sessions / Setup only`, with two `c/` notes (the owner's
  decisions, and the face as built). Pages 08, 10, 20, 24, 25 and 26 have
  `c/` notes for the picker, the LED map and the fill, the Custom
  captions, the `Recording saved` notice and the readout's footer.
  `.github/segno-design.sha` has not moved: the `design` job passes
  against the commit it names.

### Part 2: one list, Previous and Next page, and hiding a session

Built as "Owner decisions on the list" says.

- `lib/control/model/foot_sessions.dart`: one list of every session the
  player did not hide (`footSessionsListed`), in name order. The folder
  code is removed: `folder` on the entry and on the selection, `inFolder`,
  `footSessionFolders`, `footSessionsStartFolder`, `hasOtherFolders` and
  `nextFolder`. Clear's role is `previousPage`; `newLoop` is no longer a
  role, since it is Undo's Hold. The projection carries the open session
  (`open`), listed or not.
- `lib/control/cubit/control_foot_sessions.dart`: Clear and Bank turn the
  page on contact and wrap (`_turnSessionsPage`). Undo arms a Hold: its
  tap saves on release, and its Hold starts a new loop with the clearing
  fill.
- `packages/session_repository`: `sessions-face.json` beside the bundles
  holds the ids kept off the face (`readHiddenFromFace`,
  `writeHiddenFromFace`). An id with no bundle is left out when it is
  read, and a file that does not read hides nothing.
- `lib/session/cubit/`: `hiddenFromFace` in `SessionState`, re-read
  wherever the catalog is, and `setShownOnFace(id, shown:)`.
- `lib/app/foot_session_catalogue.dart`: the hand-over marks each entry
  `onFace`. A hidden session is still handed over, so the face can name
  the open one.
- `lib/library/view/`: the three-dot button on each row, its sheet
  (`showLibraryRowOptions`), and `Hidden from pedal` on the row.
- `lib/looper/view/foot_sessions_view.dart`: Clear is `Previous page`,
  Undo is `Save` with `Hold · New loop` under it, and the readout with no
  session shown says the page, then how many sessions there are and the
  open session when it is hidden.
- The app's own text says "pedal", never "face": `Hide from pedal`.
- Tests and screenshot scenes updated: the `foot_sessions_folders` scene
  is replaced by `foot_sessions_hidden`, and the Library has
  `library_row_options`.
- Not built: the map, its file, the assign sheet and the `Pedal` row.
- The Penpot writeback is in tomassasovsky/segno-design#26: page 19's
  boards 09 to 17 with the new captions and readout, board 14 redrawn as
  the open session hidden from the pedal, the three-dot button on the
  Library rows of boards 01 and 03, and both `c/` notes. The row's sheet
  is the options sheet Manage uses, which the file does not draw.
- Review: one round. Fixed: Undo's Save and New loop are asked again when
  the gesture settles, so neither lands while an Open is in flight; a face
  whose sessions are all hidden says so and where to show them; the
  hidden ids are checked in one pass over the bundles.

### Part 3: an order set by hand (not started, if it is wanted)

- A reorder page in the Library. The order is stored beside the hidden
  ids in `sessions-face.json`; a session with no place in it goes at the
  end.

### Part 4: the contract, and closing the issue

- `docs/handoff/segno-app/accepted-behavior.md`: the Sessions row of §4.5
  (a press, a hold, the list and its pages, New loop on Undo's Hold), §6.1
  (a hold is the confirmation), and the Library's section for the row
  options.
- `docs/PROGRESS.md`: the status section and the Active threads row.
- Says `Closes #1921`.

## Device checks (on the console)

- A tap with a shoe never opens, and a hold is not tiring at the long-press
  setting in use.
- The left-to-right fill is smooth at the chosen frame interval and is
  visible on the track switches from standing height, and the switch
  lights whole when the hold fires.
- A hold on the face while a Song section waits: the fill is the hold's.
- How long the preview takes to appear after a tap, text and waveforms, for
  a four-track and an eight-track session.
- The panel is readable from standing height, for a session with eight
  recorded tracks and for one with a setup and no recordings.

## Not in this plan

- Sound in the preview (R4), unless the owner asks for it.
- A new link message or new board firmware. The fill uses what the board
  has.
- Assigning from the face (R2).
- A map per folder (R1).
- The items #1910's plan lists under "Not in this plan".
