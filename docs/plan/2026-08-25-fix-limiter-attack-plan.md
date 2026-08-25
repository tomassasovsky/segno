# The master limiter's attack — the direction call (#725)

Status: **decided and implemented.**

## The defect

`master_bus_frame` set `e->lim_gain = target` in a single sample the moment the
ceiling was crossed. That is a one-sample gain step applied to **every channel of
the whole mix**, at an arbitrary offset, clustering with transients because that
is precisely when it fires — click-shaped by construction.

The part that makes it worse than it sounds: it modulates the content that did
*not* cross. A quiet pad under a loud snare gets the same step.

## Measured

Channel 0 holds only a quiet steady 100 Hz sine. Channel 1 is silent until a
sudden burst well over the ceiling. The limiter takes its peak across channels
and scales all of them, so any step on channel 0 is the gain move and nothing
else — channel 0 has no transient of its own to blame.

```
the quiet channel's own worst delta: 0.002618
instant attack: worst delta on it   0.100983   (38.6x)
~2 ms attack:   worst delta on it   0.002618   ( 1.0x)
```

## The decision

**Smoothed attack (~2 ms one-pole) plus a brickwall backstop at the ceiling.**

The issue leans this way and is right, for a reason specific to this product:
lookahead is the other way to remove the step, and it buys a clean attack at the
cost of exactly its own length in added output latency. This is a live looper —
the performer hears themselves through this bus *while playing*. Latency is the
one thing the master bus may not spend.

The backstop is what pays for the smoothing. A one-pole attack has not finished
falling while it is still moving, so samples during the attack would exceed the
ceiling. Clamping them is a deliberately different trade from what it replaces:
it touches only the samples that actually exceed the ceiling, for the few frames
the attack is still moving, instead of scaling everything. Clipping the tip of a
transient is bounded distortion on the part of the signal that was already at the
limit; a gain step is broadband and audible on the part that was not.

**The ceiling contract is unchanged**: no sample leaves the master bus above the
ceiling, and the existing test that pins that (`test_master_bus_frame_limiter`)
still passes untouched.

### Why 2 ms

Shorter and the gain move starts to look like the step it replaces; longer and
the backstop clips for more of the transient. Both coefficients are per-block, so
the RT path never divides per frame.

## How to overturn it

`lim_attack` in `le_engine_process` is the whole decision — one constant. The
test runs the fixture at both the shipped coefficient and the instant one it
replaced, so any new value can be compared on the same two numbers. Lookahead, if
the latency budget ever changes, is a buffer in `master_bus_frame` and a
correspondingly larger `a_output_latency` report.
