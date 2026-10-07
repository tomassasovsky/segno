import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_protocol.dart';
import 'package:equatable/equatable.dart';

/// How a mapped MIDI control drives its targets.
enum MidiBehavior {
  /// A knob or fader with per-target pickup.
  continuous,

  /// A button whose targets are held until release.
  momentary,

  /// A button whose accepted presses alternate Off and On.
  toggle,

  /// A Program Change, which has no release.
  trigger;

  /// Parses a saved behavior, or returns null for an unknown value.
  static MidiBehavior? tryParse(Object? name) {
    for (final behavior in values) {
      if (behavior.name == name) return behavior;
    }
    return null;
  }
}

/// Which edge runs an action.
enum MidiEdge {
  /// Run when the control goes down.
  press,

  /// Run when the control comes up.
  release;

  /// Parses a saved edge, or returns null for an unknown value.
  static MidiEdge? tryParse(Object? name) {
    for (final edge in values) {
      if (edge.name == name) return edge;
    }
    return null;
  }
}

/// One target driven by a mapped MIDI source.
///
/// Keys are opaque here. The app resolves stable action and parameter keys.
sealed class MidiControl extends Equatable {
  MidiControl({required this.key}) {
    if (key.isEmpty) throw const FormatException('Invalid MIDI control key');
  }

  /// Decodes one control without dropping malformed fields.
  static MidiControl fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    if (key is! String || key.isEmpty) {
      throw const FormatException('Invalid MIDI control key');
    }
    switch (json['kind']) {
      case 'parameter':
        final low = json['low'];
        final high = json['high'];
        if (low is! num || high is! num) {
          throw const FormatException('Invalid MIDI parameter range');
        }
        return MidiParameterControl(
          key: key,
          low: low.toDouble(),
          high: high.toDouble(),
        );
      case 'action':
        final trigger = MidiEdge.tryParse(json['trigger']);
        if (trigger == null) {
          throw const FormatException('Invalid MIDI action trigger');
        }
        return MidiActionControl(key: key, trigger: trigger);
      default:
        throw const FormatException('Invalid MIDI control kind');
    }
  }

  /// Stable target identity.
  final String key;

  /// Canonical persistence form.
  Map<String, dynamic> toJson();
}

/// A parameter with independent low/high values; reversed ranges are valid.
final class MidiParameterControl extends MidiControl {
  /// Creates a parameter control with finite normalized endpoints.
  MidiParameterControl({
    required super.key,
    required this.low,
    required this.high,
  }) {
    if (!_unit(low) || !_unit(high)) {
      throw const FormatException('Invalid MIDI parameter range');
    }
  }

  /// Value at the source's bottom, release, or Off state.
  final double low;

  /// Value at the source's top, held, or On state.
  final double high;

  /// Copies this control while validating the new endpoints.
  MidiParameterControl copyWith({double? low, double? high}) =>
      MidiParameterControl(
        key: key,
        low: low ?? this.low,
        high: high ?? this.high,
      );

  static bool _unit(double value) => value.isFinite && value >= 0 && value <= 1;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'parameter',
    'key': key,
    'low': low,
    'high': high,
  };

  @override
  List<Object?> get props => [key, low, high];
}

/// An action on an explicit button edge.
final class MidiActionControl extends MidiControl {
  /// Creates an action control.
  MidiActionControl({required super.key, this.trigger = MidiEdge.press});

  /// The edge that runs it.
  final MidiEdge trigger;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'action',
    'key': key,
    'trigger': trigger.name,
  };

  @override
  List<Object?> get props => [key, trigger];
}

/// A generic format/behavior problem, independent of app target availability.
enum MidiMappingProblem {
  /// No controls are assigned.
  noControls,

  /// A continuous source has an action.
  actionNeedsButton,

  /// Behavior does not fit the learned source format.
  behaviorDoesNotFit,

  /// A Program action requests a release that never occurs.
  programHasNoRelease,
}

/// One stable MIDI source and its ordered controls.
class MidiMapping extends Equatable {
  /// Creates a detached, complete, valid mapping.
  factory MidiMapping({
    required String id,
    required MidiSource source,
    required MidiBehavior behavior,
    List<MidiControl> controls = const [],
    bool enabled = true,
  }) {
    if (id.isEmpty) throw const FormatException('Invalid MIDI mapping ID');
    final problem = problemFor(source, behavior, controls);
    if (problem != null) {
      throw FormatException('Invalid MIDI mapping: ${problem.name}');
    }
    if ({for (final control in controls) control.key}.length !=
        controls.length) {
      throw const FormatException('Duplicate MIDI control target');
    }
    return MidiMapping._(
      id,
      source,
      behavior,
      List.unmodifiable(controls),
      enabled,
    );
  }

  const MidiMapping._(
    this.id,
    this.source,
    this.behavior,
    this.controls,
    this.enabled,
  );

  /// Decodes a complete mapping, rejecting malformed explicit fields.
  factory MidiMapping.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final rawSource = json['source'];
    final behavior = MidiBehavior.tryParse(json['behavior']);
    final rawControls = json['controls'];
    final rawEnabled = json['enabled'];
    if (id is! String ||
        id.isEmpty ||
        rawSource is! Map<String, dynamic> ||
        behavior == null ||
        rawControls is! List ||
        (json.containsKey('enabled') && rawEnabled is! bool)) {
      throw const FormatException('Invalid MIDI mapping');
    }
    final source = MidiSource.fromJson(rawSource);
    if (source == null) throw const FormatException('Invalid MIDI source');
    return MidiMapping(
      id: id,
      source: source,
      behavior: behavior,
      enabled: rawEnabled is! bool || rawEnabled,
      controls: [
        for (final raw in rawControls)
          if (raw is Map<String, dynamic>)
            MidiControl.fromJson(raw)
          else
            throw const FormatException('Invalid MIDI control'),
      ],
    );
  }

  /// The stable mapping ID; updates preserve it.
  final String id;

  /// Selected device, channel and explicit wire format.
  final MidiSource source;

  /// The source's movement/edge interpretation.
  final MidiBehavior behavior;

  /// Controls in editor order.
  final List<MidiControl> controls;

  /// Disabled mappings still reserve their source footprint.
  final bool enabled;

  /// Default behavior for a freshly learned source.
  static MidiBehavior defaultBehavior(
    MidiSource source, {
    bool drivesActions = false,
  }) {
    if (source.kind == ControllerSourceKind.midiProgram) {
      return MidiBehavior.trigger;
    }
    if (source.protocol != MidiProtocol.standard) {
      return MidiBehavior.continuous;
    }
    if (source.kind == ControllerSourceKind.midiCc && !drivesActions) {
      return MidiBehavior.continuous;
    }
    return MidiBehavior.momentary;
  }

  /// Generic validity for an unfinished editor draft, before construction.
  static MidiMappingProblem? problemFor(
    MidiSource source,
    MidiBehavior behavior,
    List<MidiControl> controls,
  ) {
    if (controls.isEmpty) return MidiMappingProblem.noControls;
    final program = source.kind == ControllerSourceKind.midiProgram;
    final fits = switch (behavior) {
      MidiBehavior.trigger => program,
      MidiBehavior.continuous =>
        !program && source.kind != ControllerSourceKind.midiNote,
      MidiBehavior.momentary || MidiBehavior.toggle =>
        !program && source.protocol == MidiProtocol.standard,
    };
    if (!fits) return MidiMappingProblem.behaviorDoesNotFit;
    final actions = controls.whereType<MidiActionControl>();
    if (behavior == MidiBehavior.continuous && actions.isNotEmpty) {
      return MidiMappingProblem.actionNeedsButton;
    }
    if (program &&
        actions.any((action) => action.trigger == MidiEdge.release)) {
      return MidiMappingProblem.programHasNoRelease;
    }
    return null;
  }

  /// Copies through the same strict constructor.
  MidiMapping copyWith({
    MidiSource? source,
    MidiBehavior? behavior,
    List<MidiControl>? controls,
    bool? enabled,
  }) => MidiMapping(
    id: id,
    source: source ?? this.source,
    behavior: behavior ?? this.behavior,
    controls: controls ?? this.controls,
    enabled: enabled ?? this.enabled,
  );

  /// Canonical persistence form.
  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source.toJson(),
    'behavior': behavior.name,
    if (!enabled) 'enabled': false,
    'controls': [for (final control in controls) control.toJson()],
  };

  @override
  List<Object?> get props => [id, source, behavior, controls, enabled];
}

/// The immutable, ordered mapping set for the rig.
class MidiMappingSet extends Equatable {
  /// Creates a detached set, rejecting duplicate IDs and overlapping sources.
  factory MidiMappingSet({List<MidiMapping> mappings = const []}) {
    for (final (index, mapping) in mappings.indexed) {
      if (mappings
          .take(index)
          .any(
            (other) =>
                other.id == mapping.id || other.source.overlaps(mapping.source),
          )) {
        throw const FormatException('Duplicate or overlapping MIDI mapping');
      }
    }
    return MidiMappingSet._(List.unmodifiable(mappings));
  }

  const MidiMappingSet._(this.mappings);

  /// Decodes a present payload strictly; absence is handled by Settings.
  factory MidiMappingSet.fromJson(Object? json) {
    if (json is! List) throw const FormatException('Invalid MIDI mappings');
    return MidiMappingSet(
      mappings: [
        for (final raw in json)
          if (raw is Map<String, dynamic>)
            MidiMapping.fromJson(raw)
          else
            throw const FormatException('Invalid MIDI mapping'),
      ],
    );
  }

  /// Fresh empty set.
  static const MidiMappingSet empty = MidiMappingSet._([]);

  /// Mappings in editor order.
  final List<MidiMapping> mappings;

  /// Returns the mapping with [id], if present.
  MidiMapping? byId(String id) {
    for (final mapping in mappings) {
      if (mapping.id == id) return mapping;
    }
    return null;
  }

  /// Returns an overlapping mapping, including disabled rows.
  MidiMapping? conflictWith(MidiSource source, {String? exceptId}) {
    for (final mapping in mappings) {
      if (mapping.id == exceptId) continue;
      if (mapping.source.overlaps(source)) return mapping;
    }
    return null;
  }

  /// Replaces a matching ID or appends, preserving order and strict invariants.
  MidiMappingSet withMapping(MidiMapping mapping) {
    final next = [...mappings];
    final at = next.indexWhere((item) => item.id == mapping.id);
    if (at < 0) {
      next.add(mapping);
    } else {
      next[at] = mapping;
    }
    return MidiMappingSet(mappings: next);
  }

  /// Removes [id] without touching other mappings.
  MidiMappingSet withoutMapping(String id) => MidiMappingSet(
    mappings: [
      for (final mapping in mappings)
        if (mapping.id != id) mapping,
    ],
  );

  /// Canonical persistence form.
  List<Map<String, dynamic>> toJson() => [
    for (final mapping in mappings) mapping.toJson(),
  ];

  @override
  List<Object?> get props => [mappings];
}
