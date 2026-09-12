/// One of the console's two external control jacks, carrying an expression
/// pedal.
///
/// The same two jacks a switch plugs into: an expression pedal is a
/// potentiometer the console board reads, so its position reaches segno on the
/// link the ten footswitches and the encoder already share.
///
/// Separate from `PedalExternalSwitch` on purpose. A jack carries either a
/// continuous position or up to two contacts, never both, and the two wire
/// shapes have nothing in common — one is a Control Change, the other a Note.
/// The numbering is part of the wire contract: append, never renumber.
enum PedalExpressionJack {
  /// CTRL 1.
  ctrl1,

  /// CTRL 2.
  ctrl2,
}

/// The Control Change number each expression jack transmits its position on.
///
/// The value is the RAW reading, `0` at one mechanical end and [maxValue] at
/// the other. Which end is which is not fixed — a pedal can be wired either
/// way round, which is what the app's calibration is for.
///
/// ## 7 bits, one message
///
/// The inbound half of this link is 3-byte MIDI only: segno's native capture
/// drops SysEx, so nothing wider than a Control Change can arrive. A
/// higher-resolution position would need the MIDI 14-bit MSB/LSB pair and a
/// half-assembled value held between two messages, which would move the wire
/// contract out of this codec and into whatever held that state.
///
/// 128 steps of raw travel is what a commercial expression input delivers. The
/// cost is at the bottom of the calibration range: a span near the accepted
/// 10% minimum leaves about 13 distinct positions. If the bench shows that
/// stepping, the fix is a 14-bit pair on the wire, not anything the app can do
/// with 7 bits.
extension PedalExpressionJackCc on PedalExpressionJack {
  /// The Control Change number CTRL 1 transmits on; CTRL 2 follows it.
  static const int firstCc = 0x11;

  /// The raw value at a mechanical end — the full 7-bit Control Change range.
  static const int maxValue = 0x7F;

  /// The Control Change number this jack transmits on.
  int get cc => firstCc + index;

  /// The [PedalExpressionJack] transmitting on [cc], or `null` if no jack
  /// does.
  static PedalExpressionJack? fromCc(int cc) {
    final index = cc - firstCc;
    if (index < 0 || index >= PedalExpressionJack.values.length) return null;
    return PedalExpressionJack.values[index];
  }
}
