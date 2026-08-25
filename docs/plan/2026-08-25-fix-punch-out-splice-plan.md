# Punching an overdub out when the player stops — the direction call (#731)

Status: **root cause corrected, design chosen, implementation deferred.** The
issue's stated cause is wrong, and both options it proposes follow from that
wrong cause — so this document exists mainly to stop the next session
implementing either of them.

## What #731 says, and why it is not that

> the loop head keeps a lap of layered material that the loop tail never got,
> and the wrap splices on it

It does not. The measured step reproduces exactly from the signal alone, and
removing the punch-in ramp entirely does not change it by a single digit:

```
b[4799] = sin(4799) + sin(4799+N)     = +0.14812
b[0]    = ramp(0)*sin(0) + sin(0+N)   = -0.35355     (ramp(0) = 0)
step                                   =  0.50168     <- the reported 0.50168
with no ramp at all: b[0] = sin(0)+sin(N) = -0.35355  (unchanged, sin(0) == 0)
```

Head and tail already receive the same number of laps. The step is simply the
overdub's **own wrap seam**: a signal that is not loop-periodic, layered across
the loop point, with no continuation to fold.

The control case (`test_loop_seam_survives_whole_lap_overdub`, 2.1x) is not
"correct behaviour" either — it is a coincidence. The player's still-live input
through the punch-out fade tail keeps writing into `[0, F)`, and that write
*happens to be* the continuation of position `len-1`. It is #728's fold, done
accidentally, by the performer.

## Both proposed options are dead

- **"Crossfade the loop's tail into its head over F frames."** A loop crossfade
  needs either a captured continuation (there is none — the player stopped) or a
  loop that is F frames shorter (the length must stay a whole multiple of the
  base, or the track desyncs). Blending `[len-F, len)` into `[0, F)` without
  either does not make the wrap continuous; it just moves the step.
- **"Make the punch-out envelope loop-position-aware so the head and tail always
  end a session with the same number of laps."** They already do. This fixes
  nothing.

## The fix that follows from the real cause

**Give the overdub LAYER an envelope at the wrap**, exactly as #730 gives a
stopped-early take one:

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
against `dub_slot` / `a_live`, at the point `le_seam_fold` already runs.

## What is landed

`test_overdub_punch_out_player_stops_still_splices_731` pins the defect at
389.8x with the arithmetic that explains it, so the fix can be measured against
the same number. **Its assertion is deliberately inverted** (`score > 100`) and
says so — flip it to `< 25` when the fix lands.
