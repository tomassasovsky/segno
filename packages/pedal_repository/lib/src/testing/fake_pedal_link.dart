// Test support, shipped from the package so the app's tests and the package's
// own tests drive one and the same fake.

import 'dart:async';

import 'package:pedal_repository/pedal_repository.dart';

/// A controllable [PedalLink] for driving a real `PedalRepository` in tests:
/// push board messages with [emit] (or [press] / [turn] / [hello]) and inspect
/// what segno sent in [sent].
class FakePedalLink implements PedalLink {
  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();

  /// Every message passed to [send], in order.
  final List<PedalLinkMessage> sent = [];

  /// Whether [dispose] has been called.
  bool disposed = false;

  /// The frame of the last [StateMessage] sent, or `null` if none was.
  PedalStateFrame? get lastFrame =>
      sent.whereType<StateMessage>().lastOrNull?.frame;

  /// Pushes one inbound message as if the board sent it.
  void emit(PedalLinkMessage message) => _inbound.add(message);

  /// A footswitch press ([down] true) or release.
  void press(PedalButton button, {required bool down}) =>
      emit(ButtonMessage(button, pressed: down));

  /// An encoder turn of [delta] detents, clamped to the wire's int8 like the
  /// on-screen pedal.
  void turn(int delta) => emit(EncoderMessage(delta.clamp(-128, 127)));

  /// The board's hello.
  void hello({int firmwareMajor = 1, int firmwareMinor = 0}) => emit(
    HelloMessage(
      protocolVersion: PedalLinkCodec.protocolVersion,
      firmwareMajor: firmwareMajor,
      firmwareMinor: firmwareMinor,
    ),
  );

  @override
  Stream<PedalLinkMessage> get inbound => _inbound.stream;

  @override
  void send(PedalLinkMessage message) => sent.add(message);

  @override
  Future<void> dispose() async {
    disposed = true;
    await _inbound.close();
  }
}
