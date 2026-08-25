# Punching an overdub out when the player stops — the direction call (#731)

Status: **root cause corrected, design chosen, implementation deferred.** The
issue's stated cause is wrong, and its RATIONALE must not drive the fix — but
one of the mechanisms it names (a loop-position-aware envelope) is exactly the
chosen design, applied one level down. This document exists to keep the next
session from re-litigating the cause or discarding the mechanism along with
the rationale.

## What #731 says, and why it is not that

> the loop head keeps a lap of layered material that the loop tail never got,
> and the wrap splices on it

It does not. The measured step reproduces exactly from the signal alone:

```
b[4799] = sin(4799) + sin(4799+N)     = +0.14812
b[0]    = ramp(0)*sin(0) + sin(0+N)   = -0.35355
step                                   =  0.50168     <- the reported 0.50168
with no ramp at all: b[0] = sin(0)+sin(N) = -0.35355  (unchanged, sin(0) == 0)
```

The ramp term drops out **because this fixture's oscillator sits at phase 0 at
the punch-in** — `ramp(0)` multiplies `sin(0) == 0`, so its value is
irrelevant here. Not because the ramp starts at zero: it does not.
`engine_process.c` advances `od_gain` BEFORE the write, so the first
overdubbed frame is written at `od_step = 1/480`, not 0. And the
ramp-changes-nothing observation is a property of this fixture only — in
general the punch-in ramp IS load-bearing (it suppresses the head's oldest
generation at the punch point) and must not be read as droppable.

Head and tail already receive the same number of laps. The step is simply the
overdub's **own wrap seam**: a signal that is not loop-periodic, layered across
the loop point, with no continuation to fold — a generational content mismatch
at the fold, not a lap-count imbalance.

The control case (`test_loop_seam_survives_whole_lap_overdub`, 2.1x) is not
"correct behaviour" either — it is a coincidence. The player's still-live input
through the punch-out fade tail keeps writing into `[0, F)`, and that write
*happens to be* the continuation of position `len-1`. It is #728's fold, done
accidentally, by the performer.

## What in #731 is dead, and what survives

- **Option 1, "crossfade the loop's tail into its head over F frames" — dead as
  stated.** A loop crossfade needs either a captured continuation (there is
  none — the player stopped) or a loop that is F frames shorter (the length
  must stay a whole multiple of the base, or the track desyncs). Blending
  `[len-F, len)` into `[0, F)` without either does not make the wrap
  continuous; it just moves the step.
- **Option 2, "make the punch-out envelope loop-position-aware so the head and
  tail always end a session with the same number of laps" — the RATIONALE is
  dead, the MECHANISM is the fix.** The lap-count story is wrong: head and
  tail already end every session with the same number of laps, so an envelope
  justified by equalizing them fixes nothing *for that reason*. But a
  loop-position-aware envelope is exactly the chosen design below — applied to
  the **layer** rather than to the punch-out gain, and justified by the
  layer's own wrap seam, not by lap counts. Do not read this section as
  killing loop-position-aware envelopes; it kills the issue's justification
  for one.

## The fix that follows from the real cause

**Give the overdub LAYER a loop-position-aware envelope at the wrap**, exactly
as #730 gives a stopped-early take one:

```
layer(i) = live(i) - shadow(i)                  # shadow = the pre-pass image
live(i)  = shadow(i) + layer(i) * ramp(i)       # over [0, F) and [len-F, len)
```

The layer becomes a self-contained one-shot inside the loop, and the underlying
loop's own continuity — whatever the take beneath it had — is untouched. It is
the same shape, the same ~10 ms, and the same reasoning as #730, applied one
level up.

## Why it is not implemented here

The pre-pass image is the **undo shadow**, which means this has to run in the
layer machinery, on the **audio thread**:

- `le_handle_retired` is the obvious home and is the wrong one — it runs on the
  control thread, and writing to the live slot there races the audio thread's
  playback reads. Every existing seam fold (#728) runs on the audio thread for
  exactly this reason.
- The shadow is only complete for a pass that wrote every position. A partial
  pass, a re-punch during the fade tail, and a drain-walk retire each leave it in
  a different state — three cases whose interactions the surrounding comments
  already describe as delicate, including one known gap (`#728`'s
  retire-before-the-fold).

That is a focused piece of work with a real correctness hazard, and it should not
be done at the tail of a long session. What is left is bounded: the design above,
against `dub_slot` / `a_live`, **at the layer's end on the audio thread** — the
two sites where an overdub session's pass actually finishes:

- `le_dub_boundary` (engine_process.c), where a completed whole pass retires at
  the pass boundary, and
- `le_dub_block_update`'s punch-out-complete path (engine_process.c), which
  fires once `state != OVERDUBBING && od_gain == 0` — the od_gain fade tail has
  fully decayed — and today arms a partial pass's drain walk.

NOT at `le_seam_fold`'s call sites: it has two (the trailing-overlap capture
in `mix_tracks_frame`, and `finalize_master_xfade`), and both are finalize-time
— they fire around a track FINALIZING, before the overdub in question even
exists.

## What is landed

`test_loop_seam_on_punch_out_with_player_stopped` pins the defect with the
arithmetic that explains it, so the fix can be measured against the same
numbers. **Its defect assertions are deliberately inverted** and say so:

- `loop[0]` against the ramp-free prediction `x(4800)`, to 1e-7 — the
  counterfactual above as arithmetic rather than as a claim.
- the wrap step at `0.50167599`, to 1e-6 (~17 float ulps at this amplitude) —
  the absolute number this analysis derives.
- `median > 0` and `wrap / median > 100` — the splice must be at the loop
  seam, measured against a loop still carrying the overdub (the global score
  alone reads a wiped-to-silence loop, or an unrelated artifact elsewhere in
  the lap, as the same failure).
- `peak < 0.45` — audio either way, never corruption; derived from this
  fixture: the steady two-pass sum has amplitude 0.38268, but the loop's true
  peak is 0.42898, in the ramped head where the attenuated first pass leaves
  the second pass's near-crest exposed. 0.45 clears that deterministically and
  stays below the 0.5 single-pass cap.
- the score inside `370x .. 410x` — two-sided, because the measured 389.8x is
  deterministic to that same float ulp, so a partial fix landing at 120x and a
  regression to 2000x must each fail rather than both read as unchanged.

When the fix lands, the defect pins flip to `score < 25` — the bound the
file's other seam tests already hold (they measure 1.6x to 2.1x) — while the
median guard and the peak bound stay, **and a content floor is added**:
`CHECK(peak > 0.35)` (the 0.38268 steady two-pass amplitude survives any
seam-local taper) or equivalently `CHECK(med > 6e-4)` (half the expected
0.0013). Without a floor, the flipped form passes on a "fix" that attenuates
the layer to near-silence — score is a scale-invariant ratio, so smooth
near-zero content reads ~2x, a denormal-positive median satisfies `med > 0`,
and a near-zero peak satisfies any upper bound. The absolute wrap/loop[0] pins
that protect the defect form are exactly the ones the flip drops, so the floor
is what replaces their content-guarantee. Everything between 25x and 370x is a
deliberate dead band: a partial fix landing inside it fails both forms of the
test, and must be read as "moved the step without removing the splice", not as
a bound to widen.
