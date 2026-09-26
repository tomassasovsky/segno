# Reverse performance

Part of appliance roadmap issue 919. The owner accepted the complete Reverse layout and behavior on 2026-09-07: immediate
reversal at the current playback position and a small Reverse marker in normal
Tracks. Mixer remains focused on level and mute. The accepted screens are saved
in the main prototype and Pen.

[Reverse](fx-ux-prototype.html?review=performance-reverse) ·
[Bank B](fx-ux-prototype.html?review=performance-reverse-bank) ·
[Tracks marker](fx-ux-prototype.html?review=performance-reverse-stage).

## Foot interaction

Enter using a custom pedal's Reverse assignment. The default Custom layout has
Reverse on the Track 1 position's Hold; its Press still enters Transpose. Entry
consumes the held gesture, so releasing it cannot reverse Track 1 by accident.

The four track pedals toggle their corresponding recorded tracks between Forward
and Reverse. Bank exposes Tracks 5–8 and returns to Tracks 1–4. The direction
changes once on pedal down; holding, key repeat and release do not toggle again.
A release after changing banks or leaving the view cannot affect another track.

The LED is lit when its track is reversed. Direction text and an accompanying
left/right icon identify the state without relying only on light or color.
The overview shows all eight tracks, including states outside the visible bank.
Empty tracks are dimmed and unavailable. Undo and Clear are unused and dimmed in
this workflow; they cannot accidentally delete or remove recorded material.

A second press restores Forward. Mode exits directly to normal Tracks without
resetting direction. Record / Play addresses the current transport track; Stop
addresses all recorded tracks. Toggling a stopped track's direction does not start
it. Touch and encoder can operate the same pedals, while the full performance
journey remains possible by foot.

## Musical behavior

Reverse is non-destructive playback direction for a recorded track. The original
recording remains intact. The intended engine behavior changes traversal direction
at the current position, without restarting the loop, changing loop duration,
playback speed, pitch, volume, mute, live monitoring or effect settings. It does
not reverse a live input. A stopped track retains the selected direction for its
next playback. Existing recording and overdub state is not stopped by the control.

This UI records the desired direction. Continuous position-preserving playback,
transition smoothing, sync with other tracks, one-shot completion, and overdub
writes against a reversed playhead need native audio implementation and listening
tests. The source extraction does not establish those exact Looper X behaviors.

## State outside Reverse

Normal Tracks shows a small **Reverse** marker only on reversed recorded tracks.
This is a readout, not a second direction editor or encoder target. Mixer does
not gain another control or repeated direction label. The current normal Tracks
pedal controls are still silent placeholders; adding the marker does not claim
that normal record/play dispatch is fully implemented there.

Direction is saved with each prototype track and survives Exit and normal-URL
reload. The performance mode resets to Tracks on reload. Review URLs use
repeatable fixtures. Clearing/removing recordings in the production app must
clear obsolete direction state as part of the track lifecycle.

## Reference and validation

The extracted [Looper X function path](../research/sheeran-looper-x-1.0.2/ux-paths.md#ux13--reverse-change-speed-or-transpose)
confirms normal/reverse states and track controls, while exact switch timing and
recovery remain native. Segno adopts the direct per-track interaction, using its
own ten-pedal faceplate and the approved timing/visibility decisions above.

`verify_reverse_performance.cjs` checks held custom entry, immediate single
changes, release after bank/Exit, empty tracks, LEDs, the Tracks marker,
independent transport/capture/pitch/level/FX state, persistence and layout in
Chrome and Firefox. Shared Transpose and Mixer checks remain green. Browser
state and native design images do not establish DSP quality or physical timing.

[Native review images](reverse-previews/index.html) preserve the 1920 × 1080
geometry and reusable pedal component. The owner accepted these frames; browser and design verification remain separate
from production audio and appliance validation.
