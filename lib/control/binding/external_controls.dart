import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';

/// When an external button's control counts as active.
///
/// Two independent facts about a button feed these, and they are not the same
/// fact. Its ON / OFF state is logical: each completed press flips it, and it
/// is remembered across a restart. Whether it is HELD is physical: the contact
/// is closed right now. A latching switch reports only the first kind — it
/// never says how long a foot stayed on it — so [held] and [released] need a
/// momentary one.
enum ExternalCondition {
  /// While the button is on.
  on,

  /// While the button is off.
  off,

  /// While a foot is on a momentary button.
  held,

  /// While no foot is on a momentary button.
  released;

  /// Whether this reads the physical contact rather than the logical state,
  /// and so needs a momentary switch to mean anything.
  bool get readsContact => this == held || this == released;

  /// Parses a persisted [name], or `null` when it names nothing.
  static ExternalCondition? tryParse(Object? name) {
    for (final condition in values) {
      if (condition.name == name) return condition;
    }
    return null;
  }
}

/// One effect a button turns on and off.
class ExternalActivation extends Equatable {
  /// Creates an [ExternalActivation]. A new one is active while the button is
  /// on, which is what the accepted screen adds it with.
  const ExternalActivation({
    required this.target,
    this.condition = ExternalCondition.on,
  });

  /// Rebuilds an activation from its [toJson] map, or `null` when the target
  /// does not decode.
  ///
  /// The same rule the expression mappings follow: a target that does not
  /// decode names nothing a player could repair, so the row goes; a target that
  /// decodes but is gone from the rig stays, and says so.
  static ExternalActivation? fromJson(Map<String, dynamic> json) {
    final encoded = json['target'];
    if (encoded is! String) return null;
    final target = FxBindingTarget.tryParse(encoded);
    if (target == null) return null;
    return ExternalActivation(
      target: target,
      condition:
          ExternalCondition.tryParse(json['condition']) ?? ExternalCondition.on,
    );
  }

  /// The chain or the effect.
  final FxBindingTarget target;

  /// When it is on.
  final ExternalCondition condition;

  /// Returns a copy with [condition] replaced.
  ExternalActivation withCondition(ExternalCondition condition) =>
      ExternalActivation(target: target, condition: condition);

  /// Serializes this activation.
  Map<String, dynamic> toJson() => {
    'target': target.canonicalString(),
    'condition': condition.name,
  };

  @override
  List<Object?> get props => [target, condition];
}

/// When a button's parameter value switches.
///
/// Two, not four: a parameter has a value on each side of the change, so Off
/// is On with the two values swapped and Released is Held with them swapped.
enum ExternalValueCondition {
  /// Each completed press toggles between the two values.
  onOff,

  /// A foot on the button applies one value, lifting it applies the other.
  heldReleased;

  /// Parses a persisted [name], or `null` when it names nothing.
  static ExternalValueCondition? tryParse(Object? name) {
    for (final condition in values) {
      if (condition.name == name) return condition;
    }
    return null;
  }
}

/// One parameter a button sets, and the two values it sets it to.
class ExternalParameter extends Equatable {
  /// Creates an [ExternalParameter].
  ///
  /// Both values are required rather than defaulted: the accepted screen adds
  /// a parameter with the value it has NOW on both sides, so adding a mapping
  /// invents no sound change, and only the screen knows what that value is.
  const ExternalParameter({
    required this.target,
    required this.active,
    required this.inactive,
    this.condition = ExternalValueCondition.onOff,
  });

  /// Rebuilds a parameter from its [toJson] map, or `null` when the target
  /// does not decode.
  static ExternalParameter? fromJson(Map<String, dynamic> json) {
    final encoded = json['target'];
    if (encoded is! String) return null;
    final target = ControlValueTarget.tryParse(encoded);
    if (target == null) return null;
    final active = json['active'];
    final inactive = json['inactive'];
    // A stored value with no number in it is not a value to guess at; the row
    // goes rather than setting a knob to something nobody chose.
    if (active is! num || inactive is! num) return null;
    return ExternalParameter(
      target: target,
      active: active.toDouble().clamp(0.0, 1.0),
      inactive: inactive.toDouble().clamp(0.0, 1.0),
      condition:
          ExternalValueCondition.tryParse(json['condition']) ??
          ExternalValueCondition.onOff,
    );
  }

  /// The parameter.
  final ControlValueTarget target;

  /// The value written while the button is on, or held.
  final double active;

  /// The value written while it is off, or released.
  final double inactive;

  /// Which of the button's two facts switches it.
  final ExternalValueCondition condition;

  /// Returns a copy with the given fields replaced.
  ExternalParameter copyWith({
    double? active,
    double? inactive,
    ExternalValueCondition? condition,
  }) => ExternalParameter(
    target: target,
    active: active ?? this.active,
    inactive: inactive ?? this.inactive,
    condition: condition ?? this.condition,
  );

  /// Serializes this parameter.
  Map<String, dynamic> toJson() => {
    'target': target.canonicalString(),
    'active': active,
    'inactive': inactive,
    'condition': condition.name,
  };

  @override
  List<Object?> get props => [target, active, inactive, condition];
}

/// Everything a button controls beside its actions: any number of effects it
/// turns on and off, and any number of parameters it sets.
///
/// One entry per target in each list, for the reason the expression pedal's
/// mappings have one: two rows driving one control would write over each other
/// in an order nothing decides.
class ExternalControls extends Equatable {
  /// Creates an [ExternalControls]. Each list must hold at most one entry per
  /// target; the `with` methods keep that and [ExternalControls.fromJson] drops
  /// a repeat.
  const ExternalControls({
    this.activations = const [],
    this.parameters = const [],
  });

  /// Rebuilds a button's controls from its [toJson] map.
  factory ExternalControls.fromJson(Map<String, dynamic> json) {
    final activations = json['activations'];
    final parameters = json['parameters'];
    final seenActivations = <FxBindingTarget>{};
    final seenParameters = <ControlValueTarget>{};
    return ExternalControls(
      activations: [
        if (activations is List)
          for (final raw in activations)
            if (raw is Map<String, dynamic>)
              if (ExternalActivation.fromJson(raw) case final activation?
                  when seenActivations.add(activation.target))
                activation,
      ],
      parameters: [
        if (parameters is List)
          for (final raw in parameters)
            if (raw is Map<String, dynamic>)
              if (ExternalParameter.fromJson(raw) case final parameter?
                  when seenParameters.add(parameter.target))
                parameter,
      ],
    );
  }

  /// A button that controls nothing.
  static const ExternalControls empty = ExternalControls();

  /// The effects it turns on and off.
  final List<ExternalActivation> activations;

  /// The parameters it sets.
  final List<ExternalParameter> parameters;

  /// Whether there is nothing here worth storing.
  bool get isEmpty => activations.isEmpty && parameters.isEmpty;

  /// Whether any control here reads the physical contact, which a latching
  /// switch cannot report.
  bool get readsContact =>
      activations.any((a) => a.condition.readsContact) ||
      parameters.any((p) => p.condition == ExternalValueCondition.heldReleased);

  /// Returns a copy with [activation] in place of the one on the same target,
  /// or appended when there is none.
  ExternalControls withActivation(ExternalActivation activation) {
    final next = [...activations];
    final at = next.indexWhere((a) => a.target == activation.target);
    if (at < 0) {
      next.add(activation);
    } else {
      next[at] = activation;
    }
    return ExternalControls(activations: next, parameters: parameters);
  }

  /// Returns a copy without the activation on [target].
  ExternalControls withoutActivation(FxBindingTarget target) =>
      ExternalControls(
        activations: [
          for (final a in activations)
            if (a.target != target) a,
        ],
        parameters: parameters,
      );

  /// Returns a copy with [parameter] in place of the one on the same target,
  /// or appended when there is none.
  ExternalControls withParameter(ExternalParameter parameter) {
    final next = [...parameters];
    final at = next.indexWhere((p) => p.target == parameter.target);
    if (at < 0) {
      next.add(parameter);
    } else {
      next[at] = parameter;
    }
    return ExternalControls(activations: activations, parameters: next);
  }

  /// Returns a copy without the parameter on [target].
  ExternalControls withoutParameter(ControlValueTarget target) =>
      ExternalControls(
        activations: activations,
        parameters: [
          for (final p in parameters)
            if (p.target != target) p,
        ],
      );

  /// Serializes these controls, omitting an empty list.
  Map<String, dynamic> toJson() => {
    if (activations.isNotEmpty)
      'activations': [for (final a in activations) a.toJson()],
    if (parameters.isNotEmpty)
      'parameters': [for (final p in parameters) p.toJson()],
  };

  @override
  List<Object?> get props => [activations, parameters];
}
