---
title: "Tempo, loop length and record timing on the 7in readout"
type: feat
date: 2026-11-04
issue: 1654
---

# Tempo, loop length and record timing on the 7in readout

<!-- cspell:words retimes retime Penpot -->

Tracking: [#1654](https://github.com/tomassasovsky/segno/issues/1654),
`autonomy:auto`. Brainstorm:
[`docs/brainstorm/2026-11-04-readout-controls.md`](../brainstorm/2026-11-04-readout-controls.md),
mockups in [`docs/images/readout-controls-1654/`](../images/readout-controls-1654/).
The exact-tempo keypad comes from #1653 (PR #1661).

## Owner decisions, 2026-11-04

All six questions in the brainstorm's section 9 were answered as
recommended:

1. Layout B. The readout does not change until its footer strip is touched.
   The touch opens one panel with every control. Done, or 10 s without a
   touch, closes it.
2. Length and record timing edit the default for all tracks. When the
   selected track has its own value, the panel says so, and that value stays
   a main-screen edit.
3. Nudges of 1 and 0.1 BPM, with hold to repeat. Hundredths go through the
   keypad.
4. Tempo changes that retime recorded loops are allowed from the readout,
   and the panel says so before the player changes anything.
5. No count-in on the panel.
6. No Clear tempo on the readout. Changed by the owner on 2026-11-05 after
   build 229: Clear tempo is on the panel, beside Tap (see "Clear tempo"
   below).

## What crosses the screen link

One new message, readout to main: `{op: 'command', command: {...}}`. The
command map is a sealed `ReadoutCommand` (`lib/visualizer/readout_command.dart`)
with a `toMap` and a tolerant `fromMap`. An unknown or garbled command is
dropped.

| Kind | Fields | Main-screen call |
|---|---|---|
| `tempo.nudge` | `delta` (+-1 or +-0.1) | `TempoSettings.setTempo` |
| `tempo.set` | `bpm` | `TempoSettings.setTempo` |
| `tempo.tap` | none | `TempoSettings.tapTempo` |
| `signature.set` | `num`, `den` | `TempoSettings.setTimeSignature` |
| `length.set` | `bars` (0 is Auto) | `RecordSettings.setDefaultLengthBars` |
| `timing.set` | `timing` (`RecordTiming.name`) | `RecordTimingSettings.setTiming` |
| `tempo.clear` | none | `TempoSettings.clearTempo` |

There is no reply. The readout sees the accepted value in its next
`PerformanceReadout` push. The Loop settings pages are not touched (#1659 is
restructuring them); only the settings classes are called.

The handler checks the tempo lock itself (`LooperState.tempoFollow` and an
external clock) before it calls the tempo owner: the engine accepts a locked
tempo or signature command and drops it later on the audio thread, while
`TempoSettings` would already have published and saved it. It also drops
every command while the console is idle-dimmed, so the waking touch presses
nothing even when the readout's barrier is a push behind.

### Clear tempo

`tempo.clear` is the one command with a reply. Like the main screen's Clear
tempo (#1653), it is offered whenever a tempo is set and the handler checks
no lock: the engine's tempo lock decides. A refusal comes back main to
readout as `{op: 'refused', refusal: <ReadoutRefusal.name>}`, one of
`tempoClearLocked` (`notReady`), `tempoClearStopped` (`notRunning`) or
`tempoClearOther`, and the panel says the main screen's notice, its title
and reason, in the tempo note's place for 6 s (the main screen's warning
time), until the next command, or until the panel closes. While it is said
it takes the recording band's place, because the 7" has no room for both.

A nudge is a delta so that a held button never works from the readout's stale
copy of the tempo. The handler adds it to the live tempo. The live tempo lags
a `setTempo` by one engine snapshot, so while it still reads what it read
before the last nudge, the handler adds to that nudge's result instead. With
no tempo set, a nudge starts from 120 BPM, the value the main screen's
Tempo page starts its slider from. Results are clamped to `kTempoRange` and
rounded to hundredths.

## What the readout push gains

`PerformanceReadout` carries:

- `tempoFollow`: `LooperState.tempoFollow` (`free`, `retimes`, `noGrid`,
  `noFollower`, `busy`).
- `clockOwnsTempo`: the tempo source is an external MIDI clock.
- `loop`, a `ReadoutLoopSettings`: the default length and record timing, the
  selected track's own length and timing when it has them, whether a take
  holds them (the capture lock), and whether both owners have loaded.
- `dimmed`: the console is idle-dimmed, so the readout lays a barrier over
  its controls and the touch that wakes the console presses nothing.

`_sameReadoutFacts` compares `tempoFollow`; the rest arrives through
`WaveformDisplayContext`, which is compared as a whole. `_AppViewState`
updates the context from the `RecordSettings` and `RecordTimingSettings`
streams and from `IdleDimCubit`.

## Locks on the panel

| State | Tempo and Tap | Signature | Length and Start |
|---|---|---|---|
| `free` | editable | editable | editable |
| `retimes` | editable, with the note "Changing the tempo retimes the recorded loops" | locked: "Clear all tracks to change it" | editable |
| `noGrid`, `noFollower` | locked, with the reason | locked | editable |
| `busy` | locked | locked | locked while a take records |
| MIDI clock | locked: "MIDI clock sets the tempo" | by `tempoFollow` | editable |

When a take holds the length and start, or the engine reports `busy`, a band
under the panel's header says "Recording: tempo, length and start are locked
until the take ends", as `b3_locked.png` draws it. Locked controls stay on
screen, dimmed, with a lock mark.

## Parts

Each part is one PR, stacked, on branches `claude/readout-controls-1654-p<K>`.

### Part 1: the link and the main screen's handler (no UI)

- `ReadoutCommand`, `ScreenLinkOp.command`, `ReadoutScreenLink.sendCommand`,
  `WaveformWindowService.onReadoutCommand` and its delivery in
  `ScreenLinkWaveformService`.
- `ReadoutCommands` (`lib/visualizer/application/`), built in `_AppViewState`
  over `LooperRepository`, `TempoSettings`, `RecordSettings` and
  `RecordTimingSettings`.
- The new readout fields, their map round trip, and the diff gate.
- This plan and the Active threads row.

Acceptance:

- Every command kind survives `toMap` and `fromMap`; an unknown kind, a
  missing field or a wrong type yields null.
- A command sent from `ReadoutScreenLink` arrives at `onReadoutCommand`
  through a real `ReceivePort`.
- Against fakes of the three owners: each command makes its call; two nudges
  before the engine publishes add up; a nudge clamps at 30 and 300; a nudge
  with no tempo starts from 120; a signature outside `kValidTimeSignatures`
  is ignored.
- A change in `tempoFollow` alone, or in the loop facts or the dim alone,
  produces a new readout push.

### Part 2: the footer strip and the panel

- The footer becomes one touch target at least 48 logical px high: tempo,
  signature, length and start, then the function and bank. Touching it opens
  the panel. The rest of the readout does not change.
- The panel (`b2_panel.png`): a header with the track, its state, a small
  waveform and Done; the tempo card with the figure, beat lights, -1, -0.1,
  +0.1, +1 (hold to repeat) and Tap (fires on pointer down); the signature
  row (3/4, 4/4, 6/8, More, where More shows all 17); the length row (-,
  value, +, Auto); the seven record timings.
- Done or 10 s without a touch closes the panel.
- The lock notes and band from the table above, and the dim barrier.
- English and Spanish strings.

Acceptance:

- Widget tests at 640x375 logical: the strip opens the panel; each control
  sends its command; hold repeats a nudge; Tap sends on pointer down; Done
  and the 10 s timeout close it; each lock state dims the right controls and
  shows its note; the track-override note shows; the waking touch on a
  dimmed readout sends activity and no command. Every target is at least
  48x48 and nothing overflows or clips, in both languages.
- A screenshot suite at 1024x600 physical, pixel ratio 1.6: the readout with
  the strip, the panel, the panel in `retimes`, the panel locked while
  recording, the full signature grid. Regenerated and viewed.

### Part 3: exact entry, and closing the issue

- Touching the tempo figure opens the readout's keypad (`k_keypad.png`):
  the entry field and range on the left, Set and Cancel under them, the
  numeric pad on the right. It uses the input rules, field and strings that
  #1653 adds (PR #1661). If #1661 has not merged, the part is based on its
  branch, and the PR says so.
- Removes the Active threads row and says `Closes #1654`.

Acceptance:

- Widget tests at 640x375: typing 128.47 and Set sends `tempo.set` 128.47;
  350 and 3 are refused with the range shown; Cancel and an empty Set send
  nothing; a third decimal is ignored.
- The screenshot suite gains the keypad.

## Design writeback

Penpot, a new page area `READOUT / controls` with the strip, the panel in its
states and the keypad, at 640x375 logical. Each part's PR lists its geometry
under "Design writeback".

## Device checks (later, on the console)

- Tap-tempo latency from the readout: taps at 120 BPM on the readout land
  within 0.5 BPM of the same taps on the main screen. If they do not, carry
  the pointer-down time in `tempo.tap` and add a timestamped tap to the
  engine; that is not built before the measurement asks for it.
- Every target is reachable at the panel's edges after touch calibration.
