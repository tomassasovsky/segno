import 'package:pedal_repository/src/pedal_link_message.dart';

/// A two-way channel to the console board, at message level.
///
/// The production link is `UartPedalLink` (the Pi's uart3 to the board's
/// Pico 2); `SimulatorPedalLink` is the on-screen pedal, and a fake stands in
/// for tests. Framing is `PedalLinkCodec`'s and lives below this seam, so a
/// `PedalRepository` never sees bytes.
abstract interface class PedalLink {
  /// Messages from the board (buttons, encoder, hello).
  Stream<PedalLinkMessage> get inbound;

  /// Sends [message] to the board. Fire-and-forget: a link with nothing on
  /// the other end drops it.
  void send(PedalLinkMessage message);

  /// Releases the channel. Idempotent.
  Future<void> dispose();
}
