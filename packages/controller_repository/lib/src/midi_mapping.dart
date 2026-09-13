import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_protocol.dart';
import 'package:equatable/equatable.dart';

/// How a mapped control's messages drive its targets.
enum MidiBehavior {
  /// A knob or fader: every reading sweeps each parameter between its two
  /// values, once it has caught up with where the parameter already is.
  continuous,

  /// A button held for as long as it is down.
  momentary,

  /// A button that flips on each press.
  toggle,

  /// A Program Change: every message is a press, and nothing is ever
  /// released.
  trigger;

  /// Parses a persisted [name], or `null` when it names nothing.
  static MidiBehavior? tryParse(Object? name) {
    for (final behavior in values) {
      if (behavior.name == name) return behavior;
    }
    return null;
  }
}

/// Which edge of a button an action runs on.
enum MidiEdge {
  /// The control going down.
  press,

  /// The control coming up.
  release;

  /// Parses a persisted [name], or `null` when it names nothing.
  static MidiEdge? tryParse(Object? name) {
    for (final edge in values) {
      if (edge.name == name) return edge;
    }
    return null;
  }
}

/// One thing a mapped control drives.
///
/// Its [key] is OPAQUE here: a parameter's canonical target string, or an
/// action's catalogue key. This package never decodes either, which is what
/// keeps it free of the looper and of the app's action vocabulary.
sealed class MidiControl extends Equatable {
  const MidiControl({required this.key});

  /// Rebuilds a control from its [toJson] map, or `null` when the map does
  /// not describe one.
  static MidiControl? fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    if (key is! String || key.isEmpty) return null;
    switch (json['kind']) {
      case 'parameter':
        final low = _unit(json['low']);
        final high = _unit(json['high']);
        if (low == null || high == null) return null;
        return MidiParameterControl(key: key, low: low, high: high);
      case 'action':
        final trigger = MidiEdge.tryParse(json['trigger']);
        if (trigger == null) return null;
        return MidiActionControl(key: key, trigger: trigger);
    }
    return null;
  }

  static double? _unit(Object? raw) {
    if (raw is! num) return null;
    final value = raw.toDouble();
    if (value.isNaN || value < 0 || value > 1) return null;
    return value;
  }

  /// What it drives, as an opaque key.
  final String key;

  /// Serializes this control.
  Map<String, dynamic> toJson();
}

/// A parameter swept between [low] and [high].
///
/// On a knob the two are the control's bottom and top; on a momentary button
/// they are Released and Held, on a toggle Off and On. Either may be the
/// larger: a range running backwards is how a control inverts a parameter.
final class MidiParameterControl extends MidiControl {
  /// Creates a [MidiParameterControl].
  const MidiParameterControl({
    required super.key,
    required this.low,
    required this.high,
  });

  /// The value at the bottom of a knob, or with a button up or off.
  final double low;

  /// The value at the top, or with a button down or on.
  final double high;

  /// Returns a copy with the given values replaced.
  MidiParameterControl copyWith({double? low, double? high}) =>
      MidiParameterControl(
        key: key,
        low: low ?? this.low,
        high: high ?? this.high,
      );

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

/// An action run on one edge of a button.
final class MidiActionControl extends MidiControl {
  /// Creates a [MidiActionControl].
  const MidiActionControl({required super.key, this.trigger = MidiEdge.press});

  /// The edge it runs on.
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

/// Why a mapping cannot be saved as it stands.
enum MidiMappingProblem {
  /// Nothing has been learned yet.
  noSource,

  /// Nothing is driven yet.
  noControls,

  /// A 14-bit, NRPN or relative control drives an action. Those formats carry
  /// a position, not a press, so there is no edge to run one on.
  actionNeedsButton,

  /// The behavior does not fit the message: a Program is a trigger and
  /// nothing else, a Note is a button, and a high-resolution or relative
  /// format is continuous.
  behaviorDoesNotFit,

  /// A Program Change action set to run on release, which a Program never
  /// has.
  programHasNoRelease,
}

/// One mapped MIDI control: its source and everything it drives.
class MidiMapping extends Equatable {
  /// Creates a [MidiMapping].
  const MidiMapping({
    required this.id,
    required this.source,
    required this.behavior,
    this.controls = const [],
    this.enabled = true,
  });

  /// Rebuilds a mapping from its [toJson] map, or `null` when the map does not
  /// describe one.
  static MidiMapping? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final rawSource = json['source'];
    final behavior = MidiBehavior.tryParse(json['behavior']);
    final rawControls = json['controls'];
    if (id is! String || id.isEmpty || behavior == null) return null;
    if (rawSource is! Map<String, dynamic>) return null;
    final source = MidiSource.fromJson(rawSource);
    if (source == null) return null;
    return MidiMapping(
      id: id,
      source: source,
      behavior: behavior,
      enabled: json['enabled'] != false,
      controls: [
        if (rawControls is List)
          for (final raw in rawControls)
            if (raw is Map<String, dynamic>) ?MidiControl.fromJson(raw),
      ],
    );
  }

  /// Stable identity, which no edit rewrites.
  final String id;

  /// The control it reads.
  final MidiSource source;

  /// How its messages drive the [controls].
  final MidiBehavior behavior;

  /// Everything it drives.
  final List<MidiControl> controls;

  /// Whether it dispatches. A disabled mapping keeps its source — and still
  /// refuses an overlapping one.
  final bool enabled;

  /// The behavior a freshly learned [source] starts with.
  ///
  /// A Program is a trigger. A high-resolution or relative control is a knob.
  /// A standard CC is a knob unless the mapping already drives an action; a
  /// Note is a momentary button.
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

  /// The first reason this mapping cannot be saved, or `null` when it can.
  MidiMappingProblem? get problem {
    if (!source.isValid) return MidiMappingProblem.noSource;
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
    if (program && actions.any((a) => a.trigger == MidiEdge.release)) {
      return MidiMappingProblem.programHasNoRelease;
    }
    return null;
  }

  /// Returns a copy with the given fields replaced.
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

  /// Serializes this mapping.
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

/// Every MIDI mapping on the rig.
class MidiMappingSet extends Equatable {
  /// Creates a [MidiMappingSet].
  const MidiMappingSet({this.mappings = const []});

  /// Rebuilds a set from its [toJson] list, dropping any entry that does not
  /// decode and any that overlaps one kept before it.
  factory MidiMappingSet.fromJson(Object? json) {
    final kept = <MidiMapping>[];
    if (json is List) {
      for (final raw in json) {
        if (raw is! Map<String, dynamic>) continue;
        final mapping = MidiMapping.fromJson(raw);
        if (mapping == null) continue;
        // A stored file that holds two overlapping sources is corruption, not
        // a choice: saving refuses it, so reading one keeps the first.
        if (kept.any((m) => m.id == mapping.id)) continue;
        if (kept.any((m) => m.source.overlaps(mapping.source))) continue;
        kept.add(mapping);
      }
    }
    return MidiMappingSet(mappings: List.unmodifiable(kept));
  }

  /// The mappings, in the order they were added.
  final List<MidiMapping> mappings;

  /// The mapping with [id], or `null`.
  MidiMapping? byId(String id) {
    for (final mapping in mappings) {
      if (mapping.id == id) return mapping;
    }
    return null;
  }

  /// The saved mapping [source] would overlap, or `null`.
  ///
  /// Disabled mappings count. A disabled mapping keeps its source so it can be
  /// turned back on, and it could not be if something else had taken that
  /// source in the meantime.
  MidiMapping? conflictWith(MidiSource source, {String? exceptId}) {
    for (final mapping in mappings) {
      if (mapping.id == exceptId) continue;
      if (mapping.source.overlaps(source)) return mapping;
    }
    return null;
  }

  /// Returns a copy with [mapping] in place of the one with its id, or added.
  ///
  /// Throws [ArgumentError] when the mapping overlaps another or cannot be
  /// saved as it stands — the screen checks both before offering Save, so
  /// reaching this with either is a programming error, not a user one.
  MidiMappingSet withMapping(MidiMapping mapping) {
    if (mapping.problem case final problem?) {
      throw ArgumentError.value(mapping.id, 'mapping', problem.name);
    }
    if (conflictWith(mapping.source, exceptId: mapping.id) != null) {
      throw ArgumentError.value(mapping.id, 'mapping', 'overlaps');
    }
    final next = [...mappings];
    final at = next.indexWhere((m) => m.id == mapping.id);
    if (at < 0) {
      next.add(mapping);
    } else {
      next[at] = mapping;
    }
    return MidiMappingSet(mappings: List.unmodifiable(next));
  }

  /// Returns a copy without the mapping [id].
  MidiMappingSet withoutMapping(String id) => MidiMappingSet(
    mappings: List.unmodifiable([
      for (final mapping in mappings)
        if (mapping.id != id) mapping,
    ]),
  );

  /// Serializes the set.
  List<Map<String, dynamic>> toJson() => [
    for (final mapping in mappings) mapping.toJson(),
  ];

  @override
  List<Object?> get props => [mappings];
}
