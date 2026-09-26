# Wave performance view

Status: owner accepted on 2026-09-07 after reviewing the continuous waveforms
and revised metadata spacing. The four-track bank and selected-track small
display are retained. This locks the design, not production audio integration.

Wave uses four horizontal lanes. Each lane shows its name, bars, layers, FX
indicator and waveform. Bar landmarks locate the phrase; the playhead locates
current playback. Each finished loop fills its own lane, so equal visual width
does not imply equal duration. Labels make that distinction visible.

The selected track uses the same waveform span and playhead on the small display.
An empty track has no invented recorded waveform. During the first recording,
the captured portion grows into an initially four-bar window. A longer take
expands that window in four-bar steps. A fixed-length take uses its chosen
length. Closing the take fits the completed phrase across the lane. During
overdub, the existing loop remains visible and the established red state applies.
Waveforms now use measured minimum/maximum peaks from real reference recordings,
rendered as continuous envelopes on both displays. They replace the invented,
spaced bars from the first draft. Bars and layers have explicit internal and
inter-group spacing; FX is aligned to the right of the track label area.

The [reference source and reproducible extraction](waveform-reference/README.md)
are documented separately. These samples demonstrate the target presentation;
they are not live input or audio from the prototype's named tracks. Recording
reveals the reference envelope progressively. Production must still project each
track's real buffer, layers and edits into peak data.

Touch selects a track without seeking or changing playback. The view menu stays
in the top bar. A configurable built-in, external or MIDI action can also open
Wave; it restores normal track pedal controls rather than entering another
pedal-editing layer. The explicit Track action returns to columns. Other mode
exits preserve the chosen performance view. Existing bank behavior is unchanged.

The silent transport now moves reversed playback from its current position in
the opposite direction. Once stops at the appropriate boundary, including when
Speed changes traversal time. This completes the visible cursor behavior; it is
not an audio-engine implementation of reverse or time stretching.

Looper X `Pages/Timeline.qml` and its `Timeline.Header` / `Timeline.Waveform`
components provide the reference for four lanes, bars/layers, effect indication
and playback cursors. The [source research](../research/sheeran-looper-x-1.0.2/features.md)
found a performance display with empty-track import. It did not establish a DAW
editing workflow. Segno's existing Library → Use in loop path remains available;
a destination-first import shortcut and production waveform projection remain
open. No trimming, destructive seek or region editing is added here.

[Try both displays](stage-two-screen-preview.html?review=stage-layout-wave).
Choose Try recording for an empty session; Wave is available through the view
icon, and the small display follows recording in either main view.

`verify_wave_performance.cjs` passes in Chrome and Firefox: foot assignment and
entry, normal recording controls, growing and closed-loop spans, shared position,
empty selection and bank changes. The general display, recording, pedal and
external function suites pass; external assignments now expose 40 choices,
including Wave and the four general recording/history commands. The revised native Pen checks are recorded in the display gallery manifest. Changes update
the existing Wave, small-display and paired references, keeping the current
canvas organized rather than adding another competing main-screen proposal.
