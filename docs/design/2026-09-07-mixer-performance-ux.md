# Mixer performance

Owner accepted the single-channel Tracks / Inputs flow on 2026-09-07, after
reviewing the main prototype. Part of appliance roadmap issue 919.

[Try Tracks](fx-ux-prototype.html?review=performance-mixer) ·
[Try Inputs](fx-ux-prototype.html?review=performance-mixer-inputs) ·
[Eighteen inputs](fx-ux-prototype.html?review=performance-mixer-many-inputs).

## What the volume controls

- **Tracks:** the playback level of one recorded loop. Changing this does not
  rewrite the audio already recorded or change the capture level.
- **Inputs:** the live-monitor level of one input. Changing or muting this branch
  does not change the signal sent to a new recording, current recording state,
  existing loop playback, or the input's FX placement and settings.
- Capture level is a separate audio-setup control. The production routing must
  split monitoring from recording before this live volume and mute stage.
- Input monitoring still respects the accepted On / Auto / Off policy. A Mixer
  mute is an additional temporary audibility state, not a replacement for Auto.
  Unmuting preserves that policy and the chosen volume. An automatically closed
  input reads **Auto · Live off**. The Effects page also reports **Muted in
  Mixer** when this is the reason a live input cannot be heard.

## Foot journey

The ten-pedal faceplate and reusable hardware widget stay in the accepted A
layout. Clear and Bank remain above the front row.

| Control | Press | Hold |
|---|---|---|
| Custom pedal assigned Mixer | Enter Mixer | Its separately configured action |
| Four channel pedals | Select that channel for volume adjustment | Mute / unmute that channel |
| Undo | Volume down | Reset selected volume to 100% |
| Clear | Volume up | Reset selected volume to 100% |
| Bank | Next four channels, wrapping at the end | Switch Tracks / Inputs |
| Mode | Exit to normal track controls | No additional action |
| Record / Play | Dispatch the current transport track's recording sequence | No additional action in this flow |
| Stop | Stop all recorded tracks | No additional action in this flow |

Only one channel is selected. Pressing it again keeps it selected. Entering
Mixer starts on the current recorded track, or the first recorded track if the
current track is empty. Paging selects the first available channel in that
page; changing Tracks / Inputs starts at the first available channel. Mixer
pages are local to Mixer and do not change the track/FX performance bank on Exit.

A channel's LED represents selection for adjustment. Muting has its own visible
label and subdued level bar; it does not erase the level or imply that playback
has stopped. Empty recorded tracks and unused positions in the last input page
are disabled. Inputs remain available even when the loop contains no recordings.
The Bank caption gives the actual range, including **Inputs 17–18** for eighteen
inputs. The selected channel's larger readout gives the volume context explicitly.
The level bars represent volume settings, not fabricated signal meters.

The rendered prototype uses five-percentage-point steps, track levels 0–200%,
and live-monitor levels 0–100%. 100% is unity. A step beyond either endpoint has
no effect; holding either volume pedal still resets to 100%. No auto-repeat.
Mute and reset remain separate: resetting volume never unmutes a channel.

Short presses act on release. The 800 ms hold consumes release, so muting does
not also select a channel and resetting does not also step its volume. A pending
channel hold follows the newly visible channel if Bank changes before it fires,
as requested for pending track holds. Changing Tracks / Inputs or leaving Mixer
cancels pending gestures; it cannot accidentally mute a source in another view.
Touch and encoder reach the same channel and source choices. The complete
performance journey remains possible by foot.

## Shared state and evidence

Track and input levels use the same gain owner as expression and external-button
Volume targets in the main prototype. Whole-track targets expose the 0–200%
range through their normalized descriptor; live-input, per-input recorded-part,
recorded-mix and output targets keep their existing ranges. Mute and Mixer use
the same recorded-track mute state. Input mute is stored separately from recorded
track mute. Gains and mute states survive Exit and normal-URL reload; temporary
selection and Mixer mode do not. Review URLs use repeatable fixtures.

`verify_mixer_performance.cjs` exercises foot entry, single selection, independent
track/input levels, mute and reset, paging through eighteen inputs, empty tracks,
limits, pending-gesture cancellation, Auto monitoring, shared expression targets,
transport intents, persistence, and layout in Chrome and Firefox. It waits for a
hold to complete before releasing; a host-side fixed delay alone proved flaky in
Firefox. The existing Transpose, pedal-performance and external-control checks
cover the shared integration paths separately.

Native Pen frames match the 1920 × 1080 browser geometry and reuse the existing
pedal component. Acceptance and visual evidence are tracked in
[mixer-previews](mixer-previews/index.html).

This remains a silent interaction study. No production audio routing, smooth
gain ramps, input capture separation, physical footswitch timing or appliance
session recall is proven by browser state or Pen. Those are implementation and
hardware validation requirements.

## Reference

The extracted [Looper X Mixer](../research/sheeran-looper-x-1.0.2/features.md#f04--three-performance-views)
uses distinct level, pan and mute controls. Its per-channel balance view informs
this design. Segno's one-channel foot workflow, live-input branch and ten-pedal
mapping are its own accepted design; the remaining pan, solo, click/backing and
output-mix journeys are not implied to be complete by this slice.
