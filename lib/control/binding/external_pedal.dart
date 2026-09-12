import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/pedal_setup.dart';

/// One of the console's two external control jacks.
enum ExternalJack {
  /// CTRL 1.
  ctrl1,

  /// CTRL 2.
  ctrl2;

  /// Parses a persisted [name], or `null` when it names neither jack.
  static ExternalJack? fromName(String? name) {
    for (final jack in values) {
      if (jack.name == name) return jack;
    }
    return null;
  }
}

/// What is plugged into a jack.
///
/// A jack keeps the assignments for every type it has been configured as, so
/// switching to Dual switch and back does not cost the single switch its
/// actions. Only the active type is dispatched.
enum ExternalJackType {
  /// A continuous pedal on a potentiometer.
  expression,

  /// One switch.
  singleSwitch,

  /// Two switches on a ring-tip-sleeve jack.
  dualSwitch;

  /// How many switches this type puts under the foot.
  int get switchCount => switch (this) {
    ExternalJackType.expression => 0,
    ExternalJackType.singleSwitch => 1,
    ExternalJackType.dualSwitch => 2,
  };

  /// Parses a persisted [name], defaulting to [singleSwitch] — what a jack
  /// with nothing plugged in opens on, and the commonest external pedal.
  static ExternalJackType fromName(String? name) {
    for (final type in values) {
      if (type.name == name) return type;
    }
    return ExternalJackType.singleSwitch;
  }
}

/// How an external switch reports its contact.
///
/// The distinction is not a preference: it decides which gestures a switch can
/// carry at all. A momentary switch reports a closure and a release, so it has
/// a press and a hold. A latching switch reports only that its state changed,
/// so there is nothing to time a hold against and it carries one action.
enum ExternalSwitchHardware {
  /// Closes while held and opens on release.
  momentary,

  /// Flips and stays.
  latching;

  /// Parses a persisted [name], defaulting to [momentary].
  static ExternalSwitchHardware fromName(String? name) {
    for (final hardware in values) {
      if (hardware.name == name) return hardware;
    }
    return ExternalSwitchHardware.momentary;
  }
}

/// One external switch: what kind it is, and what it does.
class ExternalSwitchSetup extends Equatable {
  /// Creates an [ExternalSwitchSetup].
  const ExternalSwitchSetup({
    this.hardware = ExternalSwitchHardware.momentary,
    this.gestures = ControlGesturePair.empty,
    this.change,
  });

  /// Rebuilds a switch from its [toJson] map.
  factory ExternalSwitchSetup.fromJson(Map<String, dynamic> json) {
    final change = json['change'];
    return ExternalSwitchSetup(
      hardware: ExternalSwitchHardware.fromName(json['hardware'] as String?),
      gestures: ControlGesturePair.fromJson(json),
      change: change is String ? ControlAction.tryParse(change) : null,
    );
  }

  /// The switch with nothing on it.
  static const ExternalSwitchSetup empty = ExternalSwitchSetup();

  /// What the hardware is.
  final ExternalSwitchHardware hardware;

  /// What a press and a hold do, when [hardware] is momentary.
  final ControlGesturePair gestures;

  /// What a state change does, when [hardware] is latching.
  final ControlAction? change;

  /// Whether this switch is exactly as it shipped, and so has nothing worth
  /// storing.
  ///
  /// The HARDWARE counts. Telling the rig a latching switch is plugged in is
  /// a setting in its own right, and a switch that read as empty until it
  /// carried an action would lose that the moment it was chosen.
  ///
  /// Both gesture halves are kept whatever the hardware is, so a switch
  /// retyped to latching and back finds its press and hold where it left
  /// them; this asks whether any of them is set, not whether the active one
  /// is.
  bool get isEmpty =>
      hardware == ExternalSwitchHardware.momentary &&
      gestures.isEmpty &&
      change == null;

  /// The action the ACTIVE hardware runs on a plain closure.
  ControlAction? get closureAction =>
      hardware == ExternalSwitchHardware.latching ? change : gestures.press;

  /// Returns a copy with the given fields replaced; [clearChange] drops the
  /// latching action, which `change: null` cannot express.
  ExternalSwitchSetup copyWith({
    ExternalSwitchHardware? hardware,
    ControlGesturePair? gestures,
    ControlAction? change,
    bool clearChange = false,
  }) => ExternalSwitchSetup(
    hardware: hardware ?? this.hardware,
    gestures: gestures ?? this.gestures,
    change: clearChange ? null : change ?? this.change,
  );

  /// Serializes this switch, omitting anything unassigned.
  Map<String, dynamic> toJson() => {
    'hardware': hardware.name,
    ...gestures.toJson(),
    if (change != null) 'change': change!.key,
  };

  @override
  List<Object?> get props => [hardware, gestures, change];
}

/// One jack: which type is active, and the switches configured for each.
///
/// Every type's assignments are kept side by side. The accepted design is
/// explicit that choosing another type retains the others, and a jack that
/// forgot them would punish a performer for plugging in a different pedal for
/// one song.
class ExternalJackSetup extends Equatable {
  /// Creates an [ExternalJackSetup].
  const ExternalJackSetup({
    this.type = ExternalJackType.singleSwitch,
    this.single = ExternalSwitchSetup.empty,
    this.dualFirst = ExternalSwitchSetup.empty,
    this.dualSecond = ExternalSwitchSetup.empty,
  });

  /// Rebuilds a jack from its [toJson] map.
  factory ExternalJackSetup.fromJson(Map<String, dynamic> json) {
    ExternalSwitchSetup read(String key) {
      final raw = json[key];
      return raw is Map<String, dynamic>
          ? ExternalSwitchSetup.fromJson(raw)
          : ExternalSwitchSetup.empty;
    }

    return ExternalJackSetup(
      type: ExternalJackType.fromName(json['type'] as String?),
      single: read('single'),
      dualFirst: read('dualFirst'),
      dualSecond: read('dualSecond'),
    );
  }

  /// The jack as it ships.
  static const ExternalJackSetup empty = ExternalJackSetup();

  /// Which type is plugged in, and therefore which assignments dispatch.
  final ExternalJackType type;

  /// The switch used when [type] is [ExternalJackType.singleSwitch].
  final ExternalSwitchSetup single;

  /// The first of the two switches on a dual pedal.
  final ExternalSwitchSetup dualFirst;

  /// The second of them.
  final ExternalSwitchSetup dualSecond;

  /// The switch at [index] under the ACTIVE type, or `null` when the active
  /// type has no such switch.
  ExternalSwitchSetup? switchAt(int index) => switch (type) {
    ExternalJackType.expression => null,
    ExternalJackType.singleSwitch => index == 0 ? single : null,
    ExternalJackType.dualSwitch => switch (index) {
      0 => dualFirst,
      1 => dualSecond,
      _ => null,
    },
  };

  /// Returns a copy with [setup] at [index] under the active type; an index
  /// the active type has no switch for is ignored rather than inventing one.
  ExternalJackSetup withSwitch(int index, ExternalSwitchSetup setup) =>
      switch (type) {
        ExternalJackType.expression => this,
        ExternalJackType.singleSwitch =>
          index == 0 ? copyWith(single: setup) : this,
        ExternalJackType.dualSwitch => switch (index) {
          0 => copyWith(dualFirst: setup),
          1 => copyWith(dualSecond: setup),
          _ => this,
        },
      };

  /// Whether anything is configured here, under any type.
  bool get isEmpty =>
      type == ExternalJackType.singleSwitch &&
      single.isEmpty &&
      dualFirst.isEmpty &&
      dualSecond.isEmpty;

  /// Returns a copy with the given fields replaced.
  ExternalJackSetup copyWith({
    ExternalJackType? type,
    ExternalSwitchSetup? single,
    ExternalSwitchSetup? dualFirst,
    ExternalSwitchSetup? dualSecond,
  }) => ExternalJackSetup(
    type: type ?? this.type,
    single: single ?? this.single,
    dualFirst: dualFirst ?? this.dualFirst,
    dualSecond: dualSecond ?? this.dualSecond,
  );

  /// Serializes this jack, omitting the switches nothing has touched.
  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (!single.isEmpty) 'single': single.toJson(),
    if (!dualFirst.isEmpty) 'dualFirst': dualFirst.toJson(),
    if (!dualSecond.isEmpty) 'dualSecond': dualSecond.toJson(),
  };

  @override
  List<Object?> get props => [type, single, dualFirst, dualSecond];
}

/// Both external jacks.
///
/// One value, because the accepted screen saves both ports as one draft.
class ExternalPedalSetup extends Equatable {
  /// Creates an [ExternalPedalSetup].
  const ExternalPedalSetup({
    this.jacks = const <ExternalJack, ExternalJackSetup>{},
  });

  /// Rebuilds both jacks from their [toJson] map.
  factory ExternalPedalSetup.fromJson(Map<String, dynamic> json) {
    final jacks = <ExternalJack, ExternalJackSetup>{};
    for (final jack in ExternalJack.values) {
      final raw = json[jack.name];
      if (raw is! Map<String, dynamic>) continue;
      final setup = ExternalJackSetup.fromJson(raw);
      if (setup.isEmpty) continue;
      jacks[jack] = setup;
    }
    return ExternalPedalSetup(jacks: Map.unmodifiable(jacks));
  }

  /// The jacks that carry something; an absent one is
  /// [ExternalJackSetup.empty].
  final Map<ExternalJack, ExternalJackSetup> jacks;

  /// What is on [jack].
  ExternalJackSetup forJack(ExternalJack jack) =>
      jacks[jack] ?? ExternalJackSetup.empty;

  /// Returns a copy with [setup] on [jack]; an empty jack drops its entry, so
  /// a jack set back to how it shipped encodes like one never touched.
  ExternalPedalSetup withJack(ExternalJack jack, ExternalJackSetup setup) {
    final next = {...jacks};
    if (setup.isEmpty) {
      next.remove(jack);
    } else {
      next[jack] = setup;
    }
    return ExternalPedalSetup(jacks: Map.unmodifiable(next));
  }

  /// Whether either jack carries anything.
  bool get isEmpty => jacks.isEmpty;

  /// Serializes both jacks in a fixed order.
  Map<String, dynamic> toJson() => {
    for (final jack in ExternalJack.values)
      if (jacks.containsKey(jack)) jack.name: jacks[jack]!.toJson(),
  };

  @override
  List<Object?> get props => [
    // Ordered, not the map: two setups built in different insertion orders
    // must compare equal, which a Map does not promise through Equatable.
    for (final jack in ExternalJack.values) jacks[jack],
  ];
}
