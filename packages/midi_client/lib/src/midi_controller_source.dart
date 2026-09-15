import 'dart:async';
import 'dart:ffi';

import 'package:controller_repository/controller_repository.dart';
import 'package:meta/meta.dart';
import 'package:midi_client/src/midi_client_base.dart';
import 'package:midi_client/src/midi_device.dart';
import 'package:segno_engine/segno_engine_ffi.dart';

/// A native USB MIDI input device, as a stream of messages.
///
/// Long-lived by design: [activity] is a persistent broadcast stream that
/// survives device open/close/switch, so its subscribers — the Segno pedal,
/// the MIDI device repository and the MIDI mappings — are never torn down on
/// replug. The physical device is swapped *inside* the source via [open] /
/// [close].
///
/// Raw `(status, data1, data2)` bytes from the native callback are normalized
/// to [RawControllerInput]s and delivered on [activity] as they arrive, with
/// nothing collapsed: a 14-bit or NRPN control sends its halves closer together
/// than any footswitch debounce would allow.
class MidiControllerSource {
  /// Creates a [MidiControllerSource] over [client] (defaults to a real
  /// [MidiClient] on the platform library).
  MidiControllerSource({MidiClient? client})
    : _client = client ?? MidiClient() {
    _callable = NativeCallable<le_midi_event_cbFunction>.listener(_onMidiEvent);
  }

  final MidiClient _client;

  late final NativeCallable<le_midi_event_cbFunction> _callable;

  final StreamController<RawControllerInput> _activity =
      StreamController<RawControllerInput>.broadcast();

  bool _disposed = false;

  /// Every Note, Control Change and Program Change message, as it arrives.
  /// Other traffic (SysEx, clock, active sensing, aftertouch, pitch bend)
  /// never reaches here.
  Stream<RawControllerInput> get activity => _activity.stream;

  /// Lists the host's available MIDI input devices.
  List<MidiDevice> enumerate() => _client.enumerate();

  /// Opens (or switches to) the device with the given [id], routing its
  /// messages into [activity]. Returns the native result code
  /// (`0` on success).
  int open(String id) => _client.open(id, _callable.nativeFunction);

  /// Closes the currently open device. Idempotent; [activity] stays open.
  int close() => _client.close();

  /// Handles one raw MIDI message from the native callback (or [pushForTest]).
  /// The native timestamp is not needed: messages are delivered in order.
  void _onMidiEvent(int status, int data1, int data2, int tsUs) {
    final input = _parse(status, data1, data2);
    if (input == null || _activity.isClosed) return;
    _activity.add(input);
  }

  /// Maps a MIDI status/data triple to a [RawControllerInput], or `null` when
  /// the message is not a Note On/Off, Control Change or Program Change.
  ///
  /// Channel (the status low nibble) is carried, so a mapping can listen on
  /// one channel. A Note On with velocity 0 is the conventional Note Off, so
  /// it maps to value 0, a release.
  static RawControllerInput? _parse(int status, int data1, int data2) {
    final channel = status & 0x0F;
    switch (status & 0xF0) {
      case 0x90: // Note On (velocity 0 == Note Off)
        return RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: data1,
          value: data2,
          midiChannel: channel,
        );
      case 0x80: // Note Off
        return RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: data1,
          value: 0,
          midiChannel: channel,
        );
      case 0xB0: // Control Change
        return RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: data1,
          value: data2,
          midiChannel: channel,
        );
      case 0xC0: // Program Change: one data byte, and no value
        return RawControllerInput(
          kind: ControllerSourceKind.midiProgram,
          id: data1,
          value: 0,
          midiChannel: channel,
        );
      default: // SysEx / real-time / aftertouch / pitch bend
        return null;
    }
  }

  /// Drives the event path as if a native message arrived, without hardware.
  @visibleForTesting
  void pushForTest(int status, int data1, int data2) =>
      _onMidiEvent(status, data1, data2, 0);

  /// Whether [dispose] has been called.
  @visibleForTesting
  bool get isDisposed => _disposed;

  /// Stops capture and closes [activity].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Order matters (use-after-free safety): stop native capture and free the
    // handle *before* releasing the NativeCallable, so the native side can
    // never invoke a freed callback.
    // le_midi_close -> le_midi_destroy -> callable.close.
    _client
      ..close()
      ..dispose();
    _callable.close();
    await _activity.close();
  }
}
