---
title: "Sessions face: assigned sessions, tap to preview, hold to open"
type: feat
date: 2026-11-20
issue: 1921
---

# Sessions face: assigned sessions, tap to preview, hold to open

<!-- cspell:words Penpot writeback Unfiled -->

Tracking: [#1921](https://github.com/tomassasovsky/segno/issues/1921),
`autonomy:plan-gate`. It revises the Sessions face of
[#1910](https://github.com/tomassasovsky/segno/issues/1910)
([`2026-11-19-feat-foot-session-actions-plan.md`](2026-11-19-feat-foot-session-actions-plan.md)),
which is built and in review (#1911, #1912, #1913, #1915, #1916, #1919).
Nothing here is built. The owner answers R1 to R5 below before Part 1
starts.

## Owner direction, 2026-11-19

After the face was built, the owner asked for three changes:

1. A map of sessions to pedals: a session sits over the switch the player
   gave it.
2. A simple tap shows a preview above the switch.
3. A hold opens the session, with a progress animation on the switch's LED.

## What changes on the face

| Switch | As built (#1910) | After this plan |
|---|---|---|
| Track 1 to 4, tap | Opens the session above it | Shows that session's preview; opens nothing |
| Track 1 to 4, held | The same as a press | Opens the session; the LED fills while the hold is pending |
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
- **The LED fill.** Passing `clears:` to `_armGesture` sends `CLEAR_HOLD`
  (`0x13`: switch, progress 0 to 255) every 20 ms. The board fills that
  switch's LED from both ends toward the centre, and flashes it three times
  when the app sends 255 (`_meetClearFill`). It works on any switch. The
  colour is fixed in the firmware: red (`PILL_CLEAR_RED`,
  `firmware/console_board/console_board.ino`). Clear's Hold for New loop on
  this face already uses it.
- **The on-screen cue.** A drawn pedal with a pending Hold shows a progress
  bar timed against `ControlState.holdThreshold`.
- **The preview's data.** `SessionRepository.readPreview(id)` returns the
  populated tracks (length, bars, layers, muted, effect count), the tempo
  and whether a mixdown exists, without reading audio. `readPeaks(id,
  track)` returns a track's waveform, read off the UI isolate. The Library
  uses both (`LibraryCubit`, `lib/library/view/library_preview_card.dart`).
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
four cards. It shows:

- the name, the tempo and time signature, and the loop length in bars (or
  seconds without a tempo);
- one row per recorded track with its waveform, its number of layers and
  its effect count, and `Muted` where every lane is muted;
- when the session was last saved;
- what opening it would end, in the warning colour, as the card says today
  (`Stops playback`, `Ends the take`, `Ends the recording`).

The previewed session's card is outlined. The panel stays until another
tap, a page turn, or the face closes. The text shows first and the
waveforms when they have been read.

The alternative adds sound: the tap also plays the session's saved mix
(Listen). The mix goes to every enabled output, so on stage the audience
hears it, on top of whatever is playing. It cannot run during a performance
recording. If the owner wants it, it should be a separate gesture and not
the tap.

### R5. The colour of the fill

Recommended: the red fill that exists, with its three flashes when the Open
is accepted. It needs no firmware change. On this face red already means
"this hold replaces what is loaded": Clear's Hold fills red and starts a
new loop.

The alternative is a fill in another colour (for example the `selected`
colour of the Sessions LED map). The colour is fixed in the firmware, so it
needs a new link message that carries a colour, new board firmware flashed
on the console, and a linked PR in segno-hardware. It would be a separate
issue after this one.

## The face after this plan

- **Entering.** The face opens on the page that holds the open session, or
  on page 1 when the open session has no position. No session is previewed.
  The side says `Tap to preview · Hold to open`. When the open session has
  no position, the side also names it: `Open: <name>`.
- **A tap** on a switch with a session previews it. A tap on an empty
  position does nothing.
- **A hold** on a switch with a session starts the fill on the switch's LED
  and the progress bar on the drawn pedal. Releasing before the threshold
  is a tap. At the threshold the Open is asked for: the card says
  `Opening…`, the other switches do nothing until it settles, and the LED
  flashes when the session is open. Then the face closes, as today. A hold
  needs no tap first.
- **A failed Open** keeps the face up with the reason on the card, as
  today, and the LED does not flash.
- **The open session's switch.** A tap previews it. A hold does nothing and
  draws no fill.
- **Captions.** A switch with a session says `Open` with `Hold` under it,
  as Clear says `New loop` with `Hold`. An empty position's caption is
  dimmed.
- **Touch.** A tap on a card or on a drawn switch previews. A long press
  opens, with the same progress bar.
- **LEDs.** Unchanged apart from the fill: the switch under the open
  session is lit, the others are dark.
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
  `_armGesture`: `onTap` sets the previewed id, `onHold` asks for the Open,
  and `clears:` is true while the Open could still happen (the face is
  editable, the position holds a session, and it is not the open one).
  `_onSessionCatalogue` calls `_meetClearFill` when the Open it is waiting
  for settles as opened. `FootSessionsSelection` gains `previewId`, cleared
  by a page turn.
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
  and Hold, the fill, the flash on a settled Open. The open session's
  switch no longer closes the face.
- `lib/control/model/foot_sessions.dart`: `previewId`; the captions.
- `lib/session/cubit/session_preview_cubit.dart` and its state.
- `lib/looper/view/foot_sessions_view.dart`: the panel, the outlined card,
  the long press on a card, the side text.
- Strings in English and Spanish.
- Tests: the dispatch tests (a tap never opens; a hold opens once; a
  release before the threshold previews; a hold on the open session does
  nothing; no flash on a failed Open), the projection tests, a cubit test
  for `SessionPreviewCubit`, the view tests, and the screenshot scenes
  (previewing, holding, previewing an unreadable session).
- Penpot: page 19, the boards drawn for #1917 redrawn with the panel, plus
  a board for a pending Hold; a `c/` note with R4 and R5 as answered.

### Part 2: the map

- `packages/session_repository`: the positions file, read and written
  whole, and its tests (a missing file, an id with no bundle, a deleted
  session, a moved and a renamed session keep their position).
- `lib/session/cubit/`: the positions in `SessionState`, `assignToPedal`,
  `removeFromPedal`, and their tests.
- `lib/library/view/`: the `Pedal` row on the preview card, the assign
  sheet, the position on each row, and their tests.
- `lib/app/foot_session_catalogue.dart` and `lib/control/model/`: the
  positions in the hand-over and the projection by position; the folder
  code removed; Bank on contact; the empty state.
- `lib/control/cubit/control_foot_sessions.dart`: the entry page.
- Strings, the dispatch, projection, view and screenshot tests updated
  (the `foot_sessions_folders` scene is removed).
- Penpot: page 19, the Library card's `Pedal` row and the assign sheet;
  the `Folder` board removed; a `c/` note with R1 to R3 as answered.

### Part 3: the contract, and closing the issue

- `docs/handoff/segno-app/accepted-behavior.md`: the Sessions row of §4.5
  (tap, hold, the map), §6.1 (a hold is the confirmation), and the
  Library's section for the `Pedal` row.
- `docs/PROGRESS.md`: the status section and the Active threads row.
- Says `Closes #1921`.

## Device checks (on the console)

- A tap with a shoe never opens, and a hold is not tiring at the long-press
  setting in use.
- The red fill and the flash are visible on the track switches from
  standing height.
- How long the preview takes to appear after a tap, text and waveforms, for
  a four-track and an eight-track session.
- The panel is readable from standing height.

## Not in this plan

- Sound in the preview (R4), unless the owner asks for it.
- A fill in another colour (R5).
- Assigning from the face (R2).
- A map per folder (R1).
- The items #1910's plan lists under "Not in this plan".
