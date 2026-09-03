import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// The on-screen pedal, as a [PedalLink] laid over the hardware one.
///
/// [press] and [turn] inject the same messages a footswitch or the encoder
/// would send, so the real `ControlCubit` behavior runs for a tap on the
/// plate; everything segno sends is forwarded to the inner hardware link
/// (when there is one) *and* decoded into [frame], so the plate always shows
/// what the console's LEDs show. With no inner link — every desktop build —
/// the plate is the only pedal, and nothing is lost on the floor.
class SimulatorPedalLink implements PedalLink {
  /// Creates a [SimulatorPedalLink] over [inner], the hardware link or `null`.
  SimulatorPedalLink({PedalLink? inner}) : _inner = inner {
    final hardware = inner;
    if (hardware != null) {
      _innerSub = hardware.inbound.listen(
        _inbound.add,
        onError: _inbound.addError,
      );
    }
  }

  final PedalLink? _inner;
  StreamSubscription<PedalLinkMessage>? _innerSub;

  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();
  final ValueNotifier<PedalStateFrame> _frame = ValueNotifier(
    PedalStateFrame.blank(),
  );

  // Buttons currently held on-screen, so [releaseAll] can release them and
  // never leave a press (or the cubit's undo timer) stuck.
  final Set<PedalButton> _held = {};
  bool _disposed = false;

  /// The last frame segno sent — what the plate renders. Seeded blank so the
  /// plate has a value on mount, before the first push.
  ValueListenable<PedalStateFrame> get frame => _frame;

  /// Presses ([down] true) or releases ([down] false) [button].
  void press(PedalButton button, {required bool down}) {
    if (_disposed) return;
    if (down) {
      _held.add(button);
    } else {
      _held.remove(button);
    }
    _inbound.add(ButtonMessage(button, pressed: down));
  }

  /// Turns the encoder by [delta] detents (positive = clockwise), clamped to
  /// the wire's int8.
  void turn(int delta) {
    if (_disposed) return;
    _inbound.add(EncoderMessage(delta.clamp(-128, 127)));
  }

  /// Releases every held button. Called on plate deactivate / focus loss so a
  /// held press cannot stick.
  void releaseAll() {
    if (_disposed) return;
    final held = _held.toList();
    _held.clear();
    for (final button in held) {
      _inbound.add(ButtonMessage(button, pressed: false));
    }
  }

  @override
  Stream<PedalLinkMessage> get inbound => _inbound.stream;

  @override
  void send(PedalLinkMessage message) {
    if (_disposed) return;
    _inner?.send(message);
    if (message is StateMessage) _frame.value = message.frame;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _innerSub?.cancel();
    await _inbound.close();
    _frame.dispose();
    await _inner?.dispose();
  }
}
