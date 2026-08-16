import 'package:desktop_multi_window/desktop_multi_window.dart';

/// Cross-engine channel for the output-waveform sub-window.
///
/// Both the main window and the waveform window register on this channel.
/// The sub-window sends [waveformWindowReadyMethod] after its handler is live;
/// the main window waits for that before pushing frames.
const waveformWindowChannel = WindowMethodChannel('segno/waveform_window');

/// Sent by the waveform window once [waveformWindowChannel] is registered.
const waveformWindowReadyMethod = 'ready';

/// Sent by the waveform window when the volume overlay issues a control
/// command (a `ReadoutControl` map) — the channel's first sub→main control
/// path (#698).
const waveformWindowControlMethod = 'readout_control';
