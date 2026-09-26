# Bounce performance

Owner accepted on 2026-09-07 after trying the interactive flow and asking to lock
it in. Part of the appliance UX program, issue 919.

[Try Bounce](fx-ux-prototype.html?review=performance-bounce) ·
[Native review](bounce-previews/index.html).

## Accepted journey

Select recorded source tracks, including tracks in the other bank. Press Next,
choose one destination, then press Bounce. Choosing a destination alone changes
nothing. Occupied destinations show “Replaces existing audio” and the commit
pedal reads “Replace & bounce”. A source can also be the destination.

The same ten-pedal hardware map remains visible. Selection LEDs show sources in
step one and the destination in step two. The compact diagram carries the source
selection between banks and shows the destination before committing.

| Physical pedal | Sources | Destination | Completed result |
|---|---|---|---|
| Track 1–4 | Toggle source selection | Select destination | Readout |
| Record / Play | Next | Bounce / Replace & bounce | Unavailable |
| Stop | Unavailable | Back to sources | Unavailable |
| Undo | Recover prior bounce; hold Redo | Same | Undo whole bounce; hold Redo |
| Clear | Wrap tails / Cut tails | Keep sources / Clear sources | New bounce |
| Bank | Next four tracks | Next four tracks | Unavailable |
| Mode | Exit | Exit without applying draft | Exit with result preserved |

Keep sources and Wrap tails are the defaults. Back preserves source selection;
Exit before committing does not change audio. Every gesture resolves once, and
holding Undo invokes only Redo. Touch and encoder use the same controls. The
route diagram itself does not enter encoder focus.

A bounce is one recoverable operation. Undo restores the previous destination
and any cleared sources together, including their recorded layers, lengths and
playing/stopped state. Redo reapplies the result. Keep sources leaves those source
tracks untouched and creates a stopped destination, avoiding immediate duplicate
playback. Clear sources starts the destination if any selected source was playing;
otherwise it stays stopped. These are the behaviors of the accepted study.

## Audio target and limits of the study

The browser stores a render recipe and state; it does not mix or play audio.
The proposed render includes selected recorded tracks with their individual
track processing and mix levels, excluding live inputs and shared output effects.
Selected tracks are rendered regardless of their current transport/mute state.
A destination starts with neutral track gain, pan, pitch, reverse and fade, and
without its previous track racks, so printed processing is not applied twice.
Global processing such as output FX and whole-loop Speed still applies once
outside the bounce. Audibility, routing and render composition need native tests;
these hidden recipe details are not independently established by visual approval.

Wrap tails proposes folding effect tails across the loop boundary; Cut tails
ends them at the boundary. The UI exposes the choice, but the exact rendering
algorithm, tail budget, nonlinear/stateful FX, clipping and external plugin
handling remain implementation specifications. No audible rendering is proven.

For the fixture's integer musical beat lengths, the recipe spans a complete
common cycle of the selected tracks. Eight, sixteen and twelve beats therefore
produce forty-eight beats. Real free-time audio, mixed tempo-follow settings,
Once playback, sample-accurate phase, unbounded common cycles and render duration
selection require a deliberate production policy. The integer demo is not that
policy, nor an approved duration limit.

Tracks recording or overdubbing cannot be selected as sources or destinations;
commit rechecks every involved track. Empty tracks cannot be sources but can be
destinations. A source becoming busy leaves the draft visible and disables
commit, explaining that recording must finish first.

The current grouped history is local to Bounce. It refuses recovery if a touched
track has changed since the transaction, rather than overwriting newer work.
The complete dependency-aware history belongs to the agreed
[Undo/Redo direction](../brainstorm/2026-09-07-undo-redo-brainstorm-doc.md), which the
owner chose to move past for now. Peel and length histories also remain separate
in the silent prototype. This guard is prototype evidence, not the final recovery
UX across interleaved production edits.

Normal-URL reload preserves the bounce result and its recovery record. Review
URLs reset fixtures. No Flutter, engine, firmware or CAD code changes are included.

## Reference and validation

The [official Looper X guide, page 17](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf#page=17)
uses source selection followed by destination selection and commit, with a tail
option. Its General settings also expose whether to keep or delete sources after
a bounce. The extracted `AppUI/Pages/Footswitches/Bounce.qml` delegates to the
native page and does not define those audio semantics itself. Segno's faceplate
mapping, explicit replacement feedback and grouped recovery are its own design.

`verify_bounce_performance.cjs` passes in Chrome and Firefox. It exercises source
selection across banks, occupied and source-as-destination cases, Keep/Clear,
tail policy metadata, grouped Undo/Redo, exclusive holds, canceled gestures,
capture guards, protection from overwriting subsequent edits, Exit, normal reload
and full-size layout. Multiply/Divide and Fade regression suites also pass.
These are author-side browser checks, distinct from CI or native audio proof.
Six accepted native Pen screens use the existing reusable pedal component at
1920 × 1080; the saved gallery carries the matching verification record.
