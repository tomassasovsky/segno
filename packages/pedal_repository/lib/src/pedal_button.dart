/// A footswitch on the console.
///
/// The declaration order is the wire value (`ButtonMessage` carries the
/// index, the firmware's `PEDAL_BTN_*` constants mirror it): do not reorder,
/// and append rather than reshuffle if a switch is ever added.
enum PedalButton {
  /// Record / Play footswitch (the cycling transport button).
  recPlay,

  /// Stop footswitch.
  stop,

  /// Undo footswitch (long-press = redo, derived in segno).
  undo,

  /// Mode footswitch — cycles the pedal's interaction mode.
  mode,

  /// Track 1 footswitch.
  track1,

  /// Track 2 footswitch.
  track2,

  /// Track 3 footswitch.
  track3,

  /// Track 4 footswitch.
  track4,

  /// Clear-all footswitch.
  clear,

  /// Bank toggle footswitch (A/B).
  bank,
}
