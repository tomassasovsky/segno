import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// What a HOLD on Record / Play does.
///
/// A closed list rather than the catalogue: Record / Play keeps its
/// immediate-contact press whatever is on its hold, so the hold can only
/// carry something that makes sense *after* the press has already fired.
enum RecordHold {
  /// Nothing. The switch is a plain contact again.
  none,

  /// Undo the take the press just started, or the track's latest layer.
  undoRecording;

  /// Parses a persisted [token], defaulting to [undoRecording] — the accepted
  /// default, so an absent value reads as the shipped behaviour.
  static RecordHold fromToken(String? token) => values.firstWhere(
    (value) => value.name == token,
    orElse: () => RecordHold.undoRecording,
  );
}

/// What a HOLD on one of the four track footswitches does.
///
/// Closed for the same reason as [RecordHold]: track selection keeps its
/// immediate-contact press, so the hold is an addition to it rather than an
/// alternative.
enum TrackHold {
  /// Nothing.
  none,

  /// Start overdubbing the held track — a no-op on a track with no loop yet,
  /// because "arm overdub" on empty would mean "record", and the press
  /// already covers that.
  armOverdub,

  /// Erase the held track's audio.
  clearTrack;

  /// Parses a persisted [token], defaulting to [armOverdub].
  static TrackHold fromToken(String? token) => values.firstWhere(
    (value) => value.name == token,
    orElse: () => TrackHold.armOverdub,
  );
}

/// One control's Press and Hold assignments.
///
/// Both halves are optional and independent. A pair with a [hold] moves its
/// press to the release, because until the threshold passes neither half is
/// known to be the one the foot meant; a pair without one presses on contact.
/// That rule lives in `ControlCubit`, where the gestures are; this is the
/// data it reads.
class ControlGesturePair extends Equatable {
  /// Creates a [ControlGesturePair].
  const ControlGesturePair({this.press, this.hold});

  /// Rebuilds a pair from its [toJson] map. Halves that no longer name an
  /// action decode to `null` — a broken assignment, which the setup screen
  /// shows as unassigned rather than silently re-pointing.
  factory ControlGesturePair.fromJson(Map<String, dynamic> json) {
    final press = json['press'];
    final hold = json['hold'];
    return ControlGesturePair(
      press: press is String ? ControlAction.tryParse(press) : null,
      hold: hold is String ? ControlAction.tryParse(hold) : null,
    );
  }

  /// The pair with nothing on either gesture.
  static const ControlGesturePair empty = ControlGesturePair();

  /// What a press does, or `null` when the press is unassigned.
  final ControlAction? press;

  /// What a hold does, or `null` when the switch carries only a press.
  final ControlAction? hold;

  /// Whether either gesture carries an action.
  bool get isEmpty => press == null && hold == null;

  /// Returns a copy with [press] replaced, `null` clearing it.
  ControlGesturePair withPress(ControlAction? press) =>
      ControlGesturePair(press: press, hold: hold);

  /// Returns a copy with [hold] replaced, `null` clearing it.
  ControlGesturePair withHold(ControlAction? hold) =>
      ControlGesturePair(press: press, hold: hold);

  /// Serializes this pair, omitting an unassigned half.
  Map<String, dynamic> toJson() => {
    if (press != null) 'press': press!.key,
    if (hold != null) 'hold': hold!.key,
  };

  @override
  List<Object?> get props => [press, hold];
}

/// The built-in footswitch setup: everything the accepted Pedals screen edits.
///
/// Two halves, because the accepted screen has two contexts.
///
/// **Track controls** is the fixed plate, with a few configurable gestures on
/// it: which mode MODE reaches with a press and with a hold, and what a hold
/// adds to Record / Play and to a track switch. Everything else there is
/// fixed and dimmed — Stop, Undo, Clear and Bank mean one thing, and the
/// design is explicit that they keep it.
///
/// **Custom controls** is the free map: eight switches, each with its own
/// Press and Hold drawn from the shared [ControlAction] catalogue. The four
/// track switches carry a pair PER BANK (the same [PedalBindingKey] rule the
/// FX remap uses); the four transport switches carry one pair whatever the
/// bank, because the accepted design says shared transport assignments do not
/// duplicate across banks.
///
/// Pure data: no cubit, repository or engine dependency, so the same value is
/// the settings payload and the thing `ControlCubit` dispatches against.
class PedalSetup extends Equatable {
  /// Creates a [PedalSetup].
  ///
  /// The defaults are the accepted ones: MODE presses to Mute, and its hold
  /// is the FX door.
  const PedalSetup({
    this.modePress = InteractionMode.mute,
    this.modeHold = InteractionMode.fx,
    this.recordHold = RecordHold.undoRecording,
    this.trackHold = TrackHold.armOverdub,
    this.custom = const <PedalBindingKey, ControlGesturePair>{},
  });

  /// Rebuilds a setup from its [encode] string.
  ///
  /// Never throws and never fails: an unparseable blob degrades to the
  /// accepted defaults, and an entry that names nothing this build can do is
  /// dropped. The pedal has to work at boot whatever a settings file holds.
  factory PedalSetup.decode(String encoded) {
    if (encoded.isEmpty) return const PedalSetup();
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return const PedalSetup();
    }
    if (raw is! Map<String, dynamic>) return const PedalSetup();
    final custom = <PedalBindingKey, ControlGesturePair>{};
    final entries = raw['custom'];
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) continue;
        final key = PedalBindingKey.fromJson(entry);
        if (key == null) continue;
        final pair = ControlGesturePair.fromJson(entry);
        if (pair.isEmpty) continue;
        custom[key] = pair;
      }
    }
    return PedalSetup(
      modePress: _mode(raw['modePress']) ?? InteractionMode.mute,
      modeHold: _mode(raw['modeHold']),
      recordHold: RecordHold.fromToken(raw['recordHold'] as String?),
      trackHold: TrackHold.fromToken(raw['trackHold'] as String?),
      custom: Map.unmodifiable(custom),
    );
  }

  /// The modes MODE can be assigned to reach.
  ///
  /// Every mode a foot can enter. `record` is in it because the accepted
  /// catalogue's `Exit` IS the Tracks mode, and a MODE press assigned to it
  /// is how a performer who never uses Mute keeps one switch that always
  /// goes home.
  static const List<InteractionMode> modeChoices = InteractionMode.values;

  /// Which mode a MODE press reaches — or leaves, when the rig is already in
  /// it. Never null: the switch always means something.
  final InteractionMode modePress;

  /// Which mode a MODE hold reaches, or `null` when MODE carries no hold.
  final InteractionMode? modeHold;

  /// What a Record / Play hold does.
  final RecordHold recordHold;

  /// What a track-switch hold does. One setting for all four switches: the
  /// accepted design edits them as one group.
  final TrackHold trackHold;

  /// The Custom-controls map, keyed exactly like the FX remap.
  final Map<PedalBindingKey, ControlGesturePair> custom;

  /// The pair on [button] within [bank], or [ControlGesturePair.empty].
  ///
  /// [bank] is consulted only for a bank-keyed control, so a caller can pass
  /// the live bank unconditionally.
  ControlGesturePair customFor(PedalButton button, {required int bank}) =>
      custom[PedalBindingKey(
        button: button,
        bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
      )] ??
      ControlGesturePair.empty;

  /// Whether any Custom control carries an assignment — what enables the
  /// accepted Clear custom assignments action.
  bool get hasCustomAssignments => custom.values.any((p) => !p.isEmpty);

  /// Returns a copy with [pair] on [button] within [bank]; an empty pair
  /// removes the entry, so a cleared switch and a never-touched one encode
  /// identically.
  PedalSetup withCustom(
    PedalButton button, {
    required int bank,
    required ControlGesturePair pair,
  }) {
    if (PedalBindingKey.unbindable.contains(button)) return this;
    final key = PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
    );
    final next = {...custom};
    if (pair.isEmpty) {
      next.remove(key);
    } else {
      next[key] = pair;
    }
    return copyWith(custom: Map.unmodifiable(next));
  }

  /// The setup with every Custom assignment gone, on both banks and both
  /// gestures, and the fixed Track controls untouched.
  PedalSetup clearedCustom() =>
      copyWith(custom: const <PedalBindingKey, ControlGesturePair>{});

  /// Returns a copy with the given fields replaced.
  ///
  /// [clearModeHold] drops the MODE hold, which `modeHold: null` cannot
  /// express.
  PedalSetup copyWith({
    InteractionMode? modePress,
    InteractionMode? modeHold,
    RecordHold? recordHold,
    TrackHold? trackHold,
    Map<PedalBindingKey, ControlGesturePair>? custom,
    bool clearModeHold = false,
  }) => PedalSetup(
    modePress: modePress ?? this.modePress,
    modeHold: clearModeHold ? null : modeHold ?? this.modeHold,
    recordHold: recordHold ?? this.recordHold,
    trackHold: trackHold ?? this.trackHold,
    custom: custom ?? this.custom,
  );

  /// The canonical encoding. Byte-stable for equal setups — the Custom
  /// entries are ordered by control, so a map that changed only in iteration
  /// order never looks like an edit.
  String encode() => jsonEncode({
    'modePress': ModeAction(modePress).token,
    if (modeHold != null) 'modeHold': ModeAction(modeHold!).token,
    'recordHold': recordHold.name,
    'trackHold': trackHold.name,
    if (custom.isNotEmpty)
      'custom': [
        for (final key in _orderedCustomKeys())
          {...key.toJson(), ...custom[key]!.toJson()},
      ],
  });

  List<PedalBindingKey> _orderedCustomKeys() {
    final keys = custom.keys.toList()
      ..sort((a, b) {
        final button = a.button.index.compareTo(b.button.index);
        if (button != 0) return button;
        return (a.bank ?? -1).compareTo(b.bank ?? -1);
      });
    return keys;
  }

  static InteractionMode? _mode(Object? raw) {
    if (raw is! String) return null;
    final action = ControlAction.tryParse('mode:$raw');
    return action is ModeAction ? action.mode : null;
  }

  @override
  List<Object?> get props => [
    modePress,
    modeHold,
    recordHold,
    trackHold,
    // An ORDERED flattening of the map, not the map itself: two setups built
    // in different insertion orders must compare equal, which a Map does not
    // promise through Equatable. Not the encoding either — this is compared
    // whenever a fresh setup reaches the state, and encoding JSON to answer
    // "did it change" is work the answer does not need.
    for (final key in _orderedCustomKeys()) ...[
      key,
      custom[key]!.press,
      custom[key]!.hold,
    ],
  ];
}
