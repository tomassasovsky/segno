import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/control_value_target.dart';

/// The travel an expression pedal was taught: the raw reading at each
/// mechanical end.
///
/// Calibration exists because a pedal's electrical range and its travel are
/// not the same thing. Two pedals of the same model reach different ends of
/// their pots, and a pedal can be wired the other way round — so the wire
/// carries the raw reading and this says what it means.
class ExpressionCalibration extends Equatable {
  /// Creates a calibration from the raw readings at each end.
  const ExpressionCalibration({required this.heel, required this.toe});

  /// Rebuilds a calibration from its [toJson] map, or `null` when either end
  /// is missing, is not a number, or is outside the raw `0..1` domain.
  ///
  /// An end outside that domain is rejected rather than pulled into it: a
  /// reading the wire cannot produce says nothing about where the pedal's
  /// travel is, and clamping it would invent a travel the foot never took. The
  /// jack then reads as untaught, which the screen already has a state for.
  static ExpressionCalibration? fromJson(Map<String, dynamic> json) {
    final heel = json['heel'];
    final toe = json['toe'];
    if (heel is! num || toe is! num) return null;
    if (heel < 0 || heel > 1 || toe < 0 || toe > 1) return null;
    return ExpressionCalibration(heel: heel.toDouble(), toe: toe.toDouble());
  }

  /// The narrowest travel worth dividing by, as a fraction of the pedal's raw
  /// range.
  ///
  /// A span this short means the two captures came from nearly the same place
  /// — a foot that did not move, or one end captured twice — and dividing by
  /// it would turn the remaining noise into a full sweep. The accepted design
  /// records this threshold as a study assumption rather than a measured
  /// electrical requirement, so the bench may move it.
  static const double minimumSpan = 0.1;

  /// The raw reading with the heel down.
  final double heel;

  /// The raw reading with the toe down.
  ///
  /// May be BELOW [heel]: a pedal wired the other way round reads backwards,
  /// and the accepted design takes that calibration rather than asking the
  /// player to rewire a pedal that works.
  final double toe;

  /// How much of the raw range the travel covers.
  double get span => (toe - heel).abs();

  /// Whether the travel is long enough to position against.
  bool get isUsable => span >= minimumSpan;

  /// Where [raw] sits in this travel, `0` at the heel and `1` at the toe, or
  /// `null` when the travel is too short to divide by.
  ///
  /// Reversed travel needs no special case: the same subtraction puts `0` at
  /// whichever end was captured as the heel.
  double? positionOf(double raw) {
    if (!isUsable) return null;
    return ((raw - heel) / (toe - heel)).clamp(0.0, 1.0);
  }

  /// Serializes this calibration.
  Map<String, dynamic> toJson() => {'heel': heel, 'toe': toe};

  @override
  List<Object?> get props => [heel, toe];
}

/// One thing an expression pedal sweeps, and the two values it sweeps between.
///
/// The [target] is the identity: one pedal drives each control once, so the
/// accepted screen offers a control already mapped as unavailable rather than
/// letting two rows fight over it.
class ExpressionMapping extends Equatable {
  /// Creates a mapping. The endpoints default to the whole of the target's
  /// range, which is what the accepted screen adds a control with.
  const ExpressionMapping({required this.target, this.heel = 0, this.toe = 1});

  /// Rebuilds a mapping from its [toJson] map, or `null` when the target is
  /// missing or does not decode.
  ///
  /// A target that does not decode drops the whole mapping, the same as an
  /// unparseable action drops an assignment: a row that cannot say what it
  /// used to drive is nothing a player could repair. This is NOT the case of a
  /// target that decodes but no longer exists in the rig — that row stays, and
  /// says it is unavailable.
  static ExpressionMapping? fromJson(Map<String, dynamic> json) {
    final encoded = json['target'];
    if (encoded is! String) return null;
    final target = ControlValueTarget.tryParse(encoded);
    if (target == null) return null;
    final heel = json['heel'];
    final toe = json['toe'];
    return ExpressionMapping(
      target: target,
      heel: heel is num ? heel.toDouble().clamp(0.0, 1.0) : 0,
      toe: toe is num ? toe.toDouble().clamp(0.0, 1.0) : 1,
    );
  }

  /// What this sweeps.
  final ControlValueTarget target;

  /// The value written with the heel down, `0..1` in the target's own
  /// normalized domain.
  final double heel;

  /// The value written with the toe down.
  ///
  /// May be BELOW [heel]. That is not a mistake to correct: it is how a player
  /// inverts a control, closing a filter as the pedal goes down.
  final double toe;

  /// The value this writes at [position] (`0` heel, `1` toe).
  double valueAt(double position) =>
      (heel + (toe - heel) * position).clamp(0.0, 1.0);

  /// Returns a copy with the given endpoints replaced.
  ExpressionMapping copyWith({double? heel, double? toe}) => ExpressionMapping(
    target: target,
    heel: heel ?? this.heel,
    toe: toe ?? this.toe,
  );

  /// Serializes this mapping.
  Map<String, dynamic> toJson() => {
    'target': target.canonicalString(),
    'heel': heel,
    'toe': toe,
  };

  @override
  List<Object?> get props => [target, heel, toe];
}

/// What a jack carries while an expression pedal is plugged into it: the travel
/// it was taught, and everything it sweeps.
class ExternalExpressionSetup extends Equatable {
  /// Creates an [ExternalExpressionSetup].
  ///
  /// [mappings] must hold at most one entry per target. Every path that builds
  /// one keeps that: [withMapping] replaces rather than appends, and
  /// [ExternalExpressionSetup.fromJson] drops a repeat.
  const ExternalExpressionSetup({
    this.calibration,
    this.mappings = const [],
  });

  /// Rebuilds an expression setup from its [toJson] map.
  factory ExternalExpressionSetup.fromJson(Map<String, dynamic> json) {
    final calibration = json['calibration'];
    final mappings = json['mappings'];
    return ExternalExpressionSetup(
      calibration: calibration is Map<String, dynamic>
          ? ExpressionCalibration.fromJson(calibration)
          : null,
      mappings: _deduplicated([
        if (mappings is List)
          for (final raw in mappings)
            if (raw is Map<String, dynamic>) ?ExpressionMapping.fromJson(raw),
      ]),
    );
  }

  /// One target at most, keeping the first.
  ///
  /// Two rows sweeping one control would write over each other in an order
  /// nothing decides, so a stored file that somehow holds both loses the
  /// second rather than reaching dispatch with a coin flip in it.
  static List<ExpressionMapping> _deduplicated(
    List<ExpressionMapping> mappings,
  ) {
    final seen = <ControlValueTarget>{};
    return [
      for (final mapping in mappings)
        if (seen.add(mapping.target)) mapping,
    ];
  }

  /// A jack with no expression pedal taught or assigned.
  static const ExternalExpressionSetup empty = ExternalExpressionSetup();

  /// The travel this pedal was taught, or `null` until it has been.
  final ExpressionCalibration? calibration;

  /// What it sweeps, in the order the controls were added.
  final List<ExpressionMapping> mappings;

  /// Whether nothing here is worth storing.
  bool get isEmpty => calibration == null && mappings.isEmpty;

  /// The mapping on [target], or `null` when nothing sweeps it.
  ExpressionMapping? mappingFor(ControlValueTarget target) {
    for (final mapping in mappings) {
      if (mapping.target == target) return mapping;
    }
    return null;
  }

  /// Returns a copy with [mapping] in place of the one on the same target, or
  /// appended when there is none — so editing an endpoint keeps a row where it
  /// was in the list.
  ExternalExpressionSetup withMapping(ExpressionMapping mapping) {
    final next = [...mappings];
    final at = next.indexWhere((item) => item.target == mapping.target);
    if (at < 0) {
      next.add(mapping);
    } else {
      next[at] = mapping;
    }
    return copyWith(mappings: next);
  }

  /// Returns a copy without the mapping on [target].
  ExternalExpressionSetup withoutMapping(ControlValueTarget target) => copyWith(
    mappings: [
      for (final mapping in mappings)
        if (mapping.target != target) mapping,
    ],
  );

  /// Returns a copy with the given fields replaced; [clearCalibration] drops
  /// the travel, which `calibration: null` cannot express.
  ExternalExpressionSetup copyWith({
    ExpressionCalibration? calibration,
    List<ExpressionMapping>? mappings,
    bool clearCalibration = false,
  }) => ExternalExpressionSetup(
    calibration: clearCalibration ? null : calibration ?? this.calibration,
    mappings: mappings ?? this.mappings,
  );

  /// Serializes this setup, omitting what nothing has touched.
  Map<String, dynamic> toJson() => {
    if (calibration != null) 'calibration': calibration!.toJson(),
    if (mappings.isNotEmpty)
      'mappings': [for (final mapping in mappings) mapping.toJson()],
  };

  @override
  List<Object?> get props => [calibration, mappings];
}
