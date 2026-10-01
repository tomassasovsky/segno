import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/control_value_target.dart';

/// Directed raw byte readings at the mechanical ends of an expression pedal.
class ExpressionCalibration extends Equatable {
  /// Creates a usable calibration. Reverse-wired pedals may have heel > toe.
  ExpressionCalibration({required this.heel, required this.toe}) {
    if (heel < 0 || heel > 255 || toe < 0 || toe > 255 || !isUsable) {
      throw const FormatException('Invalid expression calibration');
    }
  }

  /// Decodes an explicit calibration without guessing missing or invalid ends.
  factory ExpressionCalibration.fromJson(Map<String, dynamic> json) {
    final heel = json['heel'];
    final toe = json['toe'];
    if (heel is! int || toe is! int) {
      throw const FormatException('Invalid expression calibration');
    }
    return ExpressionCalibration(heel: heel, toe: toe);
  }

  /// Ten percent of the 255-count raw range, rounded up.
  static const int minimumSpan = 26;

  /// Raw reading with the heel down.
  final int heel;

  /// Raw reading with the toe down.
  final int toe;

  /// Mechanical travel in raw counts.
  int get span => (toe - heel).abs();

  /// Whether this travel can be trusted for dispatch.
  bool get isUsable => span >= minimumSpan;

  /// The position from heel (0) to toe (1), including reversed wiring.
  double? positionOf(int raw) {
    if (raw < 0 || raw > 255 || !isUsable) return null;
    return ((raw - heel) / (toe - heel)).clamp(0.0, 1.0);
  }

  /// Canonical persistence form.
  Map<String, dynamic> toJson() => {'heel': heel, 'toe': toe};

  @override
  List<Object?> get props => [heel, toe];
}

/// One stable value target and its independent heel/toe range.
class ExpressionMapping extends Equatable {
  /// Creates a mapping, preserving reverse target ranges.
  ExpressionMapping({required this.target, this.heel = 0, this.toe = 1}) {
    if (!target.isStructurallyValid) {
      throw const FormatException('Invalid expression target');
    }
    if (!_unit(heel) || !_unit(toe)) {
      throw const FormatException('Invalid expression range');
    }
  }

  /// Decodes a mapping. A missing target is malformed; a removed live target
  /// remains a valid, unavailable row with its stable identity intact.
  factory ExpressionMapping.fromJson(Map<String, dynamic> json) {
    final encoded = json['target'];
    if (encoded is! String || encoded.isEmpty) {
      throw const FormatException('Invalid expression target');
    }
    final target = ControlValueTarget.tryParse(encoded);
    if (target == null) {
      throw const FormatException('Invalid expression target');
    }
    final heel = json['heel'];
    final toe = json['toe'];
    if (json.containsKey('heel') && heel is! num ||
        json.containsKey('toe') && toe is! num) {
      throw const FormatException('Invalid expression range');
    }
    return ExpressionMapping(
      target: target,
      heel: (heel as num?)?.toDouble() ?? 0,
      toe: (toe as num?)?.toDouble() ?? 1,
    );
  }

  static bool _unit(double value) => value.isFinite && value >= 0 && value <= 1;

  /// Stable target identity.
  final ControlValueTarget target;

  /// Target value with the heel down.
  final double heel;

  /// Target value with the toe down.
  final double toe;

  /// Target value at a calibrated position.
  double valueAt(double position) {
    if (!_unit(position)) throw const FormatException('Invalid position');
    return heel + (toe - heel) * position;
  }

  /// Keeps target identity while editing endpoints.
  ExpressionMapping copyWith({double? heel, double? toe}) => ExpressionMapping(
    target: target,
    heel: heel ?? this.heel,
    toe: toe ?? this.toe,
  );

  /// Canonical persistence form.
  Map<String, dynamic> toJson() => {
    'target': target.canonicalString(),
    'heel': heel,
    'toe': toe,
  };

  @override
  List<Object?> get props => [target, heel, toe];
}

/// The retained expression configuration of one jack.
class ExternalExpressionSetup extends Equatable {
  /// Creates a detached, ordered mapping list with unique target identities.
  factory ExternalExpressionSetup({
    ExpressionCalibration? calibration,
    List<ExpressionMapping> mappings = const [],
  }) {
    final targets = <ControlValueTarget>{};
    for (final mapping in mappings) {
      if (!targets.add(mapping.target)) {
        throw const FormatException('Duplicate expression target');
      }
    }
    return ExternalExpressionSetup._(calibration, List.unmodifiable(mappings));
  }

  const ExternalExpressionSetup._(this.calibration, this.mappings);

  /// Decodes an explicit expression value strictly.
  factory ExternalExpressionSetup.fromJson(Map<String, dynamic> json) {
    final rawCalibration = json['calibration'];
    if (json.containsKey('calibration') &&
        rawCalibration is! Map<String, dynamic>) {
      throw const FormatException('Invalid expression calibration');
    }
    final rawMappings = json['mappings'];
    if (json.containsKey('mappings') && rawMappings is! List) {
      throw const FormatException('Invalid expression mappings');
    }
    return ExternalExpressionSetup(
      calibration: rawCalibration is Map<String, dynamic>
          ? ExpressionCalibration.fromJson(rawCalibration)
          : null,
      mappings: [
        if (rawMappings is List)
          for (final raw in rawMappings)
            if (raw is Map<String, dynamic>)
              ExpressionMapping.fromJson(raw)
            else
              throw const FormatException('Invalid expression mapping'),
      ],
    );
  }

  /// Fresh expression setup.
  static const ExternalExpressionSetup empty = ExternalExpressionSetup._(
    null,
    [],
  );

  /// Confirmed mechanical travel, or null until taught.
  final ExpressionCalibration? calibration;

  /// Mappings in editor order.
  final List<ExpressionMapping> mappings;

  /// Whether nothing has been configured.
  bool get isEmpty => calibration == null && mappings.isEmpty;

  /// Mapping on a stable target.
  ExpressionMapping? mappingFor(ControlValueTarget target) {
    for (final mapping in mappings) {
      if (mapping.target == target) return mapping;
    }
    return null;
  }

  /// Replaces one mapping in place or appends it.
  ExternalExpressionSetup withMapping(ExpressionMapping mapping) {
    final next = [...mappings];
    final index = next.indexWhere((item) => item.target == mapping.target);
    if (index < 0) {
      next.add(mapping);
    } else {
      next[index] = mapping;
    }
    return copyWith(mappings: next);
  }

  /// Removes a mapping by stable identity.
  ExternalExpressionSetup withoutMapping(ControlValueTarget target) => copyWith(
    mappings: [
      for (final mapping in mappings)
        if (mapping.target != target) mapping,
    ],
  );

  /// Copies this value, allowing a calibration to be cleared explicitly.
  ExternalExpressionSetup copyWith({
    ExpressionCalibration? calibration,
    List<ExpressionMapping>? mappings,
    bool clearCalibration = false,
  }) => ExternalExpressionSetup(
    calibration: clearCalibration ? null : calibration ?? this.calibration,
    mappings: mappings ?? this.mappings,
  );

  /// Canonical persistence form.
  Map<String, dynamic> toJson() => {
    if (calibration != null) 'calibration': calibration!.toJson(),
    if (mappings.isNotEmpty)
      'mappings': [for (final mapping in mappings) mapping.toJson()],
  };

  @override
  List<Object?> get props => [calibration, mappings];
}
