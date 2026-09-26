# Performance gesture feedback

The existing ten-pedal layout already exposes current Press and Hold assignments.
This proposal adds feedback at that same location, without another overview,
help overlay or focusable control. The owner responded positively to the preview;
the added visual treatment remains a proposal until explicitly locked in.

While a Hold is pending, a thin blue progress line fills below the pedal face and
the existing Hold caption brightens. The cue uses the actual gesture start time,
so a redraw or bank change does not restart it. It disappears when the hold fires,
is released early or is cancelled. The proposed threshold remains 800 ms.
The amber outline remains encoder focus. The LED continues to show function state.

FX contacts visibly depress the pedal until release. A momentary caption brightens
while held; a latched function keeps its LED after release. Mixed and inverse
assignments retain their existing logical-state rules. A bank change displays the
new bank's contact state, while release still clears the original logical FX slot.
Pending track holds continue to follow the newly selected bank, as requested.

Chrome and Firefox checks cover progress at fixed times, short-press/hold
exclusivity, cancellation, focus loss, reset, unchanged geometry/focus count,
bank retargeting and momentary release after Bank or Exit. Existing performance,
external-function and Tuner regressions also pass. This is silent prototype evidence;
physical timing and audio remain appliance checks.

The four browser/Pen comparisons are in the
[feedback gallery](performance-feedback-previews/index.html). Two gesture states
fill the unused spaces in the existing performance section; Tracks and FX
references are refreshed. No section moved or grew. Native checks report 72 text
nodes, 184 elements and no alignment or section-overlap errors.
