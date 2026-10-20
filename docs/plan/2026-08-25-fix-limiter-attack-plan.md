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

**Smoothed attack (~2 ms one-pole) plus a brickwall backstop at the ceiling**,
and on the trunk a ~50 ms peak hold under both (see "Review finding" below).

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

## Ported to the trunk (2026-10-19)

PR #813 targeted the old `master`. The owner decided to port it together with
the take envelope (#730) onto `claude/segno-integration`. The limiter change
itself is the same; one thing about the trunk differs from what #813 assumed:

- **The offline render has no limiter to update.** On `master`,
  `le_pr_render_master` (perf_render.c) replayed the master gain and an
  instant-attack limiter so exports matched live. Since the output setup work
  (0e1847046, 2026-10-01) the performance capture tap sits inside
  `output_bus_frame`, before the global master gain and the master limiter, and
  the offline render replays only the capture bus's chain and, under Follow
  output, its level and mute. An export carries no limiter either way, so live
  and export still match. The two comments in perf_render.c that still
  described a limiter replay were corrected instead.

The measured numbers above are unchanged on the trunk: instant attack 38.6x
and ~2 ms attack 1.0x.

### Review finding: the smoothed attack needs a peak hold

Review of the port found that #813's limiter flat-topped steady loud
material. Its detector took each frame's own |x|. Between a waveform's peaks
that falls toward zero, so the target rose in every trough, the release
pulled the gain back up, and the 2 ms attack never caught up at the next
peak. The brickwall backstop did the limiting: a sustained sine at twice the
ceiling had 27-29% of its samples clamped (up to +0.8 dB). A 110 + 347 Hz
two-tone had 11% clamped at 1.5x (+1.4 dB) and 25% at 6x (+3.6 dB). The old
instant attack clamped none. The DC fixture could not see it, because a
constant level is its own peak in every frame.

The port adds a **peak hold**. The gain follows the lowest target over the
last one to two ~50 ms windows. 50 ms is one period of 20 Hz, so every window
of audible material contains a peak. Two windows rather than one running
minimum, so a passage that gets quieter but stays over the ceiling releases
to its new level within ~100 ms. Measured at 48 and 96 kHz:

```
sine     x1.5 / x2 / x6:  clamped 0%      (no hold: 26.7% at x2)
two-tone x1.5 / x6:       clamped 0.03%, worst +0.004 dB
largest one-frame gain change: one attack step (0.006 at x6, 48 kHz)
```

The hold also delays the release by up to ~100 ms: the gain is back at
exactly 1.0 361 ms after a sustained loud passage ends (311 ms without the
hold). `test_master_limiter_holds_through_a_steady_waveform` pins the steady
behaviour. `test_master_limiter_through_process` runs the limiter through
`le_engine_process` with the coefficients it computes, so swapping the attack
and release fails it. While the limiter is off its gain and hold rest at
unity, so switching it on starts clean rather than from a stale gain.
