# Measured pedal artwork

The existing pedal widget now draws the accepted tapered body, curved hinges,
rolled edges, rubber pad, trapezoid plate and thirty grips. It caches paths and
shaders without changing their coordinates. The setup map still owns the full
hit area, focus, availability, banked labels and canonical LED activity.

The four study reference files are included. This uses one existing renderer
and adds no dependency. Dynamic app labels remain intentional. Geometry,
material values and paint order match the study; exact browser raster parity
is not claimed because the existing Flutter metal gradient spans the full art
box rather than the body's tight bounds.

## Verification

The source binding in source.json covers all implementation, test, golden and
saved Pen changes. One independent reviewer completed the bug review and five
quality perspectives; a separate adversary checked actual pixels, scaling,
repaint, labels, decorative focus boundaries, all ten hit areas and LED state.
All four adversarial groups passed. A displaced actual rendition failed the
unchanged geometry oracle. No actionable findings remain.

The app suite passed 2,374 tests with six existing skips and 90.069% line
coverage (20,460 of 22,716). The source stayed unchanged during that run.
Explicit formatting, strict analysis, Bloc lint across 673 actual files and
whitespace checks passed. Nine author-machine setup goldens were regenerated
and visually checked. The running macOS app was inspected after reload.
These desktop checks do not establish hardware usability.

Pen now includes the reusable face, selected and unavailable examples, and
an implementation note preserving dynamic labels and independent LED state.
The saved section is BdRcY and the component is N7AD5. File-save and on-disk
hash were verified. Full older-canvas reconciliation remains in milestone M7.

Native, package, firmware and dependency checks are reused from the unchanged
parent scope, whose exact-head CI passed all 21 checks. This PR still needs
its own published-head CI. Merge remains a human gate; no device was flashed.
