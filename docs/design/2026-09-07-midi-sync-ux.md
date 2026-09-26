# MIDI clock and external sync

Status: owner approved the design direction on 7 September and asked to move on.
This approval is not a claim of real-device timing validation. Programme: #919.

## Setup and performance

Settings → MIDI → Sync sits alongside Controls. Tempo source is Internal or a
connected MIDI device. Learn mappings and clock selection use the same device
list. Sync does not consume a controller mapping or depend on a MIDI channel.

With an external source, the tempo readout shows Waiting until clock arrives,
then Synced. A short pulse indicates quarter-note clock activity. It does not
claim bar alignment. The main performance header provides a compact sync status
and a direct return to this page. The local tempo slider and Tap are unavailable
while another device owns tempo. Time signature, count-in and fixed recording
length remain local, subject to the usual recording and Multi-mode locks.

Follow Play / Stop is independent of tempo following and defaults to Off.
When enabled, Start restarts recorded tracks, Stop retains their positions,
and Continue resumes the tracks paused by Stop. Repeated Stop does not erase
that resume set. A pending recording survives Start; Stop cancels pending starts
and closes an in-progress take as recoverable, stopped audio.

If clock is lost, Keep playing continues at the last known tempo. Stop loops
pauses playback without deleting audio. Reconnecting restores tempo following
but never starts stopped loops by itself. Use internal tempo is an explicit
recovery action. Source changes are locked during recording and overdubbing.
Before the first usable clock, a record request shows Waiting for clock on its
track. Input sound cannot accidentally satisfy that wait.

Send sync chooses Clock and Play / Stop per outgoing connection. Playback
messages require Clock enabled. A connection receiving clock cannot also send
it back. Disconnected output choices remain configured, with their connection
state visible. Returning to Controls preserves learned assignments.

## Reference and scope

- Looper X `Pages/GlobalSettings.qml` and the
  [extraction research](../research/sheeran-looper-x-1.0.2/features.md) expose
  receive/send, source/destination, offset and MIDI Thru. Segno's loss/recovery
  choices are its own design; they are not asserted as Looper X behavior.
- The [MIDI Association message reference](https://midi.org/about-midi-part-3midi-messages)
  separates Timing Clock from Start, Continue and Stop and specifies 24 clock
  pulses per quarter note.
- [Ableton's MIDI settings](https://help.ableton.com/hc/en-us/articles/209774205-Live-s-MIDI-Settings)
  and [MIDI synchronization guide](https://help.ableton.com/hc/en-us/articles/209071149-Synchronizing-Live-via-MIDI)
  provide established patterns for distinct sync input/output and feedback avoidance.

This is a silent UX model. Ports, messages and outgoing events are simulated.
The draft estimates tempo after six valid intervals and identifies loss after
one second without clock. Those are testable prototype choices, not production
timing guarantees. Playhead movement uses elapsed browser time at the estimated
tempo; sample-accurate phase alignment, jitter filtering, clock reacquisition,
latency offset, real MIDI I/O, independent physical input/output topology,
Song Position Pointer, MIDI Thru, network sync and tempo-aware import remain
implementation or separate design work. No audio engine or firmware changed.

## Verification and review

[Interactive clock simulator](midi-sync-preview.html) supplies clock, tempo,
Start, Continue, Stop and disconnect controls outside the appliance frame.
[Browser and Pen references](midi-sync-previews/index.html) show all six states.

`verify_midi_sync.cjs` passes in Chrome and Firefox: source filtering, tempo,
independent transport, repeated Stop/Continue, both loss policies, reconnect,
no echo to the source, armed recording, partial-take retention, local musical
settings, encoder selection, persistence, failed writes and screen bounds.
Existing recording, MIDI mapping and loop-setup browser journeys also pass;
the deterministic transport-model suite passes. Pen verification covers the six
new screens, eight revised MIDI headers, Settings and three corrected MIDI-clock
loop settings references. Native text and element bounds match the browser.
