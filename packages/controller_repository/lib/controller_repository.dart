/// MIDI control for Segno: raw MIDI messages, the explicit formats they are
/// read in, the mappings that turn a control into parameter writes and
/// actions, and the engine that applies them.
library;

export 'src/controller_input.dart';
export 'src/midi_mapping.dart';
export 'src/midi_mapping_engine.dart';
export 'src/midi_protocol.dart';
export 'src/midi_signal_levels.dart';
