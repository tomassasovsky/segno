# Virtual instruments — integrated UX proposal

September 9, 2026 · Issue 919 · Proposal for owner review.

[Open Instruments](fx-ux-prototype.html?review=instruments). Normal startup stays
in Tracks. Open Settings → Audio routing → Instruments to edit the saved
session rather than a review fixture.

The owner requested a larger catalogue, the accepted main theme, and recording
through ordinary Tracks controls. This replaces the isolated instrument recorder.
The instrument page now edits sound, controllers and live monitoring. Instruments
appear alongside physical inputs in Recording inputs, live output routing and FX.
They do not occupy physical jacks and cannot be paired as hardware stereo ports.

The sound set contains 19 specified Segno synthesis patches in seven families:
Keys, Organs, Synths, Bass, Strings, Drums and Percussion. Each family has three
meaningful parameters and distinct artwork. This is a synthesized target set;
native hosting and production sample content remain separate implementation work.
Sound browsing offers temporary audition, Apply/Cancel, and unavailable-pack
install/retry without changing the saved patch on failure.

Played by independently enables MIDI input and computer keys. MIDI uses the
shared port inventory, All or specific channel, and an optional note range.
Explicit note/pad mappings add fixed routes. Selecting an instrument changes the
editor, never its controller routing or another instrument's notes. New inputs
start without enabled controllers; the examples separate keys and pads by channel.

Pedals & controls shows shared assignments and links to built-in pedals,
External pedals and MIDI controls. Notes/chords, Sustain and sound parameters use
those existing editors, with stable target identities. The old separate CTRL 1
instrument assignment popup is removed. Held and Latch remain distinct; invalid
Press/Hold combinations explain why they cannot save.

Computer mappings are explicit rows, including defaults. Learn a source, then
play the desired notes/chord through MIDI, enter a MIDI note number, or use the
touch keyboard. MIDI remaps remain under MIDI input, with atomic outer Done/Cancel.
Channel and note ranges support touch, keyboard and encoder editing. Octave paging
only changes the touch keyboard's visible range, never incoming keyboard pitches.

Sustain supports While held and Latch. Released keys ring until all sustain
sources release; repeated strikes remain separate voices. CC64 uses the standard
threshold unless explicitly remapped. Pitch bend, modulation and channel pressure
reach the instrument runtime. Shared Cut all sound, device disconnect and control
retirement release the appropriate voices. Selection and navigation keep playing.

Remove instrument has an explicit confirmation. It removes the instrument, its
live input effects and future recording/output routes, while preserving recorded
loop content and its source name. Removal is blocked while recording from that
instrument. Cancel or a failed save leaves the setup intact. Removing the last
instrument leaves an Add instrument empty state. Existing references to a removed
FX use the prototype's existing missing-target recovery behavior.

## Normal recording journey

1. Add an instrument and set its sound and controllers.
2. In Recording inputs, select a track and choose the instrument as a source.
3. Return to Tracks and use the normal record/play pedal.
4. Playing the instrument starts a track armed to wait for that source's sound.
   Ending the recording uses the existing loop mode and timing rules.
5. The recorded source appears in that track. Hear Live, live level, output
   routing and input FX use the shared state, rather than a second recorder.

Sessions capture instrument definitions, mappings, sustain settings and routes.
New Loop retains the instrument setup while clearing recorded tracks. Recall
restores it; connection recovery recognizes internal instruments without asking
for nonexistent physical jacks. Saved state survives browser reload.

The Tracks meter is one full-width whole-track level. Its accidental horizontal
offset in Firefox was corrected; stereo channels remain in Mixer.

## Verification and boundaries

The integration, custom-note, sustain and instrument-management journeys pass in
Chrome and Firefox. They cover navigation, catalogue families, controller toggles,
release behavior, shared monitoring/FX/output routes, normal recording state,
New Loop, session recall, removal, failed saves, empty-library recovery, all MIDI
pitches and scaled layouts. Focused transport, session ownership and audio-port
repair checks also pass. These are local prototype checks, not appliance evidence.

Live instrument synthesis is audible in the browser. Recording and loop playback
in Tracks use the existing simulated transport; native audio insertion, Linux
instrument hosting, physical MIDI/pedal delivery and physical output dispatch
are not implemented. Browser audio goes to the browser output. The browser runtime routes simultaneous sources to fixed instruments independently
of the selected editor, using the shared MIDI and pedal assignment system.

Editable Pen references are grouped under Virtual instruments. The
[full UX review](2026-09-09-instrument-ux-review.md) records closure of all eight
prototype findings. Five independent reviews and the complete Chrome/Firefox
journeys cover the revised interaction. The owner accepted the revised instrument UX. Native hosting and physical-device
validation remain separate production work.
