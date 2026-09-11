# Whole-track Pre: the render boundary

Status: direction approved by the owner on 2026-09-10 on issue #1016. This
document fixes the engineering boundary the approval asked for, before
implementation.

The approval, in the owner's terms: keep the whole-track Pre/Post switch, and
implement a non-destructive processed copy of the combined track. Process the
combined material as one signal — do not fan separate copies of the effect out
to each part, because that changes the sound of compressors and distortions.
Do not make switching to Pre perform a user-facing Bounce or permanently
flatten the track. Keep original sources and recoverable edit state. Build the
playable result from those sources and the applicable processing recipe, never
by processing the previous wet result again. Keep the current working sound
until the replacement succeeds, then switch at an audio-safe boundary without
restarting the loop. Parts, layers, Undo/Redo and effect assignments must
remain usable. Pre sound stops with the loop; Post remains live and can finish
its tails after Stop.

## The boundary

A track's Pre run is a rendered copy of its combined material:

    for each active part (lane):
        that part's PRINTED material  x  its level, gated by its mute
        placed by its pan
    summed
    -> the track's Pre run
    -> one interleaved stereo buffer of the track's loop length

"That part's printed material" is the part's own Pre print where it has one,
and its dry recording at level where its chain is empty. Both are control-
thread-owned, so the assembly is the same copy-at-enqueue discipline the part
prints already use, chunked, one part at a time into the stereo accumulator —
so the render's cost does not grow with the part count.

The track's Post run always stays live over the result, exactly as a part's
Post run stays live over its own print.

## The printability rule, and why it is the whole answer

**A track's Pre run is rendered only while every one of its parts' chains is
wholly Pre.** A part carrying a Post entry makes the track's Pre run
permanently live, with the reason reported — the same shape as the rule that
already keeps a chain with a hosted plugin live.

That single condition is what makes every accepted behaviour survive:

- A part's Post run is never inside the render, so a part's Post tail keeps
  draining past a Stop. The per-instance promise the switch makes — "Can ring
  after Stop" — holds without the player ever having to know a render exists.
  Flipping a switch in the Whole track editor cannot change what a part's own
  editor says about that part.
- Nothing downstream of a part's Post run is ever committed, so Bounce's two
  categories still partition the chain: printed Pre is the parts' Pre runs
  plus the track's, runnable Post is the track's.
- The live path and the printed path compute the same function, so they agree
  everywhere including at Stop, and the fallback below is inaudible except for
  the enable ramp a part print already pays.

The alternative — rendering the parts' whole chains, so that a part's Post run
becomes captured material — was designed, reviewed and rejected. It changes a
documented per-instance behaviour from a control the player did not touch, and
it fires on the default configuration, because a new instance on a recorded
destination is Post.

Rendering a tail region alongside the lap, to play out at the Stop edge, does
not rescue it: the tail a Stop needs is a function of the position the player
stopped at, and one stored region encodes exactly one position. A loud stab
late in the lap would arrive as repeats after a Stop early in the next one.

## Engagement, fallback and Stop

Engages at the track's read position 0 — every part of a track shares that
index, so it is one boundary — and touches no transport state, so the loop
does not restart. At the engage edge the parts stop contributing to the track
bus entirely: their chains are force-bypassed and their effective bits masked,
AND their audio is no longer summed, because a bypassed entry is unity
passthrough, not silence. The parts keep being read for metering.

Any key mismatch falls back to live within the same buffer, which is the part
print's shipped policy. That reading of "keep the current working sound until
the replacement succeeds": the live path is the same signal chain, so the
fallback keeps the sound and makes an edit audible at once, where holding the
stale render would leave a control doing nothing for up to a whole loop — and
would play audio the player never configured whenever a render can never
succeed.

Stop is unchanged from what slice 3e shipped: each part's Pre run and the
track's Pre run lose their tails, everything Post drains. Printed or live, the
same.

## The key

Anything that moves the combined material moves the render's key: the track's
content revision, the part count, and per part its printed identity, level,
pan and mute, then the track's Pre run and its channel handling, and the
length. Level, pan and mute are inside the sum and cannot be applied after it,
so a Mixer gesture re-assembles the render — cheaply, because the parts' own
prints are the input and are not re-rendered. The audio thread's per-buffer
verdict memo must be invalidated by those setters too, or a muted part would
keep sounding out of a stale render.

Solo is not baked. It gates the track as a whole, so it applies to the
rendered pair on the audio thread exactly as it applies to a part's print.

## When it cannot render

A part with a Post entry; a hosted plugin anywhere in the track's or a part's
chain; a part whose own print has not settled; a job that does not fit the
memory cap; repeated render failure; the track RECORDING or OVERDUBBING or
with a layer in flight. In every one of those the track's Pre run is live and
sounds the same.

## What it does not touch

Parts, overdub layers, Undo/Redo, content revisions, effect assignments and
slot ids. Nothing is written back into any recording, so all of it survives,
and an FX configuration change still creates no audio-history entry. Bounce is
unchanged and still distinct: it writes a new take and clears the
destination's racks so printed processing is not applied twice.

## Playback transforms

Speed, Reverse, pitch preservation and Follow tempo do not exist in this
engine. The accepted direction for Speed is to stream from originals inline,
which composes with a render from originals: both read the same recordings.
