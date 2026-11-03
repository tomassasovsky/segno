/// Repository layer for Segno's MIDI inputs.
///
/// Captures every plugged-in MIDI input at once (one `MidiControllerSource`
/// per device), supervises hotplug, persists which controller the MIDI page
/// shows, and projects a `MidiConnection` stream for the presentation layer —
/// mirroring the `LooperRepository` seam for audio. Deliberately holds no
/// audio dependency, so losing a MIDI device can never restart audio.
library;

export 'package:midi_client/midi_client.dart' show MidiDevice;

export 'src/midi_device_repository.dart';
export 'src/models/midi_connection.dart';
export 'src/native_midi_source.dart';
