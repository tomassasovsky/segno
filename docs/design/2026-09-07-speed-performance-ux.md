# Speed performance

Part of appliance roadmap issue 919. The owner accepted the complete whole-loop Speed design on 2026-09-07,
including its layout, absolute choices, pitch coupling, Normal reset and physical
mapping. The owner confirmed that it applies to all tracks and is separate from
Multiply and Divide, which change length.

[Try Speed](fx-ux-prototype.html?review=performance-speed) ·
[Half speed](fx-ux-prototype.html?review=performance-speed-half) ·
[Fast speed](fx-ux-prototype.html?review=performance-speed-fast) ·
[Native review](speed-previews/index.html).

## What Speed changes

Speed multiplies recorded playback rate and changes its pitch with that rate.
It applies one multiplier to all recorded tracks, preserving their relative
timing. Live inputs, click and backing audio are outside this recorded-loop
control. Their routing, monitoring and levels remain unchanged.

The four track-pedal positions select **½×, 2×, 4× or 8× normal speed**. These
are absolute choices, not repeated multiplication commands: pressing 2× twice
leaves the loop at 2×. Undo returns the multiplier to **1× Normal speed**.
The accepted range is therefore ½×–8× with those discrete choices. This avoids
accidental compounding and makes each press's result visible before acting.

| Speed | Pitch change from Speed | Duration relative to normal |
|---|---|---|
| ½× | −12 semitones | Twice as long |
| 1× | None | Unchanged |
| 2× | +12 semitones | Half as long |
| 4× | +24 semitones | One quarter |
| 8× | +36 semitones | One eighth |

The readout shows this function's contribution. Existing Transpose offsets remain
independent and are not erased by Normal speed. Normal means a multiplier of 1
on whatever automatic tempo following is configured, not a reset of every audio
setting. The readout does not claim to calculate each track's total pitch shift.

**Audio & tempo** still owns automatic response to song-tempo changes. Speed adds
an explicit tape-speed factor without editing Follow tempo, Keep pitch, song BPM,
time signature or MIDI-clock configuration. Tempo-linked pitch preservation does
not cancel this deliberate tape-pitch effect. With Follow tempo off, manual Speed
still works; “Original speed” in that settings context means independent of song
tempo. The settings wording must keep that distinction clear when implemented.

**Multiply and Divide** are [separate length functions](2026-09-07-length-performance-ux.md)
for repetition or retaining a chosen half. Speed does not append repetitions, truncate the recording or rewrite
the source audio.

## Pedal journey

The default Custom layout exposes Speed on the Track 4 position's Hold, alongside
Mixer on Press. Holding enters Speed without briefly entering Mixer; release
cannot then choose 8× at the same physical position.

| Physical position | Action in Speed |
|---|---|
| Track 1–4 | Select ½×, 2×, 4×, 8× respectively |
| Undo | Normal speed, 1× |
| Record / Play | Current transport-track intent |
| Stop | Stop all recorded tracks |
| Mode | Exit directly to normal Tracks |
| Clear, Bank | Unused and dimmed |

Speed selection and Normal reset act once on pedal down. Hold, key repeat and
release never change speed again. Only the selected speed's LED is lit (Undo at
1×); Mode retains its Exit indicator. There is no bank because the choices address
the whole loop. Empty loops disable speed and reset; Exit remains available.

Changing speed does not start a stopped track, stop recording/overdub or change
levels, mute, Fade, Reverse, Transpose or FX settings. Exit and Stop retain the
selected speed. Normal Tracks shows a read-only Loop speed value when it is not
1×, so the retained change is visible after leaving this workflow. That readout
is not another editor or encoder focus target.

## State and audio boundary

The prototype persists one loop-speed multiplier. Normal-URL reload restores it
and returns the performance mode to Tracks. Review URLs use fixtures. Removing
all recorded material in the production app must clear obsolete speed state.

The intended native behavior applies the ratio continuously at the current
playback position, without restarting or rewriting tracks. It composes with
automatic tempo following, independent pitch offsets, Reverse, Fade and gain.
The UI does not implement that audio pipeline. Click-free transitions, sample
rate limits, timing of overdub writes, one-shot boundaries, FX tails, clock
interaction and behavior at high ratios need native work and listening tests.

## Reference and verification

The [official Looper X guide, Functions B, page 17](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf#page=17)
describes Speed as affecting both playback rate and pitch across the full loop,
with half/double/four/eight controls. It describes Multiply separately as a length
operation. The extracted `Pages/Footswitches/Speed.qml` exposes a Current speed
readout driven by native state. Neither establishes Segno's accepted absolute
selection policy, Normal pedal position or transition details.

`verify_speed_performance.cjs` exercises Chrome and Firefox: held entry, absolute
rate selection, pitch/duration feedback, Normal reset, LEDs, independent musical
state, Stop/Exit, empty loops, normal reload and 1920 × 1080 layout. Existing Fade,
Mixer and Reverse checks are rerun after shared performance changes. Native Pen
exports use the reusable hardware component and verified browser text geometry.
These are author-side silent UX checks, separate from CI, audio and hardware proof.
