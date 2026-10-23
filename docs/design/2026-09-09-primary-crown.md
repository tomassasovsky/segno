# Primary-track crown

September 9, 2026 · Issue 919 · Owner-requested prototype refinement.

A crown beside the track name identifies the primary recording. The first
completed take establishes that identity; selecting a different track or
recording a lower-numbered track later does not move it. An explicit timing
handoff updates the crown. An empty session has no crown.

The same marker appears in Track, Wave and Mixer. It is available in every
loop mode and represents the existing primary identity; this display change
does not change how the modes synchronize tracks. The small display shows the
crown only when its selected track is primary. Bank changes never create a
second crown. The icon is a readout, not another encoder destination.

Chrome and Firefox checks cover first recording on Track 3, later recording
on Track 1, selection, bank changes, all three views, reload and the small
display. The existing timing-handoff and preset-audition journey also passes.

The main prototype and shared display assets are updated. The final handoff pass
refreshed all four editable Pen display frames from current browser geometry,
including the whole-track meter and selected-track crown. Native text bounds,
representative screenshots and File → Save are verified in the
[handoff evidence](../handoff/segno-app/pen-verification.json). Fresh browser
screenshots and editable geometry remain in `primary-crown-previews/`.
