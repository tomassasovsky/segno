/// Native USB MIDI input for Segno.
///
/// Wraps the `le_midi_*` capture seam (in `segno_engine`) behind a small typed
/// Dart API (`MidiClient` + `MidiDevice`), and delivers the open device's
/// messages as a `MidiControllerSource`.
library;

export 'src/midi_client_base.dart' show MidiClient, MidiException;
export 'src/midi_controller_source.dart' show MidiControllerSource;
export 'src/midi_device.dart' show MidiDevice;
export 'src/midi_device_match.dart' show midiDeviceNameMatches;
export 'src/midi_out_client.dart' show MidiOutClient;
