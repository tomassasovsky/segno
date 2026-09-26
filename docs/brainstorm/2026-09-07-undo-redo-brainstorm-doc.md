# Undo and Redo during performance

Status: proposal for discussion, with original-recording recovery, one-layer
Undo, active-overdub cancellation, initial-take cancellation and immediate Redo
playback, and pre-Clear-All restoration accepted on
2026-09-07. The owner requested
the broader definition while the Peel prototype was being developed. Remaining
rules are proposals and do not replace the
accepted gesture layouts automatically.

The owner considers the discussed behavior sufficiently defined and asked to
move on for now. Do not reopen those accepted decisions merely to request another
review. Connecting the isolated histories remains implementation work. Bounce's
subsequent accepted study includes whole-operation Undo/Redo; its native shared
history still needs implementation.

## What We're Building

A predictable way to recover recorded audio by foot. The proposed normal Tracks
mapping is tap Undo and hold Redo, as already shown in pedal setup. Repeated taps
walk backwards; repeated holds walk forwards. A hold performs only Redo, never
Undo first. Neither action opens a menu or requires touch.

Undo targets the visibly selected track. It does not silently jump to whichever
track was edited most recently. An explicitly assigned external control can
target a fixed track, using the same history. Empty tracks with recoverable
content must remain selectable. Moving between banks does not delete history.

## Why This Approach

Three approaches were considered:

- One global history of everything is familiar in an editor, but a pedal press
  could reverse an unrelated FX or volume adjustment instead of fixing audio.
- Separate recording, length and Peel histories give focused previews, but
  become ambiguous when these operations are interleaved.
- **Recommended: one ordered recorded-content history per track.** Its scope is
  explicit, and recovery respects the order in which audio was changed.

For example: overdub, Divide, then Undo restores the full length. Another Undo
removes that overdub. Redo restores the overdub first, then reapplies Divide.
Changing a fader between these actions does not add a step or discard Redo.

## Accepted Decisions

The owner confirmed that Undo may remove the original recording, leaving the
track empty, and Redo can recover it. Peel must still preserve the original.
An empty track with recoverable history must remain selectable for Redo.

The owner chose “One layer at a time” when asked how Undo should handle multiple
overdub passes. Each completed pass is one layer: undoing a third pass preserves
the first two. Further Undo actions remove earlier layers in order, and Redo
restores them in order. A completed partial pass also needs its own recoverable
step. Undo restores that layer's previous recorded state, including decay of
earlier audio, rather than merely subtracting the new input.

The owner accepted Undo during overdubbing: remove the current in-progress
layer and return the track to playback, preserving earlier layers and keeping
the removed partial layer recoverable with Redo. Redo restores that captured
audio; it must not resume recording.

When asked what Undo should do during the first recording, the owner answered
“Clear it”. Undo cancels the in-progress initial take and leaves that track
empty. This settles the immediate result; it does not authorize permanent
destruction of recovery data. Preserve the existing direction that undone audio
can be recovered. The owner then chose immediate playback on Redo: recover the
captured first take and start playing it as a loop, without restarting recording.
The captured duration and any dependent tempo/length inference must be preserved
coherently. Handling a zero-audio take and cancellation of a pending recording
arm remain edge cases to specify.

On September 8, the owner clarified partial capture in Multi: once a four-bar
cycle exists, a take containing one bar of sound still belongs to a four-bar
loop. Preserve its captured position and leave unwritten portions silent. Redo
restores that loop and starts playback within the existing shared cycle; it
does not repeat or stretch the short audio, change modes, stop other tracks or
require a confirmation. The previous suggestion to recover this case in Free
is superseded. Captured duration and loop duration must be stored separately.
The first defining take, before a cycle exists, remains a separate timing case.

For Clear All, the owner requested returning to the state before the clear.
Treat Clear All as one recoverable operation: one Undo restores all affected
tracks together, including their audio/layers, lengths, timing relationships and
the playing/stopped states that Clear All changed. Preserve each track's earlier
history. Redo reapplies the clear as one operation. Restore any other state
changed by the clear; do not roll back unrelated FX or mixer edits made later.
The musical state is restored, not elapsed wall-clock time. Exact playback phase
and treatment of a recording/armed take at the instant of Clear All still need
specification. A broad snapshot must not silently overwrite subsequent work.

## Proposed Decisions

- Include overdub, track clear, Multiply, Divide and Peel alongside the accepted
  initial-recording recovery. Restore the content, retained region and
  length needed for that operation, including all recorded inputs in the track.
- Exclude transport presses, track selection, banking, mixer levels, mute,
  monitoring, FX controls, pitch, playback direction, Speed and settings from
  this pedal history. Their existing controls still govern those properties.
- Redo reapplies the operation most recently undone on that track. A new
  recorded-content edit after Undo starts a new branch and removes that track's
  forward Redo path. Edits on other tracks do not affect it.
- Show a compact target and action, such as “Track 3 · Undo Divide” or
  “Track 3 · Restore clear”. Unavailable actions are dimmed and have no effect.
  This is feedback on the existing performance view, not another confirmation.
- Changing single-track history must not accidentally start a stopped track, unmute it,
  rewind every track or restore old mixer/FX values. Emptying a track stops its
  audio. Redo of a canceled first take explicitly starts playback immediately.
  Other exact audible transitions and empty-track restoration cases still need
  specification. Clear All is the explicit grouped exception: recover the prior
  playing/stopped states it changed.
- Peel stays a deliberate removal of the latest remaining overdub, protecting
  the original. Its removal becomes an undoable edit. General Undo walks through
  recorded-content edits in order; it does not skip newer edits to find a layer.
- Do not discard history just because the performer changes function or bank,
  or saves the current work. Reload persistence, storage bounds and recovery
  after power loss must be specified with the session/recovery flow.

## Boundaries and Open Questions

1. Define recovery for Bounce and other operations involving multiple tracks,
   using the accepted Clear All rule as the proposed pattern. Recommendation:
   one operation is one Undo step. Immediately after Bounce, one Undo restores
   the destination and any source tracks changed by that bounce. Show the grouped
   target explicitly instead of implying that only the selected track will
   change. The owner subsequently accepted this grouped recovery in the Bounce study; see
   [Bounce](../design/2026-09-07-bounce-performance-ux.md).
   Subsequent edits on affected tracks must not be silently overwritten: group
   history ordering and dependencies need specification before implementation.
2. Initial-recording Undo clears the take, and Redo restores it with immediate
   playback, as accepted. Define cancellation of a pending recording arm and
   the zero-audio case. During overdub, specify the exact-boundary case where
   the new pass has no written
   audio; recommendation is to end overdub and undo the last completed layer.
   The existing engine's active-capture rejection is an implementation gap for
   the accepted overdub behavior, not a product constraint.
3. Define exact timing, transport treatment, history capacity, session lifetime
   and how restoring/replacing/importing recordings establishes a new history.
4. Reconcile local recovery labels and behavior in Multiply, Divide and Peel
   with this proposal after approval. The length study currently has its own
   history; Peel currently restores only removed layers. Neither proves a shared
   history across interleaved edits. Avoid importing Peel as a finished design
   while this interaction is under discussion.

## Reference and Current Evidence

The [Looper X guide, pages 7, 16 and 37](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf#page=16)
describes recording Undo, permanent Peel and protection of the first layer. It
does not establish a general history for arbitrary settings or length edits.

The [BOSS RC-600 parameter guide, page 17](https://static.roland.com/assets/media/pdf/RC-600_Parameter_eng04_W.pdf#page=17)
provides a current-track Undo/Redo assignment for recording or the latest overdub.
This supports an explicit track target, not the full proposed Segno history.

The [Loopy Pro manual, Peel/Replace Layers](https://loopypro.com/manual/)
documents removing and replacing clip overdub layers, including a choice between
individual cycles and an entire overdub. This is useful evidence for keeping
layer operations distinct and defining what constitutes one overdub.

Current Segno engine code has per-track Undo/Redo, recoverable clear, undo of the
base recording, per-pass snapshots and guards during active capture. Its
restoration/transport details require reconciliation with the product rule.
No native behavior was changed for this proposal.

Peel's silent prototype passes Chrome and Firefox checks for ordered layer
removal/restoration, original protection, capture guards, banking, cancellation,
Exit, reload and layout. Multiply/Divide and Fade regressions also pass. Peel's
native Pen import and final gallery remain pending this discussion; the broader
Undo proposal itself is not implemented or verified by those tests.


September 8 implementation update: the [recording recovery slice](../design/2026-09-08-capture-recovery-ux.md) implements accepted partial Multi recovery within the established cycle. Active Clear All is now a working proposal with one grouped Undo, frozen partial audio restored stopped, and failed-publication protection. Its additional behavior choices remain for review; this is not native audio or power-loss proof.
