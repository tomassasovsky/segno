# Song queue completion and the sustained ring comet

Tracking: [#1077](https://github.com/tomassasovsky/segno/issues/1077) and
[#1081](https://github.com/tomassasovsky/segno/issues/1081).

The owner approved the completion simulation and the sustained ring fade on
the old v2 console (PR #1079, protocol 7, a 40-pixel ring). On 2026-10-13 the
owner approved porting both onto the integration trunk, and chose the
34-pixel strip ring for the console (#1090; the 40-pixel housing and the Ring
24 holder are dropped). This plan records the port: protocol 10 on top of the
trunk's protocol 9, and the comet on 34 pixels. The v3 console board and the
XIAO ring board (#1082) are a separate, hardware-gated path and are not part
of it.

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
5. Other modes keep immediate play.

This supersedes the July Song spec's "sections start independently and
immediately" for starting a second section; the accepted design's Song card
already reads "One section at a time." A record start from a stopped rig
still resumes the stopped sections, the unpark rule every mode shares; #1079
did not change it, and neither does this port. Whether Song should start only
the recorded section is an open question for the owner.

## Control

In Mute mode, in Song, a track press asks the engine for that section. The
engine queues, cancels and replaces; the app does not keep its own copy. A
muted stopped section is unmuted first; a press on a muted playing section
only unmutes it, so it does not drop the section waiting to follow it.
Rec/Play while a section plays does nothing (expanding to every section would
make each one replace the last). Parked, Rec/Play starts the section Stop
latched, else the selected one, else the first with a take. Stop reads the
engine live and stops what plays there, what the poll saw playing and the
section that waits, so a handoff that landed between polls is stopped too.
The on-screen Play All starts the first section with a take. Record and FX
keep their meanings, and Multi keeps its mute and resume rules.

The pedal shows the sounding sections and the waiting one green. Song does not
preview a parked resume set.

## Wire and firmware

Protocol 10, STATE 53 bytes: byte 51 is the queued footswitch + 1 (0 none),
byte 52 the progress 0..254 of 255 (0 without a footswitch). The app sets the
footswitch only for a waiting section on the visible bank, and lights it like
any other: the board keeps no Song or bank logic. The board fills that pill
left to right by the progress, with the sourced centre curve, harness order
and 6000-channel budget. Nothing local advances the fill and a queue never
draws a full pill: the engine ends the wait by starting the section, and the
next frame carries no queue. The engine publishes target and progress in one
atomic word, so the two always describe the same request.

The ring is the 34-pixel strip on GP12 (`RING_N = 34`). The comet keeps its
approved look: 1100 ms per turn, a 192 peak over a two-pixel lead, colour-only
gamma, and the approved 40-pixel profile resampled to the same angles (26 of
34 lit, the last quarter dark, the first ~42% at half the peak or more). The
ring's channel budget follows the pixel count (34 x 3 x 96 = 9792), so the
modelled combined current falls to about 1.49 A.

## Validation

- Native: exact-sample handoff in both channel orders, progress, replace,
  cancel, the playing source cancelling without a rewind, invalidation by
  every lifecycle path, capture refusal, Once sections, several playing
  sections, a reversed source's lap edge, Free unchanged and the performance
  log (one STOP and one PLAY at the handoff frame, nothing for a cancelled
  request). Plain, AddressSanitizer and telemetry-off builds.
- Firmware: the C codec against the regenerated Dart fixtures, queue
  refusals, the pill fill at every progress step, the 34-pixel comet table
  against the resampled approved profile, interpolation and the wire notch,
  limits and lifecycle.
- Dart: snapshot projection, repository projection, the frame codec and
  frame, projection, invariants and the cubit's Song gestures.

Hardware remains the owner's check: a complete queued pill fill and an
audible handoff during ordinary use, the comet through the actual diffuser on
the 34-pixel ring, and the protocol 10 handshake after the appliance flashes
firmware 1.14 with the matching app.
