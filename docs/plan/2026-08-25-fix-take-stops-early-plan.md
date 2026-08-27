# A take that stops early — the direction call (#730)

Status: **decided and implemented**. This document exists so the decision is
cheap to overturn: it records what was chosen, what was measured, and what the
alternatives actually cost.

## What the defect is

A non-defining take whose length is AUTO rounds **up** to whole base loops
(`finalize_new_track`: `k = (record_pos + base - 1) / base`). The buffer past the
material stays the digital silence `le_prepare_new_capture` wrote, so the loop is
`[material][silence]` and both joins step.

## What #730 got wrong, and it matters

#730 measures one join — material to silence, 562x — and its three proposed
options all address only that one.

Measured here with the same harness, changing one thing: the oscillator starts at
its **peak** rather than at phase 0. A take begins on the loop top whatever the
performer happens to be playing, so the buffer's first sample is arbitrary;
starting at phase 0 makes it zero and the wrap join look clean for a reason that
has nothing to do with the engine.

```
cut-to-silence @6240: 0.11903 (142.4x)
wrap           @9600: 0.50000 (598.2x)   <- the bigger one, unmentioned
```

**The wrap is the dominant artifact.** Taper-the-ending (option a) and
keep-recording (option c) do not touch it at all.

## The decision

**Treat the take as what it is — a one-shot with a start and an end — and give
it a short fade at both.** Linear, `seam_xfade_frames` (~10 ms), the same shape
every other seam in this engine uses.

```
cut-to-silence @6240: 0.00000 (0.0x)
wrap           @9600: 0.00000 (0.0x)
worst step anywhere:  0.00248  score 3.3x     (was 598.2x)
```

### Why not the other two

- **Round to NEAREST.** Truncates material the performer played whenever they
  stop just past the loop top. Destructive and surprising — "I played that and it
  vanished" — and it removes the wrap step only in the cases where it happens to
  truncate. `le_sync_ratio_pow` does this for Sync/Band, but that is a feature
  whose contract is "fit the grid", not "keep what I played".
- **Keep recording until the take fills.** Records what the performer did *after*
  they said stop: their next move, the room, them talking. And it delays the take
  being usable by up to a full lap. On a looper, stop means stop.

Padding with silence is the only one of the three that keeps exactly what was
played, where it was played. It just has to stop clicking on the way in and out.

## Two things the implementation had to learn the hard way

**The material does not always start at 0.** Grid-quantized record-start (D8)
delays capture to the next grid unit, so a take can sit at `[375, 1500)` inside a
3000-frame loop with silence on *both* sides. A first draft assumed a
`[material][silence]` suffix and faded position 0 — which faded silence and left
both real steps exactly where they were. `record_start` is what the buffer
actually knows, so the fix works on the span `[record_start, record_pos)`, shifted
by the latency-compensation offset.

**Four fades of room, not two.** `seam_room`'s own minimum is `2F`, and a first
draft borrowed it — but `2F` means a take can be *entirely* fade. At 48 kHz the
grid fixtures capture 23 ms, where two 10 ms fades leave 3 ms flat and turn a stab
into a swell. Below `4F` (~40 ms) the content is left exactly as recorded: a take
that short is a transient either way, and silently reshaping one the performer
asked for is worse than the step.

## What this also unblocks

`finalize_new_track`'s #728 comment said the record-offset path could not have a
seam "without first fixing the trailing-zeros gap it shares with #730, which is a
length/round-up direction call". On the auto path `len >= record_pos > record_pos
- offset`, so the seam equality never holds and the taper always runs instead —
**every latency-calibrated rig**, which is every real one, goes from a raw splice
to a fade into the few milliseconds of trailing zeros the offset leaves. That is
an honest improvement, not the proper continuation fold, which would need
material the compensation consumed.

## How to overturn it

The whole decision is `le_take_taper_ends` in `engine_process.c` and its one call
site. Round-to-nearest is a change to the `k` expression in the auto branch;
keep-recording is a pending-finalize like the D8 record-end path already uses.
`test_take_stops_early_no_silence_cut` reports both joins by position, so any
replacement can be compared against the same two numbers.
