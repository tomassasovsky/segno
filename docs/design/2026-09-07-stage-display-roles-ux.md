# Main Stage and display roles

Status: revised proposal, informed by the owner’s corrections on 7 September.
The previous eight-card grid and generic small-screen readout were rejected.
Their Pen frames are in Superseded. They are not the redesign target.

## Direction

The main 15.6-inch display shows the active bank: tracks 1–4 in A, 5–8 in B.
Start from Segno’s existing tall columns and solid level bars, not a dashboard.
Use the existing transport palette: green playback, red recording/overdub,
white stopped/muted audio, and dark empty tracks. A white column border marks
selection. Encoder focus remains a separate amber outline. Names and compact instrument readouts sit above the meters, following the
owner’s supplied Looper X image. Thin progress bars at the bottom show loop
position. Longer names have two lines without reducing text size. Routine status
words are omitted from the main track faces; state remains in accessible labels.
A queued action appears in the center of its meter or waveform, with its action
and timing, for example “Record” and “Next bar”. It is a readout, not another
encoder target.

Track, Wave and Mixer are alternate presentations of the same session, reached
through a view icon in the top bar. They are not persistent tabs in the meter
area. Library and Settings use icons with accessible names. The bank indicator
also changes bank. Browsing views and selecting a track do not change playback.
Mixer edits use the same track levels, pan and mute as the existing foot Mixer
and expression targets; they do not create another mixer state.

The owner prefers the selected track’s waveform on the seven-inch screen, with
the broader view on the main screen. The close-up shows its name, state, phrase
length and playback position. Tempo and current pedal mode/bank stay secondary.
The prototype keeps that selected-track readout while using Settings or FX.
Bank changes show the other four tracks without silently changing selection;
this detail remains proposed. Selecting a track changes the close-up. An empty
track shows an empty state, not a fictional recorded waveform.

The small screen is a readout in this proposal; encoder focus stays on the main
page. No new cross-screen navigation or waveform editing is implied.
The subsequent Wave slice adds an explicit waveform-view pedal assignment. Existing foot-only performance modes retain their accepted layouts.

## Instrument readouts

Each track shows bars, layers and a compact FX indicator. Per-track BPM and
numeric dBFS were removed at the owner’s request; they repeat information
already available in the session footer and side meter scales. FX is
bright when at least one of that track’s assigned racks is active, dim when all
are bypassed, and absent when none are assigned. This does not indicate shared
output effects or effects already printed into earlier recordings.

The meter uses a shared -60 to 0 dBFS scale on both sides of the four columns.
A red cap marks track clipping. Stopped tracks retain a representative
level in white; an empty track has no meter fill. The production target should
meter the track after processing, before output summing. The footer also reports
output peak/clipping, because summing can clip even when individual tracks do not.
Clipping is only an indicator; no limiter or protection is implied.

The footer holds session BPM, time signature, elapsed time since the first
recording, and loop mode. CPU usage stays compact at the top left. CPU, levels
and elapsed-time origin are fixture data in this silent study; production
telemetry and clock lifecycle remain implementation work. Internal tempo-follow
and Speed values still drive each progress bar, without adding another BPM label.

## Evidence

- Current Segno: `lib/looper/view/track_column.dart`,
  `lib/looper/view/track_meters.dart`, and `lib/theme/app_theme.dart` establish the
  column structure, solid meters, names below them, state colors and selection.
- Looper X: `Pages/Track.qml`, `Pages/Timeline.qml`, and `Pages/Mixer.qml`, indexed
  in the [screen research](../research/sheeran-looper-x-1.0.2/screens.md), establish
  Track, Wave and Mixer. The owner supplied a product image showing the Track
  view’s four prominent meters and compact navigation.
- Enclosure apertures put the seven-inch display to the left of the larger
  display; the paired study preserves their approximate relative size. The
  preview does not establish native panel resolution or physical readability.

## Review and validation

[Try the two displays](stage-two-screen-preview.html), or open the
[main Track view](fx-ux-prototype.html?review=stage-layout).
Wave and Mixer are under the columns icon. Recording, overdub and queued
scenarios are selected outside the appliance UI.

The [interactive recording flow](2026-09-07-stage-recording-ux.md) now connects
the accepted capture and recovery rules, including quantized transitions and
Mute on the same columns. It remains silent: meters and capture are simulated;
waveforms use real reference recordings. Real capture, audio-clock execution,
shared edit history and device validation remain implementation work.
The settled recording and Undo/Redo requirements remain unchanged.

The verification script exercises bank filtering, shared selection, view changes,
shared mixer edits, encoder cancellation, double-tap reset, small-screen waveform
selection, empty/capture states and continuity through Settings and FX. It also
checks that track faces omit duplicate readings and routine status words, and
that queued feedback is centered only on the affected track. Browser
and native Pen results are recorded in the preview manifest after verification.

[Wave performance refinement](2026-09-07-wave-performance-ux.md) adds bar landmarks,
layers and FX metadata, shared capture growth and direct foot entry to the same
view. The owner accepted this Wave refinement; production capture remains open.
