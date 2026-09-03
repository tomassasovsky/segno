import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// The board-less [PedalLink]: the link every build without a console board
/// runs on (desktop, the mock flavor, widget and fuzz tests). It never says
/// hello, so the app reads it as disconnected.
///
/// [press] and [turn] inject the same messages a footswitch or the encoder
/// would send, so the real `ControlCubit` behavior runs for a synthetic
/// stomp; every state frame segno sends is decoded into [frame], so a test
/// (or a plate) can read what the console's LEDs would show.
class SimulatorPedalLink implements PedalLink {
  /// Creates a [SimulatorPedalLink].
  SimulatorPedalLink();

  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();
  final ValueNotifier<PedalStateFrame> _frame = ValueNotifier(
    PedalStateFrame.blank(),
  );

  // Buttons currently held on-screen, so [releaseAll] can release them and
  // never leave a press (or the cubit's undo timer) stuck.
  final Set<PedalButton> _held = {};
  bool _disposed = false;

  /// The last frame segno sent — what a plate renders. Seeded blank so the
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
    if (message is StateMessage) _frame.value = message.frame;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inbound.close();
    _frame.dispose();
  }
}
