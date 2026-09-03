/// The console's two CTRL jacks, in wire order.
///
/// One jack takes an expression pedal OR a footswitch, and the board works out
/// which from what the tip does. Only the tip is readable — the ring is the
/// pot's supply — so a two-switch pedal offers one switch per jack.
enum PedalCtrlJack {
  /// The left jack (J20).
  ctrl1,

  /// The right jack (J21).
  ctrl2,
}

/// What the board decided is plugged into a [PedalCtrlJack].
enum PedalCtrlKind {
  /// A footswitch: the value is `0` released or `255` pressed.
  switchPedal,

  /// An expression pedal: the value is its travel, `0`..`255`.
  expression,
}
