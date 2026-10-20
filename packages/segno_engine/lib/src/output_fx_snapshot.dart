/// A built-in output effect at the actual performance arm boundary.
class OutputEffectSnapshot {
  /// Creates an effect snapshot.
  const OutputEffectSnapshot({
    required this.type,
    required this.params,
    this.enabled = true,
  });

  /// Native effect type identifier.
  final int type;

  /// Ordered effect parameters.
  final List<double> params;

  /// Whether this effect was enabled.
  final bool enabled;
}

/// The selected destination chain frozen by the callback at performance arm.
class OutputFxSnapshot {
  /// Creates a chain snapshot.
  const OutputFxSnapshot({this.effects = const [], this.chainEnabled = true});

  /// Ordered effect instances.
  final List<OutputEffectSnapshot> effects;

  /// Whether the whole chain was enabled.
  final bool chainEnabled;
}
