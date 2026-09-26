# Fade performance

Part of appliance roadmap issue 919. The owner accepted the complete Fade layout and behavior on 2026-09-07,
including a shared fade-time default with per-track overrides, physical mappings,
time range, retrigger behavior and recovery. This is a
silent prototype, not production audio or physical-pedal verification.

[Try Fade](fx-ux-prototype.html?review=performance-fade) ·
[Track override](fx-ux-prototype.html?review=performance-fade-custom) ·
[Bank B](fx-ux-prototype.html?review=performance-fade-bank) ·
[Native review](fade-previews/index.html).

## Performing

Enter Fade through its Custom assignment, initially the Track 3 position's Press.
Tap a recorded track to fade out; tap again to fade in. The four positions follow
Bank A/B. A tap takes effect on release, leaving Hold available to select that
track's time without also starting a fade. Holding fires once at the shared
800 ms prototype threshold; releasing a completed hold does nothing else.

Each track has an independent fade envelope. Pressing again during a fade reverses
from its current amount, without jumping. The configured time is for a complete
0–100% traversal: reversing halfway takes half that time at the same rate.
Several tracks can fade concurrently. Editing a duration applies to the next
gesture, including a retrigger; it does not alter an already-running fade.

The progress bar represents the fade amount relative to the saved Mixer volume.
The LED is lit while fading or faded out and goes dark when fully restored.
It does not claim that a stopped or muted track is audible. Empty tracks are
unavailable. A fade never starts or stops transport and never changes recording,
overdub, mute, pitch, direction, live monitoring or FX settings.

Stop stops loop playback while retaining fade state; it does not reset the
envelope. Exit returns directly to normal Tracks, with ongoing fades continuing.
Mixer keeps its saved volume and shows a separate Fading/Faded out readout when
attenuation would otherwise make that volume misleading. Inputs are outside this
Fade workflow and retain their live-monitor levels.

## Setting times by foot

The accepted default starts with a four-second shared default and supports 0.5–30 seconds
in half-second steps. Entry selects the default time. Each track shows its effective
duration in the overview, including tracks in the other bank.

| Physical control | Tap | Hold |
|---|---|---|
| Track 1–4 | Fade the corresponding track in/out | Select that track's fade time |
| Undo | Shorten the selected time | Use the shared default for this track; reset to four seconds when editing the default |
| Clear | Lengthen the selected time | Same reset behavior as Undo |
| Bank | Show the other four tracks | Select the shared default time |
| Record / Play | Current transport-track intent | None |
| Stop | Stop all recorded tracks | None |
| Mode | Exit to normal Tracks | None |

The large time readout names its target and distinguishes Custom from Uses default.
Adjusting an inherited track time creates its override. Restoring the default
removes that override: subsequent default edits follow automatically. Other tracks'
overrides remain intact. Selecting a time does not change playback or fade state.

The pending hold follows a bank change until activation, as the owner requested
for track controls. Once activated, release cannot affect another track or start
another fade. Leaving the workflow cancels unfinished gestures. Time selection is
temporary and returns to the shared default on the next entry.

## State and audio boundary

The prototype stores default time, explicit track overrides and a separate
timestamped envelope per track. Its envelope remains independent of Mixer gain
and mute. Settings and envelope targets survive normal-URL reload; elapsed time
continues in the simulation, so a fade whose end time passed is complete on reload.
Review URLs use repeatable fixtures and do not overwrite saved work.

The native target is a smooth playback gain envelope before downstream Post/output
processing, so existing delay and reverb tails can complete. It must not rewrite
the recording, reduce input capture gain, or destroy the user's saved mix level.
The browser uses a linear coefficient and wall-clock time only to show progress.
Sample-accurate ramps, the audible curve, clicks, tails, session restore policy and
hardware timing need production design/implementation and listening tests. Removing
recorded material must clear obsolete fade state with the track lifecycle.

## Reference and verification

The extracted Looper X `Pages/Footswitches/Fade.qml` shows a per-track fade time
derived from track length and a shared fade rate. Its native event handling does
not establish retrigger semantics. Segno's default with per-track overrides is an
owner decision; seconds, the range and the physical mappings are owner-accepted
Segno decisions. See [reference path](../research/sheeran-looper-x-1.0.2/ux-paths.md#ux14--fade-multiply-or-extend-material).

`verify_fade_performance.cjs` exercises actual controls in Chrome and Firefox:
entry, tap/hold arbitration, default inheritance, overrides, reset, continuity
when reversing, bank changes, Exit, Stop, empty tracks, independent mixer/mute
state, reload and 1920 × 1080 layout. The native Pen frames use the established
reusable pedal component and browser text positions. Author-side checks remain
separate from CI and appliance verification.
