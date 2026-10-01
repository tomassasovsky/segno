import 'dart:async';
import 'dart:ffi';

import 'package:controller_repository/controller_repository.dart';
import 'package:meta/meta.dart';
import 'package:midi_client/src/midi_client_base.dart';
import 'package:midi_client/src/midi_device.dart';
import 'package:segno_engine/segno_engine_ffi.dart';

/// Native musical MIDI capture, owned and disposed by ControllerRepository.
///
/// Complete messages are never debounced: doing so loses rapid releases and
/// halves of high-resolution controls. Each opened callback captures its own
/// device lifetime, so queued callbacks from a closed port cannot be relabeled.
class MidiControllerSource implements ControllerSource {
  /// Creates native capture, optionally over an injected client.
  MidiControllerSource({MidiClient? client}) : _client = client ?? MidiClient();

  final MidiClient _client;
  final _inputs = StreamController<RawControllerInput>.broadcast();
  final _messages = StreamController<MidiInputMessage>.broadcast();
  NativeCallable<le_midi_event_cbFunction>? _callback;
  MidiInputSession? _session;
  var _epoch = 0;
  var _disposed = false;

  /// Currently opened capture lifetime, or null while closed/unavailable.
  MidiInputSession? get session => _session;

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  /// Every recognized message, independent of remote assignment enable/Learn.
  Stream<RawControllerInput> get activity => _inputs.stream;

  /// Complete messages with their capture-time device lifetime.
  Stream<MidiInputMessage> get messages => _messages.stream;

  /// Lists available host MIDI inputs.
  List<MidiDevice> enumerate() => _client.enumerate();

  /// Opens a fresh lifetime, invalidating the previous callback synchronously.
  int open(String id) {
    if (_disposed) throw StateError('MIDI source is disposed');
    close();
    final capture = MidiInputSession(id, ++_epoch);
    final callback = NativeCallable<le_midi_event_cbFunction>.listener(
      (int status, int data1, int data2, int timestamp) =>
          _receive(capture, status, data1, data2, timestamp),
    );
    _callback = callback;
    _session = capture;
    final result = _client.open(id, callback.nativeFunction);
    if (result != 0) close();
    return result;
  }

  /// Invalidates queued input before closing native capture.
  int close() {
    _session = null;
    final result = _client.close();
    // Native close joins/disposes the producer. Listener.close closes its
    // RawReceivePort, dropping callbacks already queued for Dart delivery.
    _callback?.close();
    _callback = null;
    return result;
  }

  void _receive(
    MidiInputSession capture,
    int status,
    int data1,
    int data2,
    int timestampMicros,
  ) {
    if (_disposed || _session != capture) return;
    final input = _parse(status, data1, data2);
    if (input == null) return;
    _inputs.add(input);
    _messages.add(
      MidiInputMessage(capture, input, timestampMicros: timestampMicros),
    );
  }

  static RawControllerInput? _parse(int status, int data1, int data2) {
    if (data1 < 0 || data1 > 127 || data2 < 0 || data2 > 127) return null;
    final (kind, value) = switch (status & 0xF0) {
      0x90 => (ControllerSourceKind.midiNote, data2),
      0x80 => (ControllerSourceKind.midiNote, 0),
      0xB0 => (ControllerSourceKind.midiCc, data2),
      0xC0 => (ControllerSourceKind.midiProgram, 127),
      _ => (null, 0),
    };
    if (kind == null) return null;
    return RawControllerInput(
      kind: kind,
      id: data1,
      value: value,
      midiChannel: status & 0x0F,
    );
  }

  /// Injects a message into the current opened capture lifetime.
  @visibleForTesting
  void pushForTest(int status, int data1, int data2, {int tsUs = 0}) {
    final capture = _session;
    if (capture != null) _receive(capture, status, data1, data2, tsUs);
  }

  /// Whether final disposal has completed native teardown.
  @visibleForTesting
  bool get isDisposed => _disposed;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _session = null;
    _client
      ..close()
      ..dispose();
    _callback?.close();
    _callback = null;
    await _inputs.close();
    await _messages.close();
  }
}
