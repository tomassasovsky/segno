import 'dart:async';

import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';

/// The [PedalLink] for a build with no console board to talk to (desktop,
/// the mock flavor, widget tests): it never says hello, so the app reads it
/// as disconnected, and everything sent to it is dropped.
class NoopPedalLink implements PedalLink {
  /// Creates a [NoopPedalLink].
  NoopPedalLink();

  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();

  @override
  Stream<PedalLinkMessage> get inbound => _inbound.stream;

  @override
  void send(PedalLinkMessage message) {}

  @override
  Future<void> dispose() => _inbound.close();
}
