---
title: "Song and Band: one section at a time"
type: fix
date: 2026-10-13
issue: 1323
---

# Song and Band: one section at a time

Tracking: [#1323](https://github.com/tomassasovsky/segno/issues/1323).
Branch `claude/song-one-section-1323`, cut from the integration trunk
(`claude/segno-integration`, 2d3b15298).

## Problem

Song on build 165 behaves like Free with a Play queue. The engine's Song
paths are Free's (`engine_process.c`, `engine_commands.c`), so recording a
new or stopped section while another plays starts at once and two sections
sound together. #1317 queued only Play, and only from Mute mode or a muted
section; in Record mode an unmuted stopped section punches in at once
(`control_cubit.dart` `_recAdvance`). Band, where the app never calls the
section toggle, behaves like Sync. The July spec read the manual's "played
back independently" as "simultaneously" (`2026-07-22-song-mode-spec.md` §2
Q3), and the 2026-09-24 pill plan built on that reading.

## The Looper X rules (normative)

From the vendor
[FAQ](https://support.headrushfx.com/en/support/solutions/articles/69000852044-sheeran-looper-x-frequently-asked-questions)
and the User Guide v1.0.0 (§3.1, §4.2):

1. Song: only one looper track records, overdubs or plays at a time.
2. A stopped track set to play or record/overdub while another plays starts
   when the playing track reaches its end and stops.
3. Overdubbing the playing track starts immediately.
4. A waiting track's LED flashes, green for play and red for record/overdub.
5. Band: the primary plus one other track, with the same waiting rules.
6. STOP in Song stops a section; in Band a section or the primary.
7. Track pedals select and control tracks and sections; Mute mode (MODE
   pedal) makes the track pedals mute.

## Behaviour

### Engine (Song)

- One waiting request at a time: a **Play** (a stopped section with a take),
  or a **Record** (an empty section: a new take; a stopped section with a
  take: an overdub from its beginning). A newer request replaces it; the
  same request again cancels it.
- With nothing sounding, a request acts at once, alone (#1317's kept rule:
  a start from a stopped rig starts only that section).
- With a section sounding (the source), the request waits for the source's
  next lap edge as its head reads it. At that sample the source stops and
  the target starts from its beginning: playing, recording its first take,
  or playing with an overdub pass.
- Overdub (Record) on the sounding section is immediate, as in every mode.
- Stop on the source or the target, Clear, Undo, a mode switch, configure
  and engine stop drop the request; a capture on any section other than the
  source drops it too.

### Engine (Band)

- A section is a non-primary track. Requests on the primary keep Sync's
  rules. With no other section sounding, a section starts as it does today.
- With a section sounding, a request on another section waits for that
  section's lap end and lands on the primary's next loop top at or after it.
  The source stops there and the target starts on the shared grid.

### Control

- **Record mode, Song and Band.** A track press selects the track and, on a
  stopped section with a take that is not sounding (and not Band's primary),
  asks it to play: at once with nothing sounding, else it waits. A press on
  the waiting section cancels its request. A press on an empty, sounding or
  capturing section only selects, except the existing capture hand-off
  (finish the capture, then Record on the pressed track, which now waits).
  Rec/Play keeps its meaning on the cursor: Record on a stopped or empty
  section is a Record request (it waits while another section sounds), and
  Rec/Play on a section waiting to record cancels it.
- **Mute mode, Song.** A track press toggles that section's mute and does
  nothing else. Rec/Play (start one section from a stopped rig) and Stop
  (stop the sounding section and the waiting one) keep #1317's Song rules.
- Kept from #1317: Play All in Song starts the last played section, a muted
  one counting as unavailable.

### Waiting cue

- Stage: the existing queued cue for both kinds: Play at the loop start, or
  Record / Overdub at the loop start.
- Pedal, Record mode only: the waiting section's pill fills left to right in
  the Record map's playing colour for a waiting Play and its recording colour
  for a waiting Record, on the cursor too (owner decision 2026-10-13).
- Board: while queued, every lit pixel of the pill has the same level, the
  mean of the diffused curve, so the full pill carries the same light as the
  section it becomes; the leading pixel fills partially so the fill moves
  smoothly. When a pill leaves the queue and is still lit, it blends from its
  last fill to the diffused curve over 300 ms. The board keeps no Song or
  bank logic: it reacts to the queued button the app sends. The wire does
  not change (protocol stays 10); firmware becomes 1.15.

## Decisions where the FAQ is silent

Taken under the repo's standing rules (keep audio running, no silent
behaviour changes, record every decision). Each goes into the PR body and on
#1323.

1. **The source may be capturing.** A request can wait on a section that
   overdubs or records its first take. A first take has no end yet, so its
   wait shows no progress until the take closes; an overdubbing source's
   pass ends on its lap edge when the handoff stops it. Without this, the
   capture hand-off (track press while recording) would either drop the
   press or make two sections sound.
2. **An overdub on the source keeps the waiting request.** The handoff ends
   the pass on a whole lap.
3. **Play and Record on the same target.** Play on the waiting target
   cancels its request, whatever kind it is. Record on a section waiting to
   record cancels it; Record on a section waiting to play turns the request
   into a Record (a newer request replaces).
4. **Band starts on the grid, without a rewind.** The target starts in phase
   with the primary at its loop top, as Band and Sync start any stopped
   track today, so the exported performance stems (which replay Band starts
   in phase) stay correct. A section longer than the primary therefore
   resumes the segment the grid is on. Song still rewinds its section.
5. **Song Mute mode LEDs** read green for each section with a take that is
   not muted, so a mute press on a stopped section is visible; the pedal
   does not show the waiting section in Mute mode.
6. **Band's Mute mode** keeps Multi's rules: the owner's Mute-mode change
   names Song, and a "join" press there now waits like any other request.
7. **`le_engine_toggle_section`** (Band trigger-2 transport) is not called
   by the app and could start several sections. It is left unchanged here;
   #1324 tracks removing it.
8. **The handoff is the Record's boundary.** A waiting Record starts at the
   handoff even with Sound start or quantize on; neither applies to it.
9. **Rec/Play on a muted stopped section** keeps the existing meaning in
   every mode (unmute and bring it back), so in Song and Band it is a
   waiting Play, not a Record.
10. **Undo and redo keep one section.** A redo from empty, or the undo of a
    Clear, that would bring a section back playing while another section
    sounds brings it back stopped.
11. **Band from a stopped rig.** A start resumes the primary, not the other
    sections (the unpark rule now skips Band sections). Play All and
    Mute-mode Rec/Play start every track that is not a section plus one
    section: the one sounding, else the last played, else the first
    unmuted, else the first. The engine tracks the last played section in
    Band as well.
12. **A Band request whose section ends on a held rig is dropped.** When
    the sounding section stops on its own lap end (Once) and nothing else
    keeps the clock running, there is no primary top to land on.

## Implementation

1. Engine (`packages/segno_engine/src/core`):
   - `engine_private.h`, `engine_core.h`: the request gains a kind
     (`song_record`) and an edge latch for Band; `le_song_cancel` also
     clears a waiting Record arm. The published word carries the kind
     (bit 7 of the low byte); `le_snapshot.song_queue_record` is a new
     trailing field.
   - `engine_commands.c` `le_record_impl`: in Song, and in Band for a
     non-primary section, an empty or stopped target with another section
     sounding becomes a deferred arm with trigger 3 (prepared like a
     quantized arm); a second Record on it disarms.
   - `engine_process.c`: LE_CMD_ARM trigger 3 registers the Record request;
     LE_CMD_PLAY routes Band through the section handler; the validity check
     covers both modes and the capturing source; the Song commit starts a
     Record target; the Band commit runs on the primary's wrap after the
     source's lap edge; progress covers Band's wait.
2. Dart model: `EngineSnapshot.songQueueRecord`, `TransportState`,
   `LooperState.songWaitingSection` for Song and Band, `ArmTrigger.handoff`
   (code 3) so the stage's queued cue names the waiting Record.
3. Control: `control_cubit.dart` (Record-mode track press, `_recAdvance`,
   Song Mute mode), `control_projection.dart` (Record-mode only, play or
   record colour), `invariants.dart`.
4. Firmware `console_board.ino`: uniform fill and the settle blend; README.
5. Docs: correct the July spec §2 Q3 and the 2026-09-24 pill plan.

## Validation

- Native: Song Record waits (empty and stopped targets) with an exact-sample
  start, Play/Record replace and cancel, overdub on the source keeps the
  request, a recording source, Band handoff on the primary top, Band primary
  unaffected, and the #1317 tests updated where the rule changed. Plain,
  telemetry-off and AddressSanitizer builds.
- Firmware: uniform fill at every progress step, held against time; the
  300 ms blend after the queue ends; dark when unlit, on goodbye and a lost
  link.
- Dart: snapshot, repository, projection (colours, Record mode only),
  invariants, cubit gestures for Song and Band.

## Success Criteria

```success-criteria
GOAL: Song plays, records and overdubs one section at a time and Band keeps the primary plus one section, with every stopped-section request waiting for the sounding section's end, driven from Record mode, and the pedal pill filling uniformly while it waits.

SUCCESS CRITERIA:
- In Song, Record on an empty or stopped section while another section plays leaves the playing section alone until its lap edge, then the target records (or overdubs from its top) and the source stops on the same sample | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- In Band, a request on a second section while a section plays starts it on the primary's top after the playing section's end, with the primary unaffected | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A Record-mode track press on a stopped Song section starts or queues it, a press on the waiting section cancels it, and a Mute-mode press only toggles the mute | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The pedal frame names the waiting section only in Record mode, in green for a waiting Play and red for a waiting Record | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/control_projection_test.dart
- The board fills a queued pill at one level and blends it to the diffused curve when the queue ends | verify: bash firmware/test/run_tests.sh
- Static checks are clean | verify: dart analyze
- On the appliance, a waiting section starts at the playing section's end with no overlap and the pill fills uniformly, then softens | verify: manual 1. Song mode, record sections 1 and 2. 2. Play 1, press track 2 in Record mode: pill fills green, 2 starts when 1 ends. 3. Select empty 3, press Rec/Play: pill fills red, 3 records when 2 ends. 4. Repeat 2 in Band with a primary.

NON-GOALS:
- The 34-LED ring (PR #1320); RING_N stays 40.
- Removing le_engine_toggle_section (#1324).
- Band Mute-mode changes.

VERIFICATION COMMAND: bash firmware/test/run_tests.sh && bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test test/control && dart analyze
```

## Risks

- Record preparation runs on the control thread at the press; the deferred
  start reuses the quantized-arm preparation, so a waiting Record holds its
  prepared buffers until it fires or is cancelled, as a quantized arm does.
- Band's handoff timing depends on the primary's wrap; a source played at a
  non-unit Speed reaches its lap end off the wrap, which is why the commit
  latches the lap end and waits for the next top.
- Hardware remains the owner's check: the handoff by ear and the pill on the
  board.
