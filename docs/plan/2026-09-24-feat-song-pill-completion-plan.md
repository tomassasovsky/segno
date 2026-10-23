# Song queue completion

Tracking: [#1077](https://github.com/tomassasovsky/segno/issues/1077).

The owner approved the completion simulation on the old v2 console (PR #1079,
protocol 7). On 2026-10-13 the owner approved porting it onto the integration
trunk; this plan records the port, as protocol 10 on top of the trunk's
protocol 9. The ring is not part of it: moving the sustained comet to the
34-pixel strip ring (#1090) is held by the owner on a separate draft. The v3
console board and the XIAO ring board (#1082) are a separate, hardware-gated
path.

## Behaviour

Song plays one section at a time.

1. A Play on a stopped section while another plays does not start it. The
   request waits for the playing section's next lap edge (the read lap the
   listener hears, so a reversed or re-sped section ends where its head
   reads the end of the take). At that sample the engine stops every playing
   section and starts the target from its beginning.
2. Requesting the waiting section again, or a playing section, cancels the
   request without changing playback. Another stopped section replaces it.
3. A capture anywhere refuses the request rather than cutting a take short.
   Stop, Clear, Undo, a capture, a mode switch, configure and engine stop each
   drop a waiting request. A Count-in launch keeps its own rules.
4. With nothing playing, a Play starts that section at once, alone and from
   its top; the rest of the rig stays stopped.
5. A take or a punch-in from a stopped rig starts only the section it
   captures on (owner, 2026-10-13). Song keeps no unpark rule; the other
   modes keep theirs, where a start from a held rig resumes every stopped
   track.
6. The engine remembers the section that sounded last
   (`song_last_section`). It survives a Stop and follows every handoff; it
   is forgotten when that track empties, on a mode switch and on configure.
   It is not saved with a session: under the repo's standing rules (drop uncertain native state, no silent changes)
   a recalled session has played nothing yet, and adding it to the session
   format would persist a guess.
7. Other modes keep immediate play.

This supersedes the July Song spec's "sections start independently and
immediately" for starting a second section; the accepted design's Song card
already reads "One section at a time."

## Control

In Mute mode, in Song, a track press asks the engine for that section. In
Record mode the pedal's Rec/Play on a muted stopped section, and the screen's
Play, can also queue one. The engine queues, cancels and replaces; the app does not keep its own copy. A
muted stopped section is unmuted first; a press on a muted playing section
only unmutes it, so it does not drop the section waiting to follow it.
Rec/Play while a section plays does nothing (expanding to every section would
make each one replace the last). Parked, Rec/Play starts the section Stop
latched, else the selected one, else the first with a take. Stop reads the
engine live and stops what plays there, what the poll saw playing and the
section that waits, so a handoff that landed between polls is stopped too.
The on-screen Play All starts the section that sounded last, while it still
holds a take and is not muted (a muted one would start silent), else the
first unmuted section with a take, else the first with a take (owner,
2026-10-13). In Record mode the pedal's Rec/Play keeps its meaning: on a
stopped section it punches in at once, a capture rather than a section
change; on a muted stopped section it asks for the section like a Mute-mode
press. Record and FX keep their meanings, and Multi keeps its mute
and resume rules.

The waiting section shows wherever a queue can start (owner, 2026-10-13). On
the pedal, in Mute and in Record mode, it reads green and its pill fills, on
the visible bank only; in Record mode it reads green even on the cursor until
the section starts. On the screen it wears the accepted stage's queued cue,
Play over Loop start, whatever started the request. In Mute mode the pedal
also shows the sounding sections green; Song does not preview a parked resume
set.

## Wire and firmware

Protocol 10, STATE 53 bytes: byte 51 is the queued footswitch + 1 (0 none),
byte 52 the progress 0..254 of 255 (0 without a footswitch). The app sets the
footswitch only for a waiting section on the visible bank, and lights it like
any other: the board keeps no Song or bank logic. The board fills that pill
left to right by the progress, with the sourced centre curve, harness order
and 6000-channel budget. Nothing local advances the fill and a queue never
draws a full pill: the engine ends the wait by starting the section, and the
next frame carries no queue. The engine publishes target and progress in one
atomic word, so the two always describe the same request. Firmware 1.14.

## Validation

- Native: exact-sample handoff in both channel orders, progress, replace,
  cancel, the playing source cancelling without a rewind, invalidation by
  every lifecycle path, capture refusal, Once sections, several playing
  sections, a reversed source's lap edge, Free unchanged and the performance
  log (one STOP and one PLAY at the handoff frame, nothing for a cancelled
  request). Plain, AddressSanitizer and telemetry-off builds.
- Firmware: the C codec against the regenerated Dart fixtures, queue
  refusals, and the pill fill at every progress step, held against time,
  hidden when the app does not light it, and dark on goodbye and a lost
  link.
- Dart: snapshot projection, repository projection, the frame codec and
  frame, projection, invariants and the cubit's Song gestures.

Hardware remains the owner's check: a complete queued pill fill and an
audible handoff during ordinary use, in Mute and Record mode, and the
protocol 10 handshake after the appliance flashes firmware 1.14 with the
matching app.
