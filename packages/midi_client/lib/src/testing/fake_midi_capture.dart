import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:midi_client/src/midi_controller_source.dart';
import 'package:midi_client/src/midi_device.dart';

/// A [MidiControllerSource] with no native code behind it.
///
/// [enumerate] lists what the `devices` callback returns, so several
/// captures built by one factory share one host. [open] succeeds unless
/// [openResult] says otherwise, and each successful open starts a new
/// [MidiInputSession] epoch, as the native capture does.
class FakeMidiCapture implements MidiControllerSource {
  /// Creates a capture over the host inputs [devices] lists.
  FakeMidiCapture({List<MidiDevice> Function()? devices})
    : _devices = devices ?? (() => const []);

  final List<MidiDevice> Function() _devices;
  final _inputs = StreamController<RawControllerInput>.broadcast(sync: true);
  final _messages = StreamController<MidiInputMessage>.broadcast(sync: true);
  var _epoch = 0;
  var _disposed = false;

  /// The native result [open] returns for a device id; `0` opens it.
  int Function(String id) openResult = (_) => 0;

  /// Every id [open] was called with, in order.
  final opened = <String>[];

  /// How many times [close] ran.
  int closes = 0;

  @override
  MidiInputSession? session;

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  @override
  Stream<RawControllerInput> get activity => _inputs.stream;

  @override
  Stream<MidiInputMessage> get messages => _messages.stream;

  @override
  List<MidiDevice> enumerate() => _devices();

  @override
  int open(String id) {
    close();
    opened.add(id);
    final result = openResult(id);
    if (result == 0) session = MidiInputSession(id, ++_epoch);
    return result;
  }

  @override
  int close() {
    if (session != null) closes++;
    session = null;
    return 0;
  }

  /// Delivers [input] as the open capture's next message.
  void send(RawControllerInput input, {int? timestampMicros}) {
    final capture = session;
    if (capture == null) throw StateError('MIDI capture is not open');
    _inputs.add(input);
    _messages.add(
      MidiInputMessage(capture, input, timestampMicros: timestampMicros),
    );
  }

  @override
  void pushForTest(int status, int data1, int data2, {int tsUs = 0}) =>
      throw UnimplementedError('use send');

  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    session = null;
    await _inputs.close();
    await _messages.close();
  }
}
