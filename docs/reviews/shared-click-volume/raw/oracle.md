# Independent Click volume oracle

This is a portable synthesis of expectations frozen before the corresponding
candidate executions on 2026-10-01. It is not a copy of the original private
oracle and does not change its recorded hash. Expected behavior came from the
accepted controls contract in `docs/handoff/segno-app/accepted-behavior.md`
§4.7–4.11, existing Click/editor behavior, and the explicit implementation
contract in `docs/plan/2026-10-01-shared-click-volume.md`. Author test results
were not used to choose expected values.

This slice covers Click volume only. Tempo, count-in, Click mode, loop controls,
backing and instruments are outside it. The execution report distinguishes
expectations actually exercised from omitted journeys.

## Frozen provenance and correction

| Retained artifact | SHA-256 |
| --- | --- |
| Original `m311-click-oracle.md` | `500200f3dff4ed5f457c1601f212890d644203afc05c6e949688925af9c36db3` |
| `m311-click-oracle-addendum-v1.md` | `952f5a4506c8bbd05451e5a29b86ce68d622c4bf45f566907b026ee1f2e96165` |
| Final prepared manifest `prepared-v5full.json` | `a67c3756e86589bf29ef68c232504995407732f2f596f7ca9b6e193f85e7d9c0` |

The original endpoint-default wording was too broad. Before implementation or
candidate execution, the coordinator corrected it to the existing editor
contract: External button parameters initialize both endpoints from the
accepted current value; expression and MIDI retain their full-range defaults.
The addendum also fixes the relative detent at 0.01 normalized. This was a
pre-execution contract correction, not an adjustment to a failing test.

## Identity, units and editor behavior

The canonical identity is exactly `{"ctl":"clickVolume"}`. Reject aliases,
coordinates, extra fields and malformed types. It is one stable control,
independent of output-bus count. An absent owner is unavailable; a present
value of zero is available.

Click uses linear physical gain `g = 2 × n`, where controller coordinate `n`
ranges from 0 to 1. It does not use the Mixer logarithmic law.

| Normalized value | Physical gain | Percent of unity |
| --- | --- | --- |
| 0 | 0 | 0% |
| 0.125 | 0.25 | 25% |
| 0.25 | 0.5 | 50% |
| 0.5 | 1 | 100% |
| 0.75 | 1.5 | 150% |
| 1 | 2 | 200% |

An authored reversed range 0.875 → 0.125 maps raw input 0 → gain 1.75,
raw 0.5 → gain 1, and raw 1 → gain 0.25. A full-range CC7 value 64 maps to
128/127 physical gain; CC14 value 8192 maps to 16384/16383, not exactly unity.
The latter wire-ingress midpoint is an unexecuted vector in this review.

A relative detent is 0.01 normalized or 0.02 physical gain. From unity, +1
means 1.02 and −1 means 0.98. Two's-complement byte 64 means −64. Clamp to the
authored range; reversing endpoints reverses direction. Zero delta creates no
write or accepted priority. The owner rejects non-finite or out-of-domain
physical inputs rather than accepting them as user intent.

At accepted unity, External button endpoints start at 0.5/0.5; expression and
MIDI start at 0/1. At accepted gain 1.5, button endpoints start at 0.75/0.75.
Pending desired state must not seed those defaults. Add or Save alone sends no
audio command. Repair retains authored endpoints, including reversed ranges.
These UI requirements are not claimed as executed UI coverage here.

## Durable storage and real receipt

Keep three observations distinct: the durable `tempo.click_volume` scalar,
actual native publication, and the owner's confirmed outcome.

1. Start at confirmed gain 0.5. Request Held 1.5 with Released 0.25. Permit the
   scalar write and native enqueue while withholding the callback. The scalar
   may be 0.25, but native and confirmed owner remain 0.5 and the outcome stays
   pending. Only the real callback receipt permits applied/live 1.5.
2. Queue 1.5 then 0.5. The second request cannot complete by observing the old
   native 0.5 while the first command is still pending.
3. A blocked durable write prevents enqueue. A refusal or silent wrong readback
   gains neither audible state nor arbitration priority.
4. Native admission refusal restores the exact checkpoint: missing remains
   missing, while an explicit stored unity remains present. Mutate-then-throw
   storage must restore the checkpoint or expose uncertainty.
5. A callback timeout cannot be called a clean rollback merely because the
   scalar was restored. Fence uncertain work, expose recovery, and block new
   Click admission/restart until explicit recovery. A stale high must not
   arrive later. Flush cannot certify a prior success while newer work failed.

The accepted implementation keeps its repository cache confirmed as well. The
fundamental pending-before-callback assertion does not depend on requiring a
desired cache to advance early.

## Shared input priority and durable projection

Literal test values are prior ordinary 0.5; MIDI Held 1.5/Released 0.25;
External Held 0.75/Released 0.4; later ordinary 1.25.

- The latest accepted contribution wins, including a zero-valued contribution.
  Rejected writes gain no priority. Retiring a holder preserves an eligible
  surviving holder.
- Ordinary intent before a later press does not override that press's authored
  Released value. Ordinary intent during a hold wins and later release must
  not rewind it. An accepted ordinary write equal to the held value still
  replaces the durable low with ordinary intent.
- A non-held MIDI toggle to 1.5 supersedes the older External 0.75/0.4
  contribution durably at admission, through retirement and old release.
- Refused cleanup remains owed. A later accepted press cannot be retired by an
  older completion. Release before the press receipt must finish at the low.
- A missing sibling mapping must not poison a valid Click target. Disconnect,
  reconnect, configuration and session/device epochs fence stale input; fresh
  input is needed to resume.

The zero-valued competing-holder and continuous non-held variants remain
unexecuted permutations; this statement is an oracle, not evidence of coverage.

## Session, restart and shutdown

A session file saves Released 0.25 while Held 1.5 may remain audible. A delayed
startup read cannot undo a newer accepted intent or replacement session.
Stopped ordinary gain 1.5 may be accepted as durable deferred intent, but does
not prove audible confirmation. On restart, an expired MIDI or External hold
replays its Released value; later accepted ordinary 1.25 survives. A refused
ordinary edit cannot replace the confirmed restart value.

Power-off must await scalar writes and real Click receipt. Failure stays
visible and prevents halt. Retry is explicit and checks a fresh take gate;
flushing cannot be canceled or duplicated. Shutdown first synchronously cuts
off ingress and awaits retirement. On Retry it recovers Mixer/Click, drains
retirement a second time to resolve owed cleanup, then completes ordinary
flushes and final Click flush before halt. Keep playing permits fresh input,
not replay of cached held state.

Autonomous replay timeout or wrong readback must become owner-visible recovery
even without another edit. A flush waits for the pending replay. A failed
checkpoint read cannot permit ordinary or controller edits before explicit
Retry: preserve confirmed/scalar 0.5, attempt zero new scalar writes and keep
restart blocked; recovery then permits real restart at 0.5.

A separately predefined hostile lifetime sequence uses old durable 0.25 and a
replacement session's confirmed 1.25. The old store write is delayed; the
replacement independently fails replay; the old write then mutates and throws,
and its rollback fails. Explicit recovery may restore the old preference
checkpoint, but must never apply old gain 0.25 to the replacement runtime.
Its next native restart must be 1.25. The historical diagnostic write-count
correction and the real failure of this gain assertion are recorded separately
in [the execution report](independent-execution.md).
