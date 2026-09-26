# Recording on the main view

Status: interactive proposal using the accepted recording and recovery rules.
The owner authorized this connection after the main-view cleanup and then
requested that Mute remain on the same track screen.

The paired preview opens with empty tracks. Its footswitch simulator is outside
the appliance UI and uses the ten faceplate positions. Selecting a track through
a column, encoder or track pedal does not change playback. Record / Play drives
that selection through Record → Play → Overdub, or Record → Overdub → Play when
configured. Stop ends capture and stops recorded playback. Main and selected-track
displays read the same state. Mute changes the track-pedal meanings and state
colors in place; Mode returns to normal track controls without changing the view.
The earlier separate Mute screen is superseded.

Normal Record / Play and Stop act on contact. Record's configured hold then
performs Undo recording or Peel layer; this is distinct from navigation and Undo /
Redo pairs, whose short action is suppressed when holding. Track contact selects;
a pending track hold follows the corresponding position in the currently selected
bank. This contact-timing choice remains a prototype proposal for physical testing.

The simulator respects count-in, sound arming, fixed length, the second-press
choice, and per-track recording quantization. A sound button supplies a simulated
input onset. Queued feedback shows the action and boundary in the track center.
Once queued, an action belongs to that track; selecting elsewhere cannot retarget
it. Repeating Record / Play or using Undo cancels a pending action. Stop cancels
all queued capture actions. An empty input selection shows a repair message and
does not interrupt another recording.

Each completed overdub pass creates one history step; a partial pass is recoverable
too. Undo during overdub removes the in-progress layer and returns to playback.
At an exact empty-pass boundary it removes the preceding completed pass. Undo of
an unfinished first take leaves the track empty; Redo restores its captured length
and immediately plays it. Undo restores prior decay state as well as layer count.
A new content edit removes that track's Redo branch. Mixer and FX remain outside
this recording history. A track clear and the configured Peel-layer hold are
recoverable; Peel protects the original.

This is a silent model using content descriptors, not recorded buffers. Browser
checks establish interaction transitions, not sound, synchronization accuracy or
hardware timing. Existing Multiply, Divide, Peel-mode and Bounce histories still
need the separate unified-history work in the roadmap. Grouped Clear All, durable
Redo through reload, full mode conversion, external clocks and production waveform
acquisition are not completed by this slice.

Verification: `verify_stage_transport.cjs` exercises the model; the two-browser
`verify_stage_recording_journey.cjs` exercises physical-position controls, both
displays, bank changes, recovery, settings-driven queues and inline Mute.
`verify_stage_display.cjs` and `verify_pedal_performance.cjs` retain the prior view,
encoder, gesture, FX and layout checks.
