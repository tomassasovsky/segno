# Looper X Mixer reference analysis

Status: reference analysis, not approval of a new Segno layout. The owner has
accepted Segno's current Tracks view. Changes discussed here concern Mixer.

Primary source: *Sheeran Looper X User Guide*, v1.0.0, printed page 23,
section 5.4, “Mixer”. Page 11, section 4.1, clarifies the time counters and
performance colors. The supplied PDF was read and the complete page rendered
for visual inspection. Supplemental behavior below was traced in the extracted
v1.0.2 QML; it is identified separately from the guide.

## What the page does

Mixer is the third performance view of the same loop, alongside Track and Wave.
It combines four channel strips, mix controls and live signal feedback. The
audio meters remain the dominant visual element. Volume is a movable marker
over those meters, rather than a second large widget beside them.

This distinction matters: the meter shows the signal that is occurring, while
the fader marker shows the level setting. A stationary fader and moving meter
communicate different information without requiring two separate columns.

## Controls and interactions documented on page 23

| Feature | Interaction | Result and feedback |
| --- | --- | --- |
| Four track strips | Work directly within the named track's column | Track identity, mute, solo, effects, balance and level occupy the same column. |
| Mute | Tap M | Mutes that track. The illustrated active button is white. This is separate from its level setting. |
| Solo | Tap S on one or more tracks | Other tracks are muted; multiple tracks can remain soloed together. The guide explicitly says the soloed track's pedal LED turns yellow. |
| Track FX | Tap FX | The guide describes both accessing the track's effect editor and bypassing effects that are already loaded. The distinction between these two operations is not fully specified here. |
| Stereo balance | Drag the horizontal pan control | Changes the left/right balance. The image shows a center marker and values such as 22 L or 31 R away from center. |
| Precise balance | Tap the pan control, then turn the encoder | Adjusts the selected parameter more finely. |
| Center balance | Double-tap the pan control | Returns it to center. |
| Enlarged balance control | Touch and hold the pan control | Opens a larger slider. Tap its X or outside the window to return to Mixer. |
| Track level | Drag the line/arrow marker across the meter region | Adjusts the track volume. The signal meters continue to show the track's current level. |
| Precise level | Tap the level control, then turn the encoder | Adjusts the selected track's volume more finely. |
| Default level | Double-tap the fader | Returns it to 0 dB, meaning unity gain, not silence. |
| Reset mix | Tap the circular reset icon at the top right | Resets volume and panning changes across the mix. The text does not say that this clears audio, resets FX or resets mute/solo. |
| Save loop | Tap the save icon at the top right | Enters the loop-saving workflow. It saves the loop, rather than a standalone mixer preset. |

## Information visible in the page's illustration

- A compact menu icon, CPU usage indicator, loop title, reset and save occupy
  the top bar.
- Each strip has its track name, a M/S/FX row and a compact horizontal balance
  control above its meters.
- There are separate left and right signal bars, a dB scale, small peak markers
  and the volume line/arrow. Stereo activity is therefore visible directly.
- Track 4 is muted in the illustration: its M button is active and its fader
  marker is dimmed. Selection and active states are shown in place.
- Tempo, two time counters and the current loop mode occupy the bottom bar.
- The mixer illustration does not include bars/layer counts or per-track BPM.
  Segno's compact bars/layers readouts are additional design choices.

The guide's page 11 defines the two counters precisely: the left is the current
loop playback position; the right is the duration of the longest track. They
are not an elapsed-performance timer. The same section defines red for
recording, amber for overdubbing and green for playback; stopped meters turn
off. Segno's already requested elapsed-since-first-recording counter remains
a distinct product decision.

## Additional touch behavior verified in v1.0.2 source

These details supplement page 23; they are not presented as statements made by
that page.

| Element | Source-confirmed behavior |
| --- | --- |
| Track name | Tapping the heading starts the track rename workflow. Long names are ellipsized. |
| Loop title | The common top bar can start loop renaming when it is showing a nonempty loop name. |
| Menu icon | Dispatches menu navigation. A double-click callback exists, but its result lives in native code and was not established in this review. |
| Tempo readout | Dispatches tempo selection, including whether its integer portion was tapped. The native tempo workflow owns the remaining behavior. |
| Loop-mode badge | Opens the Loop Settings mode subpage. |
| Pan hold | A 1.5-second hold opens the larger pan slider; movement restarts its hold timer. The enlarged slider also supports reset to center. |
| Meter feedback | Left/right levels and peaks are separate. The drawing includes a distinct upper-range/clip treatment. Exact meter calibration and clip-hold timing are not established by QML alone. |
| Selection | Pan and volume each have a visible selected-parameter outline. |
| FX state | FX is active only when the associated effect is initialized and not bypassed. The tap delegates to a native callback. |
| Solo availability | The Solo button can be disabled by the engine's solo-allowed state. The reason and mode rules are not established here. |
| Extra channels | A global option adds Click and B.Track strips, changing four columns to six. Both have pan and level controls. Their three-button M/S/FX rows are hidden. |
| Time visibility | The current-position counter is hidden in Sync and Free; the longest-track counter is hidden in Free. |
| Phantom power | The shared bottom bar can show a +48 V indicator when enabled. It is not a mixer control. |

Source anchors, relative to the extracted `AppUI` directory:

- `Pages/Mixer.qml`: track wiring, rename, reset, larger pan control and the
  optional Click/B.Track layout.
- `Pages/Mixer/TrackBar.qml`: channel layout, M/S/FX, stereo meters, volume
  marker, parameter selection and gesture dispatch.
- `Pages/Mixer/VolumeNew.qml`: meter, peak and scale drawing.
- `Pages/Mixer/MuteSoloFXButton.qml`: selected and unavailable button appearance.
- `Pages/Mixer/Header.qml`: tappable name and ellipsis.
- `Pages/Common/PanSliderNew.qml`: balance drawing, relative drag, hold timer
  and double-tap.
- `Pages/Common/TopBar.qml` and `BottomBar.qml`: common navigation, saving,
  title, tempo and loop-mode entry.

## Gaps in the current Segno Mixer draft

The current prototype has four tracks from the active bank, names, bars,
layers, a read-only FX indicator, mute, pan, volume, simulated signal level and
playback progress. Touch, encoder adjustment and double-tap defaults work.
Selection and mix values share the same session as Tracks and Wave.

| Reference capability | Current Segno Mixer |
| --- | --- |
| Fader integrated with stereo meters | Separate large fader beside one aggregate simulated meter. The composition still differs materially. |
| Per-channel stereo level and peak feedback | No independent L/R meters or separate peak markers in this view. |
| Level expressed in dB, with unity reference | Volume currently reads as a percentage. |
| Multi-track Solo | No Solo control in the visual Mixer. |
| FX access and bypass | Only a status indicator in the track heading. |
| Mixer-wide volume/pan reset | No direct Mixer reset. |
| Save from Mixer | Uses the shared Library/session flow; no dedicated save action in this top bar. |
| Rename a track here | Tapping its heading selects it; it does not rename it. |
| Enlarged pan popup | Not present. Direct editing was previously chosen for Segno, so this need not be copied automatically. |
| Click and backing audio in the mix | Not shown in the visual Mixer. The earlier foot-operated Mixer has a separate accepted input/track workflow. |

## Design conclusion

The most useful pattern to adopt is one compact, complete channel strip:
identity and essential state, Mute/Solo/FX, balance, then stereo meters with an
integrated volume marker. That provides more information with less competing
geometry. Preserve Segno's four-tracks-per-bank behavior, selected-track waveform
on the small display and accepted Tracks view.

Before implementing further Mixer behavior, define FX editing versus bypass as
distinct, predictable actions; multi-solo interaction with existing mutes; and
the scope/recovery of Reset mix. Keep gain in dB distinct from signal level in
dBFS. Do not infer these details from ambiguous manual wording or copy the
smaller display's enlarged-slider popup without a usability need.

This reference review does not approve new control behavior or modify the
accepted Tracks view.
